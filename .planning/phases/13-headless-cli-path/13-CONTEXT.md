# Phase 13: Headless CLI Path - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Add a `spawn` subcommand to `bin/claude-secure` that runs Claude Code non-interactively inside the Docker security stack. Each spawn creates an ephemeral container set, executes a prompt (built from a template + event data), captures structured JSON output, and tears everything down automatically. This phase delivers HEAD-01 through HEAD-05.

</domain>

<decisions>
## Implementation Decisions

### Spawn Invocation (D-01 through D-04)
- **D-01:** `spawn` is a new subcommand: `claude-secure spawn --profile <name> --event '<json>'`
- **D-02:** `--event` accepts a JSON string directly (webhook listener will pipe it). Also accept `--event-file <path>` for debugging/replay convenience.
- **D-03:** `--prompt-template <name>` optional flag to override automatic event-type-based template resolution.
- **D-04:** `--profile` is required for spawn (no superuser mode for headless execution — must have a scoped security context).

### Container Lifecycle (D-05 through D-08)
- **D-05:** Each spawn creates a new Docker Compose project with `COMPOSE_PROJECT_NAME=cs-<profile>-<uuid8>` for true isolation between concurrent runs.
- **D-06:** Lifecycle: `docker compose up -d` → `docker compose exec -T claude claude -p "..." --output-format json --dangerously-skip-permissions` → `docker compose down -v` (including volumes).
- **D-07:** Cleanup runs in a bash trap handler that catches EXIT (covers success, failure, timeout, and signals). Cleanup is mandatory — no orphaned containers.
- **D-08:** `--max-turns` from `profile.json` is passed to Claude Code via `--max-turns` flag. If unset in profile, Claude Code's default applies.

### Output Capture (D-09 through D-12)
- **D-09:** `docker compose exec -T` pipes stdout directly — no temp files or log parsing.
- **D-10:** Claude Code's `--output-format json` provides `result`, `cost`, `duration`, `session_id`.
- **D-11:** Wrapper adds metadata envelope: `{ "profile", "event_type", "timestamp", "claude": <claude-output> }`.
- **D-12:** Exit code propagated: 0 = success, non-zero = failure. On failure, stderr captured and included in output JSON as `error` field.

### Prompt Templates (D-13 through D-17)
- **D-13:** Templates live at `~/.claude-secure/profiles/<name>/prompts/<event-type>.md` (e.g., `issue-opened.md`, `push.md`, `ci-failure.md`).
- **D-14:** Variables use `{{VAR_NAME}}` double-brace syntax (not shell `$VAR` — avoids accidental expansion).
- **D-15:** Substitution done in bash via sed before passing to Claude Code `-p` flag.
- **D-16:** Template resolution order: explicit `--prompt-template` flag > event-type derived from `--event` JSON > error if no template found.
- **D-17:** Event payload fields extracted via jq and mapped to template variables. Standard variables: `{{REPO_NAME}}`, `{{EVENT_TYPE}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{COMMIT_SHA}}`, `{{BRANCH}}`.

### Claude's Discretion
- Exact metadata envelope schema (D-11) — add fields as needed during implementation
- Error message formatting for missing templates, invalid JSON, profile validation failures
- Whether to add `--dry-run` flag for spawn (shows resolved prompt without executing) — nice-to-have if trivial
- How to handle Claude Code bug #7263 (empty output with large stdin) — test empirically, add workaround if confirmed

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — HEAD-01 through HEAD-05 acceptance criteria

### Phase 12 Context (dependency)
- `.planning/phases/12-profile-system/12-CONTEXT.md` — Profile system decisions (D-01 through D-17), especially directory layout (D-07, D-08), profile.json schema (Claude's Discretion), and CLI patterns (D-10 through D-14)

### Existing Code
- `bin/claude-secure` — CLI wrapper with profile system, command parsing, docker compose lifecycle patterns
- `docker-compose.yml` — Container topology, network config, volume mounts, env_file patterns
- `claude/Dockerfile` — Claude container image with Claude Code CLI installed

### Research
- `.planning/phases/12-profile-system/12-RESEARCH.md` — Contains headless execution research: `-p` flag behavior, `--output-format json` schema, `--max-turns` flag, `docker compose exec -T` patterns, known bug #7263

### Project Decisions
- `.planning/PROJECT.md` — Key Decisions table, Out of Scope (especially: "Agent SDK integration — SDK bypasses Docker security layers, must use CLI -p via docker compose exec")

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `bin/claude-secure` main case statement — spawn will be a new case alongside stop/status/upgrade/etc.
- `load_profile_config()` — Already resolves profile directory, exports COMPOSE_PROJECT_NAME, SECRETS_FILE, WHITELIST_PATH, WORKSPACE_PATH. Reusable for spawn with modified COMPOSE_PROJECT_NAME.
- `validate_profile()` — Profile validation (PROF-03) already implemented. Spawn reuses this.
- `cleanup_containers()` — Existing cleanup pattern, but spawn needs per-project-name cleanup (not global).
- `parse_log_flags()` — Log flag parsing reusable for spawn debugging.

### Established Patterns
- `docker compose up -d` then `docker compose exec -it claude claude --dangerously-skip-permissions` — Current interactive flow. Spawn replaces `-it` with `-T` and adds `-p` and `--output-format json`.
- `COMPOSE_PROJECT_NAME` for namespace isolation — Already used for profiles, spawn extends with UUID suffix.
- Config via exported env vars (`SECRETS_FILE`, `WHITELIST_PATH`, etc.) — Docker Compose reads these at `up` time.
- Trap-based cleanup — Already used for `_CLEANUP_FILES` temp file cleanup.

### Integration Points
- `bin/claude-secure` case statement — Add `spawn)` case
- `docker-compose.yml` — No changes needed; env vars already parameterized
- Profile directory — Add `prompts/` subdirectory for templates
- `profile.json` — Already has `max_turns` field (optional) from Phase 12

</code_context>

<specifics>
## Specific Ideas

- Spawn is the bridge between profile system (Phase 12) and webhook automation (Phase 14-15). It must work standalone via CLI before webhooks are wired up.
- UUID8 suffix in compose project name (e.g., `cs-myservice-a1b2c3d4`) enables concurrent spawns for the same profile — critical for HOOK-06 downstream.
- Template variable extraction from event JSON via jq means downstream phases (15: Event Handlers) just need to pass the raw webhook payload as `--event` — no preprocessing needed.
- `--event-file` flag enables HOOK-07 (webhook replay) without any additional Phase 15 work.

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 13-headless-cli-path*
*Context gathered: 2026-04-11*
