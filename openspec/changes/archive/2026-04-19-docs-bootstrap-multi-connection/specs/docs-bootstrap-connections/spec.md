## ADDED Requirements

### Requirement: connections stored as JSON array in dedicated directory
The `bootstrap-docs` connection config SHALL be stored at `~/.claude-secure/docs-bootstrap/connections.json` as a JSON array. The directory SHALL have mode `700` and the file SHALL have mode `600`. Each element SHALL contain `name` (string, required), `repo` (string, required), `token` (string, required), and optionally `branch` (string, default `main`).

#### Scenario: Directory and file created on first add
- **WHEN** `--add-connection` is run and `~/.claude-secure/docs-bootstrap/` does not exist
- **THEN** the directory is created with mode `700` and `connections.json` is created with mode `600` containing the new connection

#### Scenario: File contains valid JSON array after add
- **WHEN** `claude-secure bootstrap-docs --add-connection --name work-docs --repo https://github.com/org/docs --token ghp_xxx` is run
- **THEN** `connections.json` is a valid JSON array containing one object with `name`, `repo`, `token`, and `branch` fields

#### Scenario: Branch defaults to main when omitted
- **WHEN** `--add-connection` is run without `--branch`
- **THEN** the stored connection has `"branch": "main"`

### Requirement: connection names are unique; duplicate add is rejected
`--add-connection` SHALL check for an existing connection with the same `name` (case-sensitive) and exit non-zero with an error message if one is found. The file SHALL NOT be modified.

#### Scenario: Duplicate name is rejected
- **WHEN** `--add-connection --name work-docs ...` is run and a connection named `work-docs` already exists
- **THEN** the command exits with status 1 and prints `Error: connection 'work-docs' already exists`

#### Scenario: Different name is accepted
- **WHEN** `--add-connection --name personal ...` is run and only `work-docs` exists
- **THEN** `connections.json` contains both connections

### Requirement: connections can be removed by name
`--remove-connection <name>` SHALL remove the connection with the given name and rewrite `connections.json`. If the name does not exist the command SHALL exit non-zero with an error message.

#### Scenario: Known connection is removed
- **WHEN** `claude-secure bootstrap-docs --remove-connection work-docs` is run and `work-docs` exists
- **THEN** `connections.json` no longer contains a connection named `work-docs`

#### Scenario: Unknown connection name is rejected
- **WHEN** `claude-secure bootstrap-docs --remove-connection nonexistent` is run
- **THEN** the command exits with status 1 and prints `Error: connection 'nonexistent' not found`

### Requirement: list-connections shows name, repo, branch without token
`--list-connections` SHALL print each connection on its own line showing `name`, `repo`, and `branch`. The token SHALL NOT appear in the output.

#### Scenario: Connections listed without token
- **WHEN** `claude-secure bootstrap-docs --list-connections` is run with two connections configured
- **THEN** output contains two lines each showing name, repo, branch but no token value

#### Scenario: No connections configured
- **WHEN** `--list-connections` is run and `connections.json` does not exist or is empty
- **THEN** the command prints `No connections configured.` and exits 0

### Requirement: connections.json is written atomically
All writes to `connections.json` SHALL be performed via a temp file in the same directory followed by a rename, so a crash mid-write cannot corrupt the file.

#### Scenario: Atomic write on add
- **WHEN** `--add-connection` succeeds
- **THEN** `connections.json` is a valid JSON array (never a partial write)
