## 1. listener.py — Config reads bind/port from webhook.json; github_token from profile

- [x] 1.1 In `Config.__init__`, add `self.bind = data.get("bind", "127.0.0.1")` and `self.port = int(data.get("port", 9000))`
- [x] 1.2 Remove `self.github_token` from `Config.__init__` (no longer in webhook.json)
- [x] 1.3 Replace hard-coded `127.0.0.1` / `9000` in server startup with `cfg.bind` / `cfg.port`
- [x] 1.4 In `resolve_profile_by_repo()`, add `"github_token": data.get("github_token", "")` to the returned dict
- [x] 1.5 In `has_meaningful_todo_change()` (line ~162), replace `config.github_token` with `profile.get("github_token", "")` — `profile` is already in scope at that call site
- [x] 1.6 Verify listener starts with a webhook.json that has no `github_token` key and no bind/port defaults

## 2. bin/claude-secure — retire env file helpers, write webhook.json directly

- [x] 2.1 Remove `_webhook_listener_set_config_key()` function
- [x] 2.2 Remove `_webhook_listener_load_config()` function
- [x] 2.3 Define `WEBHOOK_JSON="${WEBHOOK_CONFIG:-$HOME/.claude-secure/webhooks/webhook.json}"` at the top of `cmd_webhook_listener()`
- [x] 2.4 Replace `--set-token` handler: write `github_token` to `~/.claude-secure/profiles/<name>/profile.json` via `jq` (atomic write-then-move); require `--profile` flag or auto-select if only one profile exists
- [x] 2.5 Replace `--set-bind` handler: atomic `jq` write of `bind` key to `$WEBHOOK_JSON` (no sudo)
- [x] 2.6 Replace `--set-port` handler: atomic `jq --argjson` write of `port` as number to `$WEBHOOK_JSON`
- [x] 2.7 In status path, replace `_webhook_listener_load_config` call with `jq` reads from `$WEBHOOK_JSON` for bind/port
- [x] 2.8 Remove sudo fallback from all webhook config writes (no longer needed)

## 3. systemd service unit — add User=, update --config path

- [x] 3.1 In `webhook/claude-secure-webhook.service`, add `User=` and `Group=` placeholder lines (e.g., `User=__WEBHOOK_USER__`)
- [x] 3.2 In installer, substitute `__WEBHOOK_USER__` with `$(id -un)` and update `ExecStart --config` path to `$(realpath ~)/.claude-secure/webhooks/webhook.json`
- [x] 3.3 After writing the unit file, run `sudo systemctl daemon-reload`
- [x] 3.4 Verify service starts and `systemctl show claude-secure-webhook --property=User` shows the correct user

## 4. Installer — new config path, profile scaffold, retire /etc/ file

- [x] 4.1 Create `~/.claude-secure/webhooks/` directory (mode 700) and write `webhook.json` with keys: `bind`, `port`, `max_concurrent_spawns`, `profiles_dir`, `events_dir`, `logs_dir`, `claude_secure_bin`, `config_dir` (no `github_token`)
- [x] 4.2 Remove creation of `/etc/claude-secure/webhook.json` from `--with-webhook` install path
- [x] 4.3 Remove creation of `webhook-listener.env` from install path
- [x] 4.4 Add `github_token` key (empty string) to the profile.json scaffold written for new profiles
- [x] 4.5 Verify clean install creates `~/.claude-secure/webhooks/webhook.json` and service unit with correct `User=`

## 5. Template discovery — simplify fallback chain

- [x] 5.1 In `bin/claude-secure`, locate the template discovery block
- [x] 5.2 Simplify to: `${WEBHOOK_TEMPLATES_DIR:-/opt/claude-secure/webhook/templates}`; remove `$WEBHOOK_REPORT_TEMPLATES_DIR` and dev-checkout heuristic
- [x] 5.3 Update README webhook section to document `$WEBHOOK_TEMPLATES_DIR` as the override variable

## 6. Tests — update for new paths and --set-token behavior

- [x] 6.1 In `tests/test-webhook-listener-cli.sh`, update WLCLI-01 (set-token): assert `github_token` written to `profile.json`, not env file
- [x] 6.2 Update WLCLI-02 (set-bind): assert `bind` written to `~/.claude-secure/webhooks/webhook.json`
- [x] 6.3 Update WLCLI-03 (set-port): assert `port` as number in `webhook.json`
- [x] 6.4 Update WLCLI-04 (preserves other keys): assert preservation in `webhook.json`
- [x] 6.5 Update WLCLI-05 (token redacted): no behavior change, confirm still passes
- [x] 6.6 Update WLCLI-06 (status no config): assert missing `~/.claude-secure/webhooks/webhook.json` triggers message
- [x] 6.7 Add WLCLI-09: `--set-token` without `--profile` when multiple profiles exist → non-zero exit with profile list
- [x] 6.8 Run full test suite: `bash tests/test-webhook-listener-cli.sh` — all tests pass

## 7. README — update host file locations table

- [x] 7.1 Update "Host file locations" table: change `/etc/claude-secure/webhook.json` entry to `~/.claude-secure/webhooks/webhook.json` with owner `user` and correct purpose
- [x] 7.2 Update Webhook Listener "Configuration" section: remove sudo note, update paths
- [x] 7.3 Update `--set-token` description to mention `--profile` requirement
