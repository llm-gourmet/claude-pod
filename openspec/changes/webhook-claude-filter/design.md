## Context

The webhook listener (`webhook/listener.py`) currently has two problems:

1. **Dead spawn**: `_spawn_worker` logs `spawn_skipped` and never calls `claude-secure spawn`. The spawn infrastructure (semaphore, thread, event persistence) was built but the actual subprocess call was deferred.

2. **Python filter logic**: `apply_event_filter()`, `has_meaningful_todo_change()`, and `DEFAULT_FILTER` encode business logic (which branches, which file patterns, what constitutes a meaningful diff change) in Python. Every new condition requires a code change + listener redeploy.

The shift: after HMAC verification and repo lookup, always spawn. The spawned Claude Code session receives the event JSON and a system prompt that describes what to do — it acts as the filter and the actor in one step.

## Goals / Non-Goals

**Goals:**
- Wire `_spawn_worker` to call `claude-secure spawn <connection_name> --event-file <path>`
- Remove all Python filter logic from `listener.py` (event type, branch, diff, label, bot-user filters)
- Simplify `connections.json` schema — remove `webhook_event_filter`, `webhook_bot_users`, `todo_path_pattern`
- Maintain HMAC verification and repo lookup (security boundary stays in Python)
- Log spawn outcome (exit code, stdout/stderr to per-delivery log file)

**Non-Goals:**
- Changing how profiles or system prompts are authored (out of scope)
- Removing the semaphore / concurrency limit (stays, protects the host)
- Supporting streaming Claude output from spawned sessions
- Any change to `claude-secure spawn` itself

## Decisions

### D-01: Remove filter logic entirely vs. keep as opt-in

**Decision**: Remove entirely. No `webhook_event_filter`, no `todo_path_pattern`, no `DEFAULT_FILTER`.

**Rationale**: Keeping opt-in fallback filters creates two code paths to maintain and confuses the mental model. The Claude-filter approach is the replacement, not an addition. Connections with existing filter fields have them silently ignored (backward compat at the data level only).

**Alternative considered**: Keep Python filters as an optional fast-path to avoid API costs on clearly irrelevant events. Rejected — adds complexity, and the target repos are low-frequency enough that cost is negligible.

### D-02: What `_spawn_worker` calls

**Decision**: `subprocess.run([config.claude_secure_bin, "spawn", connection_name, "--event-file", str(event_path)], capture_output=True, text=True)`

**Rationale**: `subprocess.run` (blocking within the worker thread) is the simplest correct choice. The semaphore already bounds concurrency. The worker thread is daemon-mode so it doesn't block shutdown. `capture_output=True` lets us write stdout+stderr to a per-delivery log file for debugging.

**Alternative considered**: `subprocess.Popen` (non-blocking). Rejected — the semaphore logic requires knowing when the spawn completes to release the slot. `run` gives us that naturally.

### D-03: Log file location for spawn output

**Decision**: `config.logs_dir / f"spawn-{delivery_id[:12]}.log"` — same logs dir as `webhook.jsonl`.

**Rationale**: Consistent with existing log layout. Short delivery-id prefix keeps filenames readable. Claude session output can be large; per-file keeps `webhook.jsonl` clean.

### D-04: Backward compatibility for existing connections.json entries

**Decision**: Silently ignore `webhook_event_filter`, `webhook_bot_users`, `todo_path_pattern` if present. Do not error or warn.

**Rationale**: Users upgrading from the old behavior should not need to edit their `connections.json` immediately. The fields do nothing but their presence is harmless.

## Risks / Trade-offs

- **Every valid push spawns Claude** → API cost on noise pushes (e.g., README edits). Mitigation: router profile system prompt exits in <1 second for irrelevant events; cost per irrelevant spawn ~$0.001.
- **Non-deterministic filtering** → Claude might occasionally act on an event it should ignore. Mitigation: system prompt design (clear exit conditions) and the fact that spawn sessions are read-only by default.
- **Spawn log growth** → Each spawn creates a log file. Mitigation: `claude-secure reap` already handles stale event files; extend to old spawn logs (separate change).

## Migration Plan

1. Deploy updated `listener.py` — `_spawn_worker` now calls subprocess; filter code removed
2. Restart `claude-secure-webhook` systemd service
3. Create router profile on VPS (`claude-secure profile create obsidian-router`) with system prompt describing filter logic
4. Update connection entry: remove `todo_path_pattern`, `webhook_event_filter`, `webhook_bot_users` if present (optional — ignored either way)
5. Verify with a test push: check `webhook.jsonl` for `spawn_start` / `spawn_done` events
