## ADDED Requirements

### Requirement: Optional base URL prompt during API key auth setup
When a user selects API key authentication during installation or profile creation, the system SHALL prompt for an optional custom base URL. The prompt SHALL display an example of a valid URL (e.g., `https://yourcompany.com/anthropic/v1`). If the user provides no input, the system SHALL use the default Anthropic endpoint.

#### Scenario: User provides a custom base URL
- **WHEN** user selects API key auth and enters a non-empty base URL at the prompt
- **THEN** the profile `.env` SHALL contain both `ANTHROPIC_API_KEY` and `REAL_ANTHROPIC_BASE_URL` with the provided value

#### Scenario: User skips the base URL prompt
- **WHEN** user selects API key auth and presses Enter without entering a base URL
- **THEN** the profile `.env` SHALL contain only `ANTHROPIC_API_KEY` and the proxy SHALL forward to `https://api.anthropic.com` by default

### Requirement: Base URL persisted in profile `.env`
The custom base URL SHALL be stored as `REAL_ANTHROPIC_BASE_URL` in the profile's `.env` file alongside the API key.

#### Scenario: Value survives session restart
- **WHEN** a profile with `REAL_ANTHROPIC_BASE_URL` in `.env` is loaded
- **THEN** the proxy container SHALL use that URL as the upstream endpoint

### Requirement: docker-compose proxy upstream uses variable substitution
The proxy service in `docker-compose.yml` SHALL resolve `REAL_ANTHROPIC_BASE_URL` from the host environment with a fallback to `https://api.anthropic.com`.

#### Scenario: No custom URL set (existing installs)
- **WHEN** `REAL_ANTHROPIC_BASE_URL` is absent from the profile `.env`
- **THEN** the proxy SHALL forward to `https://api.anthropic.com` unchanged

#### Scenario: Custom URL set
- **WHEN** `REAL_ANTHROPIC_BASE_URL=https://corp.example.com/ai/v1` is present in the profile `.env`
- **THEN** the proxy container's `REAL_ANTHROPIC_BASE_URL` SHALL equal `https://corp.example.com/ai/v1`
