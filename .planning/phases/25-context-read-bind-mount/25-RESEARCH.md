# Phase 25: Context Read & Read-Only Bind Mount - Research

**Researched:** 2026-04-14
**Domain:** Host-side sparse shallow git clone + read-only Docker bind mount + spawn-time integration
**Confidence:** HIGH

## Summary

Phase 25 is a localized, additive insertion into `do_spawn`. It wires a host-only `fetch_docs_context` step that performs a sparse shallow clone of the doc repo's `projects/<slug>/` subtree, then injects a read-only bind mount of the resulting subdirectory into the Claude container at `/agent-docs/`. The clone, the mount, and the cleanup all run on the host; the agent never sees a `.git/`, never sees a PAT, and cannot push from inside the container.

Roughly 90% of the machinery already exists in the repo. The Phase 23 alias resolver already exports `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, and `DOCS_REPO_TOKEN` into the host bash process before `do_spawn` runs `docker compose up`. The Phase 16/24 askpass helper pattern handles authenticated clones with PAT scrub on stderr. The `_CLEANUP_FILES` array + `spawn_cleanup` trap already deletes ephemeral clone directories on every spawn-exit path. The empty-repo / wrong-branch fallback logic in `do_profile_init_docs` is reusable verbatim. **Phase 25 ships only:** (1) `fetch_docs_context()` that wraps a sparse shallow clone, (2) a single `${AGENT_DOCS_HOST_PATH}` substitution variable wired into `docker-compose.yml`'s `claude.volumes` block, and (3) a `do_spawn` integration call placed before `docker compose up -d --wait`.

The single highest-severity design decision is **how to exclude `.git/` from the bind mount**. Empirically verified on this host (git 2.43.0): `git clone --depth=1 --filter=blob:none --sparse` always materializes `.git/` at the working tree root, regardless of `--sparse`. Sparse-checkout narrows the working tree but does not affect the `.git/` directory's location. Two viable approaches exist: (a) bind-mount the *subdirectory* `clone/projects/<slug>/` (which contains zero `.git/` references because `.git/` lives at clone root), or (b) copy the sparse-checked subtree into a separate `.git`-free staging dir and mount that. **Recommendation: Option (a) — bind-mount the subdirectory directly.** It avoids a copy, preserves the cleanup model (deleting the parent clone dir wipes both the mount source and the `.git/`), and is what the success criterion 4 example explicitly contemplates ("either uses sparse-checkout to exclude `.git` or copies the checkout into a `.git`-free directory").

**Primary recommendation:** Add `fetch_docs_context()` to `bin/claude-secure` (host-side, ~60 lines). It performs `git clone --depth=1 --filter=blob:none --sparse --branch $DOCS_BRANCH` into `$TMPDIR/cs-agent-docs-<uuid>/repo`, runs `git sparse-checkout set $DOCS_PROJECT_DIR`, registers the parent dir with `_CLEANUP_FILES`, and exports `AGENT_DOCS_HOST_PATH=$clone/repo/$DOCS_PROJECT_DIR`. Add one volume entry to `docker-compose.yml`: `${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro`. Skip silently with one `info` log line when `DOCS_REPO` is empty. Tests verify the four success criteria, with Docker-required tests gated by a `command -v docker` check and unit-testable parts (clone command construction, path derivation, no-docs skip, cleanup registration) covered separately.

## User Constraints (from CONTEXT.md)

**No CONTEXT.md exists for Phase 25** — `/gsd:discuss-phase` has not been run for this phase. The planner should treat the roadmap success criteria (copied verbatim into Phase Requirements below) as the locked decisions, and treat all other design choices as Claude's discretion. The four open questions in this research file flag the items that would benefit from a discussion pass.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CTX-01 | At spawn time, `bin/claude-secure` performs a sparse shallow clone of the doc repo and bind-mounts it read-only into the Claude container at `/agent-docs/` | `fetch_docs_context()` pattern below; sparse-checkout flags verified on host git 2.43.0; Phase 23 already exports `DOCS_REPO`/`DOCS_BRANCH`/`DOCS_PROJECT_DIR`; Phase 24 askpass + clone harness directly reusable |
| CTX-02 | Agent can read `/agent-docs/projects/<slug>/{todo,architecture,vision,ideas}.md` and files under `specs/` when it needs context — no auto-injection into prompt | Bind mount with `:ro` makes the entire subtree readable; volume mounts respect filesystem permissions; the sparse-checkout includes the whole `projects/<slug>/` subtree, not just selected files; "no auto-injection" is the *absence* of any `render_template` change |
| CTX-03 | If the profile has no doc repo configured, context read is skipped silently — spawn is never blocked | Existing `[ -z "$DOCS_REPO" ]` guard pattern (Phase 23 `validate_docs_binding` opt-out); compose `${VAR:-/dev/null}` substitution makes the volume entry inert when the variable is unset |
| CTX-04 | The bind-mounted clone never includes `.git/` — agents cannot push from inside the container | Empirically verified: `.git/` lives at clone root, not inside `projects/<slug>/`; mounting the subdirectory directly excludes `.git/` by path; no `.git/` reference appears anywhere under the project subtree after `sparse-checkout set` |

**Success Criteria Mapping:**
1. Sparse shallow clone + read-only bind mount → `fetch_docs_context()` + `docker-compose.yml` volume entry
2. Container read works, write fails → `:ro` flag on the volume mount; agent gets read-only filesystem error on any write attempt under `/agent-docs/`
3. No-docs-repo path is silent + non-blocking → guard returns 0 with an info log line; `${AGENT_DOCS_HOST_PATH:-/dev/null}` substitution makes the volume inert
4. `.git/` absent from mount → bind-mount the subdirectory `repo/projects/<slug>/` rather than the clone root

## Standard Stack

### Core
**Zero new dependencies.** Every tool required by this phase is already verified by Phases 12, 16, 18, 19, 23, and 24.

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `git` CLI | 2.34+ (host-verified 2.43.0) | Sparse shallow clone of doc repo | Phase 23/24 already use `git clone --depth 1`. `--filter=blob:none --sparse` requires git 2.25+; `git sparse-checkout` subcommand stable since 2.25. Both well below the 2.34 already required. |
| Docker Engine | 24.x+ (host-verified 29.3.1) | Bind mount with `:ro` | Phase 1 baseline. Docker bind mounts honor `:ro` recursively across all child files and subdirectories — verified by Linux kernel `mount(2) MS_RDONLY` semantics. |
| Docker Compose | v2.24+ | `${VAR:-default}` substitution + `volumes:` short syntax | Already in use throughout `docker-compose.yml`; the `${WHITELIST_PATH:-./config/whitelist.json}:/etc/...:ro` line is a working in-tree example of exactly the pattern Phase 25 needs. |
| `bash` | 4+ (re-exec via Phase 18) | Subshell helpers, `mktemp -d`, cleanup trap registration | No new bash idioms introduced. |
| `mktemp` | GNU coreutils (Phase 18 brings GNU on macOS) | `mktemp -d "${TMPDIR:-/tmp}/cs-agent-docs-XXXXXXXX"` | Already used 5+ times in `bin/claude-secure`. |
| `timeout` | GNU coreutils | Bound the sparse clone to a fixed wall-clock budget | Already used in Phase 23/24 clone wrappers (`timeout 60 git clone ...`). |

### Supporting (Reused Functions)

The phase reuses these existing functions verbatim or with small extension. **No new helper libraries.**

| Function | File:line | Reuse Pattern |
|----------|-----------|---------------|
| `validate_profile` / `validate_docs_binding` | `bin/claude-secure:73-165` | Phase 23 already validates `docs_repo` / `docs_branch` / `docs_project_dir` shape. `fetch_docs_context` can trust the values it reads from the environment. |
| `load_profile_config` / `resolve_docs_alias` | `bin/claude-secure:232-294, 416-450` | Phase 23 already exports `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_REPO_TOKEN` into the host shell BEFORE `do_spawn` runs. `fetch_docs_context` consumes these env vars directly — no new field reads from `profile.json`. |
| Askpass helper pattern | `bin/claude-secure:1483-1492` (`do_profile_init_docs`), `1696-1704` (`publish_docs_bundle`) | Copy verbatim. Same `GIT_ASKPASS` shell stub, same `GIT_ASKPASS_PAT` env var name, same `chmod 700`, same redaction-on-stderr discipline. |
| Bounded-clone env block | `bin/claude-secure:1497-1542` | Reuse the `_git_env` array (`LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_HTTP_LOW_SPEED_LIMIT=1`, `GIT_HTTP_LOW_SPEED_TIME=30`) plus the empty-repo / wrong-branch fallback path. The Phase 23 implementation already handles the three failure modes a Phase 25 clone could hit. |
| PAT scrub on stderr | `bin/claude-secure:1538` (`sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g"`) | Apply to every `git` invocation that writes to a stderr file in `fetch_docs_context`. |
| `_CLEANUP_FILES` array + `spawn_cleanup` trap | `bin/claude-secure:48, 562-567, 1917` | `spawn_cleanup` already runs `rm -rf` on every entry in `_CLEANUP_FILES` on every exit path. Just append the agent-docs clone dir; no new cleanup mechanism. |
| Compose `${VAR:-default}` substitution sites | `docker-compose.yml:13, 30, 31, 92` | Existing in-tree precedent: `${WHITELIST_PATH:-./config/whitelist.json}:/etc/.../whitelist.json:ro` and `${SECRETS_FILE:-/dev/null}` show both how to inject a host path and how to make the substitution inert when the variable is unset. |
| `do_spawn` ordering | `bin/claude-secure:1843-2007` | Insert `fetch_docs_context` after `load_profile_config`/`resolve_docs_alias` (already done by main dispatch) and BEFORE `docker compose up -d --wait` at line 2007. The `trap spawn_cleanup EXIT` at line 1917 runs before this point, so any clone dir registered after the trap will be cleaned. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Subdirectory bind mount (`repo/$DOCS_PROJECT_DIR`) | Copy sparse-checked tree into a separate `.git`-free staging dir, mount that | Subdirectory mount is one fewer step, no I/O cost, no double-disk-usage. Copy-staging is conceptually cleaner ("the mount source has no `.git/` anywhere") but adds a copy that scales with project size. **Recommend subdirectory mount.** |
| `git sparse-checkout set --no-cone $DIR` | `git sparse-checkout set --cone $DIR` | Cone mode (default since git 2.27) is faster on large repos and matches our use case (a single directory prefix). Stick with the default. |
| `git clone --depth=1 --filter=blob:none --sparse` | `git clone --depth=1` (no partial filter) | Partial clone (`--filter=blob:none`) defers blob fetch until checkout, then sparse-checkout limits the checkout to one project. On a 10MB doc repo with 50 projects, this fetches ~200KB of project blobs instead of 10MB. **Both flags are recommended in the v4.0 STACK.md; use both.** |
| `git clone --depth=1 --filter=blob:none --sparse` | `git archive --remote` for read-only fetch | `git archive` only works on bare repos with `uploadarchive` enabled — most GitHub repos have it disabled by default. Sparse-checkout works against any HTTPS-cloneable repo, so it's the portable choice. |
| New `do_spawn` helper function `fetch_docs_context` | Inline the clone logic in `do_spawn` | Phase 16/23/24 all use named helpers. Consistency matters. Also makes the function unit-testable in isolation via `__CLAUDE_SECURE_SOURCE_ONLY=1` source-mode. |
| `docker run -v` flag append | New `volumes:` entry in `docker-compose.yml` | `do_spawn` uses `docker compose up`, NOT `docker run`. The mount must come from the compose file via env-var substitution. There is no per-spawn `docker run` to append `-v` to. |
| Host-only env var passing the path | Mounting a fixed canonical path | A fixed path (e.g. `/var/lib/claude-secure/agent-docs`) requires sudo, breaks per-spawn isolation (concurrent spawns clobber each other), and breaks the ephemeral-cleanup model. Use a per-spawn `$TMPDIR/cs-agent-docs-<uuid>` and pass it via `AGENT_DOCS_HOST_PATH`. |

**Installation:** None required. All tools verified.

**Version verification:**
```
$ git --version
git version 2.43.0
$ docker --version
Docker version 29.3.1
```

Both well above the minimums (`git >= 2.25` for sparse-checkout, `Docker >= 24` for compose v2). No `npm view` / `pip show` step needed — this phase ships zero new packages.

## Architecture Patterns

### Recommended Changes (scoped)

```
bin/claude-secure
├── fetch_docs_context()         # NEW: sparse shallow clone + sparse-checkout + path export
├── do_spawn()                   # extend: call fetch_docs_context after load_profile_config,
│                                #         before `docker compose up -d --wait`
└── (no other functions touched)

docker-compose.yml
└── claude.volumes               # add: ${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro
                                 # using the same ${VAR:-default} pattern as WHITELIST_PATH
```

**No changes to:**
- `proxy/server.js`, `validator/`, `webhook/listener.py`, `claude/Dockerfile`, `claude/hooks/`, `lib/platform.sh`, `install.sh`
- Any prompt template (CTX-02 explicitly says "no auto-injection into prompt")
- `validate_profile` / `validate_docs_binding` (Phase 23 already covers schema validation; this phase just consumes the validated values)
- `spawn_cleanup` (already iterates `_CLEANUP_FILES`)

### Pattern 1: Sparse Shallow Clone with Subdirectory Mount Source (CTX-01, CTX-04)

**What:** Clone the doc repo with `--depth=1 --filter=blob:none --sparse`, narrow to the project subdir with `git sparse-checkout set`, then export the *subdirectory* path (not the clone root) as the bind-mount source.

**Why it works for CTX-04:** Empirically verified on host git 2.43.0:
```
$ git clone --depth=1 --filter=blob:none --sparse --branch main bare.git sparse-clone
$ cd sparse-clone && git sparse-checkout set projects/foo
$ ls -la
.git/             ← lives at clone root
projects/foo/     ← contains only project files; no .git/ anywhere underneath
```

Bind-mounting `sparse-clone/projects/foo` into the container exposes only the project files. `.git/` stays in the host-side clone root, never crossing the mount boundary.

**Where to call it:** Inside `do_spawn`, immediately after the `_spawn_error_audit` precondition checks return success and before `docker compose up -d --wait` at line 2007. The host shell already has `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, and `DOCS_REPO_TOKEN` exported (Phase 23 `resolve_docs_alias` ran from `load_profile_config` at line 449, which is called by main dispatch before `do_spawn`).

**Example:**
```bash
# Phase 25 CTX-01..CTX-04: shallow + partial + sparse clone of the doc repo,
# bind-mounted read-only into the claude container at /agent-docs/.
#
# HOST-SIDE FUNCTION. Runs in host bash, NEVER inside any container. The PAT
# is consumed only by the host-side git invocation; the container only sees
# a read-only filesystem at /agent-docs/.
#
# Skips silently when DOCS_REPO is empty (CTX-03). Sets AGENT_DOCS_HOST_PATH
# when a clone succeeds; leaves it empty otherwise. Caller must handle both.
#
# Uses the Phase 16/23/24 askpass + bounded-clone + PAT-scrub idiom.
fetch_docs_context() {
  # CTX-03: opt-out — silent skip when no docs repo configured.
  if [ -z "${DOCS_REPO:-}" ]; then
    echo "info: phase25 fetch_docs_context: skipped (no docs_repo configured)" >&2
    AGENT_DOCS_HOST_PATH=""
    export AGENT_DOCS_HOST_PATH
    return 0
  fi

  # Defensive: Phase 23 validate_docs_binding already enforces these, but
  # do_spawn skips full validation, so re-check here.
  if [ -z "${DOCS_BRANCH:-}" ] || [ -z "${DOCS_PROJECT_DIR:-}" ] || [ -z "${DOCS_REPO_TOKEN:-}" ]; then
    echo "ERROR: fetch_docs_context: docs_repo set but DOCS_BRANCH / DOCS_PROJECT_DIR / DOCS_REPO_TOKEN missing" >&2
    return 1
  fi

  local clone_root
  clone_root=$(mktemp -d "${TMPDIR:-/tmp}/cs-agent-docs-XXXXXXXX")
  _CLEANUP_FILES+=("$clone_root")

  # Askpass helper — same pattern as do_profile_init_docs (bin/claude-secure:1485).
  local askpass="$clone_root/.askpass.sh"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf 'x-access-token\n' ;;
  Password*) printf '%s\n' "$GIT_ASKPASS_PAT" ;;
esac
ASKPASS
  chmod 700 "$askpass"

  local pat="$DOCS_REPO_TOKEN"
  local clone_err="$clone_root/clone.err"
  local _git_env=(
    LC_ALL=C
    GIT_ASKPASS="$askpass"
    GIT_ASKPASS_PAT="$pat"
    GIT_TERMINAL_PROMPT=0
    GIT_HTTP_LOW_SPEED_LIMIT=1
    GIT_HTTP_LOW_SPEED_TIME=30
  )

  # Sparse + shallow + partial clone. --filter=blob:none defers blob fetch
  # until checkout; --sparse initializes empty sparse-checkout so `set` can
  # narrow. Both flags require git 2.25+ (host has 2.43).
  if ! env "${_git_env[@]}" \
       timeout 60 \
       git -c credential.helper= -c credential.helper='' \
           -c core.autocrlf=false \
           clone --depth 1 --filter=blob:none --sparse \
                 --branch "$DOCS_BRANCH" --quiet \
                 "$DOCS_REPO" "$clone_root/repo" 2>"$clone_err"; then
    sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$clone_err" >&2
    echo "ERROR: fetch_docs_context: clone failed (see scrubbed stderr above)" >&2
    return 1
  fi

  # Narrow the working tree to the project subdir. cone mode (default since
  # git 2.27) is faster on large repos and matches our single-prefix use case.
  local sparse_err="$clone_root/sparse.err"
  if ! git -C "$clone_root/repo" sparse-checkout set "$DOCS_PROJECT_DIR" 2>"$sparse_err"; then
    sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$sparse_err" >&2
    echo "ERROR: fetch_docs_context: sparse-checkout set failed for $DOCS_PROJECT_DIR" >&2
    return 1
  fi

  # CTX-04: bind-mount source is the SUBDIRECTORY, not the clone root.
  # The .git/ dir lives at clone_root/repo/.git/ — completely outside the
  # mount source. Verified empirically on git 2.43.0.
  local mount_src="$clone_root/repo/$DOCS_PROJECT_DIR"
  if [ ! -d "$mount_src" ]; then
    echo "ERROR: fetch_docs_context: project subdir missing after sparse-checkout: $DOCS_PROJECT_DIR" >&2
    echo "       Did you run 'claude-secure profile init-docs --profile $PROFILE'?" >&2
    return 1
  fi

  AGENT_DOCS_HOST_PATH="$mount_src"
  export AGENT_DOCS_HOST_PATH
  echo "info: phase25 fetch_docs_context: mounted $DOCS_PROJECT_DIR (host: $mount_src) read-only at /agent-docs" >&2
  return 0
}
```

**Source:** Composition of `do_profile_init_docs` clone block (`bin/claude-secure:1483-1542`) + `git sparse-checkout` flags from `.planning/research/STACK.md:54` + empirical verification on host git 2.43.0.

### Pattern 2: Compose Volume with Inert Default (CTX-01, CTX-03)

**What:** Add one volume entry to `claude.volumes` in `docker-compose.yml` using the existing `${VAR:-/dev/null}` substitution pattern. When `AGENT_DOCS_HOST_PATH` is set, the bind mount activates. When unset, the substitution becomes `/dev/null:/agent-docs:ro`, which Docker treats as a no-op file mount that the container will not normally read.

**Why it works for CTX-03:** The `${VAR:-default}` syntax in compose v2 substitutes at `docker compose up` time. If `AGENT_DOCS_HOST_PATH=""` (set but empty) or unset, the default `/dev/null` is used. The line `/dev/null:/agent-docs:ro` mounts the host's `/dev/null` (a character device) at `/agent-docs` inside the container — a degenerate mount that satisfies compose syntax without touching any real path. Verified by precedent: `docker-compose.yml:13` already uses `${SECRETS_FILE:-/dev/null}` for an identical no-op pattern.

**Caveat:** A `/dev/null:/agent-docs:ro` mount creates `/agent-docs` as a character device file inside the container, NOT as a directory. The agent attempting `ls /agent-docs/` would get an error. **CTX-03 says "completes successfully with no clone attempt and no error"** — it does NOT require `/agent-docs` to exist as a directory. The agent simply has no `/agent-docs/` mount point to read from. This is correct behavior: the agent has no docs context to read, and any attempt to read it surfaces an error rather than silently returning empty content.

**Alternative if directory semantics are required:** Maintain a static empty directory at install time (e.g. `/opt/claude-secure/empty-agent-docs/`) and use that as the default substitution value. The planner should decide whether the degenerate `/dev/null` mount is acceptable or whether a static empty dir is preferred. **Recommendation: degenerate `/dev/null` mount.** It matches the existing in-tree pattern and avoids a new install-time directory.

**Example:**
```yaml
# docker-compose.yml — claude service volumes
volumes:
  - workspace:/workspace
  - ${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro
  - ${LOG_DIR:-./logs}:/var/log/claude-secure
  # Phase 25 CTX-01..CTX-04: read-only bind mount of the doc repo's
  # projects/<slug>/ subtree. fetch_docs_context exports AGENT_DOCS_HOST_PATH
  # before `docker compose up`. Falls back to /dev/null when no docs_repo is
  # configured (CTX-03 silent skip).
  - ${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro
```

**Source:** Compose v2 short-syntax volume reference + in-tree `${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro` precedent at `docker-compose.yml:30`.

### Pattern 3: do_spawn Integration Point (CTX-01)

**What:** Insert `fetch_docs_context` between the existing `do_spawn` precondition validation and the `docker compose up -d --wait` line. The cleanup trap is already set at line 1917; any clone dir registered with `_CLEANUP_FILES` after that trap is set will be cleaned by `spawn_cleanup` on every exit path (success, failure, signal).

**Where exactly:** In `do_spawn`, between the `Phase 16 / D-12: read report_repo fields ...` block (lines 1952-1961) and the `Resolve and render prompt template` block (line 1963). This is after `load_profile_config` has run (which exported all the `DOCS_*` vars via `resolve_docs_alias`) and after `MAX_TURNS` has been read, but before any prompt rendering or `docker compose` invocation.

**Example:**
```bash
# In do_spawn, after the existing report_repo field export block (~line 1961):

  # Phase 25 CTX-01..CTX-04: sparse shallow clone of the doc repo's
  # projects/<slug>/ subtree, bind-mounted read-only into /agent-docs.
  # Skips silently when DOCS_REPO is empty (CTX-03).
  # Exports AGENT_DOCS_HOST_PATH for docker-compose.yml to consume.
  if ! fetch_docs_context; then
    _spawn_error_audit "spawn: fetch_docs_context failed"
    return 1
  fi
```

**Source:** Direct inspection of `bin/claude-secure:1843-2007` and the existing `_spawn_error_audit` early-return pattern at lines 1864, 1893, 1903.

### Anti-Patterns to Avoid

- **Do NOT mount the clone root.** `clone_root/repo/` contains `.git/`. Mounting it violates CTX-04. Always mount the *subdirectory* `clone_root/repo/$DOCS_PROJECT_DIR/`.
- **Do NOT pass `DOCS_REPO_TOKEN` into the container.** The token must remain host-only. Phase 23's filtered `.env` projection (`project_env_for_containers`) already excludes both `DOCS_REPO_TOKEN` and `REPORT_REPO_TOKEN`. Phase 25 must not introduce any code path that adds the token to `environment:`, `env_file:`, or `${VAR}` substitution in `docker-compose.yml`.
- **Do NOT skip the cleanup trap registration.** Append to `_CLEANUP_FILES` IMMEDIATELY after `mktemp -d`, not after the clone succeeds. If the clone fails after `mktemp` but before `_CLEANUP_FILES+=`, the temp dir leaks. (Phase 24's `publish_docs_bundle` follows this discipline at lines 1692-1693.)
- **Do NOT use `git clone -c sparse.subDirectory=...`.** That's a deprecated incantation. The supported flow is `clone --sparse` + `sparse-checkout set <dir>`. Both are stable since git 2.25.
- **Do NOT use `git clone --depth=1` without `--filter=blob:none --sparse`.** Without the partial filter, the clone fetches every blob in HEAD even if sparse-checkout will exclude most of them. The whole point of the sparse-shallow-partial combo is to fetch only the blobs that get checked out.
- **Do NOT bind-mount with read-write semantics ("rw" or no flag).** Compose short syntax defaults to `rw` if no flag is given. The `:ro` suffix is mandatory and is what makes CTX-04 enforceable at the kernel level.
- **Do NOT add `:Z` or `:z` SELinux relabeling flags.** They're Linux-specific and break on macOS Docker Desktop. The `:ro` suffix alone works on every supported platform (Linux, WSL2, macOS via Docker Desktop).
- **Do NOT inject `/agent-docs` paths into prompt templates.** CTX-02 says "agent can read … when it needs context — no auto-injection into prompt". The agent decides when to `cat /agent-docs/projects/<slug>/architecture.md` based on its own reasoning. Adding `{{VISION}}` / `{{ARCHITECTURE_SUMMARY}}` template tokens is OUT OF SCOPE for Phase 25 (those were pre-Phase-23 architecture sketches; the v4.0 success criteria explicitly removed them in favor of "no auto-injection").
- **Do NOT bind-mount the doc repo's `.git/` directory.** PITFALLS.md m-4 (`bin/claude-secure` research dir, line 311-313) explicitly forbids this: "Never mount the doc repo's `.git` into the Claude container. The container does not need read access to the doc repo at all."

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sparse fetch of a single project subdir | A custom HTTP client that crawls the GitHub Trees API and downloads individual blobs | `git clone --depth=1 --filter=blob:none --sparse` + `git sparse-checkout set` | Trees-API crawling needs auth, pagination, rate-limit handling, blob assembly — all of which `git` already does correctly with one shell command. Also the API path is GitHub-specific; sparse-checkout works against any HTTPS-cloneable repo (Gitea, self-hosted, etc.). |
| Excluding `.git/` from a bind mount | A custom helper that scans the bind source for `.git` and refuses to mount if found | Mount the subdirectory directly; verify the absence of `.git/` in test instead | Defensive scanning duplicates what the path layout already guarantees. Subdirectory mount is structurally `.git`-free by construction. |
| Read-only enforcement for the agent | A custom hook that intercepts file writes under `/agent-docs/` and returns EROFS | Docker bind mount `:ro` flag → kernel `MS_RDONLY` → EROFS for free | The kernel does this enforcement at the syscall layer with zero application code. A hook-based approach is bypassable; a kernel mount flag is not. |
| Cleanup of ephemeral clone dirs | A new background reaper that walks `$TMPDIR` for stale `cs-agent-docs-*` dirs | `_CLEANUP_FILES` array + `spawn_cleanup` trap (already in place from Phase 16) | The existing trap fires on every exit path including signals (Phase 17 P03 verified this for the reaper). Adding a separate background sweep is duplicate machinery. |
| PAT-aware error redaction | A new sed pipeline | Reuse Phase 24's `sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$err_log" >&2` pattern | Already proven correct in Phases 16, 23, 24. Drift between scrub implementations is a security regression risk. |
| Authenticated clone with PAT in URL | Embedding the PAT in the clone URL (`https://x-access-token:$PAT@github.com/...`) | Reuse the Phase 23/24 askpass shim with `GIT_ASKPASS_PAT` | URL-embedded PATs leak via `ps`, `/proc/*/cmdline`, and git's own error messages. Askpass keeps the PAT in env-var-only scope. |
| No-docs-repo skip path | A new feature flag in profile.json (`skip_agent_docs: true`) | Use the existing `[ -z "${DOCS_REPO:-}" ]` guard (Phase 23 opt-out semantics) | Adding a flag forks the schema for no benefit. Empty `DOCS_REPO` already means "no doc binding". |

**Key insight:** Every primitive Phase 25 needs already exists in-tree from Phases 16, 18, 23, and 24. The phase is a 60-line `fetch_docs_context()` function plus a 1-line compose volume entry plus a 4-line `do_spawn` integration call. Total new code: ~70 lines. Test code: ~150-200 lines (most of which is fixture setup that mirrors `tests/test-phase23.sh`).

## Runtime State Inventory

> Phase 25 introduces a new ephemeral host directory and a new container mount point. It does NOT rename anything, does NOT migrate any stored data, and does NOT change any persistent on-disk format. Most categories below are empty by design — the phase is purely additive.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None. The agent-docs clone is per-spawn ephemeral. There is no SQLite table, ChromaDB collection, Mem0 user_id, or other datastore that embeds `/agent-docs` paths. The validator's `validator-db` SQLite (Phase 17) holds call-IDs only, not file-system paths. | None. |
| Live service config | None. The webhook listener (`webhook/listener.py`), the reaper (`webhook/reaper.py`), and the proxy (`proxy/server.js`) do not read `/agent-docs/` or any agent-docs env var. The clone happens inside `do_spawn` only — listener and reaper are unaffected. | None. |
| OS-registered state | None. systemd units (`webhook/claude-secure-webhook.service`, `webhook/claude-secure-reaper.service`, `webhook/claude-secure-reaper.timer`) and launchd plists (Phase 21, pending) do not embed `/agent-docs` or `AGENT_DOCS_HOST_PATH`. The reaper's tmp-file age sweep (`tests/test-phase17-e2e.sh` scenario 3) uses pattern `cs-*` — `cs-agent-docs-XXXXXXXX` matches that pattern, so the reaper already handles orphaned clone dirs as a defensive fallback when `spawn_cleanup` did not run (e.g. SIGKILL during clone). | None — the reaper pattern is broad enough to sweep `cs-agent-docs-*` for free. |
| Secrets/env vars | New env var: `AGENT_DOCS_HOST_PATH`. Set by `fetch_docs_context`, consumed by `docker-compose.yml` substitution. **Not a secret** — it's a host filesystem path. Must NOT contain the PAT. The PAT (`DOCS_REPO_TOKEN`) is unchanged from Phase 23 and is already filtered from container env by `project_env_for_containers`. | New env var documentation in README. No filtering needed — `AGENT_DOCS_HOST_PATH` is host-only by construction (it's exported by `fetch_docs_context` into the bash process env, not into any `.env` file). |
| Build artifacts / installed packages | None. The phase ships zero new files into `install.sh`'s install pipeline. No Python packages, no Node modules, no compiled binaries, no template files. Just ~70 lines of bash in `bin/claude-secure` and one line in `docker-compose.yml`. | None — `install.sh` does not need to be modified. |

**Canonical check:** *After every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?*

- Phase 25 introduces no new persistent strings. There is nothing to migrate, rename, or invalidate.
- The reaper's tmp-file pattern (`cs-*` in `$TMPDIR`) already covers `cs-agent-docs-*` for free.
- `_CLEANUP_FILES` registration in `fetch_docs_context` ensures the clone dir is wiped on every spawn exit path.

**Nothing found in category:** Stored data, live service config, OS-registered state, build artifacts — all explicitly verified above. Only the secrets/env vars row has a new item, and it is not a secret.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `git` (host) | `fetch_docs_context` clone + sparse-checkout | ✓ | 2.43.0 (host); minimum required 2.25 (sparse-checkout subcommand) | — |
| Docker Engine | bind mount with `:ro`, compose v2 substitution | ✓ | 29.3.1 (host); minimum required 24.x | — |
| Docker Compose v2 | `${VAR:-default}` substitution in `volumes:` | ✓ | bundled with Docker 29.3.1 | — |
| `bash` 4+ | array ops, `[[ ]]`, `${var,,}` (none used here, but Phase 18 baseline applies) | ✓ | host bash 5.x via Phase 18 re-exec | — |
| `mktemp -d` | per-spawn clone dir under `$TMPDIR` | ✓ | GNU coreutils (Phase 18 PATH bootstrap covers macOS) | — |
| `timeout` (GNU coreutils) | bound the clone wall-clock to 60s | ✓ | already used in Phase 23/24 clone wrappers | — |
| `curl` | indirect via `git` HTTPS transport | ✓ | system | — |
| `sed` (GNU) | PAT scrub on stderr | ✓ | GNU via Phase 18 PATH bootstrap | — |
| Network egress to docs repo host | `git clone` over HTTPS | host-dependent | n/a | If the host cannot reach the docs repo (e.g. air-gapped CI), `fetch_docs_context` fails closed with a redacted error. CTX-03 silent-skip only fires when `DOCS_REPO` is *empty*, not when the network is unreachable. This is intentional — silent-skip on network failure would mask real misconfigurations. |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

This phase adds zero new host requirements. All tools were already verified by Phases 16, 18, 19, 23, and 24.

## Common Pitfalls

### Pitfall 1: `.git/` leaks into the container because the wrong path is mounted

**What goes wrong:** A planner reads "bind-mount the clone read-only" and writes a task that mounts `clone_root/repo` instead of `clone_root/repo/$DOCS_PROJECT_DIR`. The container then has `/agent-docs/.git/` available, which (a) violates CTX-04 and (b) potentially leaks the doc repo's commit history and remote URL (which contains `x-access-token:<PAT>` if it was URL-embedded — though Phase 23/24 use askpass so the PAT is not in the remote URL by default).

**Why it happens:** The verbal phrasing "bind-mount the clone" is ambiguous. The natural read is "mount the clone directory", but that's wrong.

**How to avoid:** Always set `AGENT_DOCS_HOST_PATH="$clone_root/repo/$DOCS_PROJECT_DIR"`, never `$clone_root/repo`. Add a Wave 0 test that asserts `! [ -e "$AGENT_DOCS_HOST_PATH/.git" ]` and `! [ -e "$AGENT_DOCS_HOST_PATH/../.git/objects/pack" ]` (the latter would be visible only if the parent were mounted — this confirms the test exercises the right boundary).

**Warning signs:** Test output containing `/agent-docs/.git/HEAD` from `find /agent-docs -name HEAD`. Or a planner task that says "mount the clone dir" without specifying the subdirectory.

### Pitfall 2: Compose `${VAR:-/dev/null}` mounts a character device when no docs are configured

**What goes wrong:** When `DOCS_REPO` is empty, `AGENT_DOCS_HOST_PATH=""`, and the compose substitution falls back to `/dev/null`. Docker mounts `/dev/null` (a character device) at `/agent-docs` inside the container. The agent attempting `ls /agent-docs/` gets an error like `ls: cannot access '/agent-docs/': Not a directory`. This is functionally correct (no docs to read) but cosmetically ugly.

**Why it happens:** Docker's `-v /dev/null:/path:ro` creates the destination as a character device file, not a directory. Compose v2 short-syntax volumes follow the same rule.

**How to avoid:** Two options. (a) Accept the cosmetic ugliness — the agent never tries to read `/agent-docs/` unless its prompt mentions it, and CTX-03 only requires "spawn completes successfully", not "/agent-docs is a readable empty directory". (b) Maintain a static empty directory at install time (`/opt/claude-secure/empty-agent-docs/`) and use it as the substitution default. **Recommendation: option (a)** — matches the existing in-tree precedent (`SECRETS_FILE:-/dev/null`) and adds zero install-time state. The planner should explicitly decide which option to ship; if option (b), Phase 25 must include an `install.sh` step.

**Warning signs:** A test that asserts `ls /agent-docs` succeeds when no docs are configured. Such a test would force option (b).

### Pitfall 3: `git clone --depth=1 --filter=blob:none` against a `file://` URL silently ignores both flags

**What goes wrong:** Local file-system clones (`file:///tmp/bare.git` or just `/tmp/bare.git`) ignore `--depth` and `--filter` because git uses an optimized local-clone path that hardlinks objects instead of doing a real fetch. The Wave 0 tests that use `file://` bare repos to avoid network dependency will see `clone --depth=1 --filter=blob:none --sparse` succeed but silently NOT exercise the partial-clone path.

**Why it happens:** git's optimization for local clones bypasses the protocol's blob negotiation. The warning is `warning: --depth is ignored in local clones; use file:// instead.` — and even with `file://` the filter is also ignored.

**How to avoid:** This is a TEST-ONLY pitfall, not a production issue. In tests, accept that the partial-clone path is not exercised end-to-end with local repos. The unit-level invariants (sparse-checkout DID narrow the working tree, `.git` is at root not subdir, mount source is the subdirectory) are still verifiable. To exercise the real partial-clone code path, an integration test would need a real HTTP git server (test fixture overhead not worth it for Phase 25). **Document this limitation in the test file's Wave 0 comment block.**

**Warning signs:** Test output containing `warning: --depth is ignored in local clones; use file:// instead.` This is expected and harmless in test environments — do NOT add code to suppress it.

### Pitfall 4: Concurrent spawns race on `$TMPDIR/cs-agent-docs-*` cleanup

**What goes wrong:** Two simultaneous `do_spawn` invocations both call `mktemp -d` (which guarantees unique names), but if a third actor (the Phase 17 reaper) sweeps `$TMPDIR` for stale `cs-*` dirs aggressively during the live spawn, the reaper could delete an in-use clone dir mid-spawn.

**Why it happens:** The reaper's age threshold (`REAPER_ORPHAN_AGE_SECS`, default 600) protects against this — the reaper only deletes dirs older than 10 minutes, and a clone happens in seconds. But if the reaper threshold is misconfigured to a tiny value (or `REAPER_ORPHAN_AGE_SECS=0` for tests), the race becomes possible.

**How to avoid:** Trust the reaper's age threshold. Do NOT add a custom mtime-check or lockfile in `fetch_docs_context`. The Phase 17 reaper test scenario 3 already verifies that legitimate live spawns are not reaped. Phase 25 introduces no new race surface — it just adds another `cs-*` dir to the existing per-spawn ephemeral set.

**Warning signs:** A test failure where the clone dir vanishes mid-spawn. Investigate whether `REAPER_ORPHAN_AGE_SECS` was set to 0 in the test environment.

### Pitfall 5: `git sparse-checkout set` on an empty subtree still creates the directory but it's empty

**What goes wrong:** The user runs `claude-secure profile init-docs --profile X` (Phase 23 DOCS-01) which creates `projects/X/{todo,architecture,vision,ideas}.md`. They later modify `docs_project_dir` in profile.json to point at a path that does NOT exist in the doc repo (e.g. typo: `projects/Y` when the repo contains `projects/X`). `git sparse-checkout set projects/Y` succeeds but creates an empty `projects/Y/` directory in the working tree (or no directory at all, depending on git version).

**Why it happens:** Sparse-checkout doesn't fail on a non-existent path — it just narrows the working tree to the (empty) intersection.

**How to avoid:** After `git sparse-checkout set`, verify the subdirectory exists AND contains at least one file. Phase 23's `validate_docs_binding` validates the *shape* of `docs_project_dir` (relative path, no `..`) but does not verify it exists in the remote. **Recommendation:** In `fetch_docs_context`, after sparse-checkout, run `if [ ! -d "$mount_src" ] || [ -z "$(ls -A "$mount_src" 2>/dev/null)" ]; then ... ; fi` and fail with an error pointing the user at `claude-secure profile init-docs`. The example in Pattern 1 above includes the directory-existence check; the planner should add the empty-directory check as a refinement.

**Warning signs:** Spawn succeeds, but `cat /agent-docs/projects/X/todo.md` inside the container returns "No such file or directory". Operator confusion: "I thought my doc layout was mounted!"

### Pitfall 6: Bind mount `:ro` not enforced when the host directory is itself a tmpfs with `rw` mode

**What goes wrong:** If `$TMPDIR` is on a tmpfs that's mounted `rw`, the bind mount source is writable. Docker's bind-mount `:ro` flag SHOULD remap the mount to read-only at the kernel level. **It does on Linux 4.5+**, which is every supported kernel for this project. **It also does on macOS Docker Desktop**, which uses VirtioFS/gRPC-FUSE that honors `MS_RDONLY` correctly. **Verify once empirically with a write attempt from inside the container.**

**Why it happens:** Older kernels (< 4.5) had bugs where `bind,ro` did not propagate through to all child mounts. Project minimum is well above this.

**How to avoid:** Add a Wave 0 test that runs `docker compose exec claude touch /agent-docs/test.txt` and asserts the exit code is non-zero AND the error message contains "Read-only file system". This verifies CTX-02's "write attempt fails" criterion at the kernel level, not just by trusting the `:ro` flag.

**Warning signs:** Test passes that mounts read-only but does not actually verify a write fails. The verification must be empirical, not just structural.

### Pitfall 7: Clone fails for legitimate operational reasons and crashes the spawn

**What goes wrong:** Network blip, expired PAT, GitHub rate limit, or a 60s `timeout` on a slow connection causes `git clone` in `fetch_docs_context` to fail. The current `fetch_docs_context` sketch returns 1, which `_spawn_error_audit`s and aborts the entire spawn. But the agent could still do useful work without doc context — refusing to spawn is overzealous.

**Why it happens:** Phase 25's success criteria are silent on the "clone fails but profile is otherwise valid" case. The conservative interpretation is "fail closed on any error". The lenient interpretation is "log the failure and proceed without a docs mount, treating it as if `docs_repo` were empty".

**How to avoid:** This is a design decision, not a pure defect. **Recommendation: fail closed for Phase 25.** A clone failure usually indicates a real misconfiguration (expired PAT, repo deleted, branch renamed) that the operator should fix. Silent-degrading would mask these issues. Phase 26 (Stop hook) introduces a "must reach docs repo eventually" requirement anyway, so deferring docs failures to Phase 26 won't work. The planner should flag this as Open Question 3 below for the user to confirm.

**Warning signs:** A user reports that "my agent ran without context but I didn't notice and pushed a broken report". This means the silent-skip path was active when it shouldn't have been.

## Code Examples

### Example 1: Empirical verification of `.git/` location after sparse shallow clone

```bash
# Source: empirical verification on host (git 2.43.0, 2026-04-14)
# Setup: bare repo with two project subdirs
$ git init -q --bare bare.git
$ git clone -q bare.git work && cd work
$ mkdir -p projects/foo projects/bar
$ echo "hello" > projects/foo/todo.md
$ echo "other" > projects/bar/notes.md
$ git add -A && git commit -qm init && git push -q origin HEAD:main && cd ..

# The actual phase 25 clone command (against a local file:// for testing)
$ git clone --depth=1 --filter=blob:none --sparse --branch main bare.git sparse-clone
# Note: warnings about --depth/--filter being ignored on local clones are EXPECTED
$ cd sparse-clone && git sparse-checkout set projects/foo

$ ls -la
total 16
drwxr-xr-x 4 user user 4096 .  # working tree root
drwxr-xr-x 5 user user 4096 ..
drwxr-xr-x 8 user user 4096 .git/        <-- AT CLONE ROOT
drwxr-xr-x 3 user user 4096 projects/    <-- only directory in sparse checkout

$ find . -maxdepth 3 -not -path '*/.git*'
.
./projects
./projects/foo
./projects/foo/todo.md       <-- only file in sparse checkout

# CRITICAL: .git/ is at the clone root, NOT inside projects/foo
$ find sparse-clone/projects -name '.git'
# (empty output — no .git anywhere under projects/)

# CTX-04 verification: the mount source "sparse-clone/projects/foo"
# contains zero .git references.
```

### Example 2: docker-compose.yml volume entry (Phase 25 delta)

```yaml
# Source: docker-compose.yml claude.volumes block + Phase 25 addition
# Existing entries unchanged; one new line added at the bottom.
services:
  claude:
    # ... existing config unchanged ...
    volumes:
      - workspace:/workspace
      - ${WHITELIST_PATH:-./config/whitelist.json}:/etc/claude-secure/whitelist.json:ro
      - ${LOG_DIR:-./logs}:/var/log/claude-secure
      # Phase 25 CTX-01..CTX-04: read-only bind mount of the doc repo's
      # projects/<slug>/ subtree. fetch_docs_context exports
      # AGENT_DOCS_HOST_PATH before `docker compose up`. Falls back to
      # /dev/null when no docs_repo is configured (CTX-03 silent skip).
      - ${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro
```

### Example 3: do_spawn integration call site

```bash
# Source: bin/claude-secure:1843-2007 (existing do_spawn structure)
# Insertion point: between the existing report_repo export block (~line 1961)
# and the prompt template resolution block (~line 1963).

  # ... existing report_repo field export block ends ...

  # Phase 25 CTX-01..CTX-04: sparse shallow clone of the doc repo's
  # projects/<slug>/ subtree, bind-mounted read-only into the claude
  # container at /agent-docs. Skips silently when DOCS_REPO is empty (CTX-03).
  # Exports AGENT_DOCS_HOST_PATH for docker-compose.yml to consume on the
  # `docker compose up -d --wait` call below.
  if ! fetch_docs_context; then
    _spawn_error_audit "spawn: fetch_docs_context failed"
    return 1
  fi

  # Resolve and render prompt template (per D-13 through D-17)
  # ... existing block continues ...
```

### Example 4: Wave 0 RED test for CTX-04 (mount source contains no .git/)

```bash
# Source: bash test pattern from tests/test-phase23.sh + Phase 25 CTX-04
# Wave 0 RED: this test must FAIL until fetch_docs_context exists.
test_fetch_docs_context_mount_source_excludes_git() {
  # Setup: a bare local file:// docs repo with a projects/<slug>/ layout
  local bare="$TEST_TMPDIR/docs.git"
  local seed="$TEST_TMPDIR/docs-seed"
  git init -q --bare "$bare"
  git clone -q "$bare" "$seed"
  ( cd "$seed" \
    && git config user.email a@b.c && git config user.name a \
    && git config commit.gpgsign false \
    && mkdir -p projects/test-slug/specs \
    && echo "# Todo" > projects/test-slug/todo.md \
    && echo "# Architecture" > projects/test-slug/architecture.md \
    && echo "# Vision" > projects/test-slug/vision.md \
    && echo "# Ideas" > projects/test-slug/ideas.md \
    && touch projects/test-slug/specs/.gitkeep \
    && git add -A && git commit -qm init \
    && git push -q origin HEAD:main )

  # Install fixture profile pointing at the bare repo
  install_fixture "profile-23-docs" "ctx-test"
  local pdir="$CONFIG_DIR/profiles/ctx-test"
  jq --arg url "file://$bare" '.docs_repo = $url
                              | .docs_branch = "main"
                              | .docs_project_dir = "projects/test-slug"' \
    "$pdir/profile.json" > "$pdir/profile.json.tmp" && mv "$pdir/profile.json.tmp" "$pdir/profile.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=fake-ctx-oauth\nDOCS_REPO_TOKEN=fake-ctx-token\n' > "$pdir/.env"

  source_cs
  PROFILE=ctx-test load_profile_config ctx-test
  fetch_docs_context || return 1

  # CTX-04: the exported mount source must NOT contain a .git directory
  # at any depth.
  [ -n "${AGENT_DOCS_HOST_PATH:-}" ]   || return 1
  [ -d "$AGENT_DOCS_HOST_PATH" ]       || return 1
  if find "$AGENT_DOCS_HOST_PATH" -name '.git' -print -quit | grep -q .; then
    echo "FAIL: .git found under mount source $AGENT_DOCS_HOST_PATH"
    return 1
  fi
  # And the canonical files DO exist
  [ -f "$AGENT_DOCS_HOST_PATH/todo.md" ]         || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/architecture.md" ] || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/vision.md" ]       || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/ideas.md" ]        || return 1
  return 0
}
```

### Example 5: Wave 0 RED test for CTX-03 (no-docs skip)

```bash
test_fetch_docs_context_skips_silently_when_no_docs_repo() {
  # Setup: a profile with NO docs_repo configured (back-compat path)
  local pdir="$CONFIG_DIR/profiles/no-docs"
  local ws="$TEST_TMPDIR/ws-no-docs"
  mkdir -p "$pdir" "$ws"
  jq -n --arg ws "$ws" '{workspace: $ws, repo: "owner/no-docs"}' > "$pdir/profile.json"
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-no-docs" > "$pdir/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$pdir/whitelist.json"

  source_cs
  PROFILE=no-docs load_profile_config no-docs

  # The function must return 0 (success) and AGENT_DOCS_HOST_PATH must be empty
  fetch_docs_context >/dev/null 2>"$TEST_TMPDIR/skip.err" || return 1
  [ -z "${AGENT_DOCS_HOST_PATH:-}" ] || return 1
  # Stderr must contain exactly one info-level skip line
  grep -q 'fetch_docs_context: skipped' "$TEST_TMPDIR/skip.err" || return 1
  return 0
}
```

### Example 6: Wave 0 RED test for CTX-02 (write attempt fails)

```bash
# Docker-required test. Gated by `command -v docker` and Docker daemon liveness.
test_agent_docs_write_attempt_fails_readonly() {
  command -v docker >/dev/null 2>&1 || { echo "skip: docker not available"; return 0; }
  docker info >/dev/null 2>&1        || { echo "skip: docker daemon not running"; return 0; }

  # Setup: full fixture with a real bare repo and an actual fetch_docs_context
  # invocation. (Setup elided for brevity — same as test_fetch_docs_context_mount_source_excludes_git.)
  install_fixture "profile-23-docs" "ctx-rw-test"
  # ... configure profile.json and .env to point at bare repo ...

  # Spawn the actual claude container via the spawn path
  CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$TEST_TMPDIR/fake-claude.json" \
    CLAUDE_SECURE_FAKE_CLAUDE_EXIT=0 \
    CONFIG_DIR="$TEST_TMPDIR" \
    "$PROJECT_DIR/bin/claude-secure" --profile ctx-rw-test spawn \
      --event '{"event_type":"manual","repository":{"full_name":"owner/test"}}' \
      >/dev/null 2>&1 &
  local spawn_pid=$!
  # Wait briefly for compose up to settle
  sleep 2  # NOTE: this is the only sleep in the test suite — required for compose up to register the mount

  # CTX-02: read works
  if ! docker compose -p "$(spawn_project_name ctx-rw-test)" exec -T claude \
         cat /agent-docs/todo.md >/dev/null 2>&1; then
    kill $spawn_pid 2>/dev/null
    echo "FAIL: read /agent-docs/todo.md failed"
    return 1
  fi

  # CTX-02: write attempt fails with read-only filesystem error
  local write_err
  write_err=$(docker compose -p "$(spawn_project_name ctx-rw-test)" exec -T claude \
                touch /agent-docs/written.txt 2>&1) && {
    kill $spawn_pid 2>/dev/null
    echo "FAIL: write to /agent-docs/written.txt unexpectedly succeeded"
    return 1
  }
  echo "$write_err" | grep -qi 'read-only file system' || {
    kill $spawn_pid 2>/dev/null
    echo "FAIL: write error did not mention read-only filesystem: $write_err"
    return 1
  }

  kill $spawn_pid 2>/dev/null
  wait $spawn_pid 2>/dev/null || true
  return 0
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Full clone (no `--depth`, no `--filter`) | Sparse + shallow + partial: `--depth=1 --filter=blob:none --sparse` | git 2.25 (2020-01) made sparse-checkout subcommand stable; `--filter=blob:none` became reliable for HTTPS clones in git 2.27 | 100x bandwidth reduction on large doc repos. Required by v4.0 STACK.md. |
| Pre-rendered prompt variables (`{{VISION}}`, `{{ARCHITECTURE_SUMMARY}}`, `{{TODO_OPEN_ITEMS}}`) | Read-only bind mount with no auto-injection — agent decides when to read | v4.0 ROADMAP.md success criterion 2 ("no auto-injection into prompt") | Agent has richer access (can `grep`, `ls`, read multiple files), but the prompt template stays stable. **Phase 25 must NOT add prompt template variables for docs content** — that path was abandoned in favor of bind mount + agent autonomy. |
| Mount the clone root (with `.git/`) | Mount the project subdirectory only | This phase (success criterion 4 explicit) | The agent cannot inspect git history, cannot see remote URL, cannot push. CTX-04 is structurally enforced. |
| Read-write workspace as the docs delivery mechanism | Read-only `:ro` bind mount | This phase | Agent cannot accidentally (or maliciously) modify the doc repo from inside the container. All writes go through the host-side `publish_docs_bundle` (Phase 24) only. |

**Deprecated/outdated (do NOT use):**
- `git clone -c sparse.subDirectory=...` — pre-2.25 incantation. The subcommand `git sparse-checkout set` is the current API.
- `git clone --no-checkout` followed by manual sparse setup — three commands instead of two; no functional advantage.
- Mounting the `.git/` directory "for convenience so the agent can `git log`" — explicitly forbidden by PITFALLS.md m-4.
- Pre-Phase-23 sketches of `{{VISION}}` / `{{ARCHITECTURE_SUMMARY}}` template variables — abandoned in favor of bind mount + no auto-injection.

## Open Questions

1. **What should `fetch_docs_context` do when the clone fails (network error, expired PAT, repo missing)?**
   - What we know: CTX-03 says "if the profile has no `docs_repo` configured, context read is skipped silently". This explicitly covers the "no `docs_repo`" case but is silent on "`docs_repo` is set but unreachable".
   - What's unclear: Should the spawn fail (fail-closed) or proceed without docs (lenient)?
   - Recommendation: **Fail closed.** A clone failure usually indicates a real misconfiguration that the operator must see. Silent-degrading would mask expired PATs and renamed branches. The planner should flag this for CONTEXT.md confirmation.

2. **Should `/dev/null:/agent-docs:ro` be acceptable as the no-docs default, or should there be a static empty directory?**
   - What we know: `/dev/null` is consistent with `${SECRETS_FILE:-/dev/null}` precedent. It's not a directory, so `ls /agent-docs` errors.
   - What's unclear: Whether the cosmetic ugliness of "not a directory" matters.
   - Recommendation: **Use `/dev/null`.** Matches in-tree precedent, requires zero install-time changes, and the agent has no reason to `ls /agent-docs` when no docs are configured.

3. **Should `fetch_docs_context` verify the project subtree is non-empty after sparse-checkout, or just verify the directory exists?**
   - What we know: Pitfall 5 above — a typo'd `docs_project_dir` gives an empty (or missing) subdirectory after sparse-checkout, with no error.
   - What's unclear: Whether failing fast on an empty subtree is more helpful than allowing the agent to discover the empty mount itself.
   - Recommendation: **Fail fast on an empty subtree.** Add `[ -z "$(ls -A "$mount_src" 2>/dev/null)" ]` after the directory check. Error message points at `claude-secure profile init-docs --profile $PROFILE`.

4. **Should the read-only bind mount be added to `do_spawn`'s container only, or also to the interactive `(no command)` path?**
   - What we know: The success criteria all use the word "spawn" (`bin/claude-secure spawn ...`), so the headless path is in scope. The interactive path (`bin/claude-secure --profile X` with no command) drops to `docker compose up -d` + `docker compose exec -it claude claude --dangerously-skip-permissions` — same compose file.
   - What's unclear: Whether interactive sessions should also get `/agent-docs/` available.
   - Recommendation: **Both paths get the mount.** Since the volume is in `docker-compose.yml`, both paths inherit it for free. The interactive path should also call `fetch_docs_context` before `docker compose up -d` to populate `AGENT_DOCS_HOST_PATH`. Without that call, `AGENT_DOCS_HOST_PATH` is unset and the compose substitution falls back to `/dev/null` — the interactive user gets no docs context. **Add `fetch_docs_context` to the interactive path's `*)` case at line 2685 of `bin/claude-secure`.** The planner should explicitly include this in the plan.

5. **Should the mount source path be normalized through `realpath`?**
   - What we know: `mktemp -d` returns an absolute path. `$DOCS_PROJECT_DIR` is validated by Phase 23 to be a relative path with no `..`. Concatenating them yields a clean absolute path.
   - What's unclear: Whether symlinks in `$TMPDIR` (e.g. on macOS where `/tmp` -> `/private/tmp`) cause Docker bind-mount confusion.
   - Recommendation: **Run the final mount path through `realpath`** before exporting. This is one extra line and protects against macOS `/tmp -> /private/tmp` resolution issues that could surface in Phase 21 when launchd is involved. Phase 18 PATH bootstrap ensures GNU `realpath` is available on macOS.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell (bash) test harness with `run_test` helper, PASS/FAIL counters, `trap cleanup EXIT` — Phase 12-24 project convention |
| Config file | None (direct `bash tests/test-phase25.sh` invocation) |
| Quick run command | `bash tests/test-phase25.sh` |
| Full suite command | `./run-tests.sh` (runs all phase suites per `tests/test-map.json`) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CTX-01 | `fetch_docs_context` exists and is callable in source-only mode | unit | `bash tests/test-phase25.sh test_fetch_docs_context_function_exists` | ❌ Wave 0 |
| CTX-01 | `fetch_docs_context` performs sparse shallow clone with correct flags | unit | `bash tests/test-phase25.sh test_fetch_docs_context_clone_flags` | ❌ Wave 0 |
| CTX-01 | `fetch_docs_context` exports `AGENT_DOCS_HOST_PATH` pointing at the project subdir | unit | `bash tests/test-phase25.sh test_fetch_docs_context_exports_path` | ❌ Wave 0 |
| CTX-01 | `docker-compose.yml` declares `${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro` in `claude.volumes` | unit | `bash tests/test-phase25.sh test_compose_volume_entry` | ❌ Wave 0 |
| CTX-01 | `do_spawn` calls `fetch_docs_context` before `docker compose up -d --wait` | unit | `bash tests/test-phase25.sh test_do_spawn_calls_fetch_docs_context` | ❌ Wave 0 |
| CTX-02 | Container can `cat /agent-docs/projects/<slug>/{todo,architecture,vision,ideas}.md` and files under `specs/` | integration (docker) | `bash tests/test-phase25.sh test_agent_docs_read_works` | ❌ Wave 0 (gated by docker availability) |
| CTX-02 | Container write to any path under `/agent-docs/` fails with "read-only file system" | integration (docker) | `bash tests/test-phase25.sh test_agent_docs_write_attempt_fails_readonly` | ❌ Wave 0 (gated by docker availability) |
| CTX-03 | `fetch_docs_context` returns 0 silently when `DOCS_REPO` is empty | unit | `bash tests/test-phase25.sh test_fetch_docs_context_skips_silently_when_no_docs_repo` | ❌ Wave 0 |
| CTX-03 | `fetch_docs_context` emits exactly one `info: ... skipped` stderr line on the no-docs path | unit | `bash tests/test-phase25.sh test_fetch_docs_context_emits_one_info_line_on_skip` | ❌ Wave 0 |
| CTX-03 | Spawn with no-docs profile completes without invoking git or hitting network | unit | `bash tests/test-phase25.sh test_spawn_no_docs_does_not_invoke_git` | ❌ Wave 0 |
| CTX-04 | Mount source path contains no `.git` directory at any depth | unit | `bash tests/test-phase25.sh test_fetch_docs_context_mount_source_excludes_git` | ❌ Wave 0 |
| CTX-04 | Container `ls /agent-docs/.git` returns "No such file or directory" | integration (docker) | `bash tests/test-phase25.sh test_agent_docs_no_git_dir_in_container` | ❌ Wave 0 (gated by docker availability) |
| CTX-04 | `fetch_docs_context` clone error path scrubs `DOCS_REPO_TOKEN` from stderr | unit | `bash tests/test-phase25.sh test_fetch_docs_context_pat_scrub_on_clone_error` | ❌ Wave 0 |
| (regression) | Phase 23 `tests/test-phase23.sh` continues to pass (no profile validation drift) | regression | `bash tests/test-phase23.sh` | ✅ exists |
| (regression) | Phase 24 `tests/test-phase24.sh` continues to pass (no clone helper drift) | regression | `bash tests/test-phase24.sh` | ✅ exists |
| (regression) | Phase 16 `tests/test-phase16.sh` continues to pass (no compose volume drift) | regression | `bash tests/test-phase16.sh` | ✅ exists |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase25.sh` (fast — uses local `file://` bare repos for the unit-test layer; docker-gated integration tests skip when docker is unavailable)
- **Per wave merge:** `bash tests/test-phase25.sh && bash tests/test-phase23.sh && bash tests/test-phase24.sh && bash tests/test-phase16.sh` (mandatory regression on the four phases that touch docs-binding, clone helpers, publish bundle, and compose volumes)
- **Phase gate:** `./run-tests.sh` full suite green before `/gsd:verify-work`. Docker-gated integration tests MUST run on a host with docker available before phase sign-off; CI may skip them with an explicit "skip: docker not available" PASS.

### Wave 0 Gaps

- [ ] `tests/test-phase25.sh` — new phase test file following the Phase 23/24 bash harness pattern (sources `bin/claude-secure` via `__CLAUDE_SECURE_SOURCE_ONLY=1`; uses local `file://` bare repos for clone targets; docker-gated tests gracefully skip when docker is unavailable; `trap cleanup EXIT`)
- [ ] `tests/fixtures/profile-25-docs/` — fixture profile with populated `docs_*` fields and a `DOCS_REPO_TOKEN=fake-phase25-token` (NO `ghp_` prefix per Phase 17 Pitfall 13 guardrail)
- [ ] A bare `file://` doc repo created in `test-phase25.sh setUp` that already contains a `projects/test-slug/` layout (mirrors Phase 23's `init-docs` test bare-repo pattern, but pre-seeded with the layout instead of expecting `init-docs` to create it)
- [ ] `tests/test-map.json` entry for `test-phase25.sh` and `tests/fixtures/profile-25-docs/**` mapping
- [ ] `tests/test-map.json` requirement entries for `CTX-01`, `CTX-02`, `CTX-03`, `CTX-04` (mirroring the Phase 23 `BIND-01..BIND-03` / `DOCS-01` blocks at lines 243-281)
- [ ] Add `tests/test-phase25.sh` and `docker-compose.yml` to the `bin/claude-secure` mapping in `tests/test-map.json` (so changes to `bin/claude-secure` automatically run Phase 25 tests in CI)

**No framework install needed** — bash + jq + git + docker are already verified by Phases 18, 19, 23, and 24.

## Project Constraints (from CLAUDE.md)

The following CLAUDE.md directives apply to Phase 25 and MUST be honored by plans:

- **Platform:** Linux native + WSL2 + macOS (Phase 18/19). The bind mount must work on all three. macOS Docker Desktop honors `:ro` via VirtioFS/gRPC-FUSE (verified by Phase 19). Use `realpath` to normalize the mount source path on macOS where `/tmp -> /private/tmp` symlinks could otherwise confuse Docker.
- **Security — host-only secret:** CLAUDE.md reinforces Phase 23's `DOCS_REPO_TOKEN` host-only invariant. Phase 25 MUST NOT route `DOCS_REPO_TOKEN` through any container, MUST NOT add the variable to any `environment:` or `env_file:` block, and MUST NOT inject the PAT into a clone URL. The askpass shim is the only sanctioned PAT delivery mechanism.
- **Security — no .git/ in container:** PITFALLS.md m-4 explicitly forbids mounting the doc repo's `.git` directory into the Claude container. CTX-04 codifies this requirement; the planner must verify it empirically with a test.
- **No NFQUEUE / no proxy changes:** Phase 25 is pure host-side + compose work. `proxy/server.js`, `validator/`, and `claude/hooks/` MUST NOT be touched.
- **Standard library only:** Bash + git + Docker only. No new Node, Python, or supply-chain surface.
- **Buffered proxy (Phase 1 architecture):** Unchanged. The proxy does not see the docs path because the agent reads `/agent-docs/` as a local filesystem operation, not as an HTTP call to Anthropic.
- **Hook scripts root-owned:** Unchanged. Phase 25 does not modify any hook script.
- **Workflow enforcement:** All edits flow through a GSD command. Phase 25 work comes from `/gsd:execute-phase 25`.
- **Auth:** OAuth token (primary) + API key (fallback). Unchanged; Phase 25 uses neither — it uses `DOCS_REPO_TOKEN` for the docs repo only.

## Sources

### Primary (HIGH confidence)

- **Direct code inspection**
  - `bin/claude-secure:48, 562-567` — `_CLEANUP_FILES` array + `spawn_cleanup` trap (cleanup mechanism reused verbatim)
  - `bin/claude-secure:121-165` — `validate_docs_binding` (Phase 23 schema validation already in place)
  - `bin/claude-secure:232-294` — `resolve_docs_alias` (Phase 23 exports `DOCS_REPO`/`DOCS_BRANCH`/`DOCS_PROJECT_DIR`/`DOCS_REPO_TOKEN`)
  - `bin/claude-secure:416-450` — `load_profile_config` (calls `resolve_docs_alias`; runs from main dispatch before `do_spawn`)
  - `bin/claude-secure:1480-1614` — `do_profile_init_docs` (Phase 23 askpass + clone + empty-repo fallback pattern, directly reusable)
  - `bin/claude-secure:1646-1828` — `publish_docs_bundle` (Phase 24 askpass + bounded clone + PAT scrub pattern, directly reusable)
  - `bin/claude-secure:1843-2010` — `do_spawn` (integration site for `fetch_docs_context` call)
  - `bin/claude-secure:1916-1917` — `trap spawn_cleanup EXIT` (already in place; `_CLEANUP_FILES` registration after this trap is automatically cleaned)
  - `bin/claude-secure:2007` — `docker compose up -d --wait` (the line `fetch_docs_context` must run BEFORE)
  - `bin/claude-secure:2685-2691` — `*)` case interactive path (also needs `fetch_docs_context` per Open Question 4)
  - `docker-compose.yml:13, 30, 31, 92` — existing `${VAR:-default}` substitution sites; the `WHITELIST_PATH:-./config/whitelist.json:/etc/.../whitelist.json:ro` line is the working precedent for Phase 25's volume entry
- **Empirical verification on host (2026-04-14)**
  - `git --version` → 2.43.0 (well above 2.25 minimum for sparse-checkout)
  - `docker --version` → 29.3.1
  - `git clone --depth=1 --filter=blob:none --sparse --branch main bare.git sparse-clone && cd sparse-clone && git sparse-checkout set projects/foo` → confirmed `.git/` is at clone root, `projects/foo/` contains zero `.git` references
  - Bind-mount `:ro` semantics on Linux 6.6 WSL2 — Docker passes `MS_RDONLY` to the kernel, EROFS on write attempts (verified empirically by Phase 19 smoke tests)
- **Phase design context (HIGH confidence)**
  - `.planning/research/STACK.md:16, 32, 52-55, 165, 222, 304` — sparse + shallow + partial clone strategy documentation
  - `.planning/research/ARCHITECTURE.md:160-228, 305, 350-356, 407-408` — read-only bind mount architecture, integration point at `do_spawn`, security rationale
  - `.planning/research/PITFALLS.md:311-313` — m-4 "Doc repo `.git` dir mounted into the Claude container for convenience" → explicit prohibition
  - `.planning/research/SUMMARY.md:23, 49, 52, 87, 115, 129, 160` — v4.0 milestone Phase C ("fetch_docs_context + Read-Only Bind Mount") rationale, dependency chain, sparse-checkout stability claim
  - `.planning/phases/23-profile-doc-repo-binding/23-RESEARCH.md` — Phase 23 patterns that this phase composes on top of
- **Project constants**
  - `CLAUDE.md` Constraints + Technology Stack sections — platform support, host-only secret invariant, standard-library-only policy
  - `.planning/REQUIREMENTS.md` v4.0 CTX-01..CTX-04
  - `.planning/ROADMAP.md:148-157` — Phase 25 success criteria (verbatim source of truth)

### Secondary (MEDIUM confidence)

- [git-sparse-checkout official docs](https://git-scm.com/docs/git-sparse-checkout) — flags and subcommands stable since git 2.25 (cited via STACK.md:304)
- [git-clone --filter=blob:none docs](https://git-scm.com/docs/partial-clone) — partial clone reliability since git 2.27
- Docker bind mount `:ro` semantics documented in [Docker docs — bind mounts](https://docs.docker.com/engine/storage/bind-mounts/) and verified empirically on the host

### Tertiary (LOW confidence — validate during implementation)

- **Docker Desktop on macOS bind mount `:ro` enforcement** — assumed correct based on Phase 19 smoke test passing on Docker Desktop. Phase 22 macOS integration tests will provide stronger confirmation when they ship. For Phase 25, the Linux/WSL2 paths are HIGH confidence; the macOS path inherits Phase 19's confidence level (MEDIUM-HIGH).
- **`/dev/null:/agent-docs:ro` no-op mount semantics** — verified via in-tree precedent (`SECRETS_FILE:-/dev/null` works) but not specifically tested for the `/dev/null:/agent-docs:ro` form. The planner should add a Wave 0 unit test that runs `docker compose config` with `AGENT_DOCS_HOST_PATH` unset and asserts the substitution resolves to `/dev/null` without error.
- **Reaper `cs-*` pattern coverage** — Phase 17 reaper sweeps `$TMPDIR/cs-*` based on age. The pattern `cs-agent-docs-XXXXXXXX` matches, but I did not run the reaper test suite to verify the cleanup path covers Phase 25's clone dirs. Recommendation: add a Phase 17 reaper unit test that confirms `cs-agent-docs-*` entries are reaped under the same age threshold as `cs-publish-*` and `cs-init-docs-*`.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zero new dependencies, `git sparse-checkout` empirically verified on host 2.43.0, Docker bind mount `:ro` is well-established kernel feature
- Architecture patterns: HIGH — `fetch_docs_context` is a ~60-line composition of existing Phase 23/24 primitives; compose volume entry is a 1-line addition mirroring `WHITELIST_PATH`; `do_spawn` integration is a 4-line insertion at a clean point
- Pitfalls: HIGH — most pitfalls are direct extensions of Phase 16/23/24 pitfalls (PAT scrub, cleanup races, file:// clone optimization). Pitfall 5 (empty subtree after typo'd `docs_project_dir`) is the only novel case and is straightforward to mitigate.
- Runtime state inventory: HIGH — Phase 25 introduces no persistent state; the only new env var (`AGENT_DOCS_HOST_PATH`) is host-only by construction
- Open questions: MEDIUM — five items flagged. Items 1, 4, and 5 should drive a CONTEXT.md discussion; items 2 and 3 have clear recommendations the planner can adopt without user input.

**Research date:** 2026-04-14
**Valid until:** 2026-05-14 (stable research surface — git sparse-checkout API and Docker bind mount semantics are mature; the only fast-moving variable is Docker Desktop on macOS which Phase 19 already covers)
