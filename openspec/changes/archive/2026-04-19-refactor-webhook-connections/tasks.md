## 1. install.sh — directory creation

- [x] 1.1 Add `mkdir -p "$CONFIG_DIR/webhooks"` and `chmod 700 "$CONFIG_DIR/webhooks"` alongside the existing `profiles` and `docs` dir creation

## 2. bin/claude-secure — connection helpers

- [x] 2.1 Add `_webhook_connections_file`: returns `$CONFIG_DIR/webhooks/connections.json`
- [x] 2.2 Add `_webhook_read_connections`: reads file or echoes `[]` if absent
- [x] 2.3 Add `_webhook_write_connections`: atomic temp-file + rename + chmod 600 write
- [x] 2.4 Add `_webhook_find_connection`: finds entry by name, errors if not found

## 3. bin/claude-secure — webhook-listener CRUD verbs

- [x] 3.1 Add `--add-connection` handler: validates `--name`, `--repo`, `--webhook-secret` required; rejects duplicate names; writes new entry via `_webhook_write_connections`
- [x] 3.2 Add `--remove-connection <name>` handler: errors if name not found; removes entry and rewrites
- [x] 3.3 Add `--list-connections` handler: prints `name  repo` per line, no secret/token; prints `No connections configured.` if empty

## 4. bin/claude-secure — --set-token migration

- [x] 4.1 Remove `--profile` flag handling from `--set-token`
- [x] 4.2 Add `--name` flag requirement to `--set-token`
- [x] 4.3 Rewrite `--set-token` body: find connection by `--name` in `connections.json`, patch `github_token`, write back atomically

## 5. webhook/listener.py — connection resolver

- [x] 5.1 Add `webhooks_dir` field to `Config.__init__`: `self.webhooks_dir = pathlib.Path(data["webhooks_dir"]) if data.get("webhooks_dir") else None`
- [x] 5.2 Add `resolve_connection_by_repo(webhooks_dir, repo_full_name)`: reads `connections.json`, returns matching dict or `None`
- [x] 5.3 Replace `resolve_profile_by_repo` call in `do_POST` with `resolve_connection_by_repo`; update 404 log message

## 6. webhook/listener.py — spawn stub

- [x] 6.1 In `_spawn_worker`: replace `subprocess.Popen(["claude-secure", "spawn", ...])` block with `log_event("spawn_skipped", connection=connection_name, delivery_id=delivery_id)`
- [x] 6.2 Ensure semaphore acquire/release and `_active_spawns` counter are preserved around the stub

## 7. webhook/config.example.json

- [x] 7.1 Add `"webhooks_dir": "__REPLACED_BY_INSTALLER__WEBHOOKS__"` field
- [x] 7.2 Add `sed` replacement in `install.sh` for `__REPLACED_BY_INSTALLER__WEBHOOKS__` → `${invoking_home}/.claude-secure/webhooks`

## 8. Tests — test-webhook-listener-cli.sh

- [x] 8.1 Replace `WLCLI-01: --set-token writes github_token to profile.json` test with `WLCLI-01: --set-token writes github_token to connections.json` (fixture: pre-populate `connections.json` with a named entry, assert `github_token` in that entry after `--set-token`)
- [x] 8.2 Add `WLCLI-02: --add-connection creates connections.json` test
- [x] 8.3 Add `WLCLI-03: --remove-connection removes named entry` test
- [x] 8.4 Add `WLCLI-04: --list-connections omits secret and token` test
- [x] 8.5 Add `WLCLI-05: --add-connection rejects duplicate name` test

## 9. Tests — test-webhook-diff-filter.sh

- [x] 9.1 Update fixture setup: populate `connections.json` with test connection (including `github_token`) instead of `profile.json`
- [x] 9.2 Assert `github_token` absent from event file (still valid, source has moved)

## 10. README

- [x] 10.1 Document `~/.claude-secure/webhooks/connections.json` format with field descriptions
- [x] 10.2 Document CLI verbs: `--add-connection`, `--remove-connection`, `--list-connections`, `--set-token --name`
- [x] 10.3 Add manual migration steps from `profile.json` webhook fields to `connections.json`
- [x] 10.4 Note that spawn is currently stubbed; link to future spawn-profile change
