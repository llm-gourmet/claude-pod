## MODIFIED Requirements

### Requirement: bootstrap-docs subcommand scaffolds a path in a remote repo
`claude-secure bootstrap-docs --connection <name> <path>` SHALL look up the named connection from `~/.claude-secure/docs-bootstrap/connections.json`, clone the connection's repo, create the standard project folder structure at `<path>` using the templates from `scripts/templates/`, commit the new files, and push back to the remote. The `--connection` flag is required. The command SHALL exit non-zero and print a clear error if `<path>` already exists in the repo.

#### Scenario: Successful bootstrap of a new path
- **WHEN** `claude-secure bootstrap-docs --connection work-docs projects/JAD` is run and `projects/JAD` does not exist in the repo
- **THEN** the repo is cloned, `projects/JAD/` is created with all standard files and subdirectories, the changes are committed with message `bootstrap: projects/JAD`, and pushed to the configured branch

#### Scenario: Path already exists is rejected
- **WHEN** `claude-secure bootstrap-docs --connection work-docs projects/JAD` is run and `projects/JAD` already exists
- **THEN** the command exits with status 1 and prints `Error: projects/JAD already exists in remote repo`

#### Scenario: Missing path argument is rejected
- **WHEN** `claude-secure bootstrap-docs --connection work-docs` is run with no path
- **THEN** the command exits with status 1 and prints usage information

#### Scenario: Missing --connection flag is rejected
- **WHEN** `claude-secure bootstrap-docs projects/JAD` is run without `--connection`
- **THEN** the command exits with status 1 and prints `Error: --connection <name> is required` followed by a hint to run `--list-connections`

#### Scenario: Unknown connection name is rejected
- **WHEN** `claude-secure bootstrap-docs --connection nosuchname projects/JAD` is run
- **THEN** the command exits with status 1 and prints `Error: connection 'nosuchname' not found. Run --list-connections to see available connections.`

## REMOVED Requirements

### Requirement: bootstrap-docs config stores repo URL, token, and branch
**Reason**: Replaced by multi-connection model (`docs-bootstrap-connections` capability). The single-connection `--set-repo`, `--set-token`, `--set-branch` flags and `~/.claude-secure/docs-bootstrap.env` file are superseded by `--add-connection` / `connections.json`.
**Migration**: Use `claude-secure bootstrap-docs --add-connection --name <name> --repo <url> --token <token> [--branch <branch>]` to register connections. Manually copy values from the old `~/.claude-secure/docs-bootstrap.env` if needed.
