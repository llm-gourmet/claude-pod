## ADDED Requirements

### Requirement: webhook-listener subcommand configures listener settings
The `claude-secure webhook-listener` subcommand SHALL allow setting the GitHub token, bind address, and port. Values SHALL be persisted to `~/.claude-secure/webhook-listener.env` at mode 600.

#### Scenario: Set GitHub token
- **WHEN** `claude-secure webhook-listener --set-token ghp_abc123` is run
- **THEN** `~/.claude-secure/webhook-listener.env` contains `WEBHOOK_GITHUB_TOKEN=ghp_abc123` and the file has mode 600

#### Scenario: Set bind address
- **WHEN** `claude-secure webhook-listener --set-bind 0.0.0.0` is run
- **THEN** `~/.claude-secure/webhook-listener.env` contains `WEBHOOK_BIND=0.0.0.0`

#### Scenario: Set port
- **WHEN** `claude-secure webhook-listener --set-port 9001` is run
- **THEN** `~/.claude-secure/webhook-listener.env` contains `WEBHOOK_PORT=9001`

#### Scenario: Updating one key preserves other keys
- **WHEN** `--set-token` and `--set-port` have been set, then `--set-bind` is run
- **THEN** token and port values remain unchanged in the env file

#### Scenario: Token redacted in output
- **WHEN** `--set-token` is called
- **THEN** stdout confirms the operation without printing the token value

### Requirement: webhook-listener status shows state of all known instances
`claude-secure webhook-listener status` SHALL query each configured listener instance and display: bind address, port, systemd unit active state, and HTTP health check result.

#### Scenario: Single healthy instance
- **WHEN** `claude-secure webhook-listener status` is run and the default listener at `localhost:9000` is healthy
- **THEN** output shows bind, port, systemd status `active`, and health `ok`

#### Scenario: Listener not running
- **WHEN** `claude-secure webhook-listener status` is run and the listener is not responding
- **THEN** output shows systemd status and health check as `unreachable` or `inactive`; exit code is non-zero

#### Scenario: No config file exits with message
- **WHEN** no `~/.claude-secure/webhook-listener.env` exists and no `/etc/claude-secure/webhook.json` is readable
- **THEN** output shows "No listener configured. Run claude-secure webhook-listener --help"

### Requirement: webhook-listener is dispatch-routed without superuser load
The `webhook-listener` subcommand SHALL be added to the skip-superuser-load list in `bin/claude-secure`, matching the pattern established by `bootstrap-docs` and `status`.

#### Scenario: Non-root user can run webhook-listener status
- **WHEN** a non-root user runs `claude-secure webhook-listener status`
- **THEN** the command executes without requiring sudo or profile workspace config
