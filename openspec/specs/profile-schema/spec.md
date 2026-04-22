## ADDED Requirements

### Requirement: profile.json is the single profile configuration file
Each profile SHALL be fully described by two files: `profile.json` (configuration) and `.env` (secret values). No `whitelist.json` file SHALL exist per profile. The `config/whitelist.json` template SHALL be removed from the project.

#### Scenario: New profile directory structure
- **WHEN** a profile named `my-project` is created
- **THEN** `~/.claude-secure/profiles/my-project/` SHALL contain exactly `profile.json` and `.env`
- **AND** no `whitelist.json` file SHALL be present

### Requirement: profile.json schema
`profile.json` SHALL contain the following top-level fields:
- `workspace` (string, required): absolute path to the Claude Code workspace directory
- `secrets` (array, optional): list of secret entries (see Requirement: secrets array schema)

The `system_prompt` field SHALL NOT be written or read by the system. Unknown fields SHALL be ignored on read.

#### Scenario: Minimal valid profile.json
- **WHEN** a profile is created with only a workspace path
- **THEN** `profile.json` SHALL be `{"workspace": "/path/to/ws"}`

#### Scenario: Profile with secrets
- **WHEN** a profile has one GitHub secret
- **THEN** `profile.json` SHALL be:
  ```json
  {
    "workspace": "/path/to/ws",
    "secrets": [
      {
        "env_var": "GITHUB_TOKEN",
        "redacted": "REDACTED_GITHUB",
        "domains": ["github.com", "api.github.com"]
      }
    ]
  }
  ```

#### Scenario: system_prompt field ignored if present
- **WHEN** a legacy `profile.json` still contains a `system_prompt` field post-migration
- **THEN** the field SHALL be ignored by spawn
- **AND** `migrate-profile-prompts.sh` SHALL remove it on next run

### Requirement: secrets array schema
Each entry in `secrets[]` SHALL have:
- `env_var` (string, required): name of the environment variable in `.env` that holds the secret value
- `redacted` (string, required): the token that replaces the secret value in Anthropic-bound requests
- `domains` (array of strings, required): domains to which this secret may be sent as auth

Multiple entries MAY share the same domain list. Multiple entries MAY use the same `redacted` value (no uniqueness enforced).

#### Scenario: Multiple keys for same domain
- **WHEN** a profile has two GitHub entries with different `env_var` and `redacted` values but overlapping domains
- **THEN** both entries SHALL be preserved and both secrets SHALL be redacted independently

#### Scenario: Secret entry validation
- **WHEN** a secret entry is missing `env_var`, `redacted`, or `domains`
- **THEN** `validate_profile` SHALL exit non-zero with a descriptive error

### Requirement: Domain whitelist derived from secrets array
The set of domains to which payload (POST/PUT/PATCH/DELETE) requests are allowed SHALL be the union of all `domains[]` values across all entries in `profile.json` `secrets[]`. There is no separate domain whitelist file or `readonly_domains` list.

#### Scenario: Payload to whitelisted domain allowed
- **WHEN** `pre-tool-use.sh` intercepts a POST to `api.github.com`
- **AND** `secrets[]` contains an entry with `"domains": ["api.github.com"]`
- **THEN** the hook SHALL allow the call and register a call-ID

#### Scenario: Payload to non-whitelisted domain blocked
- **WHEN** `pre-tool-use.sh` intercepts a POST to `evil.example.com`
- **AND** no entry in `secrets[]` lists `evil.example.com` in `domains`
- **THEN** the hook SHALL deny the call

#### Scenario: GET request allowed to any domain
- **WHEN** `pre-tool-use.sh` intercepts a GET request to any domain
- **THEN** the hook SHALL allow the call unconditionally (no secrets[] check required)

### Requirement: Proxy builds redaction map from profile.json
The Anthropic proxy SHALL read `profile.json` on each request and build its redaction map from `secrets[].{env_var, redacted}`. For each entry, it SHALL look up the value of `env_var` from the container environment and replace any occurrence in the request body with `redacted`.

#### Scenario: Secret value in prompt is redacted
- **WHEN** the LLM request body contains the literal value of `GITHUB_TOKEN`
- **THEN** the proxy SHALL replace it with the corresponding `redacted` string before forwarding to Anthropic

#### Scenario: Missing env var is skipped
- **WHEN** a `secrets[]` entry references an `env_var` not present in the environment
- **THEN** the proxy SHALL skip that entry (no error, no crash)

### Requirement: validate_profile checks new schema
`validate_profile` in `bin/claude-secure` SHALL verify:
1. `profile.json` exists and is valid JSON
2. `workspace` field is present and the path exists on disk
3. `.env` exists
4. Each entry in `secrets[]` (if present) has `env_var`, `redacted`, and `domains` fields

#### Scenario: Valid profile passes validation
- **WHEN** `validate_profile` is called on a profile with correct `profile.json` and `.env`
- **THEN** it SHALL exit 0

#### Scenario: Missing secrets fields fails validation
- **WHEN** a `secrets[]` entry is missing `redacted`
- **THEN** `validate_profile` SHALL exit non-zero
