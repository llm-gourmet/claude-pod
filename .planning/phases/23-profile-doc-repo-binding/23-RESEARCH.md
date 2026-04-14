# Phase 23: Profile ↔ Doc Repo Binding - Research

**Researched:** 2026-04-13
**Domain:** Profile schema extension + host-only secret scoping + doc-repo bootstrap subcommand
**Confidence:** HIGH

## Summary

Phase 23 is a conservative, additive extension of the Phase 12 profile system and the Phase 16 report-push harness. 70% of the machinery already exists; the phase ships four field additions, a back-compat alias layer, and one new `profile init-docs` subcommand. Zero new containers, zero new long-running services, zero new runtime dependencies beyond tools already required by v1.0 (`git`, `jq`, `curl`, `uuidgen`).

The single highest-severity design decision is Phase 23 success criterion 2 — `DOCS_REPO_TOKEN` must be **provably absent from the Claude container**. Today's code path does not achieve this: `load_profile_config` in `bin/claude-secure` sources the profile `.env` with `set -a` and `docker-compose.yml` passes the raw `SECRETS_FILE` (the same `.env`) into both the `claude` and `proxy` containers via `env_file:`. Any new token added to `.env` today ends up in `claude`'s environment. Phase 23 must tighten this: either (a) split host-only vars into a sibling file loaded by bash only and generate a filtered `.env` for docker-compose, or (b) keep `.env` in compose but move `DOCS_REPO_TOKEN` out of it entirely into `host.env` / profile.json-sibling file. Recommendation: Option (a) — filtered `.env` projection — preserves Phase 7 redaction semantics while excluding the new host-only token.

All other phase deliverables (schema validation, back-compat aliasing, `init-docs` atomic commit) are direct extensions of established Phase 12/16 patterns and carry HIGH confidence.

**Primary recommendation:** Add four optional fields to profile.json (`docs_repo`, `docs_branch`, `docs_project_dir`, `docs_mode`), add `DOCS_REPO_TOKEN` as a host-only `.env` variable filtered out of the container projection, make old `report_repo` / `REPORT_REPO_TOKEN` act as aliases with a deprecation warning, and ship `claude-secure profile init-docs --profile <name>` as a new subcommand that reuses the Phase 16 clone-commit-push harness to lay down `projects/<slug>/{todo.md,architecture.md,vision.md,ideas.md,specs/,reports/INDEX.md}` in a single atomic commit.

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase — `/gsd:discuss-phase` has not been run. The planner should treat the roadmap success criteria (copied verbatim into Phase Requirements below) as the locked decisions, and mark all other design choices as Claude's discretion until/unless a discussion pass adds CONTEXT.md.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BIND-01 | User can configure `docs_repo`, `docs_branch`, `docs_project_dir`, and `DOCS_REPO_TOKEN` per profile | Schema extension pattern below; `validate_profile` extension; `load_profile_config` field export list |
| BIND-02 | `DOCS_REPO_TOKEN` stored host-only, never mounted into Claude container | "Host-Only Secret Projection" pattern below (filtered .env projection); `env_file:` audit + container-side `env` test |
| BIND-03 | Legacy `report_repo` / `REPORT_REPO_TOKEN` keep working as aliases with deprecation warning | Alias resolution function + `[ -n "$OLD" ] && [ -z "$NEW" ]` fallback pattern; stderr warning rate-limited via state file |
| DOCS-01 | `claude-secure profile init-docs --profile <name>` bootstraps `projects/<slug>/` atomically and idempotently | Reuse Phase 16 `publish_report` clone-commit-push harness with multi-file staging; idempotency via `git diff --quiet` check pre-commit |

**Success Criteria Mapping:**
1. Validation at spawn time → `validate_profile` gains a `validate_docs_binding()` branch called when any doc field is present
2. Token absence from container → Host-Only Secret Projection section (filtered `.env` generation + compose `env_file` swap)
3. Legacy alias continuity → Alias Resolution Pattern section + rate-limited deprecation warning (one-line per-profile on first use)
4. `init-docs` atomicity + idempotency → Atomic Bootstrap Pattern section (stage-all → commit-once → push-with-retry; `git diff --cached --quiet` short-circuit)

## Standard Stack

### Core
No new dependencies. Every tool required by this phase is already installed and exercised in Phases 12-17.

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `jq` | 1.7+ (already installed, host-verified 1.7) | Read/write profile.json, schema validation, one-shot field extraction | Phase 12 precedent — all profile.json manipulation in `bin/claude-secure` uses `jq` today (lines 73-112, 1273-1277) |
| `git` CLI | 2.34+ (host-verified 2.43.0) | Clone + commit + push doc repo during `init-docs` | Phase 16 precedent — `publish_report` at lines 1052-1144 already uses the exact same pattern this phase needs |
| `bash` | 4+ (GNU via Phase 18 re-exec on macOS) | Subcommand dispatch, field validation loops, deprecation warning rate-limit | Phase 18 already enforces bash 4+ via `re-exec into brew bash 5` prologue on macOS |
| `uuidgen` | BSD/GNU (already normalized lowercase by Phase 18 PORT-04) | Not directly used by this phase; mentioned only to note the helper exists if `init-docs` wants a one-shot session-id for logs | Phase 18 portability shim already in place |

### Supporting (Reused Functions)

The phase reuses these existing functions verbatim or with small extension. No rewrites.

| Function | File:line | Reuse Pattern |
|----------|-----------|---------------|
| `validate_profile_name` | `bin/claude-secure:61-71` | Called as-is by `init-docs` dispatcher |
| `validate_profile` | `bin/claude-secure:73-112` | Extend with optional `validate_docs_binding` sub-check when any `docs_*` field present |
| `load_profile_config` | `bin/claude-secure:234-257` | Extend field export list: add `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_MODE`, resolve aliases here |
| `publish_report` | `bin/claude-secure:1052-1144` | `init-docs` reuses the clone + askpass + `push_with_retry` pattern — factor the core into a shared helper if cleaner, or call a new `publish_docs_bundle_init` wrapper |
| `push_with_retry` | `bin/claude-secure:981-1035` | Called as-is for the init-docs bootstrap commit |
| `redact_report_file` (D-15) | `bin/claude-secure` (Phase 16) | Run over the six stub files staged by `init-docs` before `git add` — belt-and-braces; the stubs are empty templates so no secrets expected, but the redactor is unconditional by design |
| Spawn-time validation chokepoint | `bin/claude-secure:1793` and `:1802` | `load_profile_config` is called immediately after `validate_profile` on every command path that needs it — this is the natural place to fail closed on malformed `docs_*` fields |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Filtered `.env` projection for container | Keep single `.env`, add explicit `- VAR=${VAR}` exclusion in `environment:` (compose can't "unset" an env_file var) | Compose does not support negative filters on `env_file`; the only way to exclude a variable is to not include it in the projected file. Filtered projection is therefore the only viable mechanism, NOT an optional optimization. |
| New sibling `host.env` file | Split into `profile/.env` (container-safe) + `profile/host.env` (host-only) | Clean separation but forces users to learn a new file layout. Filtered projection keeps the single-`.env` UX and makes one well-known variable name (`DOCS_REPO_TOKEN`) the sole exclusion — smaller cognitive cost, identical security outcome. |
| `profile init-docs` as a separate binary | Add it to `bin/claude-secure` subcommand dispatch | Phase 12-17 treats `bin/claude-secure` as the single CLI; adding a new binary fragments the interface and duplicates profile resolution. Keep inside. |
| Schema-validate profile.json via `ajv` or Python | Use hand-written `jq` checks matching Phase 12 style | Phase 12 `validate_profile` is ~40 lines of `jq`/`test`. Adding a JSON-Schema validator means a new host dep (`ajv` is Node, `check-jsonschema` is Python). Stay consistent with Phase 12. |

**No installation needed.** Verified tool availability on this host:
```
$ git --version     # 2.43.0
$ which jq git curl uuidgen
/usr/bin/jq /usr/bin/git /usr/bin/curl /usr/bin/uuidgen
```

**Version verification:** Not applicable — this phase adds zero new dependencies. The versions of existing tools (git 2.43, jq 1.7, bash 5.x) are verified by Phases 18-19 and remain unchanged.

## Architecture Patterns

### Recommended Changes (scoped)

```
bin/claude-secure
├── validate_profile()               # extend: call validate_docs_binding if any docs_* field present
├── validate_docs_binding()          # NEW: schema check for the 4 fields + token presence
├── load_profile_config()            # extend: export DOCS_* vars + alias resolution
├── resolve_docs_alias()             # NEW: map report_repo → docs_repo, REPORT_REPO_TOKEN → DOCS_REPO_TOKEN
├── emit_deprecation_warning()       # NEW: rate-limited stderr warning, one per profile per shell session
├── do_profile_init_docs()           # NEW: subcommand implementation
└── CMD dispatch case                # extend: add "profile" with sub-subcommands

docker-compose.yml
└── claude.env_file                  # change: point to projected .env, not raw .env

docs_env_projection (new host-side helper, inline in bin/claude-secure)
└── Generate $TMPDIR/cs-projected-<uuid>.env from raw .env, omitting DOCS_REPO_TOKEN and report_repo_token
    Register with _CLEANUP_FILES, export SECRETS_FILE to point at it
```

### Pattern 1: Alias Resolution (BIND-03)
**What:** When the planner reads profile fields, prefer new names, fall back to legacy names, warn once if legacy is seen.

**When to use:** Inside `load_profile_config` after the `set -a; source .env; set +a` block and `jq` read of profile.json.

**Example:**
```bash
# In load_profile_config(), after sourcing .env and reading profile.json

# Token alias: prefer DOCS_REPO_TOKEN, fall back to REPORT_REPO_TOKEN
if [ -z "${DOCS_REPO_TOKEN:-}" ] && [ -n "${REPORT_REPO_TOKEN:-}" ]; then
  DOCS_REPO_TOKEN="$REPORT_REPO_TOKEN"
  _DEPRECATED_REPORT_TOKEN=1
fi

# Field alias: prefer docs_repo, fall back to report_repo
local legacy_repo new_repo
new_repo=$(jq -r '.docs_repo // empty' "$pdir/profile.json")
legacy_repo=$(jq -r '.report_repo // empty' "$pdir/profile.json")
if [ -z "$new_repo" ] && [ -n "$legacy_repo" ]; then
  DOCS_REPO="$legacy_repo"
  _DEPRECATED_REPORT_REPO=1
else
  DOCS_REPO="$new_repo"
fi

# Branch + project_dir aliases
DOCS_BRANCH=$(jq -r '.docs_branch // .report_branch // "main"' "$pdir/profile.json")
DOCS_PROJECT_DIR=$(jq -r '.docs_project_dir // empty' "$pdir/profile.json")
DOCS_MODE=$(jq -r '.docs_mode // "report_only"' "$pdir/profile.json")

export DOCS_REPO DOCS_BRANCH DOCS_PROJECT_DIR DOCS_MODE DOCS_REPO_TOKEN

# Emit rate-limited deprecation warning (once per profile per shell session)
if [ "${_DEPRECATED_REPORT_REPO:-0}" = "1" ] || [ "${_DEPRECATED_REPORT_TOKEN:-0}" = "1" ]; then
  emit_deprecation_warning "$name"
fi
```

**Rate-limit mechanism for the warning:** Track a sentinel in a host temp file keyed by profile name — `$TMPDIR/cs-deprecation-warned-<profile>`. Create on first warning; skip the stderr line if present. This file is cheap, per-session, self-expiring via shell cleanup.

### Pattern 2: Host-Only Secret Projection (BIND-02)
**What:** Create a filtered copy of the profile `.env` that excludes known host-only variables, and point `docker-compose`'s `env_file` directive at the filtered copy instead of the raw `.env`.

**When to use:** Inside `load_profile_config`, immediately before the `export SECRETS_FILE="$pdir/.env"` line (which becomes `export SECRETS_FILE="$projected_env"`).

**Why it works:** Compose's `env_file:` reads the file at `up` time. If `DOCS_REPO_TOKEN` is not in the file, it cannot enter the container's process env. The host-side bash has already sourced the raw `.env`, so `DOCS_REPO_TOKEN` is available to `publish_report` / `init-docs` without ever crossing the container boundary.

**Example:**
```bash
# Host-only variables that must NEVER reach any container's env
_HOST_ONLY_VARS=("DOCS_REPO_TOKEN" "REPORT_REPO_TOKEN")

project_env_for_containers() {
  local src="$1"       # raw $pdir/.env
  local dst            # filtered projection

  dst=$(mktemp "${TMPDIR:-/tmp}/cs-projected-env-XXXXXXXX")
  _CLEANUP_FILES+=("$dst")
  chmod 600 "$dst"

  # Build a regex that matches any host-only var assignment at line start
  local pattern="^("
  local first=1
  for v in "${_HOST_ONLY_VARS[@]}"; do
    if [ $first -eq 1 ]; then pattern+="$v"; first=0; else pattern+="|$v"; fi
  done
  pattern+=")="

  # grep -v removes matching lines; LC_ALL=C for deterministic regex
  LC_ALL=C grep -Ev "$pattern" "$src" > "$dst" || true
  echo "$dst"
}

# Inside load_profile_config, replace:
#   export SECRETS_FILE="$pdir/.env"
# with:
export SECRETS_FILE
SECRETS_FILE=$(project_env_for_containers "$pdir/.env")
```

**Source:** Direct code inspection of `bin/claude-secure:234-257` + `docker-compose.yml:12-13`. No external reference — this is a project-specific mechanism.

### Pattern 3: Atomic Bootstrap Commit (DOCS-01)
**What:** `init-docs` clones the doc repo, creates the six-file layout under `projects/<slug>/`, and runs exactly one `git commit` that stages all new files, then pushes via `push_with_retry`. Idempotent: if the layout already exists with identical content, no commit is created, exit 0.

**When to use:** `claude-secure profile init-docs --profile <name>` subcommand only.

**Example:**
```bash
do_profile_init_docs() {
  local profile="$1"
  validate_profile_name "$profile" || return 1
  validate_profile "$profile" || return 1
  load_profile_config "$profile" || return 1

  [ -n "${DOCS_REPO:-}" ]         || { echo "ERROR: profile '$profile' has no docs_repo" >&2; return 1; }
  [ -n "${DOCS_REPO_TOKEN:-}" ]   || { echo "ERROR: profile '$profile' has no DOCS_REPO_TOKEN in .env" >&2; return 1; }
  [ -n "${DOCS_PROJECT_DIR:-}" ]  || { echo "ERROR: profile '$profile' has no docs_project_dir" >&2; return 1; }

  local clone_dir
  clone_dir=$(mktemp -d "${TMPDIR:-/tmp}/cs-init-docs-XXXXXXXX")
  _CLEANUP_FILES+=("$clone_dir")

  # Reuse Phase 16 askpass pattern
  local askpass="$clone_dir/.askpass.sh"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf 'x-access-token\n' ;;
  Password*) printf '%s\n' "$GIT_ASKPASS_PAT" ;;
esac
ASKPASS
  chmod 700 "$askpass"

  # Clone (reuse Phase 16 flags)
  local clone_err="$clone_dir/clone.err"
  if ! LC_ALL=C \
       GIT_ASKPASS="$askpass" \
       GIT_ASKPASS_PAT="$DOCS_REPO_TOKEN" \
       GIT_TERMINAL_PROMPT=0 \
       GIT_HTTP_LOW_SPEED_LIMIT=1 \
       GIT_HTTP_LOW_SPEED_TIME=30 \
       timeout 60 \
       git -c credential.helper= -c credential.helper='' \
           -c core.autocrlf=false \
           clone --depth 1 --branch "$DOCS_BRANCH" --quiet \
                 "$DOCS_REPO" "$clone_dir/repo" 2>"$clone_err"; then
    sed "s|${DOCS_REPO_TOKEN}|<REDACTED:DOCS_REPO_TOKEN>|g" "$clone_err" >&2
    return 1
  fi

  # Create project layout. mkdir -p is idempotent; file writers use -n / [ ! -f ] to preserve existing content
  local proj="$clone_dir/repo/$DOCS_PROJECT_DIR"
  mkdir -p "$proj/specs" "$proj/reports"

  _write_stub() {
    local path="$1" content="$2"
    [ -f "$path" ] && return 0   # idempotent: never overwrite existing content
    printf '%s' "$content" > "$path"
  }

  _write_stub "$proj/todo.md"         "# Todo — $profile

- [ ] (add items)
"
  _write_stub "$proj/architecture.md" "# Architecture — $profile

Describe the system's structure here.
"
  _write_stub "$proj/vision.md"       "# Vision — $profile

Describe the project goal here.
"
  _write_stub "$proj/ideas.md"        "# Ideas — $profile

Append-only findings.
"
  _write_stub "$proj/reports/INDEX.md" "# Report Index — $profile

| Date | Session | Summary |
|------|---------|---------|
"

  # specs/ is a directory — create a .gitkeep so git tracks it
  _write_stub "$proj/specs/.gitkeep" ""

  # Stage all new files relative to the project subdir
  if ! git -C "$clone_dir/repo" add "$DOCS_PROJECT_DIR/"; then
    return 1
  fi

  # Idempotency check: if nothing to commit, exit 0 without error
  if git -C "$clone_dir/repo" diff --cached --quiet; then
    echo "Doc layout already initialized at $DOCS_PROJECT_DIR — nothing to do."
    return 0
  fi

  # Atomic commit (single commit per Phase 23 success criterion 4)
  local commit_msg="docs($profile): initialize projects/$DOCS_PROJECT_DIR layout"
  if ! LC_ALL=C \
       GIT_AUTHOR_NAME="claude-secure" \
       GIT_AUTHOR_EMAIL="claude-secure@localhost" \
       GIT_COMMITTER_NAME="claude-secure" \
       GIT_COMMITTER_EMAIL="claude-secure@localhost" \
       git -C "$clone_dir/repo" -c core.autocrlf=false commit -q -m "$commit_msg"; then
    return 1
  fi

  # Reuse Phase 16 push_with_retry (handles non-ff races + 3 attempts + stderr scrub)
  if ! push_with_retry "$clone_dir" "$DOCS_BRANCH"; then
    return 1
  fi

  echo "Initialized $DOCS_PROJECT_DIR in $DOCS_REPO ($DOCS_BRANCH)"
  return 0
}
```

**Source:** Phase 16 `publish_report` structure (`bin/claude-secure:1052-1144`) is the template — this function is its moral twin with stub generation replacing the single-file copy.

### Pattern 4: Schema Validation at Spawn Chokepoint (BIND-01)
**What:** Fail closed at the existing spawn-time validation chokepoint (`validate_profile` at line 1790) when any `docs_*` field is malformed.

**When to use:** Add a `validate_docs_binding` helper called unconditionally inside `validate_profile` (so both `spawn` and interactive mode get the check), but only enforce if at least one doc field is present — profiles with no docs intent must keep working.

**Example:**
```bash
validate_docs_binding() {
  local name="$1"
  local pdir="$CONFIG_DIR/profiles/$name"
  local pj="$pdir/profile.json"

  # Read all four fields (with alias fallback for BIND-03)
  local repo branch project_dir
  repo=$(jq -r '.docs_repo // .report_repo // empty' "$pj")
  branch=$(jq -r '.docs_branch // .report_branch // "main"' "$pj")
  project_dir=$(jq -r '.docs_project_dir // empty' "$pj")

  # If nothing is set, doc binding is opt-out — return 0 silently.
  if [ -z "$repo" ]; then
    return 0
  fi

  # At least one field is set → all of them must be valid (fail-closed)
  if [[ ! "$repo" =~ ^https://[^[:space:]]+\.git$ ]]; then
    echo "ERROR: profile '$name' docs_repo must be HTTPS URL ending in .git (got: $repo)" >&2
    return 1
  fi
  if [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: profile '$name' docs_branch is malformed: $branch" >&2
    return 1
  fi
  if [ -z "$project_dir" ]; then
    echo "ERROR: profile '$name' docs_repo set but docs_project_dir is missing" >&2
    echo "       Add: jq '.docs_project_dir = \"projects/<slug>\"' > profile.json" >&2
    return 1
  fi
  if [[ "$project_dir" =~ \.\. ]] || [[ "$project_dir" = /* ]]; then
    echo "ERROR: profile '$name' docs_project_dir must be relative and contain no '..': $project_dir" >&2
    return 1
  fi

  # DOCS_REPO_TOKEN check — source .env temporarily to avoid polluting caller state
  local token
  token=$(grep -E '^(DOCS_REPO_TOKEN|REPORT_REPO_TOKEN)=' "$pdir/.env" 2>/dev/null | head -1 | cut -d= -f2-)
  if [ -z "$token" ]; then
    echo "ERROR: profile '$name' docs_repo set but DOCS_REPO_TOKEN missing from $pdir/.env" >&2
    return 1
  fi
}
```

Called from `validate_profile` after the existing whitelist.json checks. Return non-zero fails the whole profile load, same as any other Phase 12 validator.

### Anti-Patterns to Avoid

- **Do NOT add a separate host-only secrets file.** Keep the single `.env` UX; filter the projection. Users already know where profile `.env` lives.
- **Do NOT write DOCS_REPO_TOKEN into any compose `environment:` key.** It must travel from host bash → `publish_report` / `init-docs` call stack only. The variable name should never appear in `docker-compose.yml` or any container image dockerfile.
- **Do NOT delete legacy `report_repo` / `REPORT_REPO_TOKEN` handling.** Success criterion 3 explicitly requires it to continue working. Only add; never remove in this phase.
- **Do NOT use `git push --force` or `git commit --amend` in `init-docs`.** Success criterion 4 requires "single atomic commit" — a straight `commit` + `push_with_retry` with rebase-on-non-ff handles it cleanly.
- **Do NOT overwrite existing files in `init-docs`.** Idempotency means: if `projects/<slug>/todo.md` already exists, leave it alone. Use `[ -f "$path" ] && return 0` in the stub writer.
- **Do NOT bypass the Phase 16 askpass helper pattern.** The file-based credential helper with `GIT_TERMINAL_PROMPT=0` is the only method that works reliably across dev/CI and keeps PAT out of `ps` output. Reuse it directly.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Clone + push with PAT | A custom curl-based REST client that commits trees via GitHub API | Existing Phase 16 `publish_report` / `push_with_retry` | REST multi-file commits need Tree+Blob+Commit API choreography, which is several orders of magnitude more code than `git commit` and has no atomicity advantage. Training-data patterns that use `octokit` or `gh api` here are wrong for this project. |
| Non-fast-forward retry | A fresh retry loop around `git push` | `push_with_retry` from Phase 16 | Already handles 5 flavors of remote-ref rejection (`non-fast-forward`, `Updates were rejected`, `failed to update ref`, `cannot lock ref`, `remote rejected`), all with PAT-scrub on stderr. Phase 17 plan 01 expanded these specifically to cover file:// and https:// paths. Re-deriving means re-discovering the same surface. |
| Secret redaction over staged files | A one-off `sed -i s/token/REDACTED/` | `redact_report_file` (D-15) | Handles awk-from-file substitution safely across metacharacter-bearing secret values (Phase 16 Pitfall 1). `init-docs` stubs are empty so redaction is mostly defensive, but run it anyway — "no opt-out" is the Phase 16 invariant. |
| PAT presence in stderr on failure | Uncontrolled `2>err` without post-processing | Phase 16 `sed "s|$PAT|<REDACTED>|g" err_log >&2` pattern | Git occasionally echoes the URL-embedded PAT into error messages. Phase 16 pattern scrubs every error path before it reaches operator stderr. Do not skip. |
| Atomic `.env` projection without leaks | Inline `grep -v VAR1 .env > tmp; grep -v VAR2 tmp > tmp2` (multiple passes) | Single `grep -Ev "^(VAR1\|VAR2)=" .env > tmp` | One pass, one file, zero intermediate state. Use `LC_ALL=C` for deterministic ERE matching across glibc/BSD. |
| JSON schema validation | `ajv`, `check-jsonschema`, or `jsonschema` python | Hand-written `jq` + `[[ =~ ]]` checks matching Phase 12 `validate_profile` style | Phase 12 already validates schema in ~40 lines. Adding a runtime schema dep means new host install friction. Mirror the existing convention. |
| Subcommand dispatch | Nested `case` with ad-hoc flag parsing | Mirror the existing Phase 13 `do_spawn` REMAINING_ARGS loop pattern | `bin/claude-secure` already has a `while [ $i -lt ${#REMAINING_ARGS[@]} ]` pattern (lines 1194-1203). Copy it for `profile init-docs`. Consistency > novelty. |

**Key insight:** This phase is 90% reuse and 10% new code. Every problem it touches has an in-tree solution from Phases 12, 16, or 17. The research bias should be toward "what's the nearest existing pattern" rather than "what's the textbook library for this".

## Runtime State Inventory

> Phase 23 is a schema extension + rename-alias phase. Runtime state matters because `report_repo` / `REPORT_REPO_TOKEN` already exist in users' profile files and tests.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None. Profile data lives in filesystem files (`~/.claude-secure/profiles/<name>/profile.json`, `.env`) — no SQLite, no ChromaDB, no Mem0. Phase 17 validator SQLite (`validator-db:/data`) holds call-IDs only, nothing profile-schema-related. | None — schema is entirely file-based and the alias layer is read-time. |
| Live service config | Phase 17 webhook listener (`webhook/listener.py`) reads profile.json on each incoming webhook via `resolve_profile_by_repo` (line 212) to route events. It does NOT currently read `report_repo`. Any future reader of the new `docs_*` fields is out of scope for Phase 23. | None for Phase 23. Phase 26 (Stop hook) and Phase 24 (publish bundle) will read `docs_*` — the listener stays unchanged. |
| OS-registered state | launchd plists (Phase 21, pending) and `claude-secure-webhook.service` / `claude-secure-reaper.service` / `claude-secure-reaper.timer` systemd units (`webhook/*.service`). None embed `report_repo` / `REPORT_REPO_TOKEN` in unit files — those units load environment from `~/.claude-secure/webhook/config.json`, not from profile `.env`. | None — the rename does not touch any unit file because unit files do not reference these variable names. |
| Secrets/env vars | `REPORT_REPO_TOKEN` is present in test fixtures (`tests/fixtures/profile-e2e/.env`, value `fake-e2e-token` — per Phase 17 Pitfall 13 guardrail) and in every real user profile `.env` that uses Phase 16 reporting. The name rename to `DOCS_REPO_TOKEN` with alias fallback is a code edit only — no data migration needed because the alias resolver reads both names. Users who never rename their `.env` keep working indefinitely. | Code edit in `load_profile_config` (alias resolver); test fixture update optional (can leave fixtures as `REPORT_REPO_TOKEN` to exercise the alias path — this is arguably better coverage). |
| Build artifacts / installed packages | None. claude-secure has no packaged artifacts that embed field names — `install.sh` copies scripts and templates, no compile step. The Phase 13 template directory (`/opt/claude-secure/webhook/report-templates/`) contains markdown templates that may reference `{{REPORT_URL}}` variables, but those are different variables than `report_repo` / `REPORT_REPO_TOKEN` — no aliasing required. | None — grep confirmed no template file references the renamed fields. |

**Canonical check:** *After every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?*

- User profile `.env` files on real installs — **handled by alias resolver, zero migration needed**.
- User profile.json files with `report_repo` — **handled by alias resolver, zero migration needed**.
- Test fixtures — **optional to update; leaving them as-is gives us alias-path test coverage**.
- Documentation (README.md at lines 226, 231, 331, 408) — **update documentation to mention new names primarily, legacy names as "also accepted (deprecated)"**.

**Nothing found in category:** Stored data, OS-registered state, and build artifacts — all verified by direct codebase grep (`report_repo|REPORT_REPO_TOKEN` → 33 files, all either code/docs/tests/research — no runtime state stores).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `git` | init-docs clone + commit + push | ✓ | 2.43.0 | — (Phase 16 already depends on this) |
| `jq` | profile.json read/write | ✓ | 1.7+ (verified by which jq) | — (Phase 12 already depends on this) |
| `curl` | (indirect via `git` HTTPS) | ✓ | system | — |
| `uuidgen` | (not directly needed; noted for completeness) | ✓ | util-linux | lowercase via Phase 18 PORT-04 shim |
| `mktemp` | `.env` projection + clone dir | ✓ | GNU coreutils | — |
| `grep -E` | `.env` projection filter | ✓ | GNU (macOS uses brew gnubin via Phase 18) | `LC_ALL=C` for deterministic regex |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

This phase adds zero new host requirements.

## Common Pitfalls

### Pitfall 1: Filtered `.env` projection runs too late (after load_profile_config has already exported into the current shell)
**What goes wrong:** Bash source-ing `.env` with `set -a` exports `DOCS_REPO_TOKEN` into the host shell process. If the projection happens AFTER the export, the variable is in the process env of anything the host bash spawns, including subcommands that bubble env into docker. If those subcommands use `docker compose run -e` instead of pure `env_file`, the variable leaks.
**Why it happens:** `load_profile_config` currently runs `set -a; source .env; set +a` at line 252-256. That's correct for host bash (publish_report needs the token), but means any `docker compose ...` call in the same shell process carries the variable in its env.
**How to avoid:** After sourcing `.env`, explicitly `unset` `DOCS_REPO_TOKEN` in the subshell that invokes `docker compose up`. Pattern: wrap compose calls in a function that does `env -i PATH="$PATH" HOME="$HOME" DOCS_REPO= DOCS_REPO_TOKEN= ... docker compose up`. OR: rely entirely on `env_file:` projection and verify docker compose does not propagate the host process env automatically. **Recommendation:** Use the compose docs' `--no-env-file` isolation — compose v2 does not inherit arbitrary host variables unless they appear in `environment:` substitution (`${FOO}`). Audit every substitution in `docker-compose.yml` and ensure `DOCS_REPO_TOKEN` appears nowhere.
**Warning signs:** `docker compose exec claude env | grep DOCS_REPO_TOKEN` returns anything.

### Pitfall 2: `grep -Ev` projection deletes valid lines with `DOCS_REPO_TOKEN` as substring
**What goes wrong:** A variable like `MY_DOCS_REPO_TOKEN_OVERRIDE=x` matches `DOCS_REPO_TOKEN` as a substring and is erroneously excluded.
**Why it happens:** Naive regex `DOCS_REPO_TOKEN=` matches anywhere in the line.
**How to avoid:** Anchor the regex to line start: `^(DOCS_REPO_TOKEN|REPORT_REPO_TOKEN)=`. Phase 16 already uses anchored regexes throughout; follow suit.
**Warning signs:** Unit test asserting the projected `.env` contains `MY_OTHER_SECRET` but it's missing.

### Pitfall 3: `init-docs` on a freshly-created empty repo (no branches) fails with "remote branch main not found"
**What goes wrong:** `git clone --depth 1 --branch main` on a repo that has zero commits fails because `main` does not exist yet.
**Why it happens:** GitHub creates repos with an initial commit only if the user clicks "Initialize with README". An empty repo has no refs.
**How to avoid:** Detect the empty-repo case and initialize locally: `git init -b <branch> "$clone_dir/repo"; git -C ... remote add origin $DOCS_REPO; git -C ... push -u origin <branch>` after the first commit. Alternatively, document the requirement: "create the repo on GitHub with at least one commit before running `init-docs`". **Recommendation:** Document the requirement. Adding init-from-empty branches the code path significantly and is better delivered as a follow-up.
**Warning signs:** Error message mentioning `Remote branch main not found in upstream origin`.

### Pitfall 4: Idempotency check passes but files are stale / outdated template
**What goes wrong:** User ran `init-docs` six months ago. New template has a different `todo.md` stub. `init-docs` detects "files exist, nothing to do", returns success, but the user never gets the new layout.
**Why it happens:** Idempotency at the file level means "don't overwrite". It does not mean "keep in sync".
**How to avoid:** Do not attempt template upgrade in Phase 23. Document that `init-docs` creates the baseline layout once; upgrades are a manual `git` operation. If the user wants to refresh templates, they delete the file and re-run. **Accept this limitation** — template drift is a v4.1+ concern and conflating it with Phase 23 doubles the surface.
**Warning signs:** Planner writes tasks to "refresh template versions". Push back: out of scope.

### Pitfall 5: Deprecation warning spams stderr on every `bin/claude-secure list` call
**What goes wrong:** Warning fires every time `load_profile_config` runs. `claude-secure list` iterates all profiles and loads each — N profiles = N warnings per invocation, per command.
**Why it happens:** The warning is not rate-limited.
**How to avoid:** Use a per-shell-session sentinel file: `touch $TMPDIR/cs-deprecation-warned-$profile` on first warning; skip if present. Since `$TMPDIR` is per-shell-session on most systems and the bash script is short-lived, this naturally resets per invocation. Alternative: gate the warning on `[ -t 2 ]` (only if stderr is a terminal) so JSON-parsing wrappers and CI logs stay quiet.
**Warning signs:** `claude-secure list` prints "WARNING: report_repo is deprecated" more than once for the same profile.

### Pitfall 6: `DOCS_REPO_TOKEN` in profile `.env` gets redacted by the Phase 3 Anthropic proxy but the redacted value is then used as the actual PAT
**What goes wrong:** Proxy redaction replaces `$DOCS_REPO_TOKEN` with `<REDACTED:DOCS_REPO_TOKEN>` in outbound HTTP bodies. If the host-side `publish_report` / `init-docs` somehow reads the redacted form (e.g. from a log dump, from container stdout), the PAT is broken.
**Why it happens:** Redaction operates on HTTP request bodies, not on host shell variables. The risk is only if a developer adds code that re-reads the host bash variable from a log file or container stdout — pathological, but worth noting.
**How to avoid:** Never log the raw PAT. Phase 16 already scrubs stderr via `sed`. Follow the same discipline in every new function — any error path that surfaces stderr must pass through the scrubber before reaching the operator. The Phase 3 redaction pipeline is orthogonal and protects the Anthropic egress path; it is not a source of truth for the host-side token value.
**Warning signs:** A log line containing the literal string `<REDACTED:DOCS_REPO_TOKEN>` on the git transport path.

### Pitfall 7: Rewriting `env_file:` in compose breaks existing `publish_report` path
**What goes wrong:** Phase 16 `publish_report` uses `DOCS_REPO_TOKEN` (previously `REPORT_REPO_TOKEN`) from the bash environment. If Phase 23 changes the variable's provenance (from "sourced from `.env`" to "read directly from `$pdir/.env` via grep"), the existing `publish_report` still works because bash has the variable. But if a refactor inadvertently skips the `set -a; source .env; set +a` for non-docker commands, `publish_report` loses its token.
**Why it happens:** Two ways to provide the variable to host bash: (1) `set -a; source .env; set +a` (current), (2) explicit `grep+cut` read per variable. Mixing the two creates drift.
**How to avoid:** Keep the `set -a; source .env; set +a` pattern intact. Only change `SECRETS_FILE` (the compose projection). The variable continues to be available to host bash via sourcing; the projection only affects what compose can see.
**Warning signs:** Phase 16 e2e test (`tests/test-phase16.sh`) breaks after Phase 23 changes — it means the host-side token path is broken.

## Code Examples

### Example 1: Full schema shape of the extended profile.json
```json
// Source: derived from Phase 12 create_profile + this phase's extension spec
{
  "workspace": "/home/user/claude-workspace-myapp",
  "repo": "owner/myapp",
  "webhook_secret": "xxx",
  "event_filter": ["issues.opened", "push.main"],
  "max_turns": 5,

  "docs_repo":        "https://github.com/user/claude-docs.git",
  "docs_branch":      "main",
  "docs_project_dir": "projects/myapp",
  "docs_mode":        "report_only",

  "report_repo":        "https://github.com/user/claude-docs.git",
  "report_branch":      "main",
  "report_path_prefix": "projects/myapp/reports"
}
```

The `report_*` fields can be removed once the user migrates; the system works with either set. On first use with only legacy fields, `load_profile_config` emits the deprecation warning and internally aliases them.

### Example 2: Profile `.env` shape
```bash
# Source: derived from Phase 12 install.sh:237-290 + this phase's extension spec

# Auth (existing, unchanged)
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...

# Host-only — MUST be filtered out of container projection
DOCS_REPO_TOKEN=github_pat_11ABCDEFG_...

# Legacy alias (for zero-migration back-compat; optional)
# REPORT_REPO_TOKEN=github_pat_11ABCDEFG_...

# Other secrets (container-visible, auto-redacted by Phase 3 proxy)
GITHUB_TOKEN=ghp_xxx
```

### Example 3: Subcommand dispatch addition
```bash
# Source: pattern matches existing do_replay / do_reap dispatch at bin/claude-secure:1959-1968
# Add to the top-level `case "$CMD" in` block (around line 1832)

  profile)
    PROFILE_SUB="${REMAINING_ARGS[1]:-}"
    case "$PROFILE_SUB" in
      init-docs)
        if [ -z "$PROFILE" ]; then
          echo "ERROR: --profile is required for 'profile init-docs'" >&2
          exit 1
        fi
        do_profile_init_docs "$PROFILE"
        ;;
      ""|--help|-h)
        echo "Usage: claude-secure --profile NAME profile <subcommand>"
        echo ""
        echo "Profile subcommands:"
        echo "  init-docs    Bootstrap the per-project doc repo layout"
        ;;
      *)
        echo "Unknown profile subcommand: $PROFILE_SUB" >&2
        exit 1
        ;;
    esac
    ;;
```

### Example 4: Container-absence assertion test (BIND-02 validation)
```bash
# Source: Phase 7 test-phase7.sh pattern for verifying env_file projection

test_docs_token_absent_from_container() {
  # Setup: profile with DOCS_REPO_TOKEN in .env
  local pdir="$TEST_TMPDIR/profiles/docsbind"
  mkdir -p "$pdir"
  cat > "$pdir/.env" <<EOF
CLAUDE_CODE_OAUTH_TOKEN=sk-test
DOCS_REPO_TOKEN=github_pat_SHOULD_NOT_LEAK
GITHUB_TOKEN=ghp_xxx
EOF
  jq -n --arg ws "$TEST_TMPDIR/ws" '{workspace: $ws, docs_repo: "https://example.com/repo.git", docs_branch: "main", docs_project_dir: "projects/test"}' \
    > "$pdir/profile.json"
  mkdir -p "$TEST_TMPDIR/ws"
  cp "$PROJECT_DIR/config/whitelist.json" "$pdir/whitelist.json"

  # Spawn the claude container via the actual compose pipeline
  CONFIG_DIR="$TEST_TMPDIR" \
    "$PROJECT_DIR/bin/claude-secure" --profile docsbind status &>/dev/null &
  wait

  # Assertion: container's env dump contains neither the variable name nor the value
  local container_env
  container_env=$(docker compose -p claude-docsbind exec -T claude env 2>/dev/null || echo "")
  if echo "$container_env" | grep -q 'DOCS_REPO_TOKEN'; then
    echo "FAIL: DOCS_REPO_TOKEN variable name found in container env"
    return 1
  fi
  if echo "$container_env" | grep -q 'github_pat_SHOULD_NOT_LEAK'; then
    echo "FAIL: DOCS_REPO_TOKEN value found in container env"
    return 1
  fi

  # Belt-and-braces: GITHUB_TOKEN (not host-only) SHOULD be present — proves the
  # projection did not accidentally strip everything.
  if ! echo "$container_env" | grep -q 'GITHUB_TOKEN=ghp_xxx'; then
    echo "FAIL: GITHUB_TOKEN unexpectedly filtered out of container env"
    return 1
  fi

  return 0
}
```

This is the canonical test for success criterion 2 and must fail in Wave 0 before any implementation.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| GitHub classic PAT (full-account scope) | GitHub fine-grained PAT (single-repo scope, 366-day max expiry) | 2022-10 (GA), GitHub blog canonical reference | BIND-02 relies on this — users SHOULD use a fine-grained PAT scoped to only the docs repo. README / profile.json example must say "Create a fine-grained PAT at github.com/settings/personal-access-tokens/new with Contents:Write for exactly the docs repo." |
| Phase 16 single-file `publish_report` | Phase 24 `publish_docs_bundle` (N-file atomic commit) | v4.0 milestone | Phase 23 does NOT build the bundle; it only lays the groundwork by shipping the schema fields the bundle will read. Tasks in Phase 23 plans must not write any code that touches Phase 24's surface. |
| `set -a; source .env; set +a` → `env_file: .env` in compose (Phase 7) | `set -a; source .env; set +a` → `env_file: projected.env` in compose (Phase 23 delta) | This phase | One-line change in `load_profile_config` — `SECRETS_FILE` now points at a filtered projection. Zero impact on existing secrets that stay container-visible. |

**Deprecated/outdated:**
- `report_repo` / `REPORT_REPO_TOKEN` — **still functional via alias**, do not remove. README moves them to a "Legacy (deprecated but supported)" section.

## Open Questions

1. **Should `init-docs` also push changes to `docs_branch` upstream, or only commit locally?**
   - What we know: Success criterion 4 says "created as a single atomic commit" and "is idempotent when the layout already exists." Does "atomic commit" mean local commit only, or local + remote?
   - What's unclear: The word "commit" is singular — could be read either way.
   - Recommendation: **Interpret as "commit + push"**. A local-only commit is useless because the doc repo is shared; the whole point is to seed a remote layout. Also, success criterion 4 pairs with the v4.0 architecture that says "all git operations run on the host", implying network traffic is expected. Flag this as the primary ambiguity for the planner to resolve or re-ask in CONTEXT.

2. **What slug rule does `init-docs` use if `docs_project_dir` is unset?**
   - What we know: The roadmap says the command creates `projects/<slug>/`. If `profile.json.docs_project_dir` already contains `projects/myapp`, that's the slug. But if the field is empty, should the command fail or derive a slug from the profile name?
   - What's unclear: Criterion 1 says `docs_project_dir` must be set for the profile to validate. So `init-docs` can require it too.
   - Recommendation: **Require `docs_project_dir` to be set** — consistent with the rest of the phase's "fail-closed" validation philosophy. Error message should suggest `jq -i '.docs_project_dir = "projects/<name>"'` with the profile name pre-filled.

3. **Does the deprecation warning need to be persistent across invocations, or only per-shell-session?**
   - What we know: Success criterion 3 says "a one-line deprecation warning is logged on first use."
   - What's unclear: "First use" across what window? Per shell, per day, per-profile-ever?
   - Recommendation: **Per-shell-session** via the `$TMPDIR` sentinel pattern. Persistent state across invocations adds complexity without value — operators who see the warning once have enough signal to rename.

4. **Should the filtered `.env` projection also filter `REPORT_REPO_TOKEN` (legacy name)?**
   - What we know: The legacy name is still accepted as an alias. If we filter only `DOCS_REPO_TOKEN`, users on the legacy name bypass the filter and the token leaks into the container.
   - What's unclear: Nothing — this is a gap in the roadmap spec.
   - Recommendation: **Filter both names.** The `_HOST_ONLY_VARS` array is `("DOCS_REPO_TOKEN" "REPORT_REPO_TOKEN")`. This is a direct security requirement of success criterion 2.

5. **Does `init-docs` create `reports/INDEX.md` as a file or leave it for Phase 24?**
   - What we know: Success criterion 4 explicitly lists `reports/INDEX.md` as part of the layout.
   - What's unclear: Nothing — the criterion is explicit.
   - Recommendation: **Create it**, with the minimal stub shown in Pattern 3 (header + empty markdown table). Phase 24 will append rows.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell (bash) test harness with `run_test` helper, PASS/FAIL counters, `trap cleanup EXIT` — Phase 12-19 project convention |
| Config file | None (direct `bash tests/test-phase23.sh` invocation) |
| Quick run command | `bash tests/test-phase23.sh` |
| Full suite command | `./run-tests.sh` (runs all phase suites per `tests/test-map.json`) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BIND-01 | `validate_profile` fails closed on malformed `docs_repo` URL | unit | `bash tests/test-phase23.sh test_docs_repo_url_validation` | ❌ Wave 0 |
| BIND-01 | `validate_profile` passes when all four fields are valid | unit | `bash tests/test-phase23.sh test_valid_docs_binding` | ❌ Wave 0 |
| BIND-01 | `validate_profile` passes silently when no `docs_*` fields are set (back-compat) | unit | `bash tests/test-phase23.sh test_no_docs_fields_ok` | ❌ Wave 0 |
| BIND-01 | `load_profile_config` exports `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_MODE` | unit | `bash tests/test-phase23.sh test_docs_vars_exported` | ❌ Wave 0 |
| BIND-02 | `DOCS_REPO_TOKEN` absent from claude container env (name AND value) | integration | `bash tests/test-phase23.sh test_docs_token_absent_from_container` | ❌ Wave 0 |
| BIND-02 | Projected `.env` omits `DOCS_REPO_TOKEN` line; retains all other vars | unit | `bash tests/test-phase23.sh test_projected_env_omits_docs_token` | ❌ Wave 0 |
| BIND-02 | `REPORT_REPO_TOKEN` (legacy name) also filtered from container | unit | `bash tests/test-phase23.sh test_projected_env_omits_legacy_token` | ❌ Wave 0 |
| BIND-03 | Profile with only `report_repo` still loads correctly | unit | `bash tests/test-phase23.sh test_legacy_report_repo_alias` | ❌ Wave 0 |
| BIND-03 | Profile with only `REPORT_REPO_TOKEN` still resolves token correctly | unit | `bash tests/test-phase23.sh test_legacy_report_token_alias` | ❌ Wave 0 |
| BIND-03 | Deprecation warning emitted exactly once per shell session per profile | unit | `bash tests/test-phase23.sh test_deprecation_warning_rate_limit` | ❌ Wave 0 |
| BIND-03 | Phase 16 `tests/test-phase16.sh` still passes unchanged | regression | `bash tests/test-phase16.sh` | ✅ exists |
| DOCS-01 | `init-docs` creates all six paths in the layout | integration | `bash tests/test-phase23.sh test_init_docs_creates_layout` | ❌ Wave 0 |
| DOCS-01 | `init-docs` produces exactly one commit | integration | `bash tests/test-phase23.sh test_init_docs_single_commit` | ❌ Wave 0 |
| DOCS-01 | `init-docs` is idempotent on second run (no new commits) | integration | `bash tests/test-phase23.sh test_init_docs_idempotent` | ❌ Wave 0 |
| DOCS-01 | `init-docs` fails closed when `docs_repo` is missing from profile | unit | `bash tests/test-phase23.sh test_init_docs_requires_docs_repo` | ❌ Wave 0 |
| DOCS-01 | `init-docs` never echoes the PAT to stderr on clone failure | unit | `bash tests/test-phase23.sh test_init_docs_pat_scrub_on_error` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase23.sh` (fast — all-shell, uses local `file://` bare repos and temp dirs, no network)
- **Per wave merge:** `bash tests/test-phase23.sh && bash tests/test-phase16.sh` (Phase 16 regression is mandatory because this phase rewires `SECRETS_FILE`)
- **Phase gate:** `./run-tests.sh` full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test-phase23.sh` — new phase test file following the Phase 12/16 bash harness pattern (sourcing helpers from `bin/claude-secure` via `__CLAUDE_SECURE_SOURCE_ONLY=1`, local `file://` bare repo for clone targets, `trap cleanup EXIT`)
- [ ] `tests/fixtures/profile-23-docs/` — fixture profile with populated `docs_*` fields and a `DOCS_REPO_TOKEN=fake-phase23-token` (NO `ghp_` prefix per Phase 17 Pitfall 13 guardrail)
- [ ] `tests/fixtures/profile-23-legacy/` — fixture profile with only `report_repo` + `REPORT_REPO_TOKEN` for the alias-path test
- [ ] A bare `file://` init repo created in `test-phase23.sh setUp` that the `init-docs` tests clone from and push to — mirrors the Phase 16 `docs-bare.git` fixture pattern

**No framework install needed** — bash + jq + git are already available.

## Project Constraints (from CLAUDE.md)

The following CLAUDE.md directives apply to Phase 23 and MUST be honored by plans:

- **Platform:** Linux native + WSL2. Phase 18 + 19 added macOS. `init-docs` must work on all three. Use the Phase 18 `re-exec into brew bash 5` prologue pattern if any new bash 4+ features are used.
- **Security — host-only secret:** CLAUDE.md reinforces the Phase 23 success criterion 2. Any design that routes `DOCS_REPO_TOKEN` through a container is a direct constraint violation.
- **No NFQUEUE / no proxy changes:** This phase is pure host-side work. `proxy/server.js`, `validator/`, and `hooks/pretooluse.sh` must not be touched.
- **Standard library only:** Node/Python both rejected for this phase — everything is bash + jq. No new supply-chain surface.
- **Redaction philosophy:** "Every byte that leaves the container must pass through the same scrubber, OR the byte was never near an LLM." `DOCS_REPO_TOKEN` must be in category 2 (never near the LLM). Filtered `.env` projection is the mechanism.
- **Workflow enforcement:** All edits flow through a GSD command. Phase 23 work comes from `/gsd:execute-phase 23`.

## Sources

### Primary (HIGH confidence)
- **Direct code inspection**
  - `bin/claude-secure:61-112` (validate_profile_name, validate_profile) — Phase 12 validation template to extend
  - `bin/claude-secure:114-161` (create_profile) — interactive profile creation flow
  - `bin/claude-secure:234-257` (load_profile_config) — the critical 24-line function that Phase 23 must modify
  - `bin/claude-secure:981-1035` (push_with_retry) — reusable non-ff retry engine with PAT scrub
  - `bin/claude-secure:1052-1144` (publish_report) — clone+commit+push template that `do_profile_init_docs` mirrors
  - `bin/claude-secure:1268-1277` (profile.json field export in do_spawn) — the exact injection site for new field exports
  - `bin/claude-secure:1770-1824` (CMD dispatch) — top-level case where the `profile` subcommand is added
  - `docker-compose.yml:12-13` and `44-45` (env_file projection sites) — where `SECRETS_FILE` is consumed
- **Phase design context (HIGH confidence, locked decisions)**
  - `.planning/phases/16-result-channel/16-CONTEXT.md` D-01 through D-18 — the exact source of the report-push model Phase 23 extends
  - `.planning/research/SUMMARY.md` — v4.0 milestone Phase A rationale, back-compat strategy, C-1 invariant
  - `.planning/research/ARCHITECTURE.md` lines 130-188, 297-390 — profile schema extension spec, integration point table, build order
  - `.planning/research/PITFALLS.md` C-1 lines 20-54 — the DOCS_REPO_TOKEN-as-exfil-channel threat model and prevention
  - `.planning/research/STACK.md` lines 52-65, 124-139, 222, 300-304 — fine-grained PAT guidance and git version check
- **Project constants**
  - `CLAUDE.md` Constraints + Technology Stack sections — platform support, standard-library-only policy
  - `.planning/REQUIREMENTS.md` v4.0 BIND-01..BIND-03, DOCS-01
  - `.planning/ROADMAP.md` Phase 23 success criteria (lines 119-128)
- **Test precedent**
  - `tests/test-phase12.sh` — profile-system bash test harness pattern
  - `tests/test-phase16.sh:327-378` — report-push integration test pattern with PAT scrub assertions
  - `tests/fixtures/profile-e2e/` — profile fixture layout precedent
  - `tests/test-phase7.sh` — `SECRETS_FILE` + `env_file` projection test pattern

### Secondary (MEDIUM confidence)
- GitHub fine-grained PAT docs (cited via `.planning/research/PITFALLS.md:389` and `STACK.md:300-301`) — 366-day max, per-repo scope, `Contents:Write` permission required for push
- Phase 14/15 webhook-path templates and per-profile fallback chain — used to validate that no template file references `report_repo`/`DOCS_REPO_TOKEN` by name

### Tertiary (LOW confidence — validate during implementation)
- **Open question 1 (commit vs push semantics of "atomic commit")** — cannot be resolved from research alone; either the planner picks the conservative interpretation (commit + push) OR the user clarifies in CONTEXT.md
- **Compose env propagation from host process env** — I assumed docker-compose v2 does NOT propagate arbitrary host variables unless they appear as `${FOO}` substitutions in the compose file. The current `docker-compose.yml` has four substitution sites (`SECRETS_FILE`, `WHITELIST_PATH`, `LOG_DIR`, `WORKSPACE_PATH`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `LOG_HOOK`, `LOG_PREFIX`, `LOG_ANTHROPIC*`, `LOG_IPTABLES`) and none of them reference `DOCS_REPO_TOKEN`. This assumption should be verified once via a compose dry-run (`docker compose config` output) during Wave 0.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zero new dependencies, all patterns are direct extensions of Phases 12/16
- Architecture patterns: HIGH — filtered `.env` projection is a 10-line change, alias resolver is a 15-line change, `do_profile_init_docs` is a ~90-line copy of `publish_report` with a stub-writer loop
- Pitfalls: HIGH — every pitfall has precedent in Phase 7 (env projection), Phase 16 (PAT scrub, non-ff retry), or Phase 17 (test-fixture hygiene)
- Runtime state inventory: HIGH — direct grep confirmed no SQLite, no OS registrations, no build artifacts touch the renamed fields
- Open questions: MEDIUM — five items flagged, all answerable by a short CONTEXT.md pass or by the planner choosing the conservative interpretation

**Research date:** 2026-04-13
**Valid until:** 2026-05-13 (stable research surface — no fast-moving APIs)
