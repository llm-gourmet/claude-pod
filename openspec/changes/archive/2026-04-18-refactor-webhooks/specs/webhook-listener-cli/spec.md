## MODIFIED Requirements

### Requirement: webhook-listener subcommand configures listener settings
The `claude-secure webhook-listener` subcommand SHALL allow setting the bind address and port. Values SHALL be persisted to `~/.claude-secure/webhooks/webhook.json` (user-owned, mode 600). No `sudo` is required.

#### Scenario: Set bind address
- **WHEN** `claude-secure webhook-listener --set-bind 0.0.0.0` is run
- **THEN** `~/.claude-secure/webhooks/webhook.json` contains `"bind": "0.0.0.0"`

#### Scenario: Set port
- **WHEN** `claude-secure webhook-listener --set-port 9001` is run
- **THEN** `~/.claude-secure/webhooks/webhook.json` contains `"port": 9001` as a JSON number

#### Scenario: Updating one key preserves other keys
- **WHEN** `--set-port` has been set, then `--set-bind` is run
- **THEN** port value remains unchanged in `~/.claude-secure/webhooks/webhook.json`

### Requirement: --set-token writes GitHub PAT to profile.json
The `claude-secure webhook-listener --set-token <pat>` subcommand SHALL write `github_token` into the named profile's `profile.json`. The `--profile <name>` flag SHALL be required; if omitted and exactly one profile exists, that profile is used; otherwise the command exits with an error.

#### Scenario: Set token for a named profile
- **WHEN** `claude-secure webhook-listener --set-token ghp_abc123 --profile myrepo` is run
- **THEN** `~/.claude-secure/profiles/myrepo/profile.json` contains `"github_token": "ghp_abc123"`

#### Scenario: Token redacted in output
- **WHEN** `--set-token` is called
- **THEN** stdout confirms the operation without printing the token value

#### Scenario: No profile specified with multiple profiles exits with error
- **WHEN** `--set-token` is run without `--profile` and more than one profile exists
- **THEN** command exits non-zero with a message listing available profiles

### Requirement: webhook-listener status shows state of all known instances
`claude-secure webhook-listener status` SHALL query the listener instance and display: bind address, port, systemd unit active state, and HTTP health check result. Bind address and port SHALL be read from `~/.claude-secure/webhooks/webhook.json`.

#### Scenario: Single healthy instance
- **WHEN** `claude-secure webhook-listener status` is run and the listener is healthy
- **THEN** output shows bind, port, systemd status `active`, and health `ok`

#### Scenario: Listener not running
- **WHEN** `claude-secure webhook-listener status` is run and the listener is not responding
- **THEN** output shows systemd status and health check as `unreachable` or `inactive`; exit code is non-zero

#### Scenario: No config file exits with message
- **WHEN** `~/.claude-secure/webhooks/webhook.json` does not exist and `$WEBHOOK_CONFIG` is unset
- **THEN** output shows "No listener configured. Run claude-secure webhook-listener --help"

### Requirement: webhook-listener is dispatch-routed without superuser load
The `webhook-listener` subcommand SHALL be added to the skip-superuser-load list in `bin/claude-secure`, matching the pattern established by `bootstrap-docs` and `status`.

#### Scenario: Non-root user can run webhook-listener status
- **WHEN** a non-root user runs `claude-secure webhook-listener status`
- **THEN** the command executes without requiring sudo or profile workspace config

## REMOVED Requirements

### Requirement: webhook-listener --set-token writes to env file and webhook.json
**Reason**: Token is now per-profile (stored in `profile.json`), not global. Env file is retired.
**Migration**: Run `claude-secure webhook-listener --set-token <pat> --profile <name>` once per profile.

### Requirement: webhook-listener subcommand configures via /etc/claude-secure/webhook.json
**Reason**: Config moved to user-owned `~/.claude-secure/webhooks/webhook.json`; systemd service now runs as user, not root.
**Migration**: Re-run `sudo ./install.sh --with-webhook` to update the service unit and create the new config path.
