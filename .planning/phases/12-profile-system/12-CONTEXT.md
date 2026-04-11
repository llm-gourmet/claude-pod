# Phase 12: Profile System - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace the existing instance system with a profile system. Profiles are per-service security contexts with their own whitelist, secrets, workspace, and GitHub repo routing. Running `claude-secure` without `--profile` starts a superuser mode with merged access to all profiles. Running with `--profile NAME` scopes to that profile's config.

This phase delivers PROF-01 (profile creation), PROF-02 (repo mapping), and PROF-03 (fail-closed validation).

</domain>

<decisions>
## Implementation Decisions

### Profile vs Instance (D-01 through D-03)
- **D-01:** Instances are renamed to profiles. The concept of "instance" is removed entirely.
- **D-02:** All instance code (--instance flag, migration logic, instance directory structure) is deleted. No migration needed — existing instances are test data only.
- **D-03:** No backward compatibility layer. Clean break — `--instance` flag removed, not deprecated.

### Repo-to-Profile Mapping (D-04 through D-06)
- **D-04:** Each profile has a `repo` field in `profile.json` using `owner/repo` shorthand (e.g., `igorthetigor/claude-secure`). Matches GitHub webhook payload's `repository.full_name`.
- **D-05:** Repo mapping is explicit via config field, not convention-based.
- **D-06:** One profile = one repo. No multi-repo per profile. (Aligns with Out of Scope: "One profile = one repo.")

### Directory Layout (D-07 through D-09)
- **D-07:** Profiles live at `~/.claude-secure/profiles/<name>/` (replaces `instances/`).
- **D-08:** Flat structure inside profile directory: `profile.json`, `.env`, `whitelist.json`, and prompt templates (`*.md`). No subdirectories.
- **D-09:** Config format switches from `config.sh` (shell vars) to `profile.json` (structured JSON). Parseable by all services via jq (bash), native JSON (Node.js/Python).

### CLI Interface (D-10 through D-14)
- **D-10:** `--instance` flag replaced by `--profile` flag.
- **D-11:** `--profile` is optional for all commands. No flag = superuser mode. `--profile NAME` = scoped mode.
- **D-12:** Interactive auto-create preserved: first use of `--profile NAME` triggers interactive setup (workspace path, auth).
- **D-13:** Repo field is optional during profile creation. Users add it to `profile.json` when they want webhook routing.
- **D-14:** `claude-secure list` shows a table with profile name, repo (if set), and workspace path.

### Superuser Mode (D-15 through D-17)
- **D-15:** `claude-secure` without `--profile` starts a persistent instance with merged access to ALL profiles' secrets, whitelisted domains, and repos.
- **D-16:** Merged config is built at runtime on every start — reads all profile directories, unions `.env` and `whitelist.json` content. No caching.
- **D-17:** Default workspace for superuser mode is prompted on first run and saved in `~/.claude-secure/config.sh` (global config).

### Claude's Discretion
- Profile validation logic (PROF-03) — what specific checks run and error messages. Must fail closed (block execution, never fallback to default).
- `profile.json` exact schema (required vs optional fields, types). Must include at minimum: `workspace`, `repo` (optional), `max_turns` (optional).
- How auth credentials in `.env` are handled during profile creation (copy from existing profile pattern already established).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — PROF-01, PROF-02, PROF-03 acceptance criteria

### Existing Code (to be refactored)
- `bin/claude-secure` — Current CLI wrapper with instance system (lines 16-113 are instance code to be replaced)
- `config/whitelist.json` — Template whitelist format (secret entries + readonly domains)
- `docker-compose.yml` — Current volume mounts and env_file patterns for per-instance config

### Project Decisions
- `.planning/PROJECT.md` — Key Decisions table, especially "COMPOSE_PROJECT_NAME for multi-instance" and "env_file for secret loading"

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `validate_instance_name()` (bin/claude-secure:61-71) — DNS-safe name validation, reusable as `validate_profile_name()`
- `setup_instance_auth()` (bin/claude-secure:115+) — Auth setup flow (OAuth/API key), reusable for profile creation
- `create_instance()` (bin/claude-secure:81-113) — Template for `create_profile()`, needs repo field + profile.json

### Established Patterns
- Config at `~/.claude-secure/` with `config.sh` for global settings — keep for global config (default workspace)
- Docker Compose env_file for secret injection — continue this pattern with profile `.env` files
- Whitelist volume mount (docker-compose.yml) — continue with profile-specific whitelist path
- `COMPOSE_PROJECT_NAME` for container namespace isolation — continue using this

### Integration Points
- `bin/claude-secure` — Main entry point, needs profile flag parsing + superuser merge logic
- `docker-compose.yml` — `SECRETS_FILE` and `WHITELIST_PATH` env vars already parameterized, just need to point to profile paths
- Hook scripts reference `/etc/claude-secure/whitelist.json` — mounted from profile, no hook changes needed
- Proxy reads whitelist at `/etc/claude-secure/whitelist.json` — same mount point, different source

</code_context>

<specifics>
## Specific Ideas

- Superuser mode merging all profiles is a key differentiator from the old instance system — developer gets full access without specifying which project they're working on
- Profile names continue to use DNS-safe validation (existing `validate_instance_name` pattern)
- `owner/repo` shorthand chosen specifically to match GitHub webhook `repository.full_name` field — zero parsing needed in webhook listener

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 12-profile-system*
*Context gathered: 2026-04-11*
