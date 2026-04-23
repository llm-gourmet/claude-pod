## ADDED Requirements

### Requirement: bootstrap-docs subcommand scaffolds a path in a remote repo
`claude-pod bootstrap-docs --connection <name> <path>` SHALL look up the named connection from `~/.claude-pod/docs-bootstrap/connections.json`, clone the connection's repo, create the standard project folder structure at `<path>` using the templates from `scripts/templates/`, commit the new files, and push back to the remote. The `--connection` flag is required. The command SHALL exit non-zero and print a clear error if `<path>` already exists in the repo.

#### Scenario: Successful bootstrap of a new path
- **WHEN** `claude-pod bootstrap-docs --connection work-docs projects/JAD` is run and `projects/JAD` does not exist in the repo
- **THEN** the repo is cloned, `projects/JAD/` is created with all standard files and subdirectories, the changes are committed with message `bootstrap: projects/JAD`, and pushed to the configured branch

#### Scenario: Path already exists is rejected
- **WHEN** `claude-pod bootstrap-docs --connection work-docs projects/JAD` is run and `projects/JAD` already exists
- **THEN** the command exits with status 1 and prints `Error: projects/JAD already exists in remote repo`

#### Scenario: Missing path argument is rejected
- **WHEN** `claude-pod bootstrap-docs --connection work-docs` is run with no path
- **THEN** the command exits with status 1 and prints usage information

#### Scenario: Missing --connection flag is rejected
- **WHEN** `claude-pod bootstrap-docs projects/JAD` is run without `--connection`
- **THEN** the command exits with status 1 and prints `Error: --connection <name> is required` followed by a hint to run `--list-connections`

#### Scenario: Unknown connection name is rejected
- **WHEN** `claude-pod bootstrap-docs --connection nosuchname projects/JAD` is run
- **THEN** the command exits with status 1 and prints `Error: connection 'nosuchname' not found. Run --list-connections to see available connections.`

### Requirement: bootstrap-docs uses ephemeral ASKPASS for token auth
The git clone and push SHALL use an ephemeral ASKPASS helper script that reads the token from the environment, consistent with the existing report-repo publish pattern. The token SHALL NOT be passed as a CLI argument to git or stored in `.git/config`.

#### Scenario: Token never appears in git process args
- **WHEN** `claude-pod bootstrap-docs --connection <name> <path>` is run with a configured token
- **THEN** the git clone and push succeed without the token appearing in the git command arguments

#### Scenario: Token scrubbed from error output
- **WHEN** git clone fails and the error output would contain the token
- **THEN** the token is replaced with `<REDACTED:DOCS_BOOTSTRAP_TOKEN>` before printing to stderr

### Requirement: bootstrap-docs cleans up temp clone on exit
The temporary clone directory SHALL be removed on exit, whether the command succeeds or fails.

#### Scenario: Temp dir removed after success
- **WHEN** `claude-pod bootstrap-docs --connection <name> <path>` completes successfully
- **THEN** no temporary clone directory remains on the filesystem

#### Scenario: Temp dir removed after failure
- **WHEN** `claude-pod bootstrap-docs --connection <name> <path>` fails at any step
- **THEN** no temporary clone directory remains on the filesystem

### Requirement: install.sh copies scripts/templates/ to installed layout
The installer SHALL copy `scripts/templates/` to the installed share directory so that `bootstrap-docs` can locate templates when run from the installed `claude-pod` binary.

#### Scenario: Templates available after install
- **WHEN** `install.sh` completes
- **THEN** the template files exist at the installed share path and `claude-pod bootstrap-docs` can locate them
