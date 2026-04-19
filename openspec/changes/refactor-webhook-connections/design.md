## Context

Webhook connections are currently expressed as `profile.json` entries under `~/.claude-secure/profiles/<name>/`. The listener resolves a connection by scanning all profile dirs for a matching `repo` field, then reads `webhook_secret`, `github_token`, `webhook_event_filter`, and `webhook_bot_users` from that same file. This means webhook identity and Claude spawn configuration are fused into a single object.

The docs-bootstrap command (`bin/claude-secure bootstrap-docs`) already demonstrates the target pattern: a JSON array at a fixed path, CRUD via `--add-connection` / `--remove-connection` / `--list-connections`, atomic writes via temp-file rename.

## Goals / Non-Goals

**Goals:**
- Webhook connection data lives exclusively in `~/.claude-secure/webhooks/connections.json`
- `listener.py` resolves connections from `connections.json` only
- CLI supports full CRUD on webhook connections (add, remove, list, set-token)
- Spawn infrastructure kept but stubbed — no `claude-secure spawn` call issued
- Tests and README updated to match new data model

**Non-Goals:**
- Spawning Claude with a profile (separate future change)
- Auto-migrating existing `profile.json` webhook fields
- Changing the HTTP server, HMAC verification, or event filtering logic

## Decisions

### D-01: Connection schema
```json
{
  "name": "myrepo",
  "repo": "org/repo",
  "webhook_secret": "shsec_...",
  "github_token": "",
  "webhook_event_filter": {},
  "webhook_bot_users": []
}
```
`name` and `repo` are required strings. `webhook_secret` is required. The three optional fields default to empty/`{}` when absent. `github_token` replaces the `--set-token` target.

### D-02: `resolve_connection_by_repo` replaces `resolve_profile_by_repo`
`listener.py` reads `connections.json` once per request (same fresh-read-per-request pattern as profile scanning). Returns a dict with the same keys the rest of the handler expects (`name`, `repo`, `webhook_secret`, `github_token`, `webhook_event_filter`, `webhook_bot_users`). No filesystem scan — O(n) linear search over the JSON array.

### D-03: Spawn stub
`_spawn_worker` replaces the `subprocess.Popen` block with:
```python
log_event("spawn_skipped", connection=connection_name, delivery_id=delivery_id)
```
The semaphore, threading, and `spawn_async` wrapper are preserved so the future spawn change is a one-line swap. `spawn_skipped` makes it visible in `webhook.jsonl` for debugging.

### D-04: `--set-token` targets connection by name
`bin/claude-secure webhook-listener --set-token <pat> --name <n>` reads `connections.json`, finds the entry by name, patches `github_token`, and writes back atomically. `--profile` flag is removed. `--name` is required (no single-profile shortcut — that complexity is not worth carrying without profile coupling).

### D-05: CLI helpers mirror docs-bootstrap exactly
`_webhook_connections_file`, `_webhook_read_connections`, `_webhook_write_connections`, `_webhook_find_connection` follow the same bash function pattern as their `_bootstrap_docs_*` counterparts in `bin/claude-secure`. This makes the code predictable and easy to audit.

### D-06: `install.sh` directory creation
`mkdir -p "$CONFIG_DIR/webhooks"` added alongside existing `profiles` and `docs` dirs. No `connections.json` scaffold on install — file is created on first `--add-connection`.

### D-07: `Config` dataclass in `listener.py`
`webhooks_dir` field added; `profiles_dir` and `docs_dir` are no longer used by the connection resolver (kept if needed elsewhere, removed otherwise after audit).

## Risks / Trade-offs

- **Breaking change for existing users**: `profile.json`-based webhooks stop working after update. Mitigated by documenting migration in README and keeping `profile.json` fields in place (listener simply ignores them now).
- **Stub spawn breaks E2E webhook flow**: Acceptable for this change; `spawn_skipped` log makes the gap obvious.
- **Single `connections.json` file**: All webhooks share one file — a corrupt write could affect all connections. Mitigated by atomic temp-file rename (same as docs-bootstrap).

## Migration Plan

1. Run `install.sh` to create `~/.claude-secure/webhooks/`
2. For each existing `profiles/<name>/profile.json` that has `webhook_secret`:
   ```
   claude-secure webhook-listener --add-connection \
     --name <name> --repo <repo> --webhook-secret <secret>
   claude-secure webhook-listener --set-token <github_token> --name <name>
   ```
3. Restart `claude-secure-webhook.service`
4. Verify with `claude-secure webhook-listener --list-connections`

Rollback: revert binary, restart service — `profile.json` files are untouched.
