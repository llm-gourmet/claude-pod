## ADDED Requirements

### Requirement: System prompt file resolution for spawn
When spawning a Claude instance, the system prompt (passed as `--system-prompt`) SHALL be resolved from the profile directory using the following chain:
1. `~/.claude-secure/profiles/<name>/system_prompts/<event_type>.md` — event-specific system prompt
2. `~/.claude-secure/profiles/<name>/system_prompts/default.md` — profile default system prompt

If neither file exists, `--system-prompt` SHALL be omitted from the Claude invocation. Spawn SHALL NOT fail due to a missing system prompt.

System prompt files SHALL be passed to Claude as-is, with no token substitution.

#### Scenario: Event-specific system prompt file exists
- **WHEN** spawn is called with event_type `push`
- **AND** `system_prompts/push.md` exists in the profile directory
- **THEN** the content of `system_prompts/push.md` SHALL be passed as `--system-prompt` to Claude

#### Scenario: Fallback to default system prompt file
- **WHEN** spawn is called with event_type `issues-opened`
- **AND** `system_prompts/issues-opened.md` does not exist in the profile directory
- **AND** `system_prompts/default.md` exists in the profile directory
- **THEN** the content of `system_prompts/default.md` SHALL be passed as `--system-prompt` to Claude

#### Scenario: No system prompt configured — omit flag
- **WHEN** no `system_prompts/` file exists in the profile directory
- **THEN** `--system-prompt` SHALL be omitted from the Claude invocation
- **AND** spawn SHALL NOT fail

#### Scenario: Dry-run shows resolved system prompt source
- **WHEN** spawn is called with `--dry-run`
- **THEN** the output SHALL include the resolved system prompt file path, or "none" if omitted

### Requirement: Profile creation scaffolds system_prompts/default.md
When a new profile is created via `claude-secure profile <name> create`, the command SHALL create a `system_prompts/` subdirectory containing a `default.md` placeholder file.

#### Scenario: New profile has system_prompts/default.md
- **WHEN** `claude-secure profile my-agent create` is run
- **THEN** `~/.claude-secure/profiles/my-agent/system_prompts/default.md` SHALL exist
- **AND** it SHALL contain a minimal placeholder system prompt

### Requirement: Automatic migration of system_prompt field
The migration script `scripts/migrate-profile-prompts.sh`, run by `claude-secure update`, SHALL migrate existing profiles that have a `system_prompt` field in `profile.json`.

#### Scenario: Migration extracts system_prompt to file
- **WHEN** `migrate-profile-prompts.sh` runs on a profile with `system_prompt` in `profile.json`
- **AND** `system_prompts/default.md` does not already exist
- **THEN** the script SHALL write the `system_prompt` value to `system_prompts/default.md`
- **AND** remove the `system_prompt` field from `profile.json`

#### Scenario: Migration is idempotent
- **WHEN** `migrate-profile-prompts.sh` runs on a profile where `system_prompts/default.md` already exists
- **THEN** the script SHALL NOT overwrite the existing file
- **AND** SHALL remove the `system_prompt` field from `profile.json` if still present
