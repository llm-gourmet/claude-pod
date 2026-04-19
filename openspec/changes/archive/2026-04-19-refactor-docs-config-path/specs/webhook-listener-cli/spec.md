## MODIFIED Requirements

### Requirement: --set-token writes GitHub PAT to profile.json
The `claude-secure webhook-listener --set-token <pat>` subcommand SHALL write `github_token` into the named profile's `profile.json`. The `--profile <name>` flag SHALL be required; if omitted and exactly one profile exists across `profiles_dir` and `docs_dir` combined, that profile is used; otherwise the command exits with an error.

#### Scenario: Set token for a named profile in profiles dir
- **WHEN** `claude-secure webhook-listener --set-token ghp_abc123 --profile myrepo` is run and `myrepo` exists under `profiles/`
- **THEN** `~/.claude-secure/profiles/myrepo/profile.json` contains `"github_token": "ghp_abc123"`

#### Scenario: Set token for a named profile in docs dir
- **WHEN** `claude-secure webhook-listener --set-token ghp_abc123 --profile obsidian` is run and `obsidian` exists under `docs/`
- **THEN** `~/.claude-secure/docs/obsidian/profile.json` contains `"github_token": "ghp_abc123"`

#### Scenario: Token redacted in output
- **WHEN** `--set-token` is called
- **THEN** stdout confirms the operation without printing the token value

#### Scenario: No profile specified with multiple profiles exits with error
- **WHEN** `--set-token` is run without `--profile` and more than one profile exists across `profiles/` and `docs/` combined
- **THEN** command exits non-zero with a message listing available profiles
