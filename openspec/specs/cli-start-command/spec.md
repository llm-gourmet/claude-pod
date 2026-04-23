# cli-start-command Specification

## Purpose
TBD - created by archiving change refactor-cli-profile-commands. Update Purpose after archive.
## Requirements
### Requirement: start command launches an interactive Claude Code session
`claude-pod start <name>` SHALL start Docker containers for the named profile and open an interactive Claude Code session. This is the exclusive entry point for interactive sessions (the old `--profile <name>` session-start behavior is removed).

#### Scenario: Successful interactive session
- **WHEN** `claude-pod start myapp` is run and profile `myapp` exists
- **THEN** `docker compose up -d` runs for that profile's compose project, followed by `docker compose exec -it claude claude --dangerously-skip-permissions`

#### Scenario: Unknown profile exits with error
- **WHEN** `claude-pod start nonexistent` is run and no profile named `nonexistent` exists
- **THEN** command exits non-zero with "Error: profile 'nonexistent' not found. Run 'claude-pod --profile nonexistent' to create it."

#### Scenario: Containers torn down after session ends
- **WHEN** the interactive Claude Code session exits
- **THEN** `docker compose down` is run for that profile's compose project

#### Scenario: Log flags accepted
- **WHEN** `claude-pod start myapp log:hook log:anthropic` is run
- **THEN** the session starts with those log flags active (LOG_HOOK=1, LOG_ANTHROPIC=1)

