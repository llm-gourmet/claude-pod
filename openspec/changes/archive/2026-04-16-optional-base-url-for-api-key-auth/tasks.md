## 1. docker-compose.yml

- [x] 1.1 Change proxy `REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com` to `REAL_ANTHROPIC_BASE_URL=${REAL_ANTHROPIC_BASE_URL:-https://api.anthropic.com}`

## 2. install.sh — setup_auth()

- [x] 2.1 Extend `write_env_file()` to accept an optional third/fourth argument `(base_url_name, base_url_value)` and write it to `.env` inside the same grouped redirection (omit line if value is empty)
- [x] 2.2 After the API key prompt (interactive path, choice `2`), add prompt: `Base URL [https://api.anthropic.com]: ` with example hint `e.g. https://yourcompany.com/anthropic/v1`
- [x] 2.3 Pass the base URL value to `write_env_file()` so it lands in `.env` as `REAL_ANTHROPIC_BASE_URL`
- [x] 2.4 For the env-var fast path (`ANTHROPIC_API_KEY` already set), skip the base URL prompt — user edits `.env` directly

## 3. bin/claude-secure — profile create

- [x] 3.1 Locate the `profile create` API key auth path (same pattern as `setup_auth()` in install.sh)
- [x] 3.2 Add the same optional base URL prompt after the API key entry
- [x] 3.3 Write `REAL_ANTHROPIC_BASE_URL` to the profile `.env` if provided (inside the existing grouped redirection)

## 4. Verification

- [x] 4.1 Install with API key + custom base URL → confirm `.env` contains `REAL_ANTHROPIC_BASE_URL`
- [x] 4.2 `docker compose config` on the profile → confirm proxy env shows the custom URL
- [x] 4.3 Install with API key + empty base URL → confirm proxy env shows `https://api.anthropic.com`
- [x] 4.4 Existing install (no `REAL_ANTHROPIC_BASE_URL` in `.env`) → confirm proxy still forwards to `https://api.anthropic.com`
