## Context

The listener currently spawns Claude for every valid event (per `webhook-spawn-always` spec). When claude-secure creates GitHub artifacts (commits, comments, labels), GitHub fires new webhook deliveries, which re-spawn Claude — loop. The fix must be minimal: one filter check per event, no new dependencies, no behavioral change for non-matching events.

## Goals / Non-Goals

**Goals:**
- Filter evaluation in `listener.py` before `_spawn_worker` is called
- Per-connection `skip_filters` array in `connections.json`
- CLI to manage filters (add/list/remove) with informative feedback
- Structured log entry when a filter skips a spawn

**Non-Goals:**
- Complex regex or JSONPath filter expressions — exact prefix/label match only
- Per-event-type filter configuration — one filter value applies across all applicable event types automatically
- Retroactive filtering of already-persisted event files
- Any change to spawn behavior when no filter matches

## Decisions

**Filter evaluation in listener.py, not spawn subprocess**
The spawn subprocess has no mechanism to abort a spawn that has already started. Filtering before `_spawn_worker` is cheaper and keeps the "spawn means run" invariant clean.

**One filter value → auto-mapped to applicable mechanisms**
Rather than requiring users to configure separate filters per event type, a single value is applied as: commit prefix (push), label match (PR/issues/discussion), body prefix (comments/reviews). Events with no free-text field are unaffected. This is simpler and matches the use case: `[skip-claude]` is the marker, not a per-event-type rule.

**Filter match condition for push: ALL commits must match**
If only some commits match, there are legitimate commits in the push. Spawn to process them; Claude reads git and decides what to do. Skipping only when ALL commits match avoids missed work.

**`skip_filters` stored in connections.json**
Filters are per-connection (different repos may have different conventions). Reusing the existing connections.json avoids a new config file and stays consistent with the current data model.

**No filter names — values only**
Filters are short strings. A name layer adds complexity for no benefit at this scale.

## Risks / Trade-offs

- [Push with mixed commits: one skip-tagged, one legitimate] → Only skip if ALL commits match — legitimate commit still spawns Claude. Claude sees the full push via git.
- [Label-based filter requires exact match] → Case-sensitive exact match is predictable and consistent with GitHub label behavior.
- [filter add on a push event for a body-only marker] → CLI feedback explicitly shows "not applicable" for events where the filter cannot fire — user knows what they're getting.
- [connections.json read on every request in listener.py] → Already the pattern (fresh read per request for webhook_secret). Adding skip_filters to the same read has no additional I/O cost.

## Migration Plan

1. Add `skip_filters` field handling to `listener.py` request handler (after HMAC + repo lookup, before `_spawn_worker`)
2. Add filter evaluation helper function with event-type dispatch table
3. Add CLI `filter` subcommand group to `bin/claude-secure`
4. Add tests
5. Commit with `[skip-claude]` prefix
