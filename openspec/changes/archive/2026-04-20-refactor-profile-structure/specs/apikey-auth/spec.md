## ADDED Requirements

### Requirement: ANTHROPIC_API_KEY delivered to Claude container via env_file only
The Claude container SHALL receive `ANTHROPIC_API_KEY` exclusively through the `env_file` mechanism. The `environment` block in `docker-compose.yml` for the claude service SHALL NOT contain an `ANTHROPIC_API_KEY` entry (no override, no dummy fallback).

#### Scenario: API-key user starts claude-secure
- **WHEN** the profile `.env` contains `ANTHROPIC_API_KEY=<real-key>` and no `CLAUDE_CODE_OAUTH_TOKEN`
- **THEN** the claude container's `ANTHROPIC_API_KEY` SHALL equal `<real-key>` (from env_file, no override)

#### Scenario: OAuth user starts claude-secure
- **WHEN** the profile `.env` contains `CLAUDE_CODE_OAUTH_TOKEN=<token>` and no `ANTHROPIC_API_KEY`
- **THEN** the claude container SHALL have `ANTHROPIC_API_KEY` unset (not `"dummy"`)

### Requirement: Claude Code SHALL NOT prompt for OAuth login when ANTHROPIC_API_KEY is set
When `ANTHROPIC_API_KEY` is present and non-empty in the claude container environment, Claude Code SHALL use API-key auth and SHALL NOT emit an OAuth login prompt or exit with an auth error.

#### Scenario: Headless run with valid API key
- **WHEN** `docker compose exec -T claude claude -p <prompt>` is executed and `ANTHROPIC_API_KEY` is set
- **THEN** the command SHALL complete (or fail for non-auth reasons) without printing OAuth instructions to stderr

#### Scenario: Headless run with missing key (no auth configured)
- **WHEN** neither `ANTHROPIC_API_KEY` nor `CLAUDE_CODE_OAUTH_TOKEN` is set in the claude container
- **THEN** the command SHALL exit non-zero with an auth error (acceptable failure, no silent hang)

### Requirement: CLAUDE_CODE_OAUTH_TOKEN delivered to Claude container via env_file only
The `environment` block for the claude service SHALL NOT contain a `CLAUDE_CODE_OAUTH_TOKEN` entry. It SHALL be delivered exclusively via `env_file`.

#### Scenario: OAuth token reaches container
- **WHEN** the profile `.env` contains `CLAUDE_CODE_OAUTH_TOKEN=<token>`
- **THEN** the claude container's `CLAUDE_CODE_OAUTH_TOKEN` SHALL equal `<token>` (from env_file)

### Requirement: Non-interactive install supports REAL_ANTHROPIC_BASE_URL
When `ANTHROPIC_API_KEY` is supplied via environment variable to `install.sh` (non-interactive path), the installer SHALL also read `REAL_ANTHROPIC_BASE_URL` from the environment and write it to the profile `.env` if it is non-empty.

#### Scenario: Both vars set in environment
- **WHEN** `ANTHROPIC_API_KEY=<key>` and `REAL_ANTHROPIC_BASE_URL=<url>` are exported before running install.sh
- **THEN** the resulting `.env` SHALL contain both `ANTHROPIC_API_KEY=<key>` and `REAL_ANTHROPIC_BASE_URL=<url>`

#### Scenario: Only API key set in environment
- **WHEN** `ANTHROPIC_API_KEY=<key>` is exported but `REAL_ANTHROPIC_BASE_URL` is not
- **THEN** the resulting `.env` SHALL contain only `ANTHROPIC_API_KEY=<key>` (default Anthropic endpoint used)

### Requirement: .env contains only auth token and secret values
The profile `.env` file SHALL contain only:
- Exactly one auth entry: either `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` (not both, unless explicitly configured)
- One entry per `secrets[]` item in `profile.json` (the variable named by `env_var`)

No other variables SHALL be written to `.env` by the system. Webhook tokens, report tokens, docs tokens, and workspace paths SHALL NOT be stored in `.env`.

#### Scenario: Fresh install writes minimal .env
- **WHEN** `install.sh` completes with OAuth token and no additional secrets
- **THEN** `.env` SHALL contain exactly one line: `CLAUDE_CODE_OAUTH_TOKEN=<token>`

#### Scenario: Profile with GitHub secret
- **WHEN** a profile is created with one `secrets[]` entry referencing `GITHUB_TOKEN`
- **THEN** `.env` SHALL contain `CLAUDE_CODE_OAUTH_TOKEN=<token>` and `GITHUB_TOKEN=<value>`

## REMOVED Requirements

### Requirement: whitelist.json as separate per-profile file
**Reason**: Domain and redaction config is now part of `profile.json` `secrets[]`. `whitelist.json` is eliminated.
**Migration**: Copy `secrets[].allowed_domains` → `secrets[].domains`, rename `secrets[].placeholder` → `secrets[].redacted`, move the whole `secrets[]` array and `readonly_domains` (if any) into `profile.json`. Delete `whitelist.json`.
