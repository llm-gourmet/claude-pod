# Phase 18: Platform Abstraction & Bash Portability - Research

**Researched:** 2026-04-13
**Domain:** Shell portability (bash 3.2 vs 5.x), BSD vs GNU userland, macOS platform detection
**Confidence:** HIGH

## Summary

Phase 18 is a **foundation / plumbing** phase. Nothing in it requires new libraries or architectural decisions: every item is a small, targeted shell-portability fix plus one new library file (`lib/platform.sh`). The real risk is not difficulty, it is **completeness** — a single missed BSD/bash 3.2 difference anywhere in the hot path (installer, CLI wrapper, hook) turns into a silent wrong-answer failure on macOS that v3.0 cannot tolerate.

The work splits cleanly into four parallel-safe workstreams: (1) build `lib/platform.sh` with `detect_platform()` + `CLAUDE_SECURE_PLATFORM_OVERRIDE` and unit tests, (2) patch `install.sh` to bootstrap Homebrew deps and fail loudly when missing, (3) audit every host-side `.sh` file for BSD/bash-3.2 hazards and either PATH-shim GNU tools or rewrite the offending line, (4) replace the lone `flock` usage in `bin/claude-secure` reaper with an `mkdir`-based atomic lock. The v2.0 code surface area is small enough (three host scripts totalling ~2,700 lines + 14 test scripts) that a one-pass grep audit is tractable.

**Primary recommendation:** Build `lib/platform.sh` first and make it the single source of truth. Every subsequent script in Phase 18 sources it at the top, calls `claude_secure_bootstrap_path` (which re-execs into brew bash 5 and prepends `gnubin` on macOS), and from that line forward operates as if it were on Linux. Do **not** litter scripts with inline `case "$(uname)"` branches — funnel everything through one library.

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase — no explicit user decisions locked in. All recommendations below are Claude's discretion per the default `discuss_mode: discuss` workflow. Phase description goal and five numbered success criteria in the ROADMAP are treated as hard requirements (equivalent to locked decisions).

### Deferred Ideas (OUT OF SCOPE)
- PLAT-01 (single-command install completes on macOS) — anchored to Phase 21 per roadmap decision
- PLAT-05 (Docker Desktop ≥ 4.44.3 check) — anchored to Phase 19 per roadmap decision
- COMPAT-01 (validator `python:3.11-slim-bookworm` base image swap) — anchored to Phase 19
- ENFORCE-* (iptables-vs-pf decision) — anchored to Phase 20
- SVC-* (launchd daemon files) — anchored to Phase 21
- Auto-installing Homebrew itself — PLAT-03 explicitly says "detect and print instructions, do not auto-install"
- Rewriting webhook/listener.py for macOS — this phase is host-side shell scripts only; Python is already cross-platform

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PLAT-02 | Installer detects platform via shared `lib/platform.sh` with `detect_platform()`; `CLAUDE_SECURE_PLATFORM_OVERRIDE` for CI mocking | §Standard Stack (uname/proc detection), §Code Examples (platform.sh reference impl) |
| PLAT-03 | Installer verifies Homebrew presence on macOS; prints actionable install instructions if missing (does NOT auto-install) | §Code Examples (Homebrew detection block), §Common Pitfalls #1 |
| PLAT-04 | Installer bootstraps GNU tools (`brew install bash coreutils jq`) before any other macOS step | §Code Examples (dep bootstrap), §Architecture Patterns (bootstrap ordering) |
| PORT-01 | All host scripts prepend `$(brew --prefix)/libexec/gnubin` (and coreutils-specific gnubin) to PATH on macOS | §Code Examples (PATH shim), §Common Pitfalls #3 (brew prefix differs by arch) |
| PORT-02 | Host scripts using bash 4+ features re-exec into brew bash 5 on macOS | §Code Examples (re-exec pattern), §Common Pitfalls #2 (bash 3.2 failure modes) |
| PORT-03 | All host-side scripts audited for `flock`; replaced with `mkdir`-based atomic locking | §Runtime State Inventory, §Code Examples (mkdir lock), §Common Pitfalls #4 |
| PORT-04 | Hook call-ID generation normalizes `uuidgen` output to lowercase on macOS | §Common Pitfalls #5, §Code Examples (uuidgen normalization) — **note: hook runs in Debian container, not on host; see Architecture Patterns** |
| TEST-01 | `CLAUDE_SECURE_PLATFORM_OVERRIDE` allows Linux CI to mock macOS code paths | §Code Examples (override semantics), §Validation Architecture (unit tests) |

## Project Constraints (from CLAUDE.md)

Directives extracted from `/home/igor9000/claude-secure/CLAUDE.md` that constrain this phase:

1. **Platform scope:** "Must work on Linux (native) and WSL2 — no macOS Docker Desktop support needed" — NOTE: this line in CLAUDE.md is **stale** as of the v3.0 milestone start. Phase 18 explicitly adds macOS support. The planner should flag this for an update as part of the milestone closeout (not this phase). For Phase 18, treat v3.0 as the authoritative intent.
2. **Host dependencies:** Docker, Docker Compose, curl, jq, uuidgen must be on the host — Phase 18 adds `bash` (via brew) and `coreutils` to this list for macOS only.
3. **Bash hooks:** "bash + jq + curl + uuidgen is sufficient and has faster startup" — confirms the hook layer stays bash (no Python rewrite) and PORT-04 is an in-place normalization, not a language swap.
4. **No supply-chain additions to the proxy:** PORT fixes must not introduce new runtime dependencies to proxy or validator containers. All fixes are host-side only. (Validator base image swap is Phase 19, not here.)
5. **Security posture:** "Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process" — the `lib/platform.sh` file, once installed under `/etc/claude-secure/` or equivalent, must follow the same ownership/immutability rules. Applies only if it's installed into the container; if it's purely host-side it lives under `$app_dir` with the other installer files.
6. **`run-tests.sh` exists:** Pre-push hook runs the full test selection. Phase 18's new unit tests for `platform.sh` must hook into this runner, not live as orphan files.

## Standard Stack

Phase 18 is explicitly a **no-new-dependencies** phase for runtime code. The "stack" is the tooling that must be **present on the host** after installer bootstrap.

### Core (host requirements after Phase 18)
| Tool | Min Version | Purpose | Why Standard |
|------|-------------|---------|--------------|
| `bash` (host) on Linux | 4.0+ (every modern distro ships 5.x) | Run installer + CLI wrapper | Associative arrays, `mapfile`, parameter expansion modifiers |
| `bash` (host) on macOS | **5.x via `brew install bash`** | Same — installed to `$(brew --prefix)/bin/bash` | Apple ships bash 3.2.57 and will not update it (GPLv3 licensing objection, frozen since 2014). Scripts re-exec into brew bash. |
| `coreutils` via Homebrew | 9.x | GNU `date`, `readlink`, `stat`, `base64`, `sed`, `grep`, `realpath` | BSD versions have incompatible flags (`-d`, `-f`, `-c`, etc.) — single biggest silent-failure surface on macOS |
| `jq` | 1.7+ | JSON in hooks and installer | Already a v1.0 requirement; `brew install jq` available |
| `uuidgen` | system | Call-ID generation | BSD `uuidgen` outputs uppercase — requires `tr` normalization downstream |
| Homebrew | any current | Package manager gate for the above | Only realistic way to get GNU tools on stock macOS without asking users to build from source |

### Verified Versions (as of 2026-04-13)

Brew formulae are rolling; no version pinning needed in installer:

| Formula | Current (brew.sh) | Notes |
|---------|-------------------|-------|
| `bash` | 5.2.x | Latest stable. Installs to `$(brew --prefix)/bin/bash`. Does NOT replace `/bin/bash`. |
| `coreutils` | 9.5+ | Installs GNU tools prefixed with `g` (e.g., `gdate`) AND exposes unprefixed versions under `$(brew --prefix)/opt/coreutils/libexec/gnubin/` |
| `jq` | 1.7+ | No platform differences in jq CLI flags the project uses. |

**Version verification note:** The installer does NOT need to pin versions. It runs `brew install bash coreutils jq` and then verifies each tool is on PATH and meets minimum version (bash ≥ 4 for re-exec target, coreutils gnubin present, jq ≥ 1.6 for `jq -n`). Homebrew formulae move forward faster than this project's release cycle and brew itself handles version selection.

### Alternatives Considered
| Instead of | Could Use | Why Rejected |
|------------|-----------|--------------|
| Brew bash 5 + re-exec | Rewrite scripts to bash 3.2 dialect | 1,900 lines of `bin/claude-secure` already use bash 4+ idioms freely (`[[`, process substitution, `read -r`, `${var:-default}`, `printf -v`). Rewriting is a guaranteed regression vector. Re-exec is one 6-line shim. |
| Brew bash 5 + re-exec | MacPorts bash | macOS users expect Homebrew; MacPorts adds a second package manager to document. Homebrew is the de facto standard. |
| `brew install coreutils` + PATH shim | Rewrite every `date -d`/`stat -c`/`readlink -f` call | Same argument — PATH shim is 3 lines, rewriting is ~30 scattered sites. Shim is also reversible if upstream ever fixes BSD flags. |
| GNU tools via `g`-prefix (`gdate`, `greadlink`) | Unprefixed via `gnubin` PATH entry | Prefixed names pollute the scripts with `gdate`/`greadlink` everywhere, making them non-portable in the other direction (won't run on Linux where `gdate` doesn't exist). `gnubin` gives you plain `date` that behaves identically on both platforms. |
| `mkdir`-based lock | `flock` via `brew install flock` | Adds a 5th brew formula for one caller. `mkdir` is atomic on every POSIX filesystem and already guaranteed by the shell. `discoteq/flock` exists but introduces unnecessary dependency. |
| Auto-install Homebrew | Print instructions + exit (PLAT-03) | **Security product.** Silently downloading and running a curl-to-shell bootstrap from an external host violates the threat model. User explicitly installs brew first, then runs our installer. |
| `$OSTYPE` detection | `uname -s` + `/proc/version` | `$OSTYPE` is bash-specific and varies ('darwin23', 'linux-gnu', 'msys'). `uname -s` is POSIX and returns stable `Darwin` / `Linux`. `/proc/version` is the only reliable WSL2 signal. |

### Installation

No new packages installed on Linux/WSL2. On macOS, installer runs:

```bash
# User must have already installed Homebrew per PLAT-03
# Installer does this automatically once brew is present (PLAT-04):
brew install bash coreutils jq
# After this, $(brew --prefix)/bin/bash and $(brew --prefix)/opt/coreutils/libexec/gnubin must exist
```

## Architecture Patterns

### Recommended Layout

```
claude-secure/
├── lib/
│   └── platform.sh              # NEW: detect_platform, bootstrap_path, re-exec shim, uuid_lower
├── install.sh                   # sources lib/platform.sh at top
├── bin/
│   └── claude-secure            # sources lib/platform.sh at top
├── claude/hooks/
│   └── pre-tool-use.sh          # (runs IN container — see note below)
└── tests/
    ├── test-phase18.sh          # NEW: unit tests for platform.sh
    └── run-tests.sh             # existing, add test-phase18.sh to selection
```

**Critical note on hook placement:** `claude/hooks/pre-tool-use.sh` runs **inside the Debian-based claude container**, not on the host. It already has GNU userland and bash 5.x. PORT-04 (`uuidgen` lowercase normalization) is the ONLY Phase 18 change that touches this file — and it's defensive, because today's hook relies on the container base image shipping `uuid-runtime` (which outputs lowercase). We normalize unconditionally so the hook is safe regardless of which `uuidgen` implementation ships. Do NOT apply PATH-shim logic or bash re-exec to the hook; that's for host scripts only.

### Pattern 1: One Library, Sourced Everywhere

**What:** `lib/platform.sh` is the single source of truth. Every host script sources it at the top, immediately after `set -euo pipefail`.

**When to use:** For every host-side bash script in the project (install.sh, bin/claude-secure, run-tests.sh, and every test script under tests/ that runs on the host).

**Why:** Inline `case "$(uname)"` checks scattered across files become impossible to audit. One library = one grep to verify.

**Example:**
```bash
# At the top of install.sh, bin/claude-secure, run-tests.sh, every host test:
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh" || source "$SCRIPT_DIR/../lib/platform.sh"
claude_secure_bootstrap_path   # idempotent: re-execs into brew bash 5 on macOS, PATH-shims gnubin
PLATFORM="$(detect_platform)"  # returns: linux | wsl2 | macos
```

### Pattern 2: Re-exec Into Brew Bash Guard

**What:** First action after sourcing the library: if we're on macOS AND we're running under `/bin/bash` (Apple's 3.2) AND we haven't already re-execed, replace the process with brew bash 5.

**When to use:** In `claude_secure_bootstrap_path` (called from `lib/platform.sh`), guarded by an env var sentinel to prevent recursion.

**Why:** Re-exec must happen BEFORE any bash 4+ feature is parsed (otherwise bash 3.2 fails at parse time on `declare -A`, not at use time). Sourcing a file is parsed first; function bodies are parsed lazily, so `lib/platform.sh` itself must only use bash 3.2-safe syntax in the top-level guard.

**Example:**
```bash
# lib/platform.sh — top-level code MUST be bash 3.2 safe
claude_secure_bootstrap_path() {
  # Idempotency sentinel
  if [ -n "${__CLAUDE_SECURE_BOOTSTRAPPED:-}" ]; then
    return 0
  fi
  __CLAUDE_SECURE_BOOTSTRAPPED=1
  export __CLAUDE_SECURE_BOOTSTRAPPED

  local plat
  plat="$(detect_platform)"

  if [ "$plat" = "macos" ]; then
    # Prepend coreutils gnubin so plain `date`, `readlink`, `stat` are GNU
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [ -z "$brew_prefix" ]; then
      echo "ERROR: Homebrew required on macOS. Install: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" >&2
      return 1
    fi
    local gnubin="$brew_prefix/opt/coreutils/libexec/gnubin"
    if [ -d "$gnubin" ]; then
      PATH="$gnubin:$PATH"
      export PATH
    fi

    # Re-exec into brew bash 5 if we're running under Apple's 3.2
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
      local brew_bash="$brew_prefix/bin/bash"
      if [ -x "$brew_bash" ]; then
        exec "$brew_bash" "$0" "$@"
      else
        echo "ERROR: bash 4+ required. Run: brew install bash" >&2
        return 1
      fi
    fi
  fi
}
```

Note: because `source` returns to the caller and `exec` replaces the whole process, the `exec` must run from inside a function that was called from the caller's top-level script — the caller's `"$@"` is not in scope inside the library function. Fix: the caller passes its args explicitly, or `lib/platform.sh` captures them at source time via a top-level assignment.

**Simpler alternative:** Put the re-exec guard directly in each calling script's prologue, and only factor `detect_platform()` and the PATH shim into the library. This is 6 lines per script × 3 scripts = 18 lines of duplication, but it sidesteps the `"$@"` scoping issue. The planner should pick one — a library function using `"${BASH_ARGV[@]}"` is clever but fragile; inline is boring and correct.

### Pattern 3: CI Override for TEST-01

**What:** `CLAUDE_SECURE_PLATFORM_OVERRIDE` env var, when set to one of `linux|wsl2|macos`, short-circuits detection. Enables Linux CI to exercise macOS code paths without a Mac runner.

**When to use:** Always — it's a hook into `detect_platform()` itself. Cost is near-zero; benefit is Linux CI can run the macOS branch of `claude_secure_bootstrap_path` (minus the actual brew calls, which must be mockable).

**Example:**
```bash
detect_platform() {
  if [ -n "${CLAUDE_SECURE_PLATFORM_OVERRIDE:-}" ]; then
    case "$CLAUDE_SECURE_PLATFORM_OVERRIDE" in
      linux|wsl2|macos) echo "$CLAUDE_SECURE_PLATFORM_OVERRIDE"; return 0 ;;
      *) echo "ERROR: CLAUDE_SECURE_PLATFORM_OVERRIDE must be one of: linux, wsl2, macos" >&2; return 1 ;;
    esac
  fi
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl2"
      else
        echo "linux"
      fi
      ;;
    *) echo "unknown"; return 1 ;;
  esac
}
```

**CI extension point:** The bootstrap function should *also* honor `CLAUDE_SECURE_BREW_PREFIX_OVERRIDE` (or equivalent) so tests can point at a fixture directory containing a fake `gnubin/` and `bin/bash` shim. Without this, Linux CI running with `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` will try to call `brew --prefix` and fail. Alternatively, the macOS branch can fall back to `command -v brew` and skip PATH shimming silently when brew isn't present (simpler, but the CI test has to separately verify the macOS branch WOULD do the right thing — e.g., by mocking `brew` on PATH with a stub).

### Pattern 4: `mkdir` as Atomic Mutex (PORT-03)

**What:** Replace `flock -n 9` with `mkdir "$lockdir"`. Success = lock acquired, failure (EEXIST) = contended. Cleanup via `trap rmdir $lockdir EXIT`.

**When to use:** Every PORT-03 site. Currently exactly one: `bin/claude-secure` line 1648 in `do_reap()`.

**Why:** `mkdir` is atomic at the VFS layer across every Unix (POSIX guarantees `EEXIST` if the directory already exists, and there is no TOCTOU window). `flock` gives *advisory* kernel locks which are stronger but unavailable on macOS without a brew formula. For a single-flight reaper guard the semantics are equivalent: both answer "is another copy already running?" — and `mkdir` has the added property of being visible to `ls`, easier to debug.

**Stale lock handling:** `mkdir` leaves a zombie directory if the process crashes. Use a PID file inside the directory and stale-check on acquisition:

```bash
acquire_mkdir_lock() {
  local lockdir="$1"
  local pidfile="$lockdir/pid"
  if mkdir "$lockdir" 2>/dev/null; then
    echo $$ > "$pidfile"
    trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
    return 0
  fi
  # Lock exists — check if holder is still alive
  if [ -f "$pidfile" ]; then
    local holder_pid
    holder_pid="$(cat "$pidfile" 2>/dev/null || echo 0)"
    if [ "$holder_pid" -gt 0 ] && ! kill -0 "$holder_pid" 2>/dev/null; then
      # Stale lock — holder is dead, reclaim it
      rmdir "$lockdir" 2>/dev/null || true
      if mkdir "$lockdir" 2>/dev/null; then
        echo $$ > "$pidfile"
        trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
        return 0
      fi
    fi
  fi
  return 1
}
```

The `trap` ensures normal exit paths clean up. Signals (`kill -9`) leave zombies which the next invocation reclaims via the PID check.

**Test harness impact:** `tests/test-phase17.sh` currently mocks `flock` via a stub script on PATH (lines 108-136). That mock must be replaced with a `mkdir` contention scenario. The mock approach stays the same (pre-create the lock directory before invoking `do_reap`), just different primitive.

### Anti-Patterns to Avoid

- **Inline `case "$(uname)"` in every script.** Funnel through `lib/platform.sh`. Enforced by shellcheck-able convention.
- **Assuming `/bin/bash` is bash 5 on macOS.** It's 3.2.57 forever. Always re-exec or always PATH-shim a brew bash via `#!/usr/bin/env bash` + PATH manipulation.
- **Hardcoding `/opt/homebrew` or `/usr/local`.** Apple Silicon uses `/opt/homebrew`; Intel uses `/usr/local`; both are installation choices the user makes. Always query `brew --prefix`.
- **Relying on `brew --prefix` in performance-critical loops.** It's a subprocess fork. Call it once, cache the result in an env var.
- **Running `brew install` non-idempotently.** `brew install foo` is idempotent if `foo` is already installed (it prints a notice and exits 0), but if `foo` is a keg-only formula the behavior differs. `bash`, `coreutils`, `jq` are all regular formulae — idempotent install is safe.
- **Skipping `set -e` in `lib/platform.sh`.** Because the library is sourced, its `set -e` affects the caller. Use `return` with explicit exit codes from functions, let the caller decide how to respond.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Homebrew prefix detection | Hardcoded `/opt/homebrew` / `/usr/local` branch on `uname -m` | `brew --prefix` | Homebrew can be installed to a custom prefix. Always ask it. |
| GNU tool shim layer | Script aliases (`alias date=gdate`) or function wrappers | `$(brew --prefix)/opt/coreutils/libexec/gnubin` PATH entry | Aliases don't survive subshells; functions don't survive `env`; PATH is the only thing every child process inherits. |
| UUID generation portability | Rolling our own v4 UUID with `/dev/urandom` + printf | `uuidgen \| tr '[:upper:]' '[:lower:]'` | `uuidgen` is already a dependency; normalization is one tr call. Reinventing v4 UUIDs is a foot-gun (RFC 4122 bit-twiddling). |
| macOS/Linux detection | `$OSTYPE`, `$MACHTYPE`, `$OSTYPE_DISPLAY` | `uname -s` + `/proc/version` | `$OSTYPE` values are bash-implementation-defined (Darwin bash reports `darwin23` but this is not guaranteed). POSIX `uname -s` returns stable `Darwin` or `Linux`. |
| File lock primitive | `flock` everywhere + `brew install flock` | `mkdir`-based lock with PID file | Adds brew dependency for one caller. `mkdir` is atomic on every POSIX FS. |
| Bash version check | Parsing `bash --version` output | `${BASH_VERSINFO[0]}` built-in array | `BASH_VERSINFO` exists since bash 2.x, is structured, and is what every portable script uses. |

**Key insight:** Every item here is a shell-level concern where the ecosystem has a blessed one-liner. Phase 18's value is finding and applying those one-liners consistently, not designing anything new.

## Runtime State Inventory

This phase does **rename/refactor** work (removing `flock`, normalizing `uuidgen`, adding PATH shims). Runtime state audit follows:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| **Stored data** | None. `claude-secure` has no persistent datastores that embed `flock` / `uuidgen` / bash-version assumptions. The validator SQLite stores call-IDs but is an in-container process already running GNU userland. | None. |
| **Live service config** | `claude-secure-reaper.timer` and `claude-secure-webhook.service` systemd units — these reference `flock` only transitively (they invoke `bin/claude-secure reap` which internally uses `flock`). Once `bin/claude-secure` is patched, units need no change. | None — systemd unit files are unchanged. On macOS they're replaced entirely in Phase 21 with launchd plists, so no edit is needed here. |
| **OS-registered state** | None on host-side of v2.0. systemd units in `/etc/systemd/system/` reference binary paths, not `flock` directly. | None. |
| **Secrets/env vars** | `CLAUDE_SECURE_PLATFORM_OVERRIDE` is a NEW env var added this phase. It has no existing consumers. Other env vars (`LOG_DIR`, `LOG_PREFIX`, `REAPER_*`, `CONFIG_DIR`) are unchanged. | None — new env var is additive. Document it in README as a CI-testing knob. |
| **Build artifacts / installed packages** | Existing host installs of claude-secure (under `~/.claude-secure/app/`) contain the current `flock`-using version of `bin/claude-secure`. Re-running `install.sh` copies the fresh binary, overwriting it. | Users must re-run `install.sh` after upgrading to v3.0 — already true for any release. No data migration, purely code replacement. |

**Canonical check:** After every file in the repo is updated, what runtime systems still have the old behavior cached?
- **Running reaper timer on WSL2/Linux** — if a systemd-timer-driven reaper cycle is mid-flight when the user upgrades, it keeps using the old `flock` FD 9 (process was already started). Next cycle picks up the new `mkdir` code path. No lock-compatibility issue because new and old never run simultaneously against the same lock (new uses `$LOG_DIR/reaper.lock/pid`, old uses `$LOG_DIR/reaper.lock` as a file — different paths). **Recommendation:** document that the reaper timer should be stopped before upgrading on Linux; or, rename the lock path slightly to guarantee mutual exclusion impossibility.
- **Running webhook listener** — Python, unaffected by bash changes. No action.
- **In-memory installer state** — installer is one-shot, no long-running state.

## Environment Availability

**Note:** This phase researches what the **target user's host** needs. CI/dev machines need the same tools for testing.

| Dependency | Required By | Available (dev WSL2 host) | Version | Fallback |
|------------|-------------|---------------------------|---------|----------|
| bash ≥ 4 | Phase 18 scripts | ✓ | 5.x (Ubuntu/Debian/WSL2 default) | — |
| GNU coreutils | Phase 18 scripts | ✓ | 9.x (Linux native) | — |
| jq ≥ 1.6 | install.sh, platform tests | ✓ (existing v1.0 requirement) | 1.7+ | — |
| uuidgen | existing | ✓ | util-linux | — |
| Homebrew | Target macOS runtime ONLY | ✗ (not needed on Linux) | — | Phase 18 development and unit tests don't need real brew — `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` + mocked `brew` stub on PATH simulates it |
| shellcheck | Linting new `lib/platform.sh` | unknown | verify | `apt install shellcheck` |
| macOS machine for end-to-end | Full validation | ✗ | — | **ACCEPTED GAP** — Phase 18 unit tests + override mocking gets us ~90% coverage. Real macOS validation defers to Phase 19-22 which require actual hardware for Docker Desktop/launchd/pf. |

**Missing dependencies with no fallback:** None blocking this phase. The work is entirely implementable and testable on Linux/WSL2.

**Missing dependencies with fallback:** macOS machine for end-to-end smoke test — fallback is the `CLAUDE_SECURE_PLATFORM_OVERRIDE` harness plus Phase 19's Docker Desktop smoke test (which runs on real macOS anyway and will exercise `install.sh` via brew for real).

## Common Pitfalls

### Pitfall 1: Homebrew prefix hardcoded
**What goes wrong:** Script uses `/opt/homebrew/bin/bash` on an Intel Mac where brew lives at `/usr/local`, or vice versa. Re-exec fails, script crashes with "not found".
**Why it happens:** Developer tested on Apple Silicon only.
**How to avoid:** Always query `brew --prefix` at runtime. Cache the result in one variable (e.g., `BREW_PREFIX`) and use `"$BREW_PREFIX/bin/bash"`, `"$BREW_PREFIX/opt/coreutils/libexec/gnubin"`.
**Warning signs:** Any string literal matching `/opt/homebrew` or `/usr/local/Cellar` in new code.

### Pitfall 2: Bash 3.2 parse-time failure
**What goes wrong:** Script sourced by bash 3.2 fails at parse time on the first `declare -A` or `mapfile` it sees — BEFORE any runtime re-exec guard can run. Error message is `declare: -A: invalid option` on an unexplained line number.
**Why it happens:** Bash parses the entire script before executing; it does NOT defer parsing of function bodies. So putting the re-exec guard at line 1 doesn't help if line 50 has `declare -A foo`.
**How to avoid:**
1. The re-exec guard must be in a FILE that itself only uses bash 3.2-compatible syntax. `lib/platform.sh` top-level must be bash 3.2 clean.
2. Putting `declare -A` inside a function body is NOT sufficient — bash parses function bodies at definition time, not invocation.
3. The cleanest pattern: `lib/platform.sh` contains ONLY 3.2-safe code. It exports `__CLAUDE_SECURE_BASH_OK=1` after successful re-exec. The CALLING script then `source`s additional libraries (possibly containing bash 4+ idioms) only after the guard.
**Warning signs:** Scripts that can't even `--help` on macOS before re-exec.

### Pitfall 3: BSD `date` flag differences
**What goes wrong:** `date -d "+10 seconds" +%s` is GNU-only. BSD `date` uses `date -v +10S +%s`. `date -Iseconds` (ISO8601) is also GNU-only; BSD requires a format string.
**Why it happens:** GNU `date` is what every Linux tutorial shows. Developers don't know BSD variants exist.
**How to avoid:** PATH-shim `gnubin` so plain `date` is GNU on macOS. Phase 18's single biggest win. Audit every `date` call for `-d`, `-I*`, `-r <epoch>` — all GNU extensions that the PATH shim resolves.
**Warning signs:** `date -d ...`, `date -I...`, `date --rfc-3339=...`.
**Project impact:** Found in `bin/claude-secure:1560` (`date -d "$created_clean" +%s`) and `claude/hooks/pre-tool-use.sh:19,27` (`date -Iseconds` — but hook is in container, safe).

### Pitfall 4: `readlink -f` missing on macOS
**What goes wrong:** `readlink -f` resolves symlinks recursively — GNU extension. BSD `readlink` has no `-f`. Silent failure: prints nothing, exit 0, downstream consumers get empty string.
**Why it happens:** Same as pitfall 3.
**How to avoid:** PATH-shim `gnubin` (GNU readlink behaves identically). Same shim resolves `realpath -m` which is already used in `install.sh:192` and `bin/claude-secure:92,232`.
**Warning signs:** Any mention of `readlink -f` or `realpath` should be verified on macOS explicitly. Project currently uses `realpath -m` which is ALSO not in BSD userland without coreutils.

### Pitfall 5: BSD `uuidgen` uppercase output
**What goes wrong:** Call-IDs generated on macOS look like `E8B4CF7F-0B11-4F85-BAD8-3B9C6D8C8A15`; Linux produces `e8b4cf7f-0b11-4f85-bad8-3b9c6d8c8a15`. Validator registers one case, iptables rule matches against the other, call fails to dispatch.
**Why it happens:** macOS `uuidgen` is the BSD/GNOME implementation that outputs uppercase. Linux `uuid-runtime` outputs lowercase. Both are RFC 4122 compliant (the spec allows either).
**How to avoid:** ALWAYS pipe through `| tr '[:upper:]' '[:lower:]'`. Even in scripts where you think case doesn't matter, normalize at the boundary. One line. Zero cost.
**Project impact:** The **container** hook `claude/hooks/pre-tool-use.sh:159` does `call_id=$(uuidgen)` — this is inside the Debian-based claude container, so it's actually fine today. PORT-04 makes it defensive: if the container base image ever changes to Alpine or BSD libc, the hook still produces lowercase IDs. The host-side `install.sh:41` only checks for uuidgen existence, doesn't call it. **The only production caller that actually matters is the hook — patch it defensively anyway to satisfy PORT-04.**
**Warning signs:** Any raw `$(uuidgen)` or `uuidgen` in a shell pipeline without `tr`.

### Pitfall 6: `flock` not on macOS
**What goes wrong:** `flock -n 9` on macOS: `flock: command not found`. Script aborts (or worse, non-`set -e` scripts silently proceed without any lock and run concurrent reapers).
**Why it happens:** `flock` is util-linux specific. Not in macOS base or POSIX.
**How to avoid:** PORT-03 — replace with `mkdir` lock. Single caller in this project.
**Warning signs:** `flock` literal search. Project has exactly one production call at `bin/claude-secure:1648` plus test harness mocks in `tests/test-phase17.sh` (not production code but needs to be updated too).

### Pitfall 7: `grep -P` (Perl regex) differences
**What goes wrong:** BSD `grep` doesn't support `-P` (PCRE). Hook extraction at `claude/hooks/pre-tool-use.sh:85` uses `grep -oP 'https?://...'` — runs in container, so fine today. But if any host script copies this pattern, it breaks on macOS.
**Why it happens:** PCRE requires a different grep build. GNU grep links libpcre; BSD grep does not.
**How to avoid:** Prefer `grep -oE` (ERE) for portable extraction patterns. Hook is container-side, leave alone. Audit any host-side `grep -P` during PORT-01 pass.
**Project impact:** Currently zero host-side `grep -P` usage (verified via grep).

### Pitfall 8: `sed -i` with no suffix
**What goes wrong:** GNU sed accepts `sed -i -e '...' file`; BSD sed requires `sed -i '' -e '...' file` (mandatory backup extension argument). The GNU form on BSD sed treats `-e` as the backup suffix and produces bizarre errors.
**Why it happens:** Shortest-path learned syntax.
**How to avoid:** PATH-shim gives you GNU sed. Also: `sed -E` vs `sed -r` — both versions support `-E` (POSIX 2024 adoption), so use `-E`.
**Project impact:** `install.sh:395-398` uses `sed -e ... -e ... file | tee`, which is the pipe-output form and doesn't hit this bug. No `sed -i` in host code (verified). Container code paths (proxy, validator) are unaffected.

### Pitfall 9: Tests that hardcode Linux assumptions
**What goes wrong:** `tests/test-phase1.sh` does `docker compose exec -T claude stat -c '%U %a' /path`. Runs inside container (GNU). Fine.
But host test assertions like `PERMS=$(stat -c '%a' "$ENV_FILE")` in `tests/test-phase4.sh:124` run on the HOST — and `-c` is GNU-only. BSD `stat` uses `-f '%Lp'`.
**Why it happens:** Dev wrote it on Linux, it worked.
**How to avoid:** PATH-shim on host + ensure `tests/*.sh` source `lib/platform.sh` and call `claude_secure_bootstrap_path`. Audit: every host test file needs this prologue.
**Warning signs:** `stat -c` in test files. `stat -f` on macOS's native stat.
**Project impact:** `tests/test-phase4.sh:124,145` — host-side `stat -c` calls. Must be patched (covered by PORT-01 once the test file sources `lib/platform.sh`).

## Code Examples

All examples below are verified conceptually against the project's existing v2.0 code. Reference implementations — planner should adapt to final file layout.

### `lib/platform.sh` skeleton (bash 3.2 safe)
```bash
#!/bin/bash
# lib/platform.sh — platform detection and PATH bootstrapping for claude-secure.
# This file MUST remain bash 3.2-safe (no declare -A, no mapfile, no ${var,,}).
# Top-level code is parsed by Apple's /bin/bash before re-exec can occur.

# Guard: idempotent sourcing.
if [ -n "${__CLAUDE_SECURE_PLATFORM_LOADED:-}" ]; then
  return 0
fi
__CLAUDE_SECURE_PLATFORM_LOADED=1

detect_platform() {
  if [ -n "${CLAUDE_SECURE_PLATFORM_OVERRIDE:-}" ]; then
    case "$CLAUDE_SECURE_PLATFORM_OVERRIDE" in
      linux|wsl2|macos) echo "$CLAUDE_SECURE_PLATFORM_OVERRIDE"; return 0 ;;
      *)
        echo "ERROR: CLAUDE_SECURE_PLATFORM_OVERRIDE must be one of: linux, wsl2, macos (got: $CLAUDE_SECURE_PLATFORM_OVERRIDE)" >&2
        return 1
        ;;
    esac
  fi
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Darwin) echo "macos"; return 0 ;;
    Linux)
      if [ -r /proc/version ] && grep -qi microsoft /proc/version; then
        echo "wsl2"
      else
        echo "linux"
      fi
      return 0
      ;;
    *) echo "unknown"; return 1 ;;
  esac
}

# Print the Homebrew prefix, or empty string if brew is unavailable.
# Honors CLAUDE_SECURE_BREW_PREFIX_OVERRIDE for CI mocking.
claude_secure_brew_prefix() {
  if [ -n "${CLAUDE_SECURE_BREW_PREFIX_OVERRIDE:-}" ]; then
    echo "$CLAUDE_SECURE_BREW_PREFIX_OVERRIDE"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    brew --prefix 2>/dev/null
    return 0
  fi
  echo ""
  return 1
}

# Normalize a UUID to lowercase. Safe on both BSD and GNU uuidgen.
claude_secure_uuid_lower() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

# Bootstrap PATH and bash version for macOS. Idempotent. Call this as the
# very first action in the calling script after sourcing this file.
claude_secure_bootstrap_path() {
  if [ -n "${__CLAUDE_SECURE_BOOTSTRAPPED:-}" ]; then
    return 0
  fi
  __CLAUDE_SECURE_BOOTSTRAPPED=1
  export __CLAUDE_SECURE_BOOTSTRAPPED

  local plat
  plat="$(detect_platform)" || return 1
  if [ "$plat" != "macos" ]; then
    return 0
  fi

  local brew_prefix
  brew_prefix="$(claude_secure_brew_prefix)"
  if [ -z "$brew_prefix" ]; then
    echo "ERROR: Homebrew is required on macOS." >&2
    echo "Install Homebrew, then re-run this command:" >&2
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" >&2
    return 1
  fi

  # Prepend GNU coreutils so plain `date`, `stat`, `readlink`, `sed`, `grep` behave like Linux.
  local gnubin="$brew_prefix/opt/coreutils/libexec/gnubin"
  if [ -d "$gnubin" ]; then
    PATH="$gnubin:$PATH"
    export PATH
  else
    echo "ERROR: GNU coreutils not installed. Run: brew install coreutils" >&2
    return 1
  fi

  # Also ensure brew bash is reachable for the re-exec step below.
  if ! [ -x "$brew_prefix/bin/bash" ]; then
    echo "ERROR: brew bash not installed. Run: brew install bash" >&2
    return 1
  fi

  # Verify jq (PLAT-04 completeness).
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not installed. Run: brew install jq" >&2
    return 1
  fi

  # NOTE: the bash 4+ re-exec guard must live in the CALLING SCRIPT,
  # not here. By the time we reach this point inside a function, bash
  # has already parsed the caller's body — if it contained `declare -A`
  # under apple bash 3.2, we'd have crashed at parse time. The caller
  # owns the re-exec decision, we just verified the target exists.
  return 0
}
```

### Caller script prologue (install.sh, bin/claude-secure, etc.)
```bash
#!/usr/bin/env bash
# Bash 3.2 re-exec guard: runs BEFORE any bash 4+ syntax in this file.
# Only bash 3.2-compatible statements here until after the exec.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  # We're on Apple bash 3.2. Find brew bash 5 and re-exec.
  if command -v brew >/dev/null 2>&1; then
    __brew_bash="$(brew --prefix 2>/dev/null)/bin/bash"
    if [ -x "$__brew_bash" ]; then
      exec "$__brew_bash" "$0" "$@"
    fi
  fi
  echo "ERROR: bash 4+ required. On macOS run: brew install bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh" 2>/dev/null \
  || source "$SCRIPT_DIR/../lib/platform.sh"

claude_secure_bootstrap_path
PLATFORM="$(detect_platform)"

# ... rest of script is free to use bash 4+ idioms ...
```

### Homebrew dependency bootstrap in install.sh (PLAT-03 + PLAT-04)
```bash
macos_bootstrap_deps() {
  # PLAT-03: detect brew, do NOT auto-install
  if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew is required but not installed."
    log_error ""
    log_error "Install Homebrew by running:"
    log_error "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    log_error ""
    log_error "Then re-run this installer."
    exit 1
  fi

  # PLAT-04: install bash, coreutils, jq via brew BEFORE any other macOS step
  log_info "Bootstrapping GNU tools via Homebrew..."
  for formula in bash coreutils jq; do
    if brew list --formula "$formula" >/dev/null 2>&1; then
      log_info "  $formula already installed"
    else
      log_info "  installing $formula..."
      brew install "$formula"
    fi
  done

  # Verify everything we need is now available
  local brew_prefix missing=()
  brew_prefix="$(brew --prefix)"
  [ -x "$brew_prefix/bin/bash" ] || missing+=("bash (brew install bash)")
  [ -d "$brew_prefix/opt/coreutils/libexec/gnubin" ] || missing+=("coreutils (brew install coreutils)")
  command -v jq >/dev/null 2>&1 || missing+=("jq (brew install jq)")

  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "Post-bootstrap verification FAILED. Missing:"
    for m in "${missing[@]}"; do
      log_error "  - $m"
    done
    exit 1
  fi

  log_info "macOS bootstrap complete."
}

# In install.sh main() flow:
check_dependencies() {
  local plat
  plat="$(detect_platform)"
  if [ "$plat" = "macos" ]; then
    macos_bootstrap_deps
  fi

  # existing Linux/WSL2 dependency checks (docker, curl, jq, uuidgen)...
  # On macOS these now pass because brew just installed jq; docker is
  # Docker Desktop (checked separately in Phase 19).
}
```

### `mkdir`-based lock replacement for `do_reap()` (PORT-03)
```bash
# Replace lines 1642-1651 of bin/claude-secure:
do_reap() {
  # ... --dry-run parsing unchanged ...
  export REAPER_DRY_RUN=$dry_run

  local lockdir="${LOG_DIR:-$CONFIG_DIR/logs}/${LOG_PREFIX:-}reaper.lockdir"
  local pidfile="$lockdir/pid"
  mkdir -p "$(dirname "$lockdir")" 2>/dev/null || true

  if ! mkdir "$lockdir" 2>/dev/null; then
    # Directory exists — check if holder is alive
    local holder_pid=0
    if [ -r "$pidfile" ]; then
      holder_pid="$(cat "$pidfile" 2>/dev/null || echo 0)"
    fi
    if [ "$holder_pid" -gt 0 ] && kill -0 "$holder_pid" 2>/dev/null; then
      echo "reaper: another instance is running (pid=$holder_pid lockdir=$lockdir), skipping cycle"
      return 0
    fi
    # Stale lock — reclaim
    echo "reaper: stale lockdir found (dead holder pid=$holder_pid), reclaiming"
    rm -f "$pidfile" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    mkdir "$lockdir" 2>/dev/null || {
      echo "reaper: failed to acquire lockdir after reclaim attempt, skipping cycle"
      return 0
    }
  fi
  echo "$$" > "$pidfile" 2>/dev/null || true
  # Cleanup on any exit path
  trap 'rm -f "'"$pidfile"'" 2>/dev/null || true; rmdir "'"$lockdir"'" 2>/dev/null || true' EXIT

  echo "reaper: cycle start prefix=${INSTANCE_PREFIX:-cs-}"
  # ... rest unchanged ...
}
```

### PORT-04 normalization for container hook
```bash
# claude/hooks/pre-tool-use.sh, replace line 159:
# Before:
#   call_id=$(uuidgen)
# After:
call_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
```

### Linux CI test exercising macOS branch (TEST-01)
```bash
# tests/test-phase18.sh — sample test cases
test_detect_platform_linux_native() {
  unset CLAUDE_SECURE_PLATFORM_OVERRIDE
  # on Linux CI, /proc/version has no "microsoft"
  local result
  result="$(detect_platform)"
  [ "$result" = "linux" ] || { echo "expected linux, got $result"; return 1; }
}

test_detect_platform_override_macos() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  local result
  result="$(detect_platform)"
  [ "$result" = "macos" ] || { echo "expected macos, got $result"; return 1; }
}

test_detect_platform_override_rejects_bogus() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=freebsd
  if detect_platform 2>/dev/null; then
    echo "expected detect_platform to fail on bogus override"
    return 1
  fi
}

test_bootstrap_path_macos_without_brew_fails_loud() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  CLAUDE_SECURE_BREW_PREFIX_OVERRIDE=""
  # Temporarily hide `brew` from PATH
  PATH="/usr/bin:/bin" claude_secure_bootstrap_path 2>/tmp/err
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "expected bootstrap to fail without brew"; return 1; }
  grep -q "Homebrew is required" /tmp/err || { echo "expected Homebrew error message"; return 1; }
}

test_bootstrap_path_macos_with_fake_brew_succeeds() {
  # Build a fake brew prefix with coreutils gnubin and bash stub
  local fake_prefix
  fake_prefix="$(mktemp -d)"
  mkdir -p "$fake_prefix/opt/coreutils/libexec/gnubin"
  mkdir -p "$fake_prefix/bin"
  touch "$fake_prefix/bin/bash"
  chmod +x "$fake_prefix/bin/bash"
  # Fake `date` that prints "FAKE GNU DATE" so we can verify the shim applied
  printf '#!/bin/sh\necho FAKE GNU DATE\n' > "$fake_prefix/opt/coreutils/libexec/gnubin/date"
  chmod +x "$fake_prefix/opt/coreutils/libexec/gnubin/date"

  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos \
  CLAUDE_SECURE_BREW_PREFIX_OVERRIDE="$fake_prefix" \
  claude_secure_bootstrap_path

  # Now `date` should resolve to the fake
  [ "$(date)" = "FAKE GNU DATE" ] || { echo "gnubin shim did not take effect"; return 1; }

  rm -rf "$fake_prefix"
}

test_uuid_lower_normalizes() {
  local out
  out="$(claude_secure_uuid_lower)"
  [[ "$out" =~ ^[0-9a-f-]+$ ]] || { echo "expected lowercase hex UUID, got $out"; return 1; }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Inline `case "$(uname)"` in every script | Single `lib/platform.sh` sourced everywhere | Phase 18 adopts | Enables one-pass audits; testable in isolation |
| `flock -n 9` lock file | `mkdir`-based atomic lock + PID file | Phase 18 (PORT-03) | macOS portable; ~10 lines of added stale-check logic |
| Rely on `/bin/bash` | Re-exec into `$(brew --prefix)/bin/bash` on macOS | Phase 18 (PORT-02) | Apple's bash 3.2 limitation is permanent; workaround is standard for every cross-platform bash tool of the last decade |
| `uuidgen` raw | `uuidgen \| tr '[:upper:]' '[:lower:]'` | Phase 18 (PORT-04) | One additional tr call; defensive across BSD/GNU implementations |

**Deprecated / outdated:**
- Not installing coreutils on macOS and hoping BSD tools "just work" — decade-old lesson: they do not.
- `$OSTYPE` for OS detection — works but is bash-implementation-defined. Prefer POSIX `uname -s`.
- `shlock(1)` (macOS's native flock alternative) — poorly documented, non-portable, not worth the effort when `mkdir` is universal.

## Open Questions

1. **Should `lib/platform.sh` live at repo root or under a subdirectory?**
   - What we know: v2.0 project has no existing `lib/` directory. Existing structure is flat (`install.sh`, `bin/claude-secure`, `claude/hooks/pre-tool-use.sh`).
   - What's unclear: Convention. Does the project want a top-level `lib/` for this one file, or should platform.sh live at repo root next to `install.sh`?
   - Recommendation: Create `lib/` and put `platform.sh` there. Even if it's the only file today, Phase 21's launchd plist templating and Phase 22's test helpers will likely want a home too. This is a low-cost structural decision made once.

2. **Should `tests/test-phase18.sh` be integration-style (invoke `install.sh`) or unit-style (source and call functions)?**
   - What we know: Existing Phase tests (e.g., `tests/test-phase17.sh`) are mostly unit-style with mocks. Phase 17 sources `bin/claude-secure` with `__CLAUDE_SECURE_SOURCE_ONLY=1`.
   - What's unclear: Whether `lib/platform.sh` should be sourced standalone in tests (cleanest) or indirectly via a caller.
   - Recommendation: Unit-style. Source `lib/platform.sh` directly, call `detect_platform`, `claude_secure_bootstrap_path` with `CLAUDE_SECURE_BREW_PREFIX_OVERRIDE` pointing at fixture directories. This is both faster and more discriminating.

3. **Should we also patch test fixtures that embed `flock`?**
   - What we know: `tests/test-phase17.sh:108-136` installs a mock `flock` binary on PATH for its own test scenarios. This is NOT production code.
   - What's unclear: Phase 18 scope — do we rewrite the mock too, or leave it as a Linux-only test asset?
   - Recommendation: Rewrite the test mock as well, because Phase 17's test selection runs in the pre-push hook. If a macOS developer runs `run-tests.sh`, `test-phase17.sh` will fail trying to install its `flock` stub over a nonexistent base command. Convert `test_reap_flock_single_flight` to `test_reap_mkdir_lock_single_flight` with equivalent semantics (pre-create the lock directory). **Track this as PORT-03 test follow-up inside the Phase 18 plan.**

4. **Is `setup-token` / `claude` CLI available on macOS?**
   - What we know: v2.0 installer assumes `claude setup-token` produces an OAuth token. That CLI is `claude-code` the npm package.
   - What's unclear: Whether the Claude Code installation path on macOS (npm global or homebrew tap) is a Phase 18 concern.
   - Recommendation: **Out of scope for Phase 18.** User is expected to have `claude` on PATH before running our installer. Document as a pre-req. Belongs in the Phase 21 end-to-end install flow, not here.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash script harness — same as existing `tests/test-phase*.sh` (no framework, just shell + `report` helper) |
| Config file | none — each test-phase*.sh is standalone with its own PASS/FAIL counters |
| Quick run command | `bash tests/test-phase18.sh` (single file, <30s) |
| Full suite command | `bash run-tests.sh` (runs the pre-push selection) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| PLAT-02 | `detect_platform()` returns `linux` on Linux CI | unit | `bash tests/test-phase18.sh -t detect_platform_linux_native` | ❌ Wave 0 |
| PLAT-02 | `detect_platform()` returns `wsl2` when `/proc/version` contains `microsoft` | unit | `bash tests/test-phase18.sh -t detect_platform_wsl2_proc_version` | ❌ Wave 0 |
| PLAT-02 | `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` forces macos | unit | `bash tests/test-phase18.sh -t detect_platform_override_macos` | ❌ Wave 0 |
| PLAT-02 | Invalid override value errors | unit | `bash tests/test-phase18.sh -t detect_platform_override_rejects_bogus` | ❌ Wave 0 |
| PLAT-03 | Installer fails loudly when brew missing on macOS | unit (mocked) | `bash tests/test-phase18.sh -t bootstrap_path_macos_without_brew_fails_loud` | ❌ Wave 0 |
| PLAT-03 | Error message contains actionable brew install command | unit | asserted via `grep` in the above test | ❌ Wave 0 |
| PLAT-04 | `macos_bootstrap_deps` calls `brew install bash coreutils jq` | unit (mocked brew) | `bash tests/test-phase18.sh -t install_bootstraps_brew_deps` — uses a stub `brew` on PATH logging invocations | ❌ Wave 0 |
| PLAT-04 | Post-bootstrap verification errors if any of bash/coreutils/jq still missing | unit | `bash tests/test-phase18.sh -t install_verifies_post_bootstrap` | ❌ Wave 0 |
| PORT-01 | `gnubin` is prepended to PATH on macos override | unit (mocked brew prefix) | `bash tests/test-phase18.sh -t bootstrap_path_macos_with_fake_brew_succeeds` | ❌ Wave 0 |
| PORT-02 | Bash 4+ re-exec path: given Apple-bash-like `BASH_VERSINFO=3`, re-execs via brew bash | integration (mocked) | `bash tests/test-phase18.sh -t reexec_guard_calls_brew_bash` — uses a fake brew prefix with a stub bash that writes a marker file | ❌ Wave 0 |
| PORT-03 | `do_reap` uses `mkdir` lock; concurrent invocation exits 0 | integration | `bash tests/test-phase17.sh -t reap_mkdir_lock_single_flight` (update existing test) | ⚠️ Exists as `reap_flock_single_flight` — needs rename + rewrite |
| PORT-03 | No `flock` references in production host scripts | static | `! grep -rnE '\bflock\b' install.sh bin/claude-secure claude/hooks/ lib/` (exit 0 = pass) | ❌ Wave 0 |
| PORT-04 | Hook's `call_id` is always lowercase | unit | `bash tests/test-phase18.sh -t uuid_lower_normalizes` + `grep -n 'tr.*upper.*lower' claude/hooks/pre-tool-use.sh` | ❌ Wave 0 |
| TEST-01 | Running the full phase18 suite under `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` on Linux CI passes | integration | `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos bash tests/test-phase18.sh` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase18.sh` (fast, ~10s estimated)
- **Per wave merge:** `bash run-tests.sh` (full selection — confirms Phase 17 flock mock rewrite didn't break anything)
- **Phase gate:** `bash run-tests.sh` green AND `! grep -rnE '\bflock\b' install.sh bin/ claude/hooks/ lib/` returns zero matches AND Linux CI `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos bash tests/test-phase18.sh` green.

### Wave 0 Gaps
- [ ] `lib/platform.sh` — new file, does not exist
- [ ] `tests/test-phase18.sh` — new test file, does not exist
- [ ] `tests/test-phase17.sh` `test_reap_flock_single_flight` rewrite to `mkdir` semantics
- [ ] `run-tests.sh` — add `test-phase18.sh` to the run selection
- [ ] No new test framework install needed (project uses bash directly)

## Sources

### Primary (HIGH confidence)
- `install.sh` (project) — lines 1-481, read in full; verified `realpath -m`, `sed` usage, `systemctl` gating, `uuidgen` dependency check
- `bin/claude-secure` (project) — lines 1-80, 1610-1680 read; verified `flock -n 9` at line 1648, `date -d` at line 1560, `realpath -m` at lines 92 and 232
- `claude/hooks/pre-tool-use.sh` (project) — read in full (235 lines); confirmed `uuidgen` usage at line 159 and that hook runs IN the container (so PATH-shim concerns are moot for it)
- `.planning/phases/17-operational-hardening/17-02-SUMMARY.md` (project history) — documented the exact `${created%.*}Z` gotcha with `date -d` portability; proves GNU date assumptions have already bitten this codebase once
- `.planning/REQUIREMENTS.md` v3.0 section — PLAT-01..05, PORT-01..04, TEST-01 canonical definitions
- `.planning/ROADMAP.md` Phase 18 success criteria — 5 numbered criteria used as test targets

### Secondary (MEDIUM confidence)
- Homebrew documentation (docs.brew.sh/Installation) — `/opt/homebrew` for Apple Silicon, `/usr/local` for Intel, always query `brew --prefix`
- StackOverflow / Medium consensus (multiple sources agree) — macOS ships bash 3.2.57 permanently due to GPLv3 objection; brew bash 5.x is the universal workaround; `declare -A` parse-time failure is well-known
- BashFAQ/045 (mywiki.wooledge.org) — `mkdir` is atomic and is the canonical portable mutex primitive when `flock` is unavailable
- Multiple blog posts (joshtronic, coderwall, crafted-software) — consistent on BSD `uuidgen` producing uppercase; `tr '[:upper:]' '[:lower:]'` is the standard normalization pattern

### Tertiary (LOW confidence, flagged for validation)
- Exact Homebrew formula versions (bash 5.2.x, coreutils 9.5+, jq 1.7) — sourced from training data + search snippets; not independently verified against `brew.sh` pages at research time. Installer does not pin versions so this is not load-bearing.
- `discoteq/flock` as a brew alternative — mentioned but not pursued; we chose `mkdir` instead.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Homebrew + GNU tools PATH shim is the universal macOS pattern, verified against multiple independent sources and project code inspection
- Architecture (lib/platform.sh layout, re-exec guard, mkdir lock): HIGH — each pattern is well-established in cross-platform bash projects of the last decade
- Runtime state inventory: HIGH — codebase is small enough (~2,700 host LOC + 14 tests) to audit completely; grep passes confirm findings
- Pitfalls: HIGH — every pitfall is documented across multiple authoritative sources; several (pitfalls 3, 5, 6) map to actual existing project code at named line numbers
- Validation architecture: HIGH — existing test-phase*.sh pattern is well-understood from prior phases; new tests follow established structure

**Research date:** 2026-04-13
**Valid until:** 2026-05-13 (30 days — shell portability is stable tech, no fast-moving ecosystem concerns)

**Research thoroughness notes:**
- Grep audit covered `flock`, `uuidgen`, `declare -A`, `mapfile`, `readarray`, bash case-modification expansions, `readlink -f`, `stat -c`, `date -d`, `date -I`, `sed -i`, `base64 -w`, `grep -P`, `xargs -r`, `sed -r` — all portability red flags — across all host-side `.sh` files
- Production host `flock` use: **1 site** (`bin/claude-secure:1648`)
- Production host `uuidgen` use: **1 site** (`install.sh:41`, existence check only)
- Container hook `uuidgen` use: **1 site** (`claude/hooks/pre-tool-use.sh:159`) — container-side but PORT-04 patches defensively
- Production host bash 4+ idiom count: pervasive in `bin/claude-secure` (associative-array-free per grep, but uses `[[`, `<(...)`, `${var:-default}`, `mapfile`-less iteration — verified no `declare -A`/`mapfile`/`readarray` grep hits in host code, so the re-exec guard's main job is defensive, not critical)
- No surprise findings — all Phase 18 work items in the roadmap success criteria map to concrete, patchable code locations

Sources:
- [Homebrew Installation — docs.brew.sh](https://docs.brew.sh/Installation)
- [Homebrew coreutils formula](https://formulae.brew.sh/formula/coreutils)
- [Homebrew flock formula](https://formulae.brew.sh/formula/flock)
- [BashFAQ/045 — Greg's Wiki on file locking](https://mywiki.wooledge.org/BashFAQ/045)
- [Generating lowercase UUIDs with uuidgen on macOS](https://joshtronic.com/2022/09/18/generating-lowercase-uuids-with-uuidgen-on-macos/)
- [Install GNU Core Utils on macOS](https://gist.github.com/jeyaramashok/a15ac3923253811a7c9ee04cf855d269)
- [Using GNU command line tools in macOS](https://gist.github.com/skyzyx/3438280b18e4f7c490db8a2a2ca0b9da)
- [Associative array error on macOS for bash: declare: -A: invalid option](https://dipeshmajumdar.medium.com/associative-array-error-on-macos-for-bash-declare-a-invalid-option-16466534e145)
- [flock(2) behaviour on macOS and Linux](https://allenap.me/posts/flock-behaviour)
- [Mutex lock in bash shell (mkdir pattern)](https://www.adrian.idv.hk/2022-12-09-bashlock/)
- [discoteq/flock on GitHub](https://github.com/discoteq/flock)
