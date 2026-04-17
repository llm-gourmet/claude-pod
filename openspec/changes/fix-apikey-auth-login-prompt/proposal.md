## Why

After installing with API key + custom base URL, users are immediately prompted to log in when starting claude-secure. The `ANTHROPIC_API_KEY` is either reaching the Claude container as `"dummy"` (if host env var substitution failed) or Claude Code rejects `"dummy"` as a malformed key, triggering the OAuth login flow. Additionally, the custom `REAL_ANTHROPIC_BASE_URL` is correctly used by the proxy but there is no clear handshake between the API-key auth mode and the proxy — the auth design is implicit and fragile.

## What Changes

- Fix `docker-compose.yml`: remove the `ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}` override from the claude service `environment` block; rely solely on `env_file` to pass the real key (no dummy fallback that can silently break auth)
- Fix `docker-compose.yml`: change `CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}` to also rely on `env_file` only, so auth vars are consistent
- Verify that `env_file` precedence alone is sufficient for Claude Code to pick up `ANTHROPIC_API_KEY` without the OAuth login prompt
- Document the two-variable design (`ANTHROPIC_BASE_URL` = proxy, `REAL_ANTHROPIC_BASE_URL` = upstream) inline in docker-compose.yml so the intent is clear

## Capabilities

### New Capabilities
- `apikey-auth`: Auth via `ANTHROPIC_API_KEY` (with optional custom `REAL_ANTHROPIC_BASE_URL`) reaches the Claude container correctly and suppresses OAuth login prompt

### Modified Capabilities
- none

## Impact

- `docker-compose.yml` — claude and proxy service environment sections
- `install.sh` — verify the write_env_file path for API-key installs (non-interactive ANTHROPIC_API_KEY env var path does NOT write `REAL_ANTHROPIC_BASE_URL` even if the user sets it)
- `bin/claude-secure` — no change expected; env sourcing already works
- No breaking changes for OAuth users
