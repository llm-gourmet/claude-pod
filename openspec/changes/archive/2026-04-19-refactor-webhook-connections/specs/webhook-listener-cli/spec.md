## MODIFIED Requirements

### Requirement: --set-token writes GitHub PAT to connections.json
The `claude-secure webhook-listener --set-token <pat>` subcommand SHALL write `github_token` into the named connection's entry in `~/.claude-secure/webhooks/connections.json`. The `--name <name>` flag SHALL be required. If the named connection does not exist the command exits non-zero with an error.

#### Scenario: Set token for a named connection
- **WHEN** `claude-secure webhook-listener --set-token ghp_abc123 --name myrepo` is run and `myrepo` exists in `connections.json`
- **THEN** `connections.json` contains `"github_token": "ghp_abc123"` in the `myrepo` entry

#### Scenario: Token redacted in output
- **WHEN** `--set-token` is called
- **THEN** stdout confirms the operation without printing the token value

#### Scenario: Unknown connection name exits with error
- **WHEN** `--set-token` is run with `--name nonexistent` and no connection named `nonexistent` exists
- **THEN** command exits non-zero with `Error: connection 'nonexistent' not found`
