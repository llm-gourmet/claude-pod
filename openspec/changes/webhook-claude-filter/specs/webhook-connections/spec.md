## MODIFIED Requirements

### Requirement: connections stored as JSON array in dedicated directory
Webhook connection config SHALL be stored at `~/.claude-secure/webhooks/connections.json` as a JSON array. The directory SHALL have mode `700` and the file SHALL have mode `600`. Each element SHALL contain `name` (string, required), `repo` (string, required), `webhook_secret` (string, required), and optionally `github_token` (string). The fields `webhook_event_filter`, `webhook_bot_users`, and `todo_path_pattern` are no longer part of the schema; if present in existing files they SHALL be silently ignored.

#### Scenario: Directory and file created on first add
- **WHEN** `--add-connection` is run and `~/.claude-secure/webhooks/` does not exist
- **THEN** the directory is created with mode `700` and `connections.json` is created with mode `600` containing the new connection

#### Scenario: File contains valid JSON array after add
- **WHEN** `claude-secure webhook-listener --add-connection --name myrepo --repo org/repo --webhook-secret shsec_xxx` is run
- **THEN** `connections.json` is a valid JSON array containing one object with `name`, `repo`, and `webhook_secret` fields and no `webhook_event_filter` or `todo_path_pattern` fields

#### Scenario: Legacy fields in existing file are ignored
- **WHEN** `connections.json` contains entries with `webhook_event_filter`, `webhook_bot_users`, or `todo_path_pattern` fields
- **THEN** the listener processes the connection normally and those fields have no effect on spawn behaviour

### Requirement: listener stubs spawn — no claude-secure spawn call
**REMOVED** — replaced by `webhook-spawn-always` spec. See REMOVED Requirements.

#### Scenario: placeholder
- **WHEN** this requirement is removed
- **THEN** see webhook-spawn-always spec

## REMOVED Requirements

### Requirement: listener stubs spawn — no claude-secure spawn call
**Reason**: Placeholder behaviour removed. `_spawn_worker` now calls `claude-secure spawn` unconditionally after HMAC and repo lookup (see `webhook-spawn-always` spec).
**Migration**: No action required. The listener upgrade replaces the stub automatically.
