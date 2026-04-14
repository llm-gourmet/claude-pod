---
phase: 26-stop-hook-mandatory-reporting
plan: "04"
subsystem: spool-shipper
tags: [spool, stale-drain, preamble, readme, bash]
dependency_graph:
  requires: ["26-01", "26-02", "26-03"]
  provides: ["stale-spool drain at spawn preamble (D-07)", "README Mandatory Reporting section"]
  affects: ["bin/claude-secure", "README.md"]
tech_stack:
  added: []
  patterns: ["preamble drain call before fetch_docs_context", "non-fatal synchronous drain with || true guard"]
key_files:
  created: []
  modified:
    - bin/claude-secure
    - README.md
decisions:
  - "Drain call placed BEFORE fetch_docs_context in do_spawn headless preamble (line 2229 precedes 2239) — ensures stale spool cleared before new session context is loaded"
  - "Drain call placed AFTER mkdir -p LOG_DIR + chmod in interactive preamble (line 2975) — LOG_DIR guaranteed to exist for shipper audit writes"
  - "Both call sites use || true guard even though run_spool_shipper_inline itself always returns 0 — defense in depth"
  - "README Mandatory Reporting section placed between Phase 17 / Operational Hardening and Testing (mirror Phase 16-04 / 17-04 placement pattern)"
  - "README section contains zero D-IDs, zero SPOOL requirement IDs, no internal API field names"
metrics:
  duration: "~15min"
  completed: "2026-04-14"
  tasks: 2
  files: 2
---

# Phase 26 Plan 04: Stale-Spool Drain + README Documentation Summary

Phase 26 closure: D-07 stale-spool drain wired into both spawn preambles (headless and interactive) so crashed-session leftovers self-heal at next spawn. README documents mandatory reporting end-to-end for operators.

## What Was Built

### Task 1: Stale-spool drain call sites

Two `run_spool_shipper_inline` call sites added to `bin/claude-secure`:

| Site | Line | Location | Relative to |
|------|------|----------|-------------|
| Headless do_spawn preamble | 2229 | `do_spawn()` | Before `if ! fetch_docs_context` (line 2239) |
| Interactive star-dispatch preamble | 2975 | `*)` case | After `chmod 777 "$LOG_DIR"`, before `cleanup_containers` |

Both call sites follow the D-07 comment header pattern and use the `drain-$$` fallback session ID as specified in 26-RESEARCH.md.

### Task 2: README Mandatory Reporting section

New `## Mandatory Reporting` section inserted in README.md between the Phase 17 Operational Hardening section and `## Testing`. Covers:

1. Spool file path (`/var/log/claude-secure/spool.md` container, `$LOG_DIR/spool.md` host)
2. Six required report sections (Goal, Where Worked, What Changed, What Failed, How to Test, Future Findings)
3. Shipper retry behavior (3-attempt jittered backoff, success deletes spool)
4. `spool-audit.jsonl` observability file with copy-pasteable `tail -f | jq` command
5. Stuck-spool recovery via preamble drain self-heal

## Test Results

### Phase 26 full suite (15/15 PASS — first time GREEN)

```
Wave 0 (fixtures): 2/2 PASS
Wave 1 (stop-hook): 7/7 PASS
Wave 2 (spool shipper): 5/5 PASS
Wave 3 (spawn integration): 1/1 PASS  -- test_stale_spool_drained_at_spawn_preamble
```

### Regression suites

- Phase 24: 13/13 PASS
- Phase 25: 15/15 PASS

## Phase 26 Closure Summary

| Requirement | Status | Evidence |
|-------------|--------|----------|
| SPOOL-01 | CLOSED | Stop hook blocks exit when spool missing; re-prompts once via `stop_hook_active` guard |
| SPOOL-02 | CLOSED | Stop hook makes zero network calls; DNS-failure integration test GREEN |
| SPOOL-03 | CLOSED | Async fork-and-disown shipper with 3-attempt jittered retry; stale drain at preamble for crash recovery |

### Manual-only verifications (from 26-VALIDATION.md)

| Behavior | Status |
|----------|--------|
| Stop hook fires in live container + re-prompts Claude | Pending operator sign-off |
| Fork-and-disown shipper survives `docker compose down` | Pending operator sign-off |

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None. All call sites are fully wired. README documentation is complete.

## Self-Check: PASSED

Modified files:
- bin/claude-secure: FOUND — 2 new run_spool_shipper_inline call sites at lines 2229 and 2975
- README.md: FOUND — ## Mandatory Reporting section between Phase 17 and Testing

Commits:
- 059b26c: feat(26-04): add stale-spool drain call sites to spawn preamble (D-07)
- e190156: docs(26-04): add Mandatory Reporting section to README.md
