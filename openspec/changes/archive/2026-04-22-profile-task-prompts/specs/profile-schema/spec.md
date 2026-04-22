## REMOVED Requirements

### Requirement: profile.json system_prompt field
**Reason**: Replaced by `system_prompts/` file-based configuration. File-based approach supports per-event-type variation and is more ergonomic for complex prompts. A single inline JSON string field does not scale.
**Migration**: `scripts/migrate-profile-prompts.sh` (run by `claude-secure update`) automatically extracts the `system_prompt` value into `system_prompts/default.md` and removes the field from `profile.json`.

## MODIFIED Requirements

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
