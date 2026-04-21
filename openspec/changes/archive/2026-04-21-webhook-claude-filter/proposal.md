## Why

The webhook listener's Python filter logic (`apply_event_filter`, `has_meaningful_todo_change`, `DEFAULT_FILTER`) encodes business decisions in code — every new condition requires a code change, a redeploy, and understanding of Python. Claude Code is a capable decision-making agent; moving filter logic into system prompts makes it configurable in natural language, profile-specific, and updatable without touching the listener.

## What Changes

- **BREAKING** Remove `apply_event_filter()` and `DEFAULT_FILTER` from `listener.py` — no more Python-based event filtering
- **BREAKING** Remove `has_meaningful_todo_change()` and `fetch_commit_patch()` diff-filter from `listener.py`
- **BREAKING** Remove `todo_path_pattern`, `webhook_event_filter`, `webhook_bot_users` fields from `connections.json` schema (fields ignored if present for backward compat)
- Wire `_spawn_worker` to actually call `claude-secure spawn <connection_name> --event-file <path>` (currently logs `spawn_skipped` — placeholder never implemented)
- After HMAC verification and repo lookup, spawn unconditionally for all valid push/issue/workflow_run events
- Claude Code (via the connection's profile system prompt) evaluates the event JSON and decides whether to act or exit cleanly

## Capabilities

### New Capabilities
- `webhook-spawn-always`: After HMAC verification and repo lookup, the listener spawns unconditionally. No event type filtering, no diff inspection, no branch gating in Python. `_spawn_worker` calls `claude-secure spawn` with the persisted event file.

### Modified Capabilities
- `webhook-connections`: Remove `webhook_event_filter`, `webhook_bot_users`, and `todo_path_pattern` from the required/optional schema. Connection entry becomes: `name`, `repo`, `webhook_secret`, `github_token` (optional, for Claude's use in the spawned session).
- `webhook-diff-filter`: Spec is superseded — diff filtering moves into Claude's system prompt reasoning, not the listener. Spec marked as removed.

## Impact

- `webhook/listener.py`: Remove ~120 lines of filter logic; simplify `do_POST` path; implement `_spawn_worker` subprocess call
- `~/.claude-secure/webhooks/connections.json`: Schema simplification (3 fields removed)
- `claude-secure webhook-listener --add-connection`: No longer accepts `--event-filter` flags (if any were planned)
- Operational: every valid push to a registered repo now triggers a spawn — users need a router profile with a system prompt that exits cleanly for irrelevant events
- Cost: API calls on every matched push (not just filtered ones) — acceptable for low-frequency repos
