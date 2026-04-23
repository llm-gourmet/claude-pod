## MODIFIED Requirements

### Requirement: profile.json schema
`profile.json` SHALL contain the following top-level fields:
- `secrets` (array, optional): list of secret entries (see Requirement: secrets array schema)

The `workspace` field SHALL NOT be written or read by the system. The `system_prompt` field SHALL NOT be written or read by the system. Unknown fields SHALL be ignored on read.

#### Scenario: Minimal valid profile.json
- **WHEN** a profile is created
- **THEN** `profile.json` SHALL be `{"secrets": []}`

#### Scenario: Profile with secrets
- **WHEN** a profile has one GitHub secret
- **THEN** `profile.json` SHALL be:
  ```json
  {
    "secrets": [
      {
        "env_var": "GITHUB_TOKEN",
        "redacted": "REDACTED_GITHUB",
        "domains": ["github.com", "api.github.com"]
      }
    ]
  }
  ```

#### Scenario: Legacy profile.json with workspace field is accepted
- **WHEN** a `profile.json` still contains a `workspace` field from a prior installation
- **THEN** the field SHALL be silently ignored
- **AND** all other fields SHALL be read normally

## MODIFIED Requirements

### Requirement: validate_profile checks new schema
`validate_profile` in `bin/claude-pod` SHALL verify:
1. `profile.json` exists and is valid JSON
2. `.env` exists
3. Each entry in `secrets[]` (if present) has `env_var`, `redacted`, and `domains` fields

The `workspace` field SHALL NOT be checked. No filesystem path check SHALL be performed.

#### Scenario: Valid profile passes validation
- **WHEN** `validate_profile` is called on a profile with correct `profile.json` and `.env`
- **THEN** it SHALL exit 0

#### Scenario: Profile without workspace field passes validation
- **WHEN** `profile.json` has no `workspace` field
- **THEN** `validate_profile` SHALL exit 0

#### Scenario: Missing secrets fields fails validation
- **WHEN** a `secrets[]` entry is missing `redacted`
- **THEN** `validate_profile` SHALL exit non-zero

## REMOVED Requirements

### Requirement: profile.json workspace field is required
**Reason**: Workspace bind-mounts are removed. No host directory is mounted into containers. The `workspace` field served only as the source for `WORKSPACE_PATH` in docker-compose — that variable and volume are gone.
**Migration**: Existing `profile.json` files with a `workspace` field continue to work; the field is silently ignored.
