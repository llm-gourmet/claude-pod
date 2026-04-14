---
phase: 26-stop-hook-mandatory-reporting
plan: "03"
subsystem: spool-shipper
tags: [spool, async, background-fork, audit, bash]
dependency_graph:
  requires: ["26-01", "26-02"]
  provides: ["run_spool_shipper", "run_spool_shipper_inline", "_spool_shipper_loop", "_spool_audit_write"]
  affects: ["bin/claude-secure", "tests/test-phase26.sh"]
tech_stack:
  added: []
  patterns: ["fork-and-disown async background worker", "tempfile-based exit-code capture for pipe-safety", "jq if/else/end for optional object fields"]
key_files:
  created: []
  modified:
    - bin/claude-secure
    - tests/test-phase26.sh
decisions:
  - "Used tempfile pattern in _spool_shipper_loop instead of $(...|tail -1) to correctly capture publish_docs_bundle exit code without pipefail dependency"
  - "Fixed jq select() in object context bug: use if/else/end not select() to emit optional fields — select returns empty which makes the parent object invalid"
  - "Defined mock publish_docs_bundle AFTER sourcing bin/claude-secure (not before) so source cannot overwrite the mock"
  - "Used __CLAUDE_SECURE_SOURCE_ONLY=1 in test subshells to prevent the interactive dispatch block from executing during source"
metrics:
  duration: "~25min"
  completed: "2026-04-14"
  tasks: 2
  files: 2
---

# Phase 26 Plan 03: Spool Shipper Implementation Summary

Host-side async spool shipper with fork-and-disown pattern, 3-attempt jittered retry, and separate `spool-audit.jsonl` audit writer — wired into both headless do_spawn and interactive spawn paths.

## What Was Built

Four new bash functions inserted at `bin/claude-secure:1646` (immediately before `publish_docs_bundle`):

| Function | Line | Purpose |
|----------|------|---------|
| `run_spool_shipper` | 1646 | Background fork entrypoint; honors CLAUDE_SECURE_SKIP_SPOOL_SHIPPER escape hatch |
| `run_spool_shipper_inline` | 1671 | Synchronous drain entrypoint (Plan 04 stale-drain use) |
| `_spool_shipper_loop` | 1687 | Shared retry body: 3 attempts with jittered backoff |
| `_spool_audit_write` | 1731 | Writes to separate `spool-audit.jsonl` (not executions.jsonl) |

Two call sites added:

| Site | Line | Session ID Source |
|------|------|-------------------|
| `do_spawn` headless path | 2383 | `${_audit_session:-unknown}` (Claude session UUID) |
| Interactive `*)` dispatch | 2983 | `$(uuidgen ... || echo "manual-$$")` |

## Shipper Retry/Jitter Math

The `_spool_shipper_loop` uses attempt 0-indexed delay (delay computed before incrementing):

```
attempt 0: delay = 0s (no sleep before first try)
attempt 1: delay = 5 + RANDOM%5-2 = 5 ± 2s (range: 3-7s)
attempt 2: delay = 10 + RANDOM%5-2 = 10 ± 2s (range: 8-12s)
```

Worked example with RANDOM=3 (jitter=+1):
- Attempt 1 (index 0): immediate → success? return 0
- Attempt 2 (index 1): sleep 6s → success? return 0
- Attempt 3 (index 2): sleep 11s → final failure → audit push_failed, return 1

## Test Results

All 15 Phase 26 tests pass after Plan 03:

```
Wave 0 (fixtures): 2/2 PASS
Wave 1 (stop-hook): 7/7 PASS
Wave 2 (spool shipper): 5/5 PASS  ← Plan 03 target
Wave 3 (spawn integration): 1/1 PASS  ← grep-only check; full integration in Plan 04
```

Phase 24 regression: 13/13 PASS
Phase 25 regression: 15/15 PASS

## Remaining RED Tests

`test_stale_spool_drained_at_spawn_preamble` passes at grep level (function exists in file) but the actual spawn-preamble call site is Plan 04's scope. Plan 04 must add `run_spool_shipper_inline` call to `do_spawn` preamble and interactive `*)` path to satisfy D-07.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed jq `select()` in object context**
- **Found during:** Task 1 debugging
- **Issue:** The `_spool_audit_write` function used `($field | select(length > 0))` as an object value. When `select` returns nothing (empty input), the entire `jq -cn` object expression produces no output — the JSONL line is never written.
- **Fix:** Replaced with `(if ($field | length) > 0 then $field else null end)` which always produces a value.
- **Files modified:** `bin/claude-secure`
- **Commit:** fbb96d1

**2. [Rule 1 - Bug] Test pattern: mock defined before source was overwritten**
- **Found during:** Task 1 test debugging
- **Issue:** Tests that defined `publish_docs_bundle()` before `source bin/claude-secure` had the mock overwritten by the source. Tests appeared to call real publish_docs_bundle.
- **Fix:** Moved mock definitions to AFTER `source bin/claude-secure` in all test subshells. Also used `export __CLAUDE_SECURE_SOURCE_ONLY=1` to prevent the dispatch block from executing.
- **Files modified:** `tests/test-phase26.sh`
- **Commit:** fbb96d1

## Known Stubs

None. All four functions are fully implemented. Call sites are wired. Test assertions are real (not sentinels).

## Self-Check: PASSED

Created files:
- N/A (no new files created)

Modified files:
- bin/claude-secure: FOUND (2 tasks worth of changes)
- tests/test-phase26.sh: FOUND

Commits:
- fbb96d1: feat(26-03): implement run_spool_shipper family + real Wave 2 test assertions
- 74df45d: feat(26-03): wire run_spool_shipper into do_spawn and interactive spawn paths
