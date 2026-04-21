## 1. Spawn Resolution Logic

- [x] 1.1 Add `resolve_task_file()` in `bin/claude-secure` — checks `tasks/<event_type>.md` then `tasks/default.md`, fails with clear error listing checked paths if neither exists
- [x] 1.2 Add `resolve_system_prompt_file()` in `bin/claude-secure` — checks `system_prompts/<event_type>.md` then `system_prompts/default.md`, returns empty if neither exists
- [x] 1.3 Replace `resolve_template()` call in `do_spawn()` with `resolve_task_file()`
- [x] 1.4 Replace system_prompt loading in `do_spawn()` with `resolve_system_prompt_file()`
- [x] 1.5 Remove `render_template()`, `_substitute_token_from_file()`, `_substitute_multiline_token_from_file()`, `_resolve_default_templates_dir()`, `resolve_template()` functions from `bin/claude-secure`
- [x] 1.6 Remove reading of `system_prompt` field from `load_profile_config()`

## 2. Dry-Run Output

- [x] 2.1 Update `--dry-run` output to print resolved task file path alongside content
- [x] 2.2 Update `--dry-run` output to print resolved system prompt file path, or "none"

## 3. Profile Scaffolding

- [x] 3.1 Update `profile create` to generate `tasks/default.md` with placeholder content
- [x] 3.2 Update `profile create` to generate `system_prompts/default.md` with placeholder content

## 4. Migration Script

- [x] 4.1 Create `scripts/migrate-profile-prompts.sh` — iterates all profiles in `~/.claude-secure/profiles/`
- [x] 4.2 Migration: if `profile.json` has `system_prompt` and `system_prompts/default.md` does not exist, write value to file; remove field from JSON
- [x] 4.3 Migration: if `prompts/` directory exists in profile, move files to `tasks/`, remove `prompts/` directory
- [x] 4.4 Script is idempotent — safe to run multiple times, skips already-migrated profiles
- [x] 4.5 Hook `migrate-profile-prompts.sh` into `claude-secure update` — runs automatically before binary replacement

## 5. Installer Cleanup

- [x] 5.1 Remove creation of `/opt/claude-secure/webhook/templates/` from `install.sh`
- [x] 5.2 Remove creation of `/opt/claude-secure/webhook/report-templates/` from `install.sh`
- [x] 5.3 Remove `webhook/templates/` and `webhook/report-templates/` directories from the project

## 6. Tests

- [x] 6.1 Test: spawn with event-specific task file resolves correctly
- [x] 6.2 Test: spawn falls back to `tasks/default.md` when no event-specific file
- [x] 6.3 Test: spawn fails with clear error when no task file found
- [x] 6.4 Test: system prompt resolves from `system_prompts/<event_type>.md`
- [x] 6.5 Test: system prompt falls back to `system_prompts/default.md`
- [x] 6.6 Test: spawn proceeds without `--system-prompt` when no file found
- [x] 6.7 Test: `--dry-run` shows resolved task path and system prompt source
- [x] 6.8 Test: migration script moves `system_prompt` field to `system_prompts/default.md`
- [x] 6.9 Test: migration script is idempotent
