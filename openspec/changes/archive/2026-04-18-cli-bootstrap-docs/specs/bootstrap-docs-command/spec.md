## ADDED Requirements

### Requirement: bootstrap-docs subcommand scaffolds a path in a remote repo
`claude-secure bootstrap-docs <path>` SHALL clone the configured docs repo, create the standard project folder structure at `<path>` using the templates from `scripts/templates/`, commit the new files, and push back to the remote. The command SHALL exit non-zero and print a clear error if `<path>` already exists in the repo.

#### Scenario: Successful bootstrap of a new path
- **WHEN** `claude-secure bootstrap-docs projects/JAD` is run and `projects/JAD` does not exist in the configured repo
- **THEN** the repo is cloned, `projects/JAD/` is created with all standard files and subdirectories, the changes are committed with message `bootstrap: projects/JAD`, and pushed to the configured branch

#### Scenario: Path already exists is rejected
- **WHEN** `claude-secure bootstrap-docs projects/JAD` is run and `projects/JAD` already exists in the remote repo
- **THEN** the command exits with status 1 and prints `Error: projects/JAD already exists in remote repo`

#### Scenario: Missing path argument is rejected
- **WHEN** `claude-secure bootstrap-docs` is run with no arguments
- **THEN** the command exits with status 1 and prints usage information including `bootstrap-docs <path>`

#### Scenario: Repo not configured is rejected
- **WHEN** `claude-secure bootstrap-docs projects/JAD` is run and no repo URL is configured
- **THEN** the command exits with status 1 and prints `Error: docs repo not configured. Run: claude-secure bootstrap-docs --set-repo <url>`

### Requirement: bootstrap-docs config stores repo URL, token, and branch
`claude-secure bootstrap-docs --set-repo <url>` SHALL write the repo URL to `~/.claude-secure/docs-bootstrap.env`. `claude-secure bootstrap-docs --set-token <token>` SHALL write the token to `~/.claude-secure/docs-bootstrap.env`. `claude-secure bootstrap-docs --set-branch <branch>` SHALL write the branch (default: `main`). The file SHALL be created with mode `600`. Existing values SHALL be overwritten individually without affecting other keys.

#### Scenario: Set repo URL
- **WHEN** `claude-secure bootstrap-docs --set-repo https://github.com/user/vault.git` is run
- **THEN** `~/.claude-secure/docs-bootstrap.env` contains `DOCS_BOOTSTRAP_REPO=https://github.com/user/vault.git` and the file has mode `600`

#### Scenario: Set token
- **WHEN** `claude-secure bootstrap-docs --set-token ghp_abc123` is run
- **THEN** `~/.claude-secure/docs-bootstrap.env` contains `DOCS_BOOTSTRAP_TOKEN=ghp_abc123` and the file has mode `600`

#### Scenario: Set branch
- **WHEN** `claude-secure bootstrap-docs --set-branch master` is run
- **THEN** `~/.claude-secure/docs-bootstrap.env` contains `DOCS_BOOTSTRAP_BRANCH=master`

#### Scenario: Default branch is main
- **WHEN** no branch is configured and `claude-secure bootstrap-docs <path>` is run
- **THEN** the command clones and pushes to branch `main`

### Requirement: bootstrap-docs uses ephemeral ASKPASS for token auth
The git clone and push SHALL use an ephemeral ASKPASS helper script that reads the token from the environment, consistent with the existing report-repo publish pattern. The token SHALL NOT be passed as a CLI argument to git or stored in `.git/config`.

#### Scenario: Token never appears in git process args
- **WHEN** `claude-secure bootstrap-docs <path>` is run with a configured token
- **THEN** the git clone and push succeed without the token appearing in the git command arguments

#### Scenario: Token scrubbed from error output
- **WHEN** git clone fails and the error output would contain the token
- **THEN** the token is replaced with `<REDACTED:DOCS_BOOTSTRAP_TOKEN>` before printing to stderr

### Requirement: bootstrap-docs cleans up temp clone on exit
The temporary clone directory SHALL be removed on exit, whether the command succeeds or fails.

#### Scenario: Temp dir removed after success
- **WHEN** `claude-secure bootstrap-docs <path>` completes successfully
- **THEN** no temporary clone directory remains on the filesystem

#### Scenario: Temp dir removed after failure
- **WHEN** `claude-secure bootstrap-docs <path>` fails at any step
- **THEN** no temporary clone directory remains on the filesystem

### Requirement: install.sh copies scripts/templates/ to installed layout
The installer SHALL copy `scripts/templates/` to the installed share directory so that `bootstrap-docs` can locate templates when run from the installed `claude-secure` binary.

#### Scenario: Templates available after install
- **WHEN** `install.sh` completes
- **THEN** the template files exist at the installed share path and `claude-secure bootstrap-docs` can locate them
