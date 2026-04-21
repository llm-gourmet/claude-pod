## Why

Configuring a headless claude-secure spawn currently requires maintaining template files in two locations (`~/.claude-secure/profiles/<name>/prompts/` and `/opt/claude-secure/webhook/templates/`) alongside `system_prompt` in `profile.json`. This split makes profiles hard to configure and couples spawn behavior to global templates. Users want a single place — the profile directory — to control both what Claude does (task) and how it behaves (system prompt), with the flexibility to vary both per event type.

## What Changes

- Add `tasks/` subdirectory in the profile directory — event-type-specific task files (`push.md`, `issues-opened.md`, etc.) passed as `-p` to Claude on spawn
- Add `tasks/default.md` — fallback task used when no event-type-specific file matches
- Add `system_prompts/` subdirectory in the profile directory — event-type-specific system prompt files (`push.md`, `issues-opened.md`, etc.)
- Add `system_prompts/default.md` — fallback system prompt used when no event-type-specific file matches
- Remove global template directories `/opt/claude-secure/webhook/templates/` and `/opt/claude-secure/webhook/report-templates/` — profile-local files replace them entirely
- Update spawn resolution logic to use the new file-based lookup chain
- Remove `system_prompt` field from `profile.json` — **BREAKING**, replaced by `system_prompts/` files
- **BREAKING**: Profiles without `tasks/` files will fail spawn — a `tasks/default.md` or event-specific task file is required
- Add `scripts/migrate-profile-prompts.sh` — cleanup script run by `claude-secure update` to migrate existing profiles automatically

## Capabilities

### New Capabilities

- `profile-task-files`: File-based task configuration in the profile directory. Spawn resolves `-p` content from `tasks/<event_type>.md` → `tasks/default.md`. Enables per-event task instructions, all within the profile directory.
- `profile-system-prompt-files`: File-based system prompt configuration in the profile directory. Spawn resolves `--system-prompt` from `system_prompts/<event_type>.md` → `system_prompts/default.md`. If neither exists, `--system-prompt` is omitted.

### Modified Capabilities

- `profile-schema`: `system_prompt` field removed from `profile.json` schema. The migration script extracts existing values into `system_prompts/default.md` and removes the field.

## Impact

- `bin/claude-secure` — `do_spawn()`, `load_profile_config()`, `resolve_template()`: replace template resolution with profile-local file lookup
- `/opt/claude-secure/webhook/templates/` and `report-templates/` — removed from installer and runtime
- `~/.claude-secure/profiles/<name>/` gains `tasks/` and `system_prompts/` subdirectories
- `scripts/migrate-profile-prompts.sh` added — run automatically by `claude-secure update`; migrates `system_prompt` → `system_prompts/default.md`, `prompts/` → `tasks/`, removes old fields and directories
