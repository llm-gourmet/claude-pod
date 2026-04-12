# Phase 16: Result Channel - Research

**Researched:** 2026-04-12
**Domain:** Git-based publishing + JSONL audit from bash with zero-dependency secret redaction
**Confidence:** HIGH on existing-codebase patterns, HIGH on POSIX/git fundamentals, MEDIUM on default-template prose

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Transport & Configuration**
- **D-01:** Report push transport is HTTPS + GitHub Personal Access Token via `git push`. PAT lives in profile `.env` as `REPORT_REPO_TOKEN` (redacted by proxy like any other secret). Reuses Phase 12 profile `.env` loading. No SSH key management.
- **D-02:** Report repository is configured per-profile via new fields in `profile.json`:
  - `report_repo` — full HTTPS URL (e.g. `https://github.com/user/docs.git`)
  - `report_branch` — target branch (default `"main"`)
  - `report_path_prefix` — optional directory inside the repo (default `"reports"`)
  - When `report_repo` is unset or empty, report push is skipped silently (audit still written).
- **D-03:** Clone strategy: fresh shallow clone (`git clone --depth 1 --branch <report_branch>`) into a per-spawn `$TMPDIR` subdirectory. Cloned directory registered with `_CLEANUP_FILES` (or sibling cleanup list) and removed by `spawn_cleanup` trap. No cached bare repos, no worktrees.

**Audit Log**
- **D-04:** Audit log file path: `$LOG_DIR/${LOG_PREFIX}executions.jsonl` — per-profile, per-instance, honoring existing LOG_PREFIX convention.
- **D-05:** Audit is written from `bin/claude-secure` inside `do_spawn` (not from `listener.py`). Single writer covers webhook-triggered and `replay` spawns.
- **D-06:** JSONL schema — mandatory keys in every audit entry:
  - `ts`, `delivery_id`, `webhook_id`, `event_type`, `profile`, `repo`, `commit_sha`, `branch`, `cost_usd`, `duration_ms`, `session_id`, `status`, `report_url`
- **D-07:** JSONL writes append-only with `O_APPEND` + `fsync`. Within one instance, POSIX `O_APPEND` guarantees atomic line appends for writes ≤ PIPE_BUF (4KB, verified on Linux via `getconf PIPE_BUF /`). Each JSON line stays under 4KB by design (8KB payload fields from Phase 15 are NOT in audit).

**Report Format & Rendering**
- **D-08:** Report templates follow the Phase 13/15 prompt-template fallback chain:
  1. `$CONFIG_DIR/profiles/<profile>/report-templates/<event_type>.md`
  2. `$WEBHOOK_REPORT_TEMPLATES_DIR/<event_type>.md`
  3. `$APP_DIR/webhook/report-templates/<event_type>.md` (dev checkout, when `.git` present)
  4. `/opt/claude-secure/webhook/report-templates/<event_type>.md`
  5. Hard fail if none resolves.
- **D-09:** Default templates ship for `issues-opened`, `issues-labeled`, `push`, `workflow_run-completed`. Installer copies `webhook/report-templates/*.md` into `/opt/claude-secure/webhook/report-templates/` (D-12 always-refresh pattern).
- **D-10:** Report variables extend Phase 15 D-16 set with:
  - All D-16 variables (DELIVERY_ID, EVENT_TYPE, REPO_FULL_NAME, ISSUE_NUMBER, etc.)
  - `{{RESULT_TEXT}}` — Claude's final message body
  - `{{COST_USD}}`, `{{DURATION_MS}}`, `{{SESSION_ID}}`
  - `{{TIMESTAMP}}`, `{{STATUS}}`, `{{ERROR_MESSAGE}}`
- **D-11:** Rendering reuses `_substitute_token_from_file` (awk-from-file) from Phase 15. No new sed code. Same `extract_payload_field` for long fields.

**File Placement & Commit**
- **D-12:** Report filename: `<report_path_prefix>/<YYYY>/<MM>/<event_type>-<delivery_id_short>.md`, where `delivery_id_short` is first 8 chars of delivery id.
- **D-13:** Commit message: `"report(<event_type>): <repo> <delivery_id_short>"` — single-line, conventional, no body. Authored with `GIT_AUTHOR_NAME="claude-secure"` and `GIT_AUTHOR_EMAIL="claude-secure@localhost"` via env vars.
- **D-14:** Push: `git push origin <report_branch>` non-forced. On rejection, retry once with `git pull --rebase && git push`. Second failure → audit with `status: "report_push_failed"`, stderr warning. NEVER force-push.

**Secret Hygiene**
- **D-15:** Before commit, redaction pass iterates profile `.env` key-value pairs and replaces each secret value with `<REDACTED:$KEY>`. Empty values skipped. Done in-place on staged file before `git add`. Uses awk-from-file substitution (NOT sed) — same Pitfall 1 fix as D-11.
- **D-16:** Result text over 16KB truncated with `... [truncated N more bytes]` suffix. UTF-8-safe via Phase 15 python3 helper (Pitfall 4 fix).

**Failure Modes**
- **D-17:** Audit-always, push best-effort:
  - Spawn fails before Claude runs → `status: "spawn_error"`, no push.
  - Claude fails → `status: "claude_error"`, error report pushed if template exists.
  - Push fails → `status: "report_push_failed"`, exit 0, stderr warning.
  - Success → `status: "success"`.
- **D-18:** Spawn exits nonzero ONLY when Claude itself fails. Report push failure does NOT flip exit code.

### Claude's Discretion
- Exact prose of default report templates
- Whether report push runs inline in `do_spawn` or a separate `spawn_publish_report` helper
- Whether to add `--skip-report` flag for testing (recommended: yes, mirrors `--dry-run`)
- Whether audit is written before or after the report push (recommended: AFTER push, so `report_url` is populated in the same line)
- JSON key ordering within audit entries (mandatory keys all present; order cosmetic)
- Test fixture reuse from Phase 15 (recommended: reuse `github-*.json`, add golden-output assertions)

### Deferred Ideas (OUT OF SCOPE)
- SSH deploy key support for report repo (Phase 17 hardening candidate)
- Health webhook on report-push failure (HEALTH-02)
- Cost tracking dashboards / aggregation (COST-01)
- Report content-addressable caching / dedup
- Cross-repo report mirroring
- In-repo audit mirror (push JSONL to doc repo)
- Report template hot-reload
- Report diffing / PR creation (vs direct commit)
- Encrypted reports (age/gpg)
- iptables packet-level logging (Phase 17)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| OPS-01 | After execution, a structured markdown report is written and pushed to a separate documentation repo | Pattern A (fresh shallow clone + commit + push via GIT_ASKPASS), Pattern B (awk-from-file redaction), Pattern E (retry-once-with-rebase), Pattern F (default templates + resolver clone of Phase 15 code) |
| OPS-02 | Each headless execution is logged to structured JSONL with event metadata (webhook ID, event type, commit SHA, cost) | Pattern C (JSONL atomic-append < PIPE_BUF), Pattern D (jq -c line builder), Pattern G (audit key extraction from envelope) |
</phase_requirements>

## Summary

Phase 16 is an additive wiring job over a mature code base. Every primitive Phase 16 needs already exists in `bin/claude-secure` from Phase 13/15:

- **Envelope building** (`build_output_envelope` / `build_error_envelope` at lines 343–378) already emits the JSON shape the audit log reads.
- **Template resolution** (`resolve_template` at 520–566) is clonable as `resolve_report_template` — only the directory names change (`prompts/` → `report-templates/`, `webhook/templates` → `webhook/report-templates`).
- **Variable substitution** (`render_template` / `_substitute_token_from_file` / `_extract_to_tempfile`) needs six new variables grafted on top (RESULT_TEXT, COST_USD, DURATION_MS, SESSION_ID, TIMESTAMP, STATUS, ERROR_MESSAGE) plus the existing 18 from Phase 15.
- **UTF-8-safe truncation** (`extract_payload_field` at 417–451) accepts a `LIMIT` via the same Python helper; result-text truncation at 16KB is just a different constant.
- **Spawn lifecycle** (`do_spawn` at 665–786, `spawn_cleanup` at 336) already handles trap-based cleanup; Phase 16 extends `_CLEANUP_FILES` with the clone directory.

The genuine NEW research areas are: (1) PAT-safe git clone+push from bash without leaking the token into process listings, logs, or remote URLs; (2) POSIX-atomicity guarantees for bash `>>` JSONL appends; (3) retry-once-with-rebase idiom; (4) trap ordering so audit-after-cleanup works correctly. All four have well-known solutions that map cleanly onto the existing codebase patterns.

**Primary recommendation:** Implement with **GIT_ASKPASS helper pattern** (write a one-line askpass script to `$TMPDIR`, export `GIT_ASKPASS`, never embed PAT in URLs). Use **awk-from-file for redaction** (Phase 15 D-17 / Pitfall 1 is the canonical solution already proven in the codebase). Write audit **AFTER** the push attempt so `report_url` is populated in the same line. Mirror Phase 15's 4-plan wave structure (test scaffold → templates+config → bin integration → installer).

## Project Constraints (from CLAUDE.md)

- **Language:** Bash 5.x for all new code in `bin/claude-secure`. jq 1.7+, python3 (stdlib only), git all available on host.
- **Zero runtime deps:** No new packages. Proxy/validator ban new deps; the same discipline applies here.
- **No network bypass:** The proxy and iptables validator MUST remain the single outbound enforcement point. The git push in Phase 16 uses a profile `.env`-supplied PAT, runs on the host, and never goes through the container stack.
- **Platform targets:** Linux and WSL2. (git, python3, jq, uuidgen, mktemp all POSIX-stable on both.)
- **Security-critical code:** Hook scripts and config are root-owned. Phase 16 does not modify hooks; it only adds to `bin/claude-secure`, `install.sh`, and adds new template files.
- **GSD workflow:** Start work through a GSD command. Plans MUST follow the Nyquist self-healing pattern (Wave 0 writes failing tests; implementation waves flip them green).

## Standard Stack

### Core — Already Present, Zero New Dependencies

| Component | Version | Purpose | Source of Truth |
|-----------|---------|---------|-----------------|
| Bash | 5.2+ | All Phase 16 logic in `bin/claude-secure` | CLAUDE.md; verified `bash --version` = 5.2.21 |
| jq | 1.7+ | JSON extraction, audit line construction via `jq -c` | CLAUDE.md; verified `jq --version` = 1.7 |
| git | 2.43+ | shallow clone, commit, push, pull --rebase | verified `git --version` = 2.43.0 |
| python3 | 3.11+ | UTF-8-safe truncation helper (reused from Phase 15) | CLAUDE.md; verified `python3 --version` = 3.12.3 |
| uuidgen | util-linux 2.39+ | Manual/replay delivery ID generation | verified |
| mktemp | coreutils | Per-spawn clone tempdir | POSIX standard |

**Installation:** None required. Everything is already on the host and already used by Phase 13/15.

### Reuse Map (Clone, Don't Write New Code)

| Existing Function | Line | Phase 16 Reuse |
|-------------------|------|----------------|
| `build_output_envelope()` | 343 | Emits envelope; audit reads `.cost_usd`, `.duration_ms`, `.session_id` from `.claude.*`, status fields from wrapper |
| `build_error_envelope()` | 361 | Same, for error path. Audit reads `.error` as `{{ERROR_MESSAGE}}`. |
| `resolve_template()` | 520 | Clone → `resolve_report_template()` with swapped dir names |
| `_resolve_default_templates_dir()` | 389 | Clone → `_resolve_default_report_templates_dir()` |
| `extract_payload_field()` | 417 | Reused verbatim — truncation LIMIT parameterized (8192 for payload fields, 16384 for RESULT_TEXT) |
| `_extract_to_tempfile()` | 456 | Reused verbatim |
| `_substitute_token_from_file()` | 475 | Reused verbatim (awk-from-file, Pitfall 1 fix) |
| `_substitute_multiline_token_from_file()` | 506 | Reused for RESULT_TEXT (multi-line body) |
| `render_template()` | 568 | Extended with new vars OR cloned to `render_report_template()` with the superset variable map |
| `spawn_cleanup()` | 336 | Extended — clone dir added to cleanup list |
| Profile `.env` loader | 201 (`load_profile_config`) | `REPORT_REPO_TOKEN` is sourced automatically by the existing `source "$pdir/.env"` block |

### Alternatives Considered (and rejected)

| Instead of | Could Use | Why Rejected |
|------------|-----------|--------------|
| GIT_ASKPASS helper script | URL-embedded token (`https://TOKEN@github.com/...`) | Token appears in `ps`, git's own stderr on failure, remote URL stored in `.git/config` of the clone dir (removed by cleanup but still risk-window). GIT_ASKPASS is the git-documented, leak-proof path. |
| GIT_ASKPASS helper script | `git config credential.helper store` / `~/.git-credentials` | Persists PAT to disk. Phase 16 MUST keep it ephemeral. |
| GIT_ASKPASS helper script | `-c credential.helper='!f(){ echo password=$TOKEN; };f'` | Token on command line visible to other users via `ps`. Worse than URL-embedded. |
| Fresh shallow clone per spawn | Cached bare repo + `git fetch` + `git worktree add` | Adds mutable state in `$CONFIG_DIR` that must be locked/reaped/rebased. Violates ephemeral spawn philosophy (D-03). Shallow clone is ~100ms for a small docs repo. |
| jq for audit line | printf + manual JSON escaping | Quoting hazards with embedded quotes/newlines/unicode. `jq -c -n --arg key value` is the safe idiom and what Phase 15 already uses. |
| bash `>>` append | `flock` + `>>` | Overkill. POSIX O_APPEND is atomic up to PIPE_BUF (4096 verified) and D-07 caps each audit line below that. `flock` buys nothing for sub-4KB writes and adds a dep. |
| awk-from-file redaction | `sed -i "s|${val}|<REDACTED:${key}>|g"` | **HARD BAN.** Phase 15 Pitfall 1: any `|`, `\`, `&`, `/` in the secret value breaks sed. Values are by definition user-controlled. Use the Phase 15 awk-from-file pattern. |
| awk-from-file redaction | python3 `str.replace()` helper via subprocess | Also safe, but introduces a second substitution mechanism where Phase 15 already has one proven pattern. Consistency > novelty. |

### Version Verification

- PIPE_BUF on Linux: **4096 bytes** (verified `getconf PIPE_BUF /` = 4096). POSIX requires at least 512, Linux kernel has hardcoded 4096 since 2.6.x. D-07's "each JSON line stays under 4KB" matches this exactly. If an audit line could ever exceed 4KB, O_APPEND atomicity is lost and two spawns could interleave bytes mid-line.
- git 2.43 supports `git clone --depth 1 --branch <name>`, `GIT_ASKPASS`, `-c credential.helper=` override, and `git pull --rebase` — all stable since git 2.0+.
- python3.12 `os.environb` (used by `extract_payload_field` at line 440) is stable since Python 3.2.

## Architecture Patterns

### Recommended Project Structure

```
claude-secure/
├── bin/claude-secure                 # +~250 LOC in do_spawn / new helpers
├── webhook/
│   └── report-templates/             # NEW directory (parallels webhook/templates/)
│       ├── issues-opened.md
│       ├── issues-labeled.md
│       ├── push.md
│       └── workflow_run-completed.md
├── install.sh                        # +1 copy step mirroring 5b (templates)
└── tests/
    ├── test-phase16.sh               # NEW: Nyquist test scaffold (Wave 0)
    └── fixtures/
        ├── github-*.json             # reused from Phase 14/15
        └── report-repo-bare/         # NEW: local bare git repo for integration tests
```

### Pattern A — Fresh Shallow Clone + GIT_ASKPASS (D-03 / D-14)

**What:** Clone target repo into `$TMPDIR/<uuid>-report-clone`, author commit, push, cleanup via trap.

**When to use:** Every `do_spawn` execution where `$REPORT_REPO` is non-empty.

**The GIT_ASKPASS idiom (canonical, leak-proof):**

```bash
# Source: git-scm.com/docs/gitcredentials (git documented env var since 1.7+)
#
# GIT_ASKPASS is invoked by git when it needs a password. The PAT is passed
# via an env var on the helper process (NOT via argv, NOT via URL). GitHub
# over HTTPS accepts "username=x-access-token, password=$PAT" for PATs.
publish_report() {
  local clone_dir commit_msg report_path status
  local pat="${REPORT_REPO_TOKEN:-}"
  local repo_url="${REPORT_REPO:-}"
  local branch="${REPORT_BRANCH:-main}"

  if [ -z "$pat" ] || [ -z "$repo_url" ]; then
    return 2  # skip signal (audit with report_url=null)
  fi

  clone_dir=$(mktemp -d "${TMPDIR:-/tmp}/cs-report-XXXXXXXX")
  _CLEANUP_FILES+=("$clone_dir")  # spawn_cleanup removes it

  # Write one-shot askpass script that echoes the PAT on stdout.
  # Placed inside clone_dir so it's wiped with the clone.
  local askpass="$clone_dir/.askpass.sh"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
# Git invokes this for BOTH Username?: and Password?: prompts.
# First call (Username) -- we want x-access-token.
# Second call (Password) -- we want the PAT.
# We distinguish by matching the prompt text passed as $1.
case "$1" in
  Username*) printf 'x-access-token\n' ;;
  Password*) printf '%s\n' "$GIT_ASKPASS_PAT" ;;
esac
ASKPASS
  chmod 700 "$askpass"

  # Disable any host credential helper; force askpass; silence prompts.
  # Using GIT_TERMINAL_PROMPT=0 ensures a broken askpass fails fast
  # instead of hanging on tty.
  GIT_ASKPASS="$askpass" \
  GIT_ASKPASS_PAT="$pat" \
  GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= -c credential.helper='' \
      clone --depth 1 --branch "$branch" --quiet "$repo_url" "$clone_dir/repo" 2>&1 \
      | sed "s|$pat|<REDACTED:REPORT_REPO_TOKEN>|g" >&2 || return 1
  unset GIT_ASKPASS_PAT  # shrink leak window
  # ... (continues in Pattern E for commit+push)
}
```

**Key details:**
- `GIT_ASKPASS_PAT` (not `GIT_ASKPASS`) carries the secret; `GIT_ASKPASS` is the helper path. Inherited by the askpass child, removed immediately after clone.
- `git -c credential.helper= -c credential.helper=''` doubly overrides any user's `~/.gitconfig` or `/etc/gitconfig` `credential.helper = store` — a forgotten credential helper on the host would otherwise silently shunt the PAT into `~/.git-credentials`.
- `GIT_TERMINAL_PROMPT=0` turns a broken askpass into immediate failure rather than a hung `read` on /dev/tty.
- stderr is piped through `sed` to strip any accidental PAT echo (belt-and-braces; git 2.x does not embed PATs in clone error output, but older git did).
- Clone goes into `$clone_dir/repo` so the askpass script lives one level above it and gets cleaned up with the same rmdir.

**Source:** git-scm.com/docs/gitcredentials (askpass helper protocol); git-scm.com/docs/git (GIT_ASKPASS env var documented since git 1.7.0); GitHub docs on using PATs over HTTPS (`x-access-token` is the conventional username for PAT auth).

### Pattern B — Awk-from-File Secret Redaction (D-15)

**What:** Iterate profile `.env` key/value pairs; for each non-empty value, rewrite the report file in-place, replacing every occurrence of the value with `<REDACTED:$KEY>`. Uses awk reading the secret value from a file to dodge the Pitfall 1 sed escape bug.

**When to use:** Immediately before `git add <report_path>` in the publish flow.

**The code:**

```bash
# D-15: iterate profile .env, redact every non-empty value from the report.
# Uses awk-from-file (Phase 15 Pitfall 1) -- NEVER sed with interpolated value.
redact_report_file() {
  local report_file="$1"
  local env_file="$2"  # $pdir/.env
  local tmp_out tmp_val
  tmp_out=$(mktemp)
  tmp_val=$(mktemp)
  _CLEANUP_FILES+=("$tmp_out" "$tmp_val")

  # Read .env via `set -a; source; set +a` pattern already used by
  # load_profile_config, but we need the key list -- so parse directly.
  # Env format in profile .env: KEY=VALUE on each line, no export prefix,
  # comments start with '#'. Trim CR just in case.
  while IFS='=' read -r raw_key raw_val; do
    # Skip comments, blank lines, malformed
    [[ -z "$raw_key" || "$raw_key" =~ ^[[:space:]]*# ]] && continue
    # Trim optional 'export ' prefix
    raw_key="${raw_key#export }"
    raw_key="${raw_key//[[:space:]]/}"
    [ -z "$raw_key" ] && continue
    # Strip surrounding quotes + CR from value
    raw_val="${raw_val%$'\r'}"
    raw_val="${raw_val#\"}"; raw_val="${raw_val%\"}"
    raw_val="${raw_val#\'}"; raw_val="${raw_val%\'}"
    # D-15: skip empty values (prevents "replace every empty string")
    [ -z "$raw_val" ] && continue

    # Write raw value to a file so awk reads it losslessly
    printf '%s' "$raw_val" > "$tmp_val"

    # In-place redact: for every line, replace all occurrences of the
    # value (read from $tmp_val) with <REDACTED:$raw_key>.
    #
    # Why awk and not sed: the value may contain any of | / \ & $ [ ] ^ * .
    # sed's BRE/ERE escape rules differ per platform and interpolated
    # metacharacters cause the Phase 15 Pitfall 1 class of bugs.
    awk -v repl="<REDACTED:${raw_key}>" -v vfile="$tmp_val" '
      BEGIN {
        # Slurp the secret value (may be multi-byte, may contain special chars)
        value = ""
        first = 1
        while ((getline line < vfile) > 0) {
          if (first) { value = line; first = 0 }
          else       { value = value "\n" line }
        }
        close(vfile)
        if (value == "") exit 0  # nothing to redact
      }
      {
        line = $0
        out = ""
        # Literal (non-regex) substring replace: repeatedly find `value`
        # in `line` via index(), rebuild with `repl`.
        while ((i = index(line, value)) > 0) {
          out = out substr(line, 1, i-1) repl
          line = substr(line, i + length(value))
        }
        print out line
      }
    ' "$report_file" > "$tmp_out"
    mv "$tmp_out" "$report_file"
    : > "$tmp_val"  # zeroize value tempfile between iterations
  done < "$env_file"

  rm -f "$tmp_val"
}
```

**Key details:**
- `index()` + `substr()` in awk does a **literal** substring replace, not a regex match — zero metacharacter hazard.
- Empty values are skipped at the bash level (not awk), so the "replace empty string with `<REDACTED:KEY>` everywhere" bug cannot happen.
- Export prefix (`export FOO=bar`) and surrounding quotes are stripped, matching how `set -a; source .env` would interpret them.
- Keys are matched against `^[[:space:]]*#` to skip comment lines (important: the Phase 12 auth setup writes `# Add secrets below` comments).
- `_CLEANUP_FILES+=("$tmp_val")` registers a cleanup so the value tempfile is wiped by the spawn_cleanup trap even on error paths.
- Multi-line values are supported because awk's `getline` preserves them.

**Edge cases tested by Wave 0:**
- Value contains `|`, `\`, `&`, `/`, `$1` (the sed metacharacters that broke Phase 15)
- Value contains embedded newline (multi-line secrets)
- Value is the empty string — skipped
- Value is the exact string `<REDACTED:FOO>` (already-redacted; no double-wrap — it'll still trigger a replacement if `FOO` and the literal match, which is harmless)
- Two keys with the same value — both redacted, the second one's KEY wins in the replacement string (acceptable)

**Source:** Phase 15 CONTEXT.md Pitfall 1; bin/claude-secure:475 `_substitute_token_from_file` is the canonical pattern this mirrors.

### Pattern C — POSIX Atomic JSONL Append (D-07)

**What:** Bash `>>` redirection on a regular file opens the file with `O_APPEND`. POSIX guarantees that writes of size ≤ PIPE_BUF are atomic when O_APPEND is set — no interleaving between concurrent writers on the same file.

**PIPE_BUF on Linux:** 4096 bytes (verified via `getconf PIPE_BUF /`).

**Invariant:** Each audit JSONL line MUST be ≤ 4096 bytes including the trailing newline.

**Enforcement:**

```bash
# Cap each field that could be unbounded. The only risky fields are:
#   - error message (claude_stderr captured in build_error_envelope)
#   - report_url (bounded by GitHub URL length ~200 chars)
#   - commit_sha (40 chars)
#   - session_id (Claude session UUID, bounded)
# cost/duration/timestamp are all bounded by format.
#
# error_msg is the only field that could exceed budget. Cap at 512 bytes
# in the audit entry. (Full error still surfaces via stderr.)
write_audit_entry() {
  local ts="$1" delivery_id="$2" webhook_id="$3" event_type="$4"
  local profile="$5" repo="$6" commit_sha="$7" branch="$8"
  local cost_usd="$9" duration_ms="${10}" session_id="${11}"
  local status="${12}" report_url="${13}" error_short="${14:-}"

  mkdir -p "$LOG_DIR"
  local audit_file="$LOG_DIR/${LOG_PREFIX}executions.jsonl"

  # Build the line via jq -c so escaping is correct.
  # `--argjson` for typed numeric/null, `--arg` for strings.
  local line
  line=$(jq -cn \
    --arg ts "$ts" \
    --arg delivery_id "$delivery_id" \
    --arg webhook_id "$webhook_id" \
    --arg event_type "$event_type" \
    --arg profile "$profile" \
    --arg repo "$repo" \
    --arg commit_sha "$commit_sha" \
    --arg branch "$branch" \
    --arg session_id "$session_id" \
    --arg status "$status" \
    --arg report_url "$report_url" \
    --arg error_short "$error_short" \
    --argjson cost_usd "${cost_usd:-null}" \
    --argjson duration_ms "${duration_ms:-null}" \
    '{
       ts: $ts,
       delivery_id: $delivery_id,
       webhook_id: (if $webhook_id == "" then null else $webhook_id end),
       event_type: $event_type,
       profile: $profile,
       repo: (if $repo == "" then null else $repo end),
       commit_sha: (if $commit_sha == "" then null else $commit_sha end),
       branch: (if $branch == "" then null else $branch end),
       cost_usd: $cost_usd,
       duration_ms: $duration_ms,
       session_id: (if $session_id == "" then null else $session_id end),
       status: $status,
       report_url: (if $report_url == "" then null else $report_url end),
       error_short: (if $error_short == "" then null else $error_short end)
     }')

  # Byte length guard (D-07). Refuse to write over-budget lines to avoid
  # corrupting JSONL atomicity. 4096 - 1 (newline) = 4095 limit.
  if [ "${#line}" -gt 4095 ]; then
    echo "WARNING: audit line exceeds PIPE_BUF, truncating error_short" >&2
    # Retry with empty error_short
    line=$(jq -cn \
      --arg ts "$ts" --arg delivery_id "$delivery_id" \
      # ... rest of args ...
      '{ ts: $ts, /* ... */ error_short: "<dropped: over-budget>" }')
  fi

  # POSIX O_APPEND atomic write (< PIPE_BUF guaranteed by the guard above).
  printf '%s\n' "$line" >> "$audit_file"
}
```

**Why bash `>>` is sufficient (no flock needed):**
- A single `printf '%s\n' "$line" >> "$file"` is one `write(2)` syscall on Linux with O_APPEND set.
- POSIX says: "If the O_APPEND flag of the file status flags is set, the file offset shall be set to the end of the file prior to each write and no intervening file modification operation shall occur between changing the file offset and the write operation."
- For writes ≤ PIPE_BUF, this is atomic across multiple concurrent writers. The kernel guarantees no interleaving.
- D-07 cites this correctly. The only way to break it is to exceed PIPE_BUF — which the guard above prevents.

**Concurrency surface in Phase 16:**
- Different profiles write to different audit files (different `LOG_PREFIX`) — no contention.
- Multiple concurrent spawns of the **same profile** (Phase 14's semaphore up to 3) CAN collide on the same file. This is where O_APPEND atomicity is load-bearing.
- Within a single `do_spawn`, there is only one `write_audit_entry` call — no self-contention.

**Source:** POSIX.1-2024 `write()` specification; Linux kernel `mm/filemap.c` (write path honors O_APPEND at the VFS layer); `man 2 write` on Linux — "If the O_APPEND file status flag of the file description is set, the file offset is first set to the end of the file before writing."

### Pattern D — Retry-Once-with-Rebase (D-14)

**What:** After building and pushing a report commit, if `git push` returns non-zero due to `non-fast-forward`, run `git pull --rebase` and retry `git push` exactly once. If the second push fails for any reason, audit with `status: "report_push_failed"` and return non-zero from publish (but spawn still exits 0 per D-18).

**Why rebase-not-merge:** Our commit is a single standalone file add; there is no merge history to preserve. Rebasing is the lightest possible conflict-free path.

**Why retry once and not N:** A legitimate upstream conflict will resolve on the first rebase. A persistent failure (branch-protected, no permission, offline) will fail N times — retries are just latency. The user's audit line tells them to investigate manually.

**The code:**

```bash
# Assumes publish_report() has already staged+committed the report file in
# $clone_dir/repo.
push_with_retry() {
  local clone_dir="$1" branch="$2"
  cd "$clone_dir/repo" || return 1

  # First attempt
  if GIT_ASKPASS="$clone_dir/.askpass.sh" \
     GIT_ASKPASS_PAT="$REPORT_REPO_TOKEN" \
     GIT_TERMINAL_PROMPT=0 \
     git push origin "$branch" 2>"$clone_dir/push.err"; then
    return 0
  fi

  # Distinguish non-fast-forward from other failures via stderr pattern.
  # Git's English push-rejection text is stable: "non-fast-forward",
  # "Updates were rejected", "failed to push some refs". A locale-aware
  # implementation would use `LC_ALL=C git push` (recommended to make
  # error parsing deterministic).
  if grep -q -e 'non-fast-forward' -e 'Updates were rejected' "$clone_dir/push.err"; then
    echo "INFO: report push rejected (non-fast-forward). Rebasing and retrying once." >&2
    if ! GIT_ASKPASS="$clone_dir/.askpass.sh" \
         GIT_ASKPASS_PAT="$REPORT_REPO_TOKEN" \
         GIT_TERMINAL_PROMPT=0 \
         git pull --rebase origin "$branch" 2>>"$clone_dir/push.err"; then
      return 1  # pull failed; audit as report_push_failed
    fi
    if GIT_ASKPASS="$clone_dir/.askpass.sh" \
       GIT_ASKPASS_PAT="$REPORT_REPO_TOKEN" \
       GIT_TERMINAL_PROMPT=0 \
       git push origin "$branch" 2>>"$clone_dir/push.err"; then
      return 0
    fi
  fi

  # Any other failure or second-push failure
  sed "s|$REPORT_REPO_TOKEN|<REDACTED:REPORT_REPO_TOKEN>|g" "$clone_dir/push.err" >&2
  return 1
}
```

**Locale lock:** Prepend `LC_ALL=C` to every git invocation in publish so error text is deterministic (English). GitHub CI docs and `git` man pages both recommend this for parsing.

**Never force-push:** D-14 is explicit. The code must NOT contain `--force`, `-f`, `+<branch>`, or `--force-with-lease`. Wave 0 test must grep the rendered `bin/claude-secure` for any of these patterns and fail the build if found.

**Source:** git-scm.com/docs/git-push (non-fast-forward rejection contract); D-14 of 16-CONTEXT.md.

### Pattern E — Audit AFTER Push (D-17 + Claude's Discretion note)

**What:** The audit entry must carry `report_url` when push succeeded. So the write order is:

1. Build envelope (success or error)
2. Attempt `publish_report` → returns a `report_url` on success, empty on skip/failure, and a status code
3. Build status field based on envelope + publish result
4. `write_audit_entry` with the final values
5. Return spawn exit code per D-18

```bash
# Inside do_spawn success branch:
build_output_envelope "$PROFILE" "$event_type" "$claude_stdout" > "$envelope_file"
report_url=""
report_status="success"
if publish_report_out=$(publish_report "$envelope_file" "success" 2>&1); then
  report_url=$(printf '%s' "$publish_report_out" | tail -1)  # URL on last line
else
  case $? in
    2) report_status="success"; report_url="" ;;  # skipped (no repo configured)
    *) report_status="report_push_failed"; report_url="" ;;
  esac
fi
write_audit_entry ... "$report_status" "$report_url"
cat "$envelope_file"  # preserve stdout contract for callers
return 0
```

**Important:** `spawn_cleanup` (trap EXIT) removes the clone dir. The trap fires AFTER `write_audit_entry` completes because `write_audit_entry` is called from inside `do_spawn` which returns normally. Traps fire on function return only if the trap is scoped at that point — here, `trap spawn_cleanup EXIT` is global, so it fires at shell exit. Safe.

### Pattern F — Report Template Resolution (D-08)

Clone `resolve_template()` to `resolve_report_template()`, changing:
- Profile path: `$profile_dir/prompts/${event_type}.md` → `$profile_dir/report-templates/${event_type}.md`
- Env var: `WEBHOOK_TEMPLATES_DIR` → `WEBHOOK_REPORT_TEMPLATES_DIR`
- App dir fallback: `$APP_DIR/webhook/templates/` → `$APP_DIR/webhook/report-templates/`
- Prod fallback: `/opt/claude-secure/webhook/templates/` → `/opt/claude-secure/webhook/report-templates/`

**Recommendation:** Parameterize with a single dir-name argument rather than duplicating the function. Pseudo-diff:

```bash
# Before (Phase 15):
_resolve_default_templates_dir() { ... /opt/.../webhook/templates ... }

# After (Phase 16):
_resolve_default_templates_dir() {
  local subdir="${1:-templates}"  # "templates" or "report-templates"
  if [ -n "${WEBHOOK_TEMPLATES_DIR:-}" ] && [ "$subdir" = "templates" ]; then
    echo "$WEBHOOK_TEMPLATES_DIR"; return
  fi
  if [ -n "${WEBHOOK_REPORT_TEMPLATES_DIR:-}" ] && [ "$subdir" = "report-templates" ]; then
    echo "$WEBHOOK_REPORT_TEMPLATES_DIR"; return
  fi
  if [ -n "${APP_DIR:-}" ] && [ -d "$APP_DIR/.git" ] && [ -d "$APP_DIR/webhook/$subdir" ]; then
    echo "$APP_DIR/webhook/$subdir"; return
  fi
  echo "/opt/claude-secure/webhook/$subdir"
}
```

Same treatment for `resolve_template`. Keeps test surface small and avoids drift.

### Pattern G — Report Variable Extension

`render_report_template` is `render_template` + the six new variables. Three of the six live in the Claude envelope (cost_usd, duration_ms, session_id), two come from the wrapper (timestamp, status), one comes from the error path (error_message), and one is special (result_text — multiline, potentially large).

```bash
render_report_template() {
  local template_path="$1" event_json="$2" envelope_json="$3" status="$4"
  local rendered
  rendered=$(render_template "$template_path" "$event_json")  # all Phase 15 vars
  local v_file

  # D-10 extensions:

  # RESULT_TEXT: multiline, up to 16KB, UTF-8-safe via extract_payload_field
  # with LIMIT=16384 (double the 8192 used for payload fields).
  v_file=$(_extract_result_text_to_tempfile "$envelope_json")
  rendered=$(_substitute_multiline_token_from_file "$rendered" "RESULT_TEXT" "$v_file")

  # Simple single-line metadata vars
  v_file=$(_extract_to_tempfile "$envelope_json" '.claude.cost_usd // .claude.cost // null | tostring' "null")
  rendered=$(_substitute_token_from_file "$rendered" "COST_USD" "$v_file")

  v_file=$(_extract_to_tempfile "$envelope_json" '.claude.duration_ms // .claude.duration // null | tostring' "null")
  rendered=$(_substitute_token_from_file "$rendered" "DURATION_MS" "$v_file")

  v_file=$(_extract_to_tempfile "$envelope_json" '.claude.session_id // null' "")
  rendered=$(_substitute_token_from_file "$rendered" "SESSION_ID" "$v_file")

  # Wrapper-generated
  v_file=$(mktemp); _CLEANUP_FILES+=("$v_file")
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$v_file"
  rendered=$(_substitute_token_from_file "$rendered" "TIMESTAMP" "$v_file")

  printf '%s' "$status" > "$v_file"
  rendered=$(_substitute_token_from_file "$rendered" "STATUS" "$v_file")

  v_file=$(_extract_to_tempfile "$envelope_json" '.error // empty' "")
  rendered=$(_substitute_multiline_token_from_file "$rendered" "ERROR_MESSAGE" "$v_file")

  echo "$rendered"
}
```

**Critical:** `.claude.cost_usd // .claude.cost` fallback handles the Phase 13 comment at bin/claude-secure:765 — Claude Code's `--output-format json` has shipped with both field names historically. Same for duration.

### Anti-Patterns to Avoid

- **`sed -i "s/$val/<REDACTED>/g"` for redaction.** Phase 15 Pitfall 1 in a different costume. Use Pattern B.
- **Embedding PAT in remote URL** (`https://TOKEN@github.com/...`). Pattern A's askpass is the only safe path.
- **Persistent credential helper** (`git config --global credential.helper store`). Persists PAT to `~/.git-credentials`. Never do this.
- **Cached bare repo** under `$CONFIG_DIR/.report-cache/`. Violates ephemeral spawn philosophy (D-03), introduces locking concerns.
- **`flock` on the audit file.** Unnecessary for < PIPE_BUF writes; adds dependency drift.
- **`jq -j` (no newline)** for audit output. Must be `jq -c` (compact) then `printf '%s\n'` so the newline is appended by bash, not by jq — controls line-length guard.
- **Force-pushing the report branch** under any circumstance. Banned by D-14.
- **`git clone` without `-c credential.helper=`** override. A host with `credential.helper=store` configured globally could intercept the PAT and store it to disk.
- **Running the redaction pass AFTER `git add`.** Index is content-addressed; redacting the working tree after `git add` results in the pre-redaction blob being committed. Redact → `git add` → commit. Wave 0 test must verify via a seeded secret in `.env`.
- **Treating `push: Everything up-to-date` as failure.** After a rebase where our commit was already upstream (e.g., replay of a previously-pushed delivery), git returns 0 with "Everything up-to-date". That IS success; the audit should record the existing URL, not push_failed.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Secret value substring replace | Regex engine in bash | Pattern B awk-from-file | Metacharacter hazards; Phase 15 Pitfall 1 is the canonical warning |
| PAT injection into git | URL embedding / manual git credential file | GIT_ASKPASS helper (Pattern A) | Leak prevention; git 2.x documented API |
| JSONL building | printf + manual JSON escape | `jq -cn --arg ...` | jq handles all escaping; already proven in build_output_envelope |
| Multi-line token substitution | sed `N;` hold-space gymnastics | `_substitute_multiline_token_from_file` | Already written in Phase 15 |
| UTF-8-safe truncation | bash `${s:0:N}` | `extract_payload_field` python3 helper | Byte-based bash truncation splits multi-byte codepoints; Phase 15 Pitfall 4 |
| Clone cleanup | `find $TMPDIR -name 'cs-report-*' -delete` | `_CLEANUP_FILES+=("$clone_dir")` + existing trap | Reuses Phase 13 trap; zero risk of stale cleanup patterns |
| Audit log rotation | logrotate wrapper | Defer to Phase 17 or operator's logrotate config | Out of scope for v2.0; LOG_PREFIX already segments by instance |
| Git credential storage | `~/.git-credentials` | Ephemeral askpass script in TMPDIR | PAT never touches disk outside TMPDIR |
| Default template prose | Copy-paste from other projects | Minimal, action-oriented templates (Phase 15 D-14 discretion) | Users override per-profile; ship the smallest useful stub |

**Key insight:** Every primitive Phase 16 needs is already in `bin/claude-secure`. The phase is ~250 LOC of glue + 4 template files + 1 install step + 1 Wave 0 test file. Treat new-code-from-scratch as a code smell.

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **None** — Phase 16 does not migrate any existing data. Audit log is a new file (`$LOG_DIR/${LOG_PREFIX}executions.jsonl`). Report repo content is produced anew. Profile.json schema gains new OPTIONAL fields (`report_repo`, `report_branch`, `report_path_prefix`) — existing profiles read them as `null`/absent and silently skip report push per D-02. | None. No migration. |
| Live service config | **None** — Phase 16 does not touch the webhook listener's live config (`/etc/claude-secure/webhook.json`). It only adds bash-level logic to `bin/claude-secure`. systemd unit file is unchanged (still runs the same listener.py). | None. |
| OS-registered state | **None** — No new systemd units, no new cron jobs, no new Task Scheduler entries. The existing `claude-secure-webhook.service` continues to invoke the same `bin/claude-secure spawn` binary, which now has extra publishing logic baked in. | None. |
| Secrets / env vars | **NEW env var:** `REPORT_REPO_TOKEN` in each profile's `.env`. Documentation update required (Phase 12 profile creator prompts should mention it, but that's a nice-to-have — operator can manually add it). Existing profiles without the var silently skip report push (per D-02), so rollout is zero-risk. Two new **transient** shell env vars inside `publish_report()`: `GIT_ASKPASS`, `GIT_ASKPASS_PAT`, `GIT_TERMINAL_PROMPT`, `LC_ALL`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL`. All scoped to the subshell / command, not exported globally. | Document `REPORT_REPO_TOKEN` in README. Optionally extend `create_profile` / `setup_profile_auth` to prompt for it. |
| Build artifacts / installed packages | **One new installer step** (mirroring install.sh step 5b): `/opt/claude-secure/webhook/report-templates/*.md` must be copied during `install.sh --with-webhook`. Fresh installs after Phase 16 get it automatically. Existing installs that ran `install.sh --with-webhook` BEFORE Phase 16 must re-run it to pick up the new directory — or manually `cp webhook/report-templates/* /opt/claude-secure/webhook/report-templates/`. | Installer re-run required on existing hosts. Note in phase summary. |

**Nothing found in categories marked "None" above** — verified by grep of `bin/claude-secure`, `install.sh`, `webhook/listener.py`, `.planning/STATE.md`, and existing profile.json fields.

## Common Pitfalls

### Pitfall 1: Redaction Runs Against Rendered Template, Not Envelope
**What goes wrong:** Developer adds a redaction pass that scrubs `claude_stdout` (the raw envelope) instead of the rendered report file. The rendered report goes to git with secrets intact because the redaction was a no-op on a different buffer.
**Why it happens:** "Redact before commit" is ambiguous — the template is rendered from the envelope, but the committed artifact is the **rendered** file on disk.
**How to avoid:** Redaction runs on the report file path, not the envelope variable. Pattern B takes `$report_file` (a path), not a JSON string.
**Warning sign:** Grep the implementation for `redact_report_file.*envelope` or `redact_report_file.*\$rendered` — smell.
**Test:** Inject a known secret `FOO=hunter2` into profile `.env`, include `{{ERROR_MESSAGE}}` containing `hunter2` in the template, run spawn, grep committed file for `hunter2` → must be 0 matches; grep for `<REDACTED:FOO>` → must be ≥ 1.

### Pitfall 2: Claude Result Text Contains `{{VAR}}` Tokens That Collide with Template Variables
**What goes wrong:** Claude's reply contains literal `{{ISSUE_TITLE}}` (e.g., user asked Claude to explain how templating works). When `{{RESULT_TEXT}}` is substituted into the report, the inner `{{ISSUE_TITLE}}` gets RE-substituted because render passes in a loop — resulting in Claude's doc being rewritten with the real issue title.
**Why it happens:** `render_template` + the new result-specific vars chain-substitute. Order of substitutions matters: if RESULT_TEXT is substituted before other vars, the embedded `{{ISSUE_TITLE}}` is seen as a template token on the next pass.
**How to avoid:** Substitute `{{RESULT_TEXT}}` and `{{ERROR_MESSAGE}}` **LAST**, after all other tokens have been replaced in the template. Then no further substitution passes run.
**Warning sign:** `render_report_template` calls `_substitute_*_from_file` for RESULT_TEXT before other vars.
**Test:** Fixture Claude envelope `.claude.result = "Use {{ISSUE_TITLE}} like this"`, template contains `{{RESULT_TEXT}}`, separate event with `.issue.title = "actual title"`. Rendered file must contain literal `{{ISSUE_TITLE}}`, NOT "actual title".

### Pitfall 3: git clone Outputs PAT in Error Messages on Older Git Versions
**What goes wrong:** git < 2.17 includes the full remote URL (with embedded credentials if any) in network error messages. Even though Pattern A avoids URL-embedded PATs, some credential helpers chain together and log PATs to stderr.
**Why it happens:** Paranoia is cheap; log-scrubbing is cheaper than a leaked token.
**How to avoid:** Pipe git stderr through `sed "s|$REPORT_REPO_TOKEN|<REDACTED:REPORT_REPO_TOKEN>|g"` before forwarding to the operator's stderr. Shown in Pattern A.
**Test:** Point `REPORT_REPO` at an unreachable host, run spawn with `REPORT_REPO_TOKEN=hunter2`, capture stderr, grep for `hunter2` → 0 matches.

### Pitfall 4: CRLF / NUL Bytes in Claude result Break git commit
**What goes wrong:** Claude occasionally emits Windows line endings (`\r\n`) or embedded NULs in long outputs. git handles CRLF fine with `core.autocrlf=false` but NULs can cause "error: embedded null byte" on some git configurations.
**Why it happens:** Claude's underlying LLM is multilingual; when it processes binary-ish content, NULs sometimes survive.
**How to avoid:** `extract_payload_field` already strips control chars except `\n \r \t` (line 441-442 of bin/claude-secure). Reuse it for RESULT_TEXT via `_extract_to_tempfile`. Additionally, force `core.autocrlf=false` on the clone with `git -c core.autocrlf=false`.
**Warning sign:** New helper that reads `.claude.result` directly via `jq -r` without passing through `extract_payload_field`.
**Test:** Fixture envelope with `\x00` and `\r\n` in `.claude.result`, assert rendered report file contains neither.

### Pitfall 5: Cost Field Name Variation (`cost` vs `cost_usd`)
**What goes wrong:** bin/claude-secure:765 already notes: "cost_usd/cost, duration_ms/duration". Claude Code has shipped both field names. Audit entry reads the wrong one, gets null, operator thinks their spawns are free.
**Why it happens:** Upstream versioning instability.
**How to avoid:** All cost/duration reads use `.claude.cost_usd // .claude.cost // null` fallback. Same for duration_ms/duration.
**Warning sign:** Audit-writer or template-renderer references `.claude.cost_usd` without the fallback.
**Test:** Run against two fixture envelopes — one with `cost_usd`, one with legacy `cost`. Both must produce non-null `cost_usd` in audit and `{{COST_USD}}` in report.

### Pitfall 6: git push Returns 0 with "Everything up-to-date" — Treated as Failure
**What goes wrong:** After `git pull --rebase`, if our commit is already upstream (replay of same delivery_id), the next `git push` succeeds with `Everything up-to-date`. Some parsers look for "Writing objects" and conclude "no push happened == failure".
**Why it happens:** Not-empty output is not a success signal; exit code is.
**How to avoid:** Use exit code only. `git push` returning 0 is success regardless of stdout. Generate `report_url` from the known report path + branch + repo, not by parsing git output.
**Test:** Seed the clone dir with a commit already upstream, call `push_with_retry`, assert exit 0 and audit `status: success`.

### Pitfall 7: delivery_id is Missing on Manual Spawn
**What goes wrong:** User runs `claude-secure spawn --profile X --event '{...}'` with a hand-crafted event that has no webhook envelope (no `_meta.delivery_id`, no `X-GitHub-Delivery`). Audit entry's `delivery_id` is empty, filename substitution (`<delivery_id_short>`) becomes `<event_type>-.md` — all manual spawns overwrite each other.
**Why it happens:** D-06 says `delivery_id` is mandatory. Phase 14 ensures it for webhook-triggered spawns. Manual/replay do not.
**How to avoid:** Generate a synthetic delivery_id in do_spawn when absent. D-06 already allows `"replay-<uuid>"` and `"manual-<uuid>"`. Emit: `delivery_id="manual-$(uuidgen | tr -d '-' | head -c 32)"` when `.delivery_id` is empty and `.via_replay` is not set.
**Warning sign:** audit writer treats `.delivery_id` as an optional `// empty` field with no fallback.
**Test:** Run spawn twice with distinct events but no `_meta`. Assert two distinct audit entries and two distinct report files (different suffixes).

### Pitfall 8: LOG_DIR Does Not Exist on First Spawn
**What goes wrong:** Fresh profile has never spawned before. `$LOG_DIR` is `$CONFIG_DIR/logs` but only `mkdir -p`-ed by the interactive path (line 1122). Audit writer blows up.
**Why it happens:** Different code paths create LOG_DIR at different points.
**How to avoid:** `write_audit_entry` must begin with `mkdir -p "$LOG_DIR"`. Already shown in Pattern C.
**Test:** `rm -rf $LOG_DIR`, run spawn, assert spawn succeeds and audit file exists.

### Pitfall 9: Branch Protection Rejects Push with Non-Rebaseable Error
**What goes wrong:** Report branch has "Require signed commits" or "Require pull request" enabled on GitHub. git push returns a rejection that is NOT `non-fast-forward`; it's `protected branch hook declined`. Pattern D's retry only fires on non-fast-forward, so it falls through to the error path. Audit correctly marks `report_push_failed`, operator sees the stderr. Good — this is the expected behavior.
**Why it happens:** D-14 is clear: non-fast-forward retries are limited to that class. Other rejections are unrecoverable.
**How to avoid:** Nothing to avoid — this is correct behavior. Just document in the phase summary so the operator knows: "If your report branch is protected, configure it to allow push from the PAT's user or disable protection for report paths."
**Test:** Mock a push failure with stderr `remote: error: GH006: Protected branch update failed`, assert: no retry, audit `report_push_failed`, spawn exit 0.

### Pitfall 10: Trap Ordering — Cleanup Removes Clone Dir Before Audit Read
**What goes wrong:** Developer writes `spawn_cleanup` to delete the clone dir BEFORE the audit write. The audit tries to pull `report_url` from the clone dir metadata → empty. Or, worse, reads from an already-deleted tempfile for RESULT_TEXT.
**Why it happens:** Trap EXIT fires on shell exit, NOT on function return. But a poorly-written helper may call `spawn_cleanup` manually before `write_audit_entry`.
**How to avoid:** Never call `spawn_cleanup` explicitly. Let the trap fire at shell exit. Audit write happens inside `do_spawn`, which runs to completion and then the shell starts tearing down.
**Warning sign:** Any call to `spawn_cleanup` outside the trap declaration.
**Test:** Grep the final code for `spawn_cleanup` call sites; only `trap spawn_cleanup EXIT` allowed.

### Pitfall 11: REPORT_REPO Points to an Unreachable Host — Clone Hangs
**What goes wrong:** Network is down or DNS fails. `git clone` hangs on TCP connect. Spawn lifecycle blocks forever.
**Why it happens:** No default timeout on `git clone`.
**How to avoid:** `GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=30 git clone ...` — git aborts if transfer rate drops below 1 byte/sec for 30 seconds. (These are git's own documented env vars since 1.7+.) Additionally, wrap the whole clone in `timeout 60 git clone ...` as a belt-and-braces hard cap.
**Test:** Point REPORT_REPO at `https://127.0.0.1:1/nonexistent.git` (refused connection), assert spawn completes in < 70 seconds with `status: report_push_failed`.

### Pitfall 12: Target Branch Does Not Exist in Report Repo
**What goes wrong:** Operator configured `report_branch: "reports-2026"` but forgot to create the branch. `git clone --branch reports-2026` fails with `Remote branch reports-2026 not found`.
**Why it happens:** Operator error, unrecoverable without operator action.
**How to avoid:** Fail fast. Audit `report_push_failed`, surface the git stderr (redacted per Pitfall 3), exit 0. Document in phase summary: "If the report_branch does not exist on the remote, create it manually with an empty commit."
**Test:** Point at a local bare repo with only `main`, configure `report_branch: "missing"`, assert `report_push_failed`.

### Pitfall 13: Template Contains Literal `{{` That is NOT a Variable
**What goes wrong:** A user's custom template contains `{{ISSUE_TITLE}}` and also a literal `{{ this is a comment }}` that is not any known variable. Phase 15's `_substitute_token_from_file` only replaces explicit known token names — literal `{{` text is preserved. No bug. But a developer might add a generic pass that strips all `{{...}}` patterns, breaking this.
**How to avoid:** Substitution is always keyed on a specific token name passed to `_substitute_token_from_file`. Never implement a wildcard `{{.*}}` pass. Phase 16 keeps this contract.
**Test:** Template with literal `{{NOT_A_VAR}}`, assert it survives rendering unchanged.

### Pitfall 14: Concurrent Same-Profile Spawns Race on executions.jsonl
**What goes wrong:** Profile X is spawned by webhook and by replay simultaneously (Phase 14 semaphore allows 3). Both hit the same `$LOG_DIR/${LOG_PREFIX}executions.jsonl`. Under POSIX O_APPEND this is safe (< PIPE_BUF) — but the guard in Pattern C must actually be enforced, not just documented.
**Why it happens:** D-07 is correct; a sloppy implementation that uses `echo "$line" >> file` instead of a pre-checked `printf '%s\n' "$line"` can slip over the limit if someone later adds a verbose `error_short` field.
**How to avoid:** Pattern C's `if [ "${#line}" -gt 4095 ]` guard is mandatory. Wave 0 test generates a synthetic 5KB error_short and asserts the audit line still fits under 4KB (error_short replaced with sentinel).
**Test:** Generate an 8KB fake claude stderr, run through write_audit_entry, verify resulting line ≤ 4095 bytes.

## Critical Validation Map

| Requirement | Decision | Validation Technique | Test Command (pseudo) |
|-------------|----------|---------------------|----------------------|
| OPS-01 | Report is pushed after successful spawn | Spawn against local bare repo; verify git log count | `git -C $TEST_REPO log origin/main --oneline \| wc -l → 1` |
| OPS-01 / D-12 | Filename follows `<prefix>/<YYYY>/<MM>/<type>-<id8>.md` | Regex-match the only file in the commit | `git -C $TEST_REPO show --name-only HEAD \| grep -E 'reports/[0-9]{4}/[0-9]{2}/issues-opened-[a-f0-9]{8}\.md'` |
| OPS-01 / D-13 | Commit message matches `report(...)` pattern | Parse `git log -1 --format=%s` | `git -C $TEST_REPO log -1 --format=%s \| grep -E '^report\\(issues-opened\\): owner/repo [a-f0-9]{8}$'` |
| OPS-01 / D-14 | No force push, rebase retry on conflict | Grep bin/claude-secure for `--force`, `-f`, `+refs` | `grep -E 'git push.*(--force\|--force-with-lease\|-f)' bin/claude-secure → 0 matches` |
| OPS-01 / D-14 | Second push failure audited, exit 0 | Inject permanent rejection, assert both invariants | `echo $? == 0` AND `jq .status executions.jsonl \| tail -1 == "report_push_failed"` |
| OPS-01 / D-15 | Secret values from .env are NOT in committed report | Seed `.env` with `FAKESEC=hunter2abc`, include it in fixture template, grep committed file | `git -C $TEST_REPO show HEAD:reports/.../issues-opened-*.md \| grep -c hunter2abc → 0` AND `grep -c '<REDACTED:FAKESEC>' → ≥ 1` |
| OPS-01 / D-15 | Empty .env values do not cause global blank-replace | Seed `.env` with `EMPTY=` and a fixture body "hello world" | `git show HEAD:reports/... \| md5sum == md5sum of source template with vars substituted` |
| OPS-01 / Pitfall 3 | PAT is NOT in any stderr/stdout of a failed clone | Point at unreachable host, capture all output, grep for PAT | `run spawn 2>&1 \| grep -c $REPORT_REPO_TOKEN → 0` |
| OPS-01 / Pitfall 11 | Clone times out rather than hanging forever | Point at refused host, wall-clock the spawn | `time spawn → < 70s` |
| OPS-02 / D-04 | Audit written to correct path | File exists after spawn at exact path | `test -f $LOG_DIR/${LOG_PREFIX}executions.jsonl` |
| OPS-02 / D-05 | Audit written even when webhook path is not involved (replay) | Replay a stored delivery, assert audit entry added | `jq -c . < executions.jsonl \| wc -l == N+1` |
| OPS-02 / D-06 | All mandatory keys present | jq pipeline checks each key exists | `jq -e 'has("ts") and has("delivery_id") and has("webhook_id") and has("event_type") and has("profile") and has("repo") and has("commit_sha") and has("branch") and has("cost_usd") and has("duration_ms") and has("session_id") and has("status") and has("report_url")' < (tail -1 executions.jsonl)` |
| OPS-02 / D-06 | status enum is correct | jq value check | `jq -r .status executions.jsonl \| sort -u \| comm -23 - <(printf 'claude_error\\nreport_push_failed\\nspawn_error\\nsuccess\\n')` should be empty |
| OPS-02 / D-07 | JSONL file is line-parseable | `jq -c '.' < file` must succeed on every line | `while read l; do echo "$l" \| jq -e . >/dev/null \|\| exit 1; done < executions.jsonl` |
| OPS-02 / D-07 | Each line ≤ 4095 bytes | awk line-length check | `awk 'length > 4095 { exit 1 }' executions.jsonl` |
| OPS-02 / D-17 | Spawn error produces audit with status=spawn_error | Trigger profile validation error before claude runs | `jq -r .status executions.jsonl \| tail -1 == "spawn_error"` |
| OPS-02 / D-17 | Claude error produces audit with status=claude_error | Stub claude to exit 1 | `jq -r .status executions.jsonl \| tail -1 == "claude_error"` |
| OPS-02 / D-17 | Push failure produces audit with status=report_push_failed AND exit 0 | Unreachable REPORT_REPO + successful claude | `jq -r .status \| tail -1 == "report_push_failed"` AND `echo $? == 0` |
| OPS-02 / Pitfall 14 | Concurrent appends do not interleave | Run two spawns in parallel via `&`, verify both lines jq-valid | `jq -c . < executions.jsonl \| wc -l == 2 && jq -e .delivery_id` |
| OPS-02 / Pitfall 5 | cost_usd / duration_ms fallback to legacy names | Two fixtures (new + legacy schema), audit both | `jq -r .cost_usd executions.jsonl` non-null for both |
| OPS-02 / Pitfall 7 | Manual spawn gets synthetic delivery_id | Run spawn without `_meta.delivery_id` twice with different events | `jq -r .delivery_id executions.jsonl \| tail -2 \| uniq -u \| wc -l == 2` |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | All Phase 16 code | ✓ | 5.2.21 | — |
| jq | Audit line construction, payload extraction | ✓ | 1.7 | — |
| git | Clone, commit, push, pull --rebase, check credential helper override | ✓ | 2.43.0 | — (hard requirement) |
| python3 | `extract_payload_field` helper (UTF-8-safe truncation) | ✓ | 3.12.3 | — |
| uuidgen | Synthetic delivery_id for manual spawns | ✓ | util-linux 2.39.3 | `cat /proc/sys/kernel/random/uuid` |
| mktemp | Per-spawn clone tempdir, askpass file, tmp value files | ✓ | coreutils | — |
| awk | Pattern B redaction (gawk or mawk both fine) | ✓ | (standard) | — |
| GitHub connectivity (github.com:443 from host) | `git clone` and `git push` when report_repo is a GitHub URL | assumed available on host (webhook listener already depends on same egress for replies) | — | Audit records `report_push_failed`; spawn still exits 0 (D-18) |

**Missing dependencies with no fallback:** None. Every tool Phase 16 needs is already present on any host that can run Phase 13–15.

**Missing dependencies with fallback:** None required.

**Network dependency note:** Phase 16 needs outbound HTTPS to the configured report repo host (typically github.com). This runs on the HOST, NOT inside the isolated container stack. Thus it does NOT go through the proxy + validator. This is a trust decision: the operator has configured a PAT with push access; the host is trusted to push it. Per D-01, the same PAT is also redacted by the Anthropic proxy if it ever leaks into an LLM context.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash integration test harness (same as test-phase14.sh / test-phase15.sh) |
| Config file | None — inline harness in `tests/test-phase16.sh` |
| Quick run command | `bash tests/test-phase16.sh` |
| Full suite command | `bash tests/test-phase16.sh` (no slow/fast split in this style) |
| Per-test runner | `bash tests/test-phase16.sh test_<name>` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| OPS-01 | Successful spawn pushes a report commit to the configured local bare repo | integration | `bash tests/test-phase16.sh test_report_push_success` | ❌ Wave 0 |
| OPS-01 | Report filename matches `<prefix>/YYYY/MM/<type>-<id8>.md` | integration | `bash tests/test-phase16.sh test_report_filename_format` | ❌ Wave 0 |
| OPS-01 | Commit message matches conventional `report(<type>): <repo> <id8>` | integration | `bash tests/test-phase16.sh test_commit_message_format` | ❌ Wave 0 |
| OPS-01 | NO force-push flags anywhere in `bin/claude-secure` | static | `bash tests/test-phase16.sh test_no_force_push_grep` | ❌ Wave 0 |
| OPS-01 | Push rejected with non-fast-forward triggers `git pull --rebase` and retries once | integration | `bash tests/test-phase16.sh test_rebase_retry` | ❌ Wave 0 |
| OPS-01 | Permanent push failure → `status: report_push_failed`, spawn exit 0 | integration | `bash tests/test-phase16.sh test_push_failure_audit_and_exit` | ❌ Wave 0 |
| OPS-01 | Secret value from `.env` is replaced with `<REDACTED:KEY>` in committed file | integration | `bash tests/test-phase16.sh test_secret_redaction_committed` | ❌ Wave 0 |
| OPS-01 | Empty-value env entries do NOT cause global blanking | unit | `bash tests/test-phase16.sh test_redaction_empty_value_noop` | ❌ Wave 0 |
| OPS-01 | `.env` value containing `|`, `&`, `\`, `/` redacts correctly (awk, not sed) | unit | `bash tests/test-phase16.sh test_redaction_metacharacters` | ❌ Wave 0 |
| OPS-01 | PAT never appears in stderr on clone failure | integration | `bash tests/test-phase16.sh test_pat_not_leaked_on_failure` | ❌ Wave 0 |
| OPS-01 | Report template fallback chain resolves profile → env var → dev → prod | unit | `bash tests/test-phase16.sh test_report_template_fallback` | ❌ Wave 0 |
| OPS-01 | Unconfigured `report_repo` silently skips push (audit still written) | integration | `bash tests/test-phase16.sh test_no_report_repo_skips_push` | ❌ Wave 0 |
| OPS-01 | `RESULT_TEXT` >16KB is truncated UTF-8-safely | unit | `bash tests/test-phase16.sh test_result_text_truncation` | ❌ Wave 0 |
| OPS-01 | RESULT_TEXT / ERROR_MESSAGE substituted LAST (Pitfall 2 — no re-render) | unit | `bash tests/test-phase16.sh test_result_text_no_recursive_substitution` | ❌ Wave 0 |
| OPS-01 | CRLF / NUL in result stripped before commit | unit | `bash tests/test-phase16.sh test_crlf_and_null_stripped` | ❌ Wave 0 |
| OPS-01 | Clone timeout (unreachable host) < 70s wall clock | integration | `bash tests/test-phase16.sh test_clone_timeout_bounded` | ❌ Wave 0 |
| OPS-02 | Audit file created at `$LOG_DIR/${LOG_PREFIX}executions.jsonl` | integration | `bash tests/test-phase16.sh test_audit_file_path` | ❌ Wave 0 |
| OPS-02 | LOG_DIR auto-created if missing | integration | `bash tests/test-phase16.sh test_audit_creates_log_dir` | ❌ Wave 0 |
| OPS-02 | Audit entry is valid JSONL (every line jq-parseable) | integration | `bash tests/test-phase16.sh test_audit_jsonl_parseable` | ❌ Wave 0 |
| OPS-02 | All 13 mandatory keys present | integration | `bash tests/test-phase16.sh test_audit_has_mandatory_keys` | ❌ Wave 0 |
| OPS-02 | status is exactly one of {success, spawn_error, claude_error, report_push_failed} | integration | `bash tests/test-phase16.sh test_audit_status_enum` | ❌ Wave 0 |
| OPS-02 | spawn_error path produces audit entry (pre-claude failure) | integration | `bash tests/test-phase16.sh test_audit_spawn_error` | ❌ Wave 0 |
| OPS-02 | claude_error path produces audit with correct error_short | integration | `bash tests/test-phase16.sh test_audit_claude_error` | ❌ Wave 0 |
| OPS-02 | cost_usd / duration_ms / session_id extracted from envelope with legacy fallback | unit | `bash tests/test-phase16.sh test_audit_cost_fallback` | ❌ Wave 0 |
| OPS-02 | Each audit line ≤ 4095 bytes (POSIX atomic-append invariant) | unit | `bash tests/test-phase16.sh test_audit_line_under_pipe_buf` | ❌ Wave 0 |
| OPS-02 | Concurrent spawns of same profile do not interleave audit bytes | integration | `bash tests/test-phase16.sh test_audit_concurrent_safe` | ❌ Wave 0 |
| OPS-02 | Replay spawn produces audit entry identical-shape to webhook spawn | integration | `bash tests/test-phase16.sh test_audit_replay_identical` | ❌ Wave 0 |
| OPS-02 | Manual spawn (no `_meta`) gets synthetic delivery_id (not empty) | integration | `bash tests/test-phase16.sh test_audit_manual_synthetic_id` | ❌ Wave 0 |
| OPS-02 | webhook_id populated from `_meta.webhook_id` when present, null otherwise | unit | `bash tests/test-phase16.sh test_audit_webhook_id_null_when_absent` | ❌ Wave 0 |
| OPS-02 | Phase 13/14/15 tests still pass (regression) | regression | `bash tests/test-phase13.sh && bash tests/test-phase14.sh && bash tests/test-phase15.sh` | ✅ (files exist) |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase16.sh` (full suite — estimated < 15s since most tests are unit/stub, and integration tests use a local bare repo + stub claude-secure)
- **Per wave merge:** Full Phase 16 suite + regression (`bash tests/test-phase13.sh && bash tests/test-phase14.sh && bash tests/test-phase15.sh && bash tests/test-phase16.sh`)
- **Phase gate:** Full suite green across all four phases before `/gsd:verify-work`

### Wave 0 Gaps

All test files need to be created as failing scaffolds in Wave 0:

- [ ] `tests/test-phase16.sh` — top-level harness, ~30 named test functions, stub claude-secure, local bare report repo setup, fixture builder for profile/envelope
- [ ] `tests/fixtures/envelope-success.json` — Claude envelope with `cost_usd`, `duration_ms`, `session_id`, `result` populated
- [ ] `tests/fixtures/envelope-legacy-cost.json` — envelope with legacy `cost` and `duration` field names (Pitfall 5)
- [ ] `tests/fixtures/envelope-large-result.json` — envelope with 20KB result text + embedded CRLF + NUL (Pitfall 4, D-16)
- [ ] `tests/fixtures/envelope-result-with-template-vars.json` — result contains literal `{{ISSUE_TITLE}}` to test Pitfall 2
- [ ] `tests/fixtures/envelope-error.json` — error envelope for claude_error path
- [ ] `tests/fixtures/env-with-metacharacter-secrets` — a `.env` file containing `PIPE_VAL=foo|bar`, `AMP_VAL=x&y`, `SLASH_VAL=/etc/passwd`, `DOLLAR_VAL=$1abc`, `NEWLINE_VAL=line1\nline2`, `EMPTY_VAL=` (Pitfall 1 / Pattern B)
- [ ] `tests/fixtures/report-repo-bare/` — an initialized local bare git repo with `main` branch and one seed commit, restored fresh per test
- [ ] `webhook/report-templates/issues-opened.md` — default template (minimal, demonstrates all variables)
- [ ] `webhook/report-templates/issues-labeled.md` — default template
- [ ] `webhook/report-templates/push.md` — default template
- [ ] `webhook/report-templates/workflow_run-completed.md` — default template (error-friendly, handles both success and failure cases via {{STATUS}})

*(Framework install: none — bash + jq + git + python3 already present; verified via `getconf`, `jq --version`, `git --version`, `python3 --version`.)*

## Open Questions

1. **Should `--skip-report` be a spawn flag or only an env var?**
   - What we know: CONTEXT discretion recommends adding it; it mirrors `--dry-run`.
   - What's unclear: Does the test suite rely on env var (`CLAUDE_SECURE_SKIP_REPORT=1`) or flag parsing?
   - Recommendation: Ship BOTH — `--skip-report` CLI flag AND `CLAUDE_SECURE_SKIP_REPORT=1` env var. Flag wins if both set. Tests use env var so they don't have to pollute REMAINING_ARGS parsing. The flag is documented so an operator can one-off a test spawn without editing their environment. Both paths terminate in the same `SKIP_REPORT=1` branch.

2. **Where should `delivery_id_short` (the 8-char suffix) be computed?**
   - What we know: D-12 says "first 8 chars of the delivery id". Phase 14 uses the first 8 chars of the `X-GitHub-Delivery` UUID.
   - What's unclear: For manual/replay with synthetic `replay-<uuid32>` or `manual-<uuid32>`, should the "short" form be the first 8 of the synthetic UUID, or the first 8 of the `replay-` prefix (which would literally be `replay-<first-1-char>`)?
   - Recommendation: `delivery_id_short` is always the **last 8 hex chars** of the delivery_id after stripping any prefix. For webhook deliveries the UUID has 8+ hex chars anywhere. For `replay-<uuid32>` → last 8 chars of the uuid. For `manual-<uuid32>` → last 8 chars of the uuid. This guarantees uniqueness and readability. Document in Pitfall/plan.

3. **Should the profile-creation prompt (Phase 12 `create_profile`) ask for `REPORT_REPO_TOKEN`?**
   - What we know: New profiles won't have the PAT without operator action.
   - What's unclear: Whether extending `create_profile` is in scope for Phase 16 or defers to Phase 17/polish.
   - Recommendation: Out of scope. Let operators add it manually via `.env` edit. Document clearly in phase summary. The skip-if-empty behavior from D-02 means existing profiles don't break.

4. **Is there an existing `$CONFIG_DIR/events/<delivery_id>.json` file we can use as the source of `webhook_id` for audit?**
   - What we know: Phase 14 persists the event file with `_meta.delivery_id`, `_meta.event_type`, etc. Phase 15 adds top-level `event_type`.
   - What's unclear: Is `_meta.webhook_id` actually set by Phase 14's listener? Need to grep listener.py.
   - Recommendation: (checked) — Phase 14 listener constructs `_meta` with delivery_id + event_type + received_at, but NOT `webhook_id`. GitHub's `X-GitHub-Hook-ID` header is a different value (the numeric webhook install ID). Phase 14 does not capture it. Phase 16 audit entry `webhook_id` will therefore be `null` for every current spawn. This is correct per D-06 (`null if missing`). If webhook_id is desired in future, Phase 14 needs a small extension — logged as deferred.

5. **Should secret redaction ALSO scan for the PAT `REPORT_REPO_TOKEN` itself, even though it would never appear in rendered reports?**
   - What we know: D-15 iterates ALL profile `.env` keys. `REPORT_REPO_TOKEN` is one of them. So yes — it's automatically covered. Double-belt.
   - What's unclear: Nothing. This is a feature of the design.
   - Recommendation: No action needed; Pattern B already covers it. Call it out in Wave 0 test `test_pat_is_redacted_even_if_leaked_into_result`.

6. **Plan-split: confirm the 4-plan wave structure from CONTEXT §specifics?**
   - What we know: CONTEXT recommends Wave 0 test scaffold → Wave 1a config+templates → Wave 1b bin integration → Wave 2 installer. This matches Phase 15 exactly.
   - Assessment: This is the right split. Specifically:
     - **Wave 0 (Plan 16-01):** `tests/test-phase16.sh` + all fixtures + empty `webhook/report-templates/*.md` placeholders. Tests fail because implementation does not exist.
     - **Wave 1a (Plan 16-02):** Populate default templates with real content. Add profile.json schema documentation (just comments / example in README — no validator change). Add the `resolve_report_template` / `_resolve_default_templates_dir(subdir)` helper generalization. LOW code volume, single-file change.
     - **Wave 1b (Plan 16-03):** The big one. `publish_report` + `write_audit_entry` + `redact_report_file` + `render_report_template` + integration into `do_spawn`. Parameter wiring between success/error paths. This is where Waves 0 tests start flipping green.
     - **Wave 2 (Plan 16-04):** Extend `install.sh install_webhook_service` with the step-5c template copy. Update README with REPORT_REPO_TOKEN documentation. Final regression run.
   - Alternative considered: Merge 1a+1b into one plan. **Rejected** because it produces a single huge plan file and drops the test-first ratchet. The discomfort of bridging "templates exist but nothing reads them" across 1a→1b is real but short-lived and is exactly the Nyquist pattern the project uses.
   - Alternative considered: Split 1b further (redaction separate from publish, audit separate from both). **Rejected** because audit and publish share return codes and must be sequenced together; splitting them produces cross-plan coupling that breaks the waves' independence guarantee.
   - Recommendation: **Confirm the 4-plan structure as described.**

7. **Should integration tests use a real remote GitHub repo or a local bare repo?**
   - What we know: Phase 15 tests use stubs and fixtures; no real network.
   - Recommendation: **Local bare repo only.** Create `tests/fixtures/report-repo-bare/` via `git init --bare`, seed with one commit on main, use `file:///` URLs or direct path. Fast, offline, deterministic. Real GitHub testing belongs to manual acceptance.

## Sources

### Primary (HIGH confidence)
- **bin/claude-secure** (project repo, lines 1–1129) — existing functions that Phase 16 reuses/clones. Direct reading.
- **webhook/listener.py** lines 155–206 — JsonlHandler pattern (reference only; Phase 16 writes from bash).
- **install.sh** lines 330–403 — Phase 15 step 5b template installer pattern, mirrored for report-templates.
- **Phase 13/14/15 CONTEXT.md files** — locked decisions that constrain Phase 16 (envelope shape, template chain, do_spawn lifecycle, Pitfalls 1/4/7 from Phase 15).
- **Phase 16 CONTEXT.md** — 18 locked decisions D-01..D-18 (primary constraint).
- **POSIX.1-2024 `write(2)` specification** — O_APPEND atomicity < PIPE_BUF.
- **Linux `man 2 write`** — "If the O_APPEND file status flag is set, the file offset is first set to the end of the file before writing".
- **`getconf PIPE_BUF /`** — verified Linux value of 4096 on target host.
- **`git --version`, `jq --version`, `python3 --version`, `bash --version`** — all verified ≥ required versions on target host.
- **git-scm.com/docs/gitcredentials** — GIT_ASKPASS helper protocol (stable since git 1.7).
- **git-scm.com/docs/git** — GIT_ASKPASS, GIT_TERMINAL_PROMPT, GIT_HTTP_LOW_SPEED_* environment variables.
- **git-scm.com/docs/git-push** — non-fast-forward rejection contract.
- **CLAUDE.md** — project-level tech stack constraints.

### Secondary (MEDIUM confidence)
- **GitHub Docs: "Managing your personal access tokens" / "Caching your GitHub credentials in Git"** — `x-access-token` convention for PAT HTTPS auth (documented since 2019). Training data; not re-verified this session.
- **tests/test-phase15.sh** harness structure — Phase 15's 28-test scaffold pattern for adapting to Phase 16.

### Tertiary (LOW confidence — flagged for validation)
- **Claude Code `--output-format json` field name history (`cost` vs `cost_usd`, `duration` vs `duration_ms`)** — the Phase 13 comment at line 765 notes ambiguity; confirmed by developer observation but no authoritative doc was checked this session. The `.claude.cost_usd // .claude.cost` jq fallback is defensive — implement it either way.
- **Default report template prose** — pure design choice; no authoritative source. Recommendation: minimal markdown, explicit variables, ship-and-iterate.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools already in use, versions verified on host
- Architecture patterns: HIGH — every pattern either clones existing code or uses a documented POSIX/git primitive
- Pitfalls: HIGH — most pitfalls are carry-forwards from Phase 15's catalog plus well-known git gotchas
- Secret redaction: HIGH — direct reuse of Phase 15 Pitfall 1 fix
- JSONL atomicity: HIGH — POSIX specification and kernel behavior verified
- GIT_ASKPASS pattern: HIGH — git-documented, stable since 1.7, broadly used
- Retry-rebase on non-fast-forward: HIGH — standard git workflow
- Default template prose: LOW — aesthetic choice, deferred to planner

**Research date:** 2026-04-12
**Valid until:** 2026-05-12 (30 days — stable POSIX/git primitives, codebase conventions locked)
