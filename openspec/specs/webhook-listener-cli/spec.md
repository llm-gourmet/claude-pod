## Requirements

### Requirement: --set-token writes GitHub PAT to connections.json
The `claude-pod gh-webhook-listener --set-token <pat>` subcommand SHALL write `github_token` into the named connection's entry in `~/.claude-pod/webhooks/connections.json`. The `--name <name>` flag SHALL be required. If the named connection does not exist the command exits non-zero with an error.

#### Scenario: Set token for a named connection
- **WHEN** `claude-pod gh-webhook-listener --set-token ghp_abc123 --name myrepo` is run and `myrepo` exists in `connections.json`
- **THEN** `connections.json` contains `"github_token": "ghp_abc123"` in the `myrepo` entry

#### Scenario: Token redacted in output
- **WHEN** `--set-token` is called
- **THEN** stdout confirms the operation without printing the token value

#### Scenario: Unknown connection name exits with error
- **WHEN** `--set-token` is run with `--name nonexistent` and no connection named `nonexistent` exists
- **THEN** command exits non-zero with `Error: connection 'nonexistent' not found`

### Requirement: gh-webhook-listener status shows state of all known instances
`claude-pod gh-webhook-listener status` SHALL query the listener instance and display: bind address, port, systemd unit active state, and HTTP health check result. Bind address and port SHALL be read from `~/.claude-pod/webhooks/webhook.json`.

#### Scenario: Single healthy instance
- **WHEN** `claude-pod gh-webhook-listener status` is run and the listener is healthy
- **THEN** output shows bind, port, systemd status `active`, and health `ok`

#### Scenario: Listener not running
- **WHEN** `claude-pod gh-webhook-listener status` is run and the listener is not responding
- **THEN** output shows systemd status and health check as `unreachable` or `inactive`; exit code is non-zero

#### Scenario: No config file exits with message
- **WHEN** `~/.claude-pod/webhooks/webhook.json` does not exist and `$WEBHOOK_CONFIG` is unset
- **THEN** output shows "No listener configured. Run claude-pod gh-webhook-listener --help"

### Requirement: gh-webhook-listener is dispatch-routed without superuser load
The `gh-webhook-listener` subcommand SHALL be added to the skip-superuser-load list in `bin/claude-pod`, replacing the existing `webhook-listener` entry.

#### Scenario: Non-root user can run gh-webhook-listener status
- **WHEN** a non-root user runs `claude-pod gh-webhook-listener status`
- **THEN** the command executes without requiring sudo or profile workspace config
