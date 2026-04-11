# Phase 12: Profile System - Research

**Researched:** 2026-04-11
**Domain:** Bash CLI refactoring, JSON configuration, shell scripting patterns
**Confidence:** HIGH

## Summary

Phase 12 replaces the existing multi-instance system in `bin/claude-secure` with a profile-based system. The core work is: (1) rename instances to profiles with a new directory layout at `~/.claude-secure/profiles/<name>/`, (2) switch per-profile config from `config.sh` (shell vars) to `profile.json` (structured JSON), (3) add `repo` field mapping for GitHub webhook routing, (4) implement superuser mode that merges all profiles when `--profile` is omitted, and (5) enforce fail-closed validation (PROF-03).

The existing codebase is ~350 lines of bash in `bin/claude-secure`. The instance system (lines 16-168) is being fully replaced. Key reusable assets are the DNS-safe name validation function, the auth setup flow, and the Docker Compose integration patterns (COMPOSE_PROJECT_NAME, env_file, volume mounts). No new languages or dependencies are introduced -- this is pure bash + jq refactoring.

**Primary recommendation:** Implement as a clean rewrite of `bin/claude-secure` rather than incremental edits. The instance-to-profile rename touches nearly every function. Delete all instance code (migration logic, `--instance` flag), build profile functions fresh, reuse only the validated patterns (name validation regex, auth setup flow, compose variable exports).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Instances are renamed to profiles. The concept of "instance" is removed entirely.
- **D-02:** All instance code (--instance flag, migration logic, instance directory structure) is deleted. No migration needed -- existing instances are test data only.
- **D-03:** No backward compatibility layer. Clean break -- `--instance` flag removed, not deprecated.
- **D-04:** Each profile has a `repo` field in `profile.json` using `owner/repo` shorthand (e.g., `igorthetigor/claude-secure`). Matches GitHub webhook payload's `repository.full_name`.
- **D-05:** Repo mapping is explicit via config field, not convention-based.
- **D-06:** One profile = one repo. No multi-repo per profile.
- **D-07:** Profiles live at `~/.claude-secure/profiles/<name>/` (replaces `instances/`).
- **D-08:** Flat structure inside profile directory: `profile.json`, `.env`, `whitelist.json`, and prompt templates (`*.md`). No subdirectories.
- **D-09:** Config format switches from `config.sh` (shell vars) to `profile.json` (structured JSON). Parseable by all services via jq (bash), native JSON (Node.js/Python).
- **D-10:** `--instance` flag replaced by `--profile` flag.
- **D-11:** `--profile` is optional for all commands. No flag = superuser mode. `--profile NAME` = scoped mode.
- **D-12:** Interactive auto-create preserved: first use of `--profile NAME` triggers interactive setup (workspace path, auth).
- **D-13:** Repo field is optional during profile creation. Users add it to `profile.json` when they want webhook routing.
- **D-14:** `claude-secure list` shows a table with profile name, repo (if set), and workspace path.
- **D-15:** `claude-secure` without `--profile` starts a persistent instance with merged access to ALL profiles' secrets, whitelisted domains, and repos.
- **D-16:** Merged config is built at runtime on every start -- reads all profile directories, unions `.env` and `whitelist.json` content. No caching.
- **D-17:** Default workspace for superuser mode is prompted on first run and saved in `~/.claude-secure/config.sh` (global config).

### Claude's Discretion
- Profile validation logic (PROF-03) -- what specific checks run and error messages. Must fail closed (block execution, never fallback to default).
- `profile.json` exact schema (required vs optional fields, types). Must include at minimum: `workspace`, `repo` (optional), `max_turns` (optional).
- How auth credentials in `.env` are handled during profile creation (copy from existing profile pattern already established).

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROF-01 | User can create a profile with its own whitelist.json, .env, and workspace directory | Supported by D-07, D-08, D-09, D-12. Clean implementation using `create_profile()` function with interactive prompts. profile.json stores workspace path, whitelist.json copied from template, .env created via auth setup flow. |
| PROF-02 | User can map a GitHub repository URL to a profile so events route correctly | Supported by D-04, D-05, D-06. `repo` field in profile.json as `owner/repo` shorthand. Lookup function scans all profiles and returns matching profile name. |
| PROF-03 | Profile resolution fails closed -- missing or invalid profile blocks execution, never falls back to default | Claude's discretion on validation specifics. Research recommends checking: profile dir exists, profile.json exists and is valid JSON, workspace path exists, .env exists. All failures produce specific error messages and exit 1. |
</phase_requirements>

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Bash | 5.2 | CLI wrapper, all profile logic | Already the language of bin/claude-secure. No reason to change. |
| jq | 1.7 | Parse profile.json from bash | Already a project dependency. Required for reading structured JSON config. |
| Docker Compose | v2 (5.1.1 on host) | Container orchestration with profile-scoped config | Already used. COMPOSE_PROJECT_NAME pattern continues working. |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| uuidgen | system | Generate unique identifiers if needed | Already a dependency, used in hooks |
| curl | system | HTTP requests in hooks | Already a dependency |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| jq for profile.json | Python script | Adds process spawn overhead for every CLI invocation. jq is instant and already required. |
| profile.json (JSON) | profile.yaml | YAML needs a parser beyond jq. JSON is natively handled by jq (bash), Node.js, Python. |

## Architecture Patterns

### Profile Directory Structure
```
~/.claude-secure/
  config.sh                 # Global: APP_DIR, PLATFORM, DEFAULT_WORKSPACE (superuser)
  profiles/
    my-project/
      profile.json          # Structured config: workspace, repo, max_turns
      .env                  # Secrets (ANTHROPIC_API_KEY/OAUTH + service secrets)
      whitelist.json        # Domain allowlist + secret mappings
      system-prompt.md      # Optional: prompt template (future HEAD-05)
    another-project/
      profile.json
      .env
      whitelist.json
```

### Pattern 1: profile.json Schema
**What:** Structured JSON config replacing config.sh shell variables.
**When to use:** Every profile must have one.
**Recommended schema:**
```json
{
  "workspace": "/home/user/projects/my-project",
  "repo": "igorthetigor/claude-secure",
  "max_turns": 25
}
```
- `workspace` (string, REQUIRED): Absolute path to workspace directory. Must exist.
- `repo` (string, optional): GitHub `owner/repo` shorthand for webhook routing.
- `max_turns` (integer, optional): Per-profile turn budget for headless mode (Phase 13).

**Reading from bash:**
```bash
workspace=$(jq -r '.workspace' "$PROFILE_DIR/profile.json")
repo=$(jq -r '.repo // empty' "$PROFILE_DIR/profile.json")
max_turns=$(jq -r '.max_turns // empty' "$PROFILE_DIR/profile.json")
```

### Pattern 2: Fail-Closed Profile Validation (PROF-03)
**What:** Validation function that checks profile integrity before any Docker operations.
**When to use:** Every command that uses a profile (start, status, stop, etc.).
**Validation checks (ordered):**
1. Profile directory exists at `~/.claude-secure/profiles/$NAME/`
2. `profile.json` exists and is valid JSON (`jq empty` returns 0)
3. `profile.json` has required `workspace` field (non-null string)
4. Workspace path exists as a directory
5. `.env` file exists (auth credentials required)
6. `whitelist.json` exists and is valid JSON

**Error message pattern:**
```bash
validate_profile() {
  local name="$1"
  local pdir="$CONFIG_DIR/profiles/$name"

  if [ ! -d "$pdir" ]; then
    echo "ERROR: Profile '$name' does not exist at $pdir" >&2
    echo "Run: claude-secure --profile $name  (to create interactively)" >&2
    exit 1
  fi
  if [ ! -f "$pdir/profile.json" ]; then
    echo "ERROR: Profile '$name' is missing profile.json" >&2
    exit 1
  fi
  if ! jq empty "$pdir/profile.json" 2>/dev/null; then
    echo "ERROR: Profile '$name' has invalid profile.json (not valid JSON)" >&2
    exit 1
  fi
  local ws
  ws=$(jq -r '.workspace // empty' "$pdir/profile.json")
  if [ -z "$ws" ]; then
    echo "ERROR: Profile '$name' profile.json missing required 'workspace' field" >&2
    exit 1
  fi
  if [ ! -d "$ws" ]; then
    echo "ERROR: Profile '$name' workspace path does not exist: $ws" >&2
    exit 1
  fi
  if [ ! -f "$pdir/.env" ]; then
    echo "ERROR: Profile '$name' is missing .env (auth credentials required)" >&2
    exit 1
  fi
  if [ ! -f "$pdir/whitelist.json" ]; then
    echo "ERROR: Profile '$name' is missing whitelist.json" >&2
    exit 1
  fi
  if ! jq empty "$pdir/whitelist.json" 2>/dev/null; then
    echo "ERROR: Profile '$name' has invalid whitelist.json (not valid JSON)" >&2
    exit 1
  fi
}
```

### Pattern 3: Superuser Mode Merge
**What:** When `--profile` is omitted, build merged config from all profiles.
**Key operations:**
1. **Merge .env files:** Concatenate all profile `.env` files. Later entries override earlier for duplicate keys (standard shell behavior with `set -a; source`).
2. **Merge whitelist.json:** Union `secrets` arrays and `readonly_domains` arrays from all profiles.
3. **Workspace:** Use `DEFAULT_WORKSPACE` from global `config.sh`.

**Whitelist merge with jq:**
```bash
merge_whitelists() {
  local merged='{"secrets":[],"readonly_domains":[]}'
  for pdir in "$CONFIG_DIR/profiles"/*/; do
    [ -f "$pdir/whitelist.json" ] || continue
    merged=$(echo "$merged" | jq --slurpfile wl "$pdir/whitelist.json" '
      .secrets += $wl[0].secrets
      | .readonly_domains += ($wl[0].readonly_domains // [])
      | .secrets |= unique_by(.env_var)
      | .readonly_domains |= unique
    ')
  done
  echo "$merged"
}
```

**Merged .env (temp file):**
```bash
merge_env_files() {
  local merged_env
  merged_env=$(mktemp)
  for pdir in "$CONFIG_DIR/profiles"/*/; do
    [ -f "$pdir/.env" ] || continue
    cat "$pdir/.env" >> "$merged_env"
    echo "" >> "$merged_env"  # ensure newline separator
  done
  echo "$merged_env"
}
```

### Pattern 4: Repo-to-Profile Lookup (PROF-02)
**What:** Given an `owner/repo` string, find the matching profile.
**When to use:** Webhook listener (Phase 14) calls this to route events.
```bash
resolve_profile_by_repo() {
  local target_repo="$1"
  for pdir in "$CONFIG_DIR/profiles"/*/; do
    [ -f "$pdir/profile.json" ] || continue
    local repo
    repo=$(jq -r '.repo // empty' "$pdir/profile.json")
    if [ "$repo" = "$target_repo" ]; then
      basename "$pdir"
      return 0
    fi
  done
  echo "ERROR: No profile found for repo '$target_repo'" >&2
  return 1
}
```

### Anti-Patterns to Avoid
- **Sourcing profile.json as shell:** JSON is not shell. Always use `jq` to read profile.json. Never try to `source` it.
- **Falling back to a default profile:** D-03 and PROF-03 explicitly forbid this. If profile validation fails, exit 1. Period.
- **Caching merged config:** D-16 says merge at runtime on every start. No caching, no stale state.
- **Nested profile directories:** D-08 mandates flat structure. No `config/`, `secrets/`, or `templates/` subdirs.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON parsing in bash | `grep`/`sed` regex extraction | `jq` | JSON has edge cases (escaping, nesting, whitespace) that regex can't handle reliably |
| JSON validation | Custom parser checks | `jq empty file.json` | Returns exit code 0 for valid JSON, non-zero otherwise. Handles all edge cases. |
| JSON merging | Manual string concatenation | `jq --slurpfile` + array operations | Correct handling of duplicates, types, nested structures |
| Temp file cleanup | Manual trap chains | Single `cleanup()` function with `trap cleanup EXIT` | Ensures cleanup runs on all exit paths including errors |

## Common Pitfalls

### Pitfall 1: Duplicate Secrets in Merged Whitelist
**What goes wrong:** Two profiles define the same `env_var` (e.g., GITHUB_TOKEN) with different `placeholder` values. Proxy sees duplicates and behavior is undefined.
**Why it happens:** Independent profiles legitimately use the same secret name with different values.
**How to avoid:** `unique_by(.env_var)` in jq merge -- last profile wins. Document this behavior. The merged `.env` file handles value precedence naturally (last definition wins in shell).
**Warning signs:** Proxy logs showing unexpected placeholder swaps.

### Pitfall 2: Temp File Leaks in Superuser Mode
**What goes wrong:** Merged `.env` and `whitelist.json` temp files are created but never cleaned up.
**Why it happens:** The merge functions create temp files; if the script exits early (error, SIGINT), they remain.
**How to avoid:** Use `trap cleanup EXIT` at the top of the script. The cleanup function removes all temp files.
**Warning signs:** Growing `/tmp` with `tmp.*` files containing secrets.

### Pitfall 3: Empty Profile Directory Breaks Merge
**What goes wrong:** `for pdir in "$CONFIG_DIR/profiles"/*/` matches nothing when no profiles exist, and the glob literal gets passed.
**Why it happens:** Bash glob non-match returns the pattern string by default.
**How to avoid:** Use `shopt -s nullglob` before the loop (already used in existing code for log files). Or check `[ -d "$pdir" ] || continue` inside the loop.
**Warning signs:** jq errors about "No such file" with literal `*/` in path.

### Pitfall 4: Migration Code Left Behind
**What goes wrong:** Old `migrate_if_needed()` runs on startup and creates `instances/` directory from old config, conflicting with new `profiles/` layout.
**Why it happens:** Forgetting to remove the migration function when deleting instance code.
**How to avoid:** D-02 says delete ALL instance code. Migration function must be removed completely.
**Warning signs:** Unexpected `instances/` directory appearing.

### Pitfall 5: jq Not Installed / Wrong Version
**What goes wrong:** `jq` command not found, or old version lacks needed features.
**Why it happens:** jq was already a dependency but only used in hooks (inside Docker). Now it's used on the host in `bin/claude-secure`.
**How to avoid:** Add `jq` to the host dependency check at script start (alongside docker, curl, uuidgen). jq 1.6+ supports all needed operations.
**Warning signs:** Cryptic errors about "command not found" when running `claude-secure list`.

### Pitfall 6: Race Condition in `--profile` Auto-Create
**What goes wrong:** User runs `claude-secure --profile new-proj`, interactive prompts fire, but if they Ctrl+C midway, a partial profile directory exists that fails validation on next run.
**Why it happens:** Directory created before all files are written.
**How to avoid:** Create profile in a temp directory, then `mv` atomically to final location only after all files are written. Or: validate and offer to delete on next attempt.
**Warning signs:** "Profile 'X' is missing .env" after interrupted creation.

## Code Examples

### Creating a Profile (Interactive)
```bash
create_profile() {
  local name="$1"
  local pdir="$CONFIG_DIR/profiles/$name"
  local tmpdir
  tmpdir=$(mktemp -d)

  echo "Creating profile '$name'..."

  # Workspace
  read -rp "Workspace path [$HOME/claude-workspace-$name]: " ws_path
  ws_path="${ws_path:-$HOME/claude-workspace-$name}"
  ws_path="$(realpath -m "$ws_path")"
  mkdir -p "$ws_path"

  # Build profile.json
  jq -n --arg ws "$ws_path" '{"workspace": $ws}' > "$tmpdir/profile.json"

  # Copy whitelist template
  cp "$APP_DIR/config/whitelist.json" "$tmpdir/whitelist.json"

  # Auth setup (reuse existing pattern)
  setup_profile_auth "$tmpdir"

  # Atomic move to final location
  mkdir -p "$(dirname "$pdir")"
  mv "$tmpdir" "$pdir"

  echo "Profile '$name' created at $pdir"
}
```

### List Command with Repo Column
```bash
# D-14: show profile name, repo, workspace
list_profiles() {
  printf "%-20s %-35s %-10s %s\n" "PROFILE" "REPO" "STATUS" "WORKSPACE"
  printf "%-20s %-35s %-10s %s\n" "-------" "----" "------" "---------"

  if [ ! -d "$CONFIG_DIR/profiles" ]; then
    echo "No profiles configured."
    return
  fi

  shopt -s nullglob
  for pdir in "$CONFIG_DIR/profiles"/*/; do
    local name repo ws status project
    name=$(basename "$pdir")
    repo=$(jq -r '.repo // "-"' "$pdir/profile.json" 2>/dev/null || echo "-")
    ws=$(jq -r '.workspace // "-"' "$pdir/profile.json" 2>/dev/null || echo "-")
    project="claude-${name}"
    # Check running status
    if docker compose ls --format json 2>/dev/null | jq -e ".[] | select(.Name == \"$project\")" >/dev/null 2>&1; then
      status="running"
    else
      status="stopped"
    fi
    printf "%-20s %-35s %-10s %s\n" "$name" "$repo" "$status" "$ws"
  done
  shopt -u nullglob
}
```

### Loading Profile Config for Docker Compose
```bash
load_profile_config() {
  local name="$1"
  local pdir="$CONFIG_DIR/profiles/$name"

  # Read structured config via jq
  WORKSPACE_PATH=$(jq -r '.workspace' "$pdir/profile.json")

  # Set compose environment
  export COMPOSE_PROJECT_NAME="claude-${name}"
  export COMPOSE_FILE="$APP_DIR/docker-compose.yml"
  export WORKSPACE_PATH
  export SECRETS_FILE="$pdir/.env"
  export WHITELIST_PATH="$pdir/whitelist.json"
  export LOG_DIR="$CONFIG_DIR/logs"
  export LOG_PREFIX="${name}-"

  # Load and auto-export secrets for docker compose env substitution
  set -a
  # shellcheck source=/dev/null
  source "$pdir/.env"
  set +a
}
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash integration tests (project convention) |
| Config file | `tests/test-map.json` (smart test selection) |
| Quick run command | `bash tests/test-phase12.sh` |
| Full suite command | `for t in tests/test-phase*.sh; do bash "$t"; done` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROF-01 | Create profile with whitelist.json, .env, workspace | unit (bash) | `bash tests/test-phase12.sh` | No -- Wave 0 |
| PROF-02 | Map repo to profile, resolve profile from repo | unit (bash) | `bash tests/test-phase12.sh` | No -- Wave 0 |
| PROF-03 | Fail-closed validation blocks bad profiles | unit (bash) | `bash tests/test-phase12.sh` | No -- Wave 0 |

### Suggested Test Cases for test-phase12.sh
| Test ID | What It Tests |
|---------|---------------|
| PROF-01a | Profile directory structure: profile.json, .env, whitelist.json all present after creation |
| PROF-01b | profile.json is valid JSON with required `workspace` field |
| PROF-01c | DNS-safe profile name validation (reuse existing regex tests) |
| PROF-02a | Repo field in profile.json readable via jq |
| PROF-02b | `resolve_profile_by_repo` returns correct profile for known repo |
| PROF-02c | `resolve_profile_by_repo` returns error for unknown repo |
| PROF-03a | Missing profile directory -> error, exit 1 |
| PROF-03b | Missing profile.json -> error, exit 1 |
| PROF-03c | Invalid profile.json (bad JSON) -> error, exit 1 |
| PROF-03d | Missing workspace field in profile.json -> error, exit 1 |
| PROF-03e | Nonexistent workspace path -> error, exit 1 |
| PROF-03f | Missing .env -> error, exit 1 |
| PROF-03g | Missing whitelist.json -> error, exit 1 |
| SUPER-01 | No `--profile` flag -> superuser mode (no error) |
| SUPER-02 | Merged whitelist contains secrets from multiple profiles |
| SUPER-03 | Merged .env contains keys from multiple profiles |
| LIST-01 | `list` command shows profile name, repo, workspace columns |
| NOINSTANCE-01 | `--instance` flag is not recognized (clean break) |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase12.sh`
- **Per wave merge:** All test scripts
- **Phase gate:** Full suite green before verification

### Wave 0 Gaps
- [ ] `tests/test-phase12.sh` -- covers PROF-01, PROF-02, PROF-03, superuser merge, list command
- [ ] Update `tests/test-map.json` -- add `bin/claude-secure` -> `test-phase12.sh` mapping
- [ ] Retire or update `tests/test-phase9.sh` -- old instance tests no longer valid

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | CLI wrapper | Yes | 5.2 | -- |
| jq | profile.json parsing (host-side) | Yes | 1.7 | -- |
| docker | Container orchestration | Yes | 29.3.1 | -- |
| docker compose | Service management | Yes | v5.1.1 | -- |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

## Open Questions

1. **Superuser mode with zero profiles**
   - What we know: D-15 says superuser merges ALL profiles. If there are zero profiles, the merge produces empty config.
   - What's unclear: Should superuser mode with zero profiles be allowed (empty whitelist, no secrets) or blocked?
   - Recommendation: Allow it but warn. The user may just be getting started. Docker will start with empty whitelist (no domains allowed) which is safe.

2. **Updating test-phase9.sh**
   - What we know: The old instance tests (MULTI-01 through MULTI-09) test code that is being deleted.
   - What's unclear: Delete test-phase9.sh entirely or replace its contents with profile tests?
   - Recommendation: Delete test-phase9.sh and create test-phase12.sh. Cleaner separation. Update test-map.json accordingly.

3. **install.sh changes**
   - What we know: The installer creates `~/.claude-secure/` and `config.sh`. It currently may create instance-related structure.
   - What's unclear: How much installer refactoring is needed for the profile system.
   - Recommendation: Minimal -- installer only creates global config. Profile creation is interactive via CLI. Verify installer doesn't create `instances/` directory.

## Sources

### Primary (HIGH confidence)
- `bin/claude-secure` (349 lines) -- full existing implementation read and analyzed
- `docker-compose.yml` -- current volume mount and env_file patterns confirmed
- `config/whitelist.json` -- template format confirmed
- `tests/test-phase9.sh` -- existing test patterns analyzed for reuse
- `tests/test-map.json` -- smart test selection system understood
- `.planning/phases/12-profile-system/12-CONTEXT.md` -- all 17 decisions documented

### Secondary (MEDIUM confidence)
- jq 1.7 capabilities (unique_by, --slurpfile, --arg) -- verified available via `jq --version` on host

### Tertiary (LOW confidence)
- None. All findings are based on direct codebase analysis and locked decisions.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new tools, all existing dependencies
- Architecture: HIGH -- patterns derived directly from existing code + locked decisions
- Pitfalls: HIGH -- identified from direct analysis of code paths and merge semantics

**Research date:** 2026-04-11
**Valid until:** Indefinite (code-only phase, no external dependency drift)
