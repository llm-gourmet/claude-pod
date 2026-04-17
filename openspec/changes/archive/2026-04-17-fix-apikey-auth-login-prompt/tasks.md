## 1. Fix docker-compose.yml auth env vars

- [x] 1.1 Remove `ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}` from the claude service `environment` block in `docker-compose.yml`
- [x] 1.2 Remove `CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}` from the claude service `environment` block (rely on env_file only)
- [x] 1.3 Add inline comment to the claude service `env_file` entry explaining that `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are delivered exclusively via env_file, not environment overrides

## 2. Fix non-interactive install path for REAL_ANTHROPIC_BASE_URL

- [x] 2.1 In `install.sh` `setup_auth()`, update the `ANTHROPIC_API_KEY` env-var branch (lines 352–356) to also check `REAL_ANTHROPIC_BASE_URL` in the host environment and pass it as the extra pair to `write_env_file` if non-empty
- [x] 2.2 Verify the updated branch still rejects newline-tainted values for `REAL_ANTHROPIC_BASE_URL` (same validation as the interactive path)

## 3. Verify and document the auth flow

- [x] 3.1 Run a local test: start a fresh container with `ANTHROPIC_API_KEY=<real_key>` in `.env` (no `environment` override), confirm Claude Code does not prompt for OAuth login in headless mode (`docker compose exec -T claude claude -p "hello"`)
- [ ] 3.2 Run a local test: OAuth user path — start with `CLAUDE_CODE_OAUTH_TOKEN=<token>` only, confirm no `ANTHROPIC_API_KEY=dummy` appears in container env (`docker compose exec claude env | grep API_KEY`)
- [x] 3.3 Add a comment block above the proxy service's `REAL_ANTHROPIC_BASE_URL` line in `docker-compose.yml` clarifying the two-variable design: `ANTHROPIC_BASE_URL` (claude container) always points to the proxy; `REAL_ANTHROPIC_BASE_URL` (proxy container) is the actual upstream Anthropic endpoint
