# Phase 16 — Deferred Items (Out-of-Scope Discoveries)

Items discovered during Phase 16 execution that are NOT caused by Phase 16 changes.
These are out-of-scope and must be addressed by a future phase or dedicated fix.

## Pre-existing failures observed

### Phase 14: `test_unit_file_parses` fails against unmodified HEAD
- **Suite:** `tests/test-phase14.sh`
- **Result:** 15/16 passed, 1 failed (`FAIL: unit file parses`)
- **Reproduced with bin/claude-secure stashed to HEAD** — failure is pre-existing,
  not caused by 16-02 edits.
- **Discovered during:** 16-02 Task 1 regression sweep
- **Scope:** Out of Phase 16 scope. Log and continue.
