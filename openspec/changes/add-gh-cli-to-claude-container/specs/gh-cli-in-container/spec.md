## ADDED Requirements

### Requirement: gh CLI available in claude container
The claude container image SHALL include the `gh` (GitHub CLI) binary, installed from the official GitHub CLI apt repository, accessible to the `claude` user without elevated privileges.

#### Scenario: gh binary found on PATH
- **WHEN** the claude user runs `which gh` inside the container
- **THEN** the command returns a non-empty path (e.g., `/usr/bin/gh`)

#### Scenario: gh version command succeeds
- **WHEN** the claude user runs `gh --version` inside the container
- **THEN** the command exits with code 0 and prints a version string

### Requirement: gh authenticates via GITHUB_TOKEN environment variable
The container's `gh` binary SHALL use the `GITHUB_TOKEN` environment variable for authentication when it is set, enabling profile-injected secrets to authorize GitHub API calls without interactive login.

#### Scenario: gh command uses injected token
- **WHEN** `GITHUB_TOKEN` is set to a valid GitHub token
- **AND** the user runs a `gh` command targeting a whitelisted GitHub domain
- **THEN** the command authenticates and completes successfully

#### Scenario: gh command blocked when domain not whitelisted
- **WHEN** `GITHUB_TOKEN` is set but `github.com` / `api.github.com` are not in the profile's domain whitelist
- **THEN** the hook blocks the outbound call and `gh` receives a connection error
