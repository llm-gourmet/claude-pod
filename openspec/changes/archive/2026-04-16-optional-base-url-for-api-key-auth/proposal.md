## Why

When using an API key with a compatible Anthropic API provider (e.g., a corporate gateway or third-party service), the endpoint differs from `api.anthropic.com`. Currently there is no way to configure this during installation — the proxy's upstream URL is hardcoded in `docker-compose.yml` and cannot be overridden via the profile `.env`.

## What Changes

- Installation prompts for an optional base URL when API key auth is selected (interactive and env-var paths)
- Base URL is written to the profile `.env` as `REAL_ANTHROPIC_BASE_URL`
- `docker-compose.yml` proxy environment entry changes from hardcoded value to variable substitution with fallback
- `claude-secure profile create` also gains the optional base URL prompt for API key auth

## Capabilities

### New Capabilities

- `api-key-base-url`: Optional custom upstream base URL for API-key-authenticated profiles, configurable at install/profile-create time and stored in the profile `.env`

### Modified Capabilities

<!-- none — no existing spec files to delta -->

## Impact

- `install.sh`: `setup_auth()` — add optional base URL prompt + write to `.env`
- `bin/claude-secure`: `profile create` API key path — same prompt addition
- `docker-compose.yml`: line 50 — `REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com` → `REAL_ANTHROPIC_BASE_URL=${REAL_ANTHROPIC_BASE_URL:-https://api.anthropic.com}`
- No proxy code changes required (`proxy.js` already reads `REAL_ANTHROPIC_BASE_URL` from env)
