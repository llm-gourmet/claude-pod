## Why

The webhook subsystem has three structural problems:
1. Two overlapping config stores (`webhook-listener.env` and `/etc/claude-secure/webhook.json`) that drift independently — `--set-bind` and `--set-port` only write the env file, which the listener never reads.
2. A single global `github_token` in `webhook.json` that can't be scoped per-repo — different repos may need different GitHub PATs.
3. `webhook.json` lives in `/etc/` (root-owned) because the systemd service runs as root, forcing the CLI to use `sudo` for every config write and tying webhook config to system-level administration.

## What Changes

- **Config path**: `webhook.json` moves to `~/.claude-secure/webhooks/webhook.json` (user-owned, no sudo needed)
- **systemd service**: Installer writes `User=<installing-user>` into the service unit so the listener runs as the user, not root
- **Single config store**: `--set-bind` and `--set-port` write to `~/.claude-secure/webhooks/webhook.json`; env file (`webhook-listener.env`) is retired entirely
- **Per-repo GitHub token**: `github_token` moves out of `webhook.json` and into each `profile.json`; listener reads it from the resolved profile at request time
- **`listener.py` Config**: picks up `bind` and `port` from `webhook.json`; no longer holds a global `github_token`
- **`resolve_profile_by_repo()`**: returns `github_token` from `profile.json` alongside existing fields
- Remove `_webhook_listener_load_config()` and `_webhook_listener_set_config_key()` from `bin/claude-secure`
- Remove `webhook-listener.env` creation from installer
- Template discovery simplified: `$WEBHOOK_TEMPLATES_DIR` → `/opt/claude-secure/webhook/templates` (drop dev-checkout heuristic and second env var)

## Capabilities

### New Capabilities

_(none — this is a structural refactor with no new user-facing capabilities)_

### Modified Capabilities

- `webhook-listener-cli`: config store changes from `webhook-listener.env` + `/etc/claude-secure/webhook.json` to `~/.claude-secure/webhooks/webhook.json`; `--set-bind`, `--set-port`, `--set-token` all write to the new path without sudo; status reads from the same path

## Impact

- `bin/claude-secure`: remove `_webhook_listener_load_config`, `_webhook_listener_set_config_key`; update `cmd_webhook_listener` to read/write `~/.claude-secure/webhooks/webhook.json` via `jq`; remove sudo fallback from token write
- `webhook/listener.py`: extend `Config.__init__` to read `bind`/`port` from webhook.json; remove `self.github_token`; update `resolve_profile_by_repo()` to return `github_token` from profile.json; update call sites to use `profile["github_token"]`
- `webhook/claude-secure-webhook.service`: installer adds `User=<installing-user>` and updates `--config` path to absolute `~/.claude-secure/webhooks/webhook.json`
- `installer`: create `~/.claude-secure/webhooks/webhook.json` (no `/etc/` file); add `github_token` key to profile scaffold; set `User=` in service unit; remove env file creation
- `tests/test-webhook-listener-cli.sh`: update scenarios WLCLI-01 through WLCLI-06 for new paths
- No breaking CLI flag changes; users must run `--set-token` once per profile after upgrade
