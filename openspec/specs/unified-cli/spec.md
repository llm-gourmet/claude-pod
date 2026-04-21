# unified-cli Specification

## Purpose
Defines the unified CLI surface for `claude-secure`. All profile operations are consolidated under the `profile` subcommand; the legacy `--profile` flag is removed. This spec establishes the authoritative command structure for profile creation, inspection, and the rejection of deprecated flag syntax.

## Requirements

### Requirement: profile subcommand is the single entry point for all profile operations
`claude-secure profile` SHALL be the top-level subcommand for all profile creation, inspection, and configuration. No other top-level flag or subcommand SHALL create or configure profiles.

#### Scenario: profile create runs interactive setup
- **WHEN** `claude-secure profile create myapp` is run and no profile named `myapp` exists
- **THEN** interactive prompts are shown for workspace path and auth method, profile files are written, and the process exits with code 0 without starting any containers

#### Scenario: profile create no-ops if profile exists
- **WHEN** `claude-secure profile create myapp` is run and profile `myapp` already exists
- **THEN** output shows "Profile 'myapp' already exists at <path>" and exits with code 0

#### Scenario: profile create hint shown after creation
- **WHEN** `claude-secure profile create myapp` succeeds
- **THEN** output includes: "Run 'claude-secure start myapp' to start a session"

### Requirement: profile <name> bare invocation shows profile info
`claude-secure profile <name>` with no further subcommand SHALL print the profile's workspace path, secret count, and running container state, then exit with code 0.

#### Scenario: profile info shown for existing profile
- **WHEN** `claude-secure profile myapp` is run and profile `myapp` exists
- **THEN** output includes workspace path, number of configured secrets, and whether containers are running

#### Scenario: profile info for unknown profile exits non-zero
- **WHEN** `claude-secure profile myapp` is run and no profile named `myapp` exists
- **THEN** exits non-zero with "Profile 'myapp' not found. Run 'claude-secure profile create myapp' to create it."

### Requirement: --profile flag is removed
The `--profile <name>` flag SHALL NOT be accepted by the CLI. Any invocation using `--profile` SHALL exit non-zero with a message directing the user to `profile create`.

#### Scenario: --profile flag rejected
- **WHEN** `claude-secure --profile myapp` is run
- **THEN** exits non-zero with: "Unknown option: --profile. Did you mean: claude-secure profile create myapp?"
