## Context

`do_spawn` in `bin/claude-secure` builds the Claude human-turn prompt by reading a task file (`tasks/<event_type>.md`) and passing it verbatim as the first argument to `claude -p`. The full event JSON is already in `$EVENT_JSON` (read from `--event-file` at line 1341), but it is only used for metadata extraction — it never reaches Claude.

The fix is a two-line append: after `rendered_prompt=$(cat "$task_file")`, concatenate a fenced JSON block containing `$EVENT_JSON`. Bootstrap stubs in `create_profile()` are updated so new profiles get meaningful starting task files that demonstrate how to use the payload.

## Goals / Non-Goals

**Goals:**
- Every spawn call passes the full event JSON to Claude in the human turn
- New-profile stubs show useful examples (not just `# TODO`)
- `--dry-run` output includes the appended payload block
- No change to how Claude receives the prompt structurally — it's still a single string

**Non-Goals:**
- Template variable substitution (`{{COMMITS_JSON}}` etc.) — the full JSON covers all use cases; per-field tokens are a separate concern (`commits-json-token` spec)
- Filtering or trimming the payload before appending
- Any change to the system prompt path

## Decisions

**Append unconditionally when `$EVENT_JSON` is non-empty**
Guard: `if [ -n "$EVENT_JSON" ]`. Spawns triggered without `--event` or `--event-file` (manual / test) don't append anything. Webhook-triggered spawns always have `$EVENT_JSON` set.

**Format: markdown fenced block with `json` language tag**
```
---
Event Payload (`<event_type>`):
```json
{ ... }
```
```
Claude parses fenced blocks reliably. The event_type label orients Claude immediately without requiring it to inspect `event_type` from the JSON itself.

**Append after task content, before `claude_args` construction (line 1441)**
Insertion point: between `rendered_prompt=$(cat "$task_file")` (line 1406) and `local claude_args=(...)` (line 1441). The system prompt path is untouched.

**Update `--dry-run` output**
`--dry-run` currently prints `$rendered_prompt` (line 1424). After the append, it naturally includes the payload block. No separate change needed.

**Update stubs in `create_profile()` — not as a migration**
Existing profiles keep their existing task files. Only new profiles created after this change get the updated stubs. The stubs explain the payload block and show jq-style usage hints.

## Risks / Trade-offs

- [Large payloads (e.g. push with many commits) increase token cost] → Acceptable; Claude needs the data. The payload is already persisted to disk for other uses.
- [Existing task files that end with content Claude might misread near the separator] → The `---` + labeled fenced block is unambiguous; Claude won't confuse it with task instructions.
- [Test suites that check exact prompt content] → Tests that assert `rendered_prompt` content will need updating if they check end-of-string. Tests using `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` are unaffected.
