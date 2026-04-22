## Requirements

### Requirement: connections stored as JSON array in dedicated directory
Webhook connection config SHALL be stored at `~/.claude-secure/webhooks/connections.json` as a JSON array. The directory SHALL have mode `700` and the file SHALL have mode `600`. Each element SHALL contain `name` (string, required), `repo` (string, required), `webhook_secret` (string, required), and optionally `github_token` (string) and `skip_filters` (array of strings). The fields `webhook_event_filter`, `webhook_bot_users`, and `todo_path_pattern` are no longer part of the schema; if present in existing files they SHALL be silently ignored.

#### Scenario: Directory and file created on first add
- **WHEN** `--add-connection` is run and `~/.claude-secure/webhooks/` does not exist
- **THEN** the directory is created with mode `700` and `connections.json` is created with mode `600` containing the new connection

#### Scenario: File contains valid JSON array after add
- **WHEN** `claude-secure gh-webhook-listener --add-connection --name myrepo --repo org/repo --webhook-secret shsec_xxx` is run
- **THEN** `connections.json` is a valid JSON array containing one object with `name`, `repo`, and `webhook_secret` fields

#### Scenario: Legacy fields in existing file are ignored
- **WHEN** `connections.json` contains entries with `webhook_event_filter`, `webhook_bot_users`, or `todo_path_pattern` fields
- **THEN** the listener processes the connection normally and those fields have no effect on spawn behaviour

#### Scenario: skip_filters persisted on connection
- **WHEN** `filter add "[skip-claude]" --name myrepo` is run
- **THEN** `connections.json` contains `"skip_filters": ["[skip-claude]"]` in the `myrepo` entry

### Requirement: connection names are unique; duplicate add is rejected
`--add-connection` SHALL check for an existing connection with the same `name` (case-sensitive) and exit non-zero with an error message if one is found. The file SHALL NOT be modified.

#### Scenario: Duplicate name is rejected
- **WHEN** `--add-connection --name myrepo ...` is run and a connection named `myrepo` already exists
- **THEN** the command exits with status 1 and prints `Error: connection 'myrepo' already exists`

#### Scenario: Different name is accepted
- **WHEN** `--add-connection --name other ...` is run and only `myrepo` exists
- **THEN** `connections.json` contains both connections

### Requirement: connections can be removed by name
`--remove-connection <name>` SHALL remove the connection with the given name and rewrite `connections.json`. If the name does not exist the command SHALL exit non-zero with an error message.

#### Scenario: Known connection is removed
- **WHEN** `claude-secure webhook-listener --remove-connection myrepo` is run and `myrepo` exists
- **THEN** `connections.json` no longer contains a connection named `myrepo`

#### Scenario: Unknown connection name is rejected
- **WHEN** `claude-secure webhook-listener --remove-connection nonexistent` is run
- **THEN** the command exits with status 1 and prints `Error: connection 'nonexistent' not found`

### Requirement: list-connections shows name, repo without secret or token
`--list-connections` SHALL print each connection on its own line showing `name` and `repo`. The `webhook_secret` and `github_token` fields SHALL NOT appear in the output.

#### Scenario: Connections listed without sensitive fields
- **WHEN** `claude-secure webhook-listener --list-connections` is run with two connections configured
- **THEN** output contains two lines each showing name and repo but no secret or token value

#### Scenario: No connections configured
- **WHEN** `--list-connections` is run and `connections.json` does not exist or is empty
- **THEN** the command prints `No connections configured.` and exits 0

### Requirement: connections.json is written atomically
All writes to `connections.json` SHALL be performed via a temp file in the same directory followed by a rename, so a crash mid-write cannot corrupt the file.

#### Scenario: Atomic write on add
- **WHEN** `--add-connection` succeeds
- **THEN** `connections.json` is a valid JSON array (never a partial write)

### Requirement: listener resolves connection from connections.json by repo
`webhook/listener.py` SHALL read `~/.claude-secure/webhooks/connections.json` to find the connection matching an incoming webhook's repository full name. Profile directories SHALL NOT be scanned for webhook credentials.

#### Scenario: Incoming webhook matched to connection
- **WHEN** a push event arrives for `org/repo` and `connections.json` contains an entry with `"repo": "org/repo"`
- **THEN** the listener uses that entry's `webhook_secret` for HMAC verification

#### Scenario: No matching connection returns 404
- **WHEN** a push event arrives for a repo not present in `connections.json`
- **THEN** the listener returns HTTP 404

### Requirement: listener stubs spawn — no claude-secure spawn call
**REMOVED** — replaced by `webhook-spawn-always` spec. `_spawn_worker` now calls `claude-secure spawn` unconditionally after HMAC and repo lookup. No action required; the listener upgrade replaces the stub automatically.

## REMOVED Requirements

### Requirement: listener stubs spawn — no claude-secure spawn call
**Reason**: Placeholder behaviour removed. `_spawn_worker` now calls `claude-secure spawn` unconditionally after HMAC and repo lookup (see `webhook-spawn-always` spec).
**Migration**: No action required. The listener upgrade replaces the stub automatically.
