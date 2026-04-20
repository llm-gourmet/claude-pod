# cli-profile-create Specification

## Purpose
TBD - created by archiving change refactor-cli-profile-commands. Update Purpose after archive.
## Requirements
### Requirement: --profile flag only creates a profile and exits
`claude-secure --profile <name>` SHALL run interactive profile setup (workspace path, auth method) and exit without starting any Docker containers. If the profile already exists, the command SHALL exit with an informational message and zero exit code.

#### Scenario: New profile created and exits
- **WHEN** `claude-secure --profile myapp` is run and no profile named `myapp` exists
- **THEN** interactive prompts are shown for workspace and auth, profile files are written, and the process exits with code 0 without starting any containers

#### Scenario: Existing profile no-ops cleanly
- **WHEN** `claude-secure --profile myapp` is run and profile `myapp` already exists
- **THEN** output shows "Profile 'myapp' already exists at <path>" and exits with code 0

#### Scenario: No containers started during profile creation
- **WHEN** `claude-secure --profile myapp` completes successfully
- **THEN** no `docker compose up` is invoked and no Docker networks or containers are created

#### Scenario: Help shown after creation
- **WHEN** profile creation succeeds
- **THEN** output includes a hint: "Run 'claude-secure start myapp' to start a session"

