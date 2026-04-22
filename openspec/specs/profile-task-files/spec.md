## Requirements

### Requirement: Task file resolution for spawn
When spawning a Claude instance, the task prompt (passed as `-p`) SHALL be resolved from the profile directory using the following chain:
1. `~/.claude-pod/profiles/<name>/tasks/<event_type>.md` — event-specific task
2. `~/.claude-pod/profiles/<name>/tasks/default.md` — profile default task

If neither file exists, spawn SHALL fail with exit code 1 and print an error listing the paths checked.

Task files SHALL be passed to Claude as-is, with no token substitution.

#### Scenario: Event-specific task file exists
- **WHEN** spawn is called with event_type `push`
- **AND** `tasks/push.md` exists in the profile directory
- **THEN** the content of `tasks/push.md` SHALL be passed as `-p` to Claude

#### Scenario: Fallback to default task file
- **WHEN** spawn is called with event_type `issues-opened`
- **AND** `tasks/issues-opened.md` does not exist in the profile directory
- **AND** `tasks/default.md` exists in the profile directory
- **THEN** the content of `tasks/default.md` SHALL be passed as `-p` to Claude

#### Scenario: No task file found — spawn fails
- **WHEN** spawn is called with event_type `push`
- **AND** neither `tasks/push.md` nor `tasks/default.md` exist in the profile directory
- **THEN** spawn SHALL exit with code 1
- **AND** the error message SHALL list the paths that were checked

#### Scenario: Dry-run shows resolved task path
- **WHEN** spawn is called with `--dry-run`
- **THEN** the output SHALL include the resolved task file path and its content

### Requirement: Profile creation scaffolds tasks/default.md
When a new profile is created via `claude-pod profile <name> create`, the command SHALL create a `tasks/` subdirectory containing a `default.md` placeholder file.

#### Scenario: New profile has tasks/default.md
- **WHEN** `claude-pod profile my-agent create` is run
- **THEN** `~/.claude-pod/profiles/my-agent/tasks/default.md` SHALL exist
- **AND** it SHALL contain a minimal placeholder task prompt

### Requirement: Global webhook templates removed
The directories `/opt/claude-pod/webhook/templates/` and `/opt/claude-pod/webhook/report-templates/` SHALL NOT be created by the installer and SHALL NOT be referenced by the spawn logic.

#### Scenario: Installer does not create global template directories
- **WHEN** `install.sh` is run
- **THEN** `/opt/claude-pod/webhook/templates/` SHALL NOT exist

#### Scenario: Spawn does not fall back to global templates
- **WHEN** no task file exists in the profile directory
- **THEN** spawn SHALL fail, not fall back to any path under `/opt/claude-pod/`
