## Why

Webhook credentials (`webhook_secret`, `github_token`, event filters) are embedded in `profile.json` alongside Claude spawn config, coupling two unrelated concerns: webhook identity/auth and Claude execution context. Moving webhook connections to a dedicated `connections.json` mirrors the proven docs-bootstrap pattern and makes each concern independently manageable.

## What Changes

- New `~/.claude-secure/webhooks/connections.json`: JSON array, each entry holds `name`, `repo`, `webhook_secret`, and optional `github_token`, `webhook_event_filter`, `webhook_bot_users`
- `webhook/listener.py`: replace `resolve_profile_by_repo` (scans `profile.json` files) with `resolve_connection_by_repo` (reads `connections.json`); stub out spawn with `log_event("spawn_skipped")` — no `claude-secure spawn` call in this change
- `bin/claude-secure` `webhook-listener` subcommand: add `--add-connection`, `--remove-connection`, `--list-connections`; migrate `--set-token` to write `github_token` into the matching connection in `connections.json` instead of `profile.json`
- `install.sh`: create `~/.claude-secure/webhooks/` (mode 700) alongside existing dirs
- Tests: update `test-webhook-listener-cli.sh` and `test-webhook-diff-filter.sh` fixtures; replace profile-based setup with connections-based setup
- README: document `connections.json` format and CLI verbs; note manual migration from `profile.json`

## Capabilities

### New Capabilities

- `webhook-connections`: Standalone webhook connection store at `~/.claude-secure/webhooks/connections.json` with CLI CRUD operations (`--add-connection`, `--remove-connection`, `--list-connections`) and atomic file writes

### Modified Capabilities

- `webhook-listener-cli`: `--set-token` now targets a named connection in `connections.json` instead of `profile.json`; spawning is stubbed (no `--profile` arg)
- `webhook-diff-filter`: `github_token` sourced from `connections.json` connection entry instead of `profile.json`

## Impact

- `webhook/listener.py` — `resolve_profile_by_repo`, `apply_event_filter`, `_spawn_worker`, `Config`
- `bin/claude-secure` — `cmd_webhook_listener`, `--set-token` handler
- `install.sh` — directory creation
- `tests/test-webhook-listener-cli.sh`, `tests/test-webhook-diff-filter.sh` — fixtures and assertions
- `README.md` — webhook setup documentation
- **No automatic migration**: existing `profile.json` webhook fields remain; users must run `--add-connection` manually (documented in README)
