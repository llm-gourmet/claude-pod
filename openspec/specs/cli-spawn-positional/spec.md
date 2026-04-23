# cli-spawn-positional Specification

## Purpose
TBD - created by archiving change refactor-cli-profile-commands. Update Purpose after archive.
## Requirements
### Requirement: spawn takes profile name as positional argument
`claude-pod spawn <name>` SHALL run a headless Claude Code session for the named profile. The old invocation `claude-pod --profile <name> spawn` SHALL be removed. All existing spawn flags (`--event`, `--event-file`, `--dry-run`, `--prompt-template`) SHALL be supported.

#### Scenario: Headless session with inline event
- **WHEN** `claude-pod spawn myapp --event '{"action":"push"}'` is run and profile `myapp` exists
- **THEN** a headless Claude session is started scoped to that profile with the given event payload

#### Scenario: Unknown profile exits with error
- **WHEN** `claude-pod spawn nonexistent --event '{}'` is run and profile `nonexistent` does not exist
- **THEN** command exits non-zero with "Error: profile 'nonexistent' not found."

#### Scenario: Old --profile spawn invocation removed
- **WHEN** `claude-pod --profile myapp spawn --event '{}'` is run
- **THEN** command exits non-zero or shows usage error; the old invocation is no longer valid

#### Scenario: replay subcommand adopts positional name
- **WHEN** `claude-pod replay <name> <delivery-id>` is run
- **THEN** it replays the delivery for the named profile (was `claude-pod --profile <name> replay <id>`)

