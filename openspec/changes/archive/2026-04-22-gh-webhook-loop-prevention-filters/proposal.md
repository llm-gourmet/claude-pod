## Why

When claude-secure acts on a GitHub event (commits, comments, labels), it can trigger new webhook deliveries and re-spawn itself — creating an infinite loop. The listener currently spawns Claude unconditionally after HMAC verification. A minimal filter layer before the spawn decision prevents loops without requiring Claude to self-manage re-entrancy.

## What Changes

- `webhook/listener.py` gains per-event filter evaluation before spawning; matching events are skipped and logged
- `connections.json` schema gains a `skip_filters` array field per connection
- CLI gains `filter add`, `filter list`, `filter remove` subcommands under `gh-webhook-listener`
- `filter add` output explains which event types the filter applies to and via which mechanism
- New test file `tests/test-gh-webhook-listener-filter-cli.sh` covers CLI commands
- `tests/test-webhook-spawn.sh` gains scenarios for filter-based skip
- README updated with filter usage examples

## Capabilities

### New Capabilities

- `gh-webhook-filter-cli`: CLI subcommands to manage per-connection skip filters (add, list, remove)
- `gh-webhook-filter-eval`: Listener-side filter evaluation before spawn — skips event and logs when a filter matches

### Modified Capabilities

- `webhook-connections`: `connections.json` schema gains optional `skip_filters: string[]` field per connection
- `webhook-spawn-always`: Spawn is no longer unconditional — filter evaluation runs first; non-matching events still spawn as before

## Impact

- `webhook/listener.py`: filter evaluation added to request handler, new `skipped` log event type
- `bin/claude-secure`: new `filter` subcommand group under `gh-webhook-listener`
- `~/.claude-secure/webhooks/connections.json`: new optional `skip_filters` field
- `tests/test-gh-webhook-listener-filter-cli.sh`: new file
- `tests/test-webhook-spawn.sh`: new filter-skip scenarios
- `README.md`: filter usage section
