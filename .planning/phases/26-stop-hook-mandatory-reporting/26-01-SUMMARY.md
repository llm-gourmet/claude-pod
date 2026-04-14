---
phase: 26-stop-hook-mandatory-reporting
plan: "01"
subsystem: tests
tags: [wave-0, tdd, spool, stop-hook, test-scaffold, nyquist]
dependency_graph:
  requires: []
  provides:
    - "tests/test-phase26.sh (Wave 0 RED harness for SPOOL-01/02/03)"
    - "tests/fixtures/profile-26-spool/ (fixture profile)"
    - "tests/fixtures/spools/ (valid + broken bundle fixtures)"
    - "tests/fixtures/stop-hook-inputs/ (Stop hook stdin JSON fixtures)"
    - "tests/test-map.json (SPOOL-01/02/03 routing entries)"
  affects:
    - "tests/test-map.json (claude/, bin/claude-secure, claude/settings.json mappings updated)"
tech_stack:
  added: []
  patterns:
    - "Wave 0 RED-before-GREEN Nyquist pattern (mirrors Phase 12-17, 24-25)"
    - "TEST_SPOOL_FILE_OVERRIDE env var testability contract for stop-hook.sh (Plan 02)"
    - "CLAUDE_SECURE_SKIP_SPOOL_SHIPPER env var for shipper unit tests (Plan 03)"
    - "MOCK_PUBLISH_BUNDLE_EXIT stub pattern for publish_docs_bundle (Plan 03)"
key_files:
  created:
    - tests/test-phase26.sh
    - tests/fixtures/profile-26-spool/profile.json
    - tests/fixtures/profile-26-spool/.env
    - tests/fixtures/profile-26-spool/whitelist.json
    - tests/fixtures/spools/valid-bundle.md
    - tests/fixtures/spools/broken-missing-section.md
    - tests/fixtures/stop-hook-inputs/active-false.json
    - tests/fixtures/stop-hook-inputs/active-true.json
    - tests/fixtures/stop-hook-inputs/malformed.json
  modified:
    - tests/test-map.json
decisions:
  - "Force-added tests/fixtures/profile-26-spool/.env with git add -f (gitignored by .gitignore, consistent with profile-e2e pattern)"
  - "15 test functions created (14+ required): extra test is test_stale_spool_drained_at_spawn_preamble (Plan 04 integration)"
  - "test_test_map_registered uses jq contains() query rather than CTX-style key check since plan adds SPOOL-01/02/03 keys"
metrics:
  duration: "~5min"
  completed: "2026-04-14"
  tasks_completed: 3
  files_changed: 10
---

# Phase 26 Plan 01: Wave 0 RED Test Scaffold Summary

Wave 0 RED test harness for Phase 26 stop-hook mandatory reporting — 15 failing test stubs encoding SPOOL-01/02/03 contract before any production code exists.

## What Was Built

### Task 1: Fixtures (8 files)

All 8 fixture files created under `tests/fixtures/`:

| File | Purpose |
|------|---------|
| `profile-26-spool/profile.json` | Fixture profile with empty `docs_repo` (test rewrites to file:// bare) |
| `profile-26-spool/.env` | DOCS_REPO_TOKEN + REPORT_REPO_TOKEN (Phase 23 alias back-fill) |
| `profile-26-spool/whitelist.json` | Minimal secrets/readonly_domains (copied from profile-25-docs) |
| `spools/valid-bundle.md` | 6 mandatory H2 sections for shipper success path tests |
| `spools/broken-missing-section.md` | 5 sections (missing Future Findings) for best-effort publish test (D-04) |
| `stop-hook-inputs/active-false.json` | Stop hook stdin with `stop_hook_active: false` |
| `stop-hook-inputs/active-true.json` | Stop hook stdin with `stop_hook_active: true` (infinite-loop guard test) |
| `stop-hook-inputs/malformed.json` | Intentionally invalid JSON (`this is not json{`) for Pitfall 6 fallback |

### Task 2: Test Harness (tests/test-phase26.sh)

15 test functions registered via `run_test`:

**Structural (PASS in Wave 0):**
1. `test_fixtures_exist` — validates all 8 fixture files
2. `test_test_map_registered` — asserts test-map.json routes to test-phase26.sh

**Stop Hook contract (FAIL until Plan 02):**
3. `test_stop_hook_script_exists` — claude/hooks/stop-hook.sh exists and is executable
4. `test_stop_hook_yields_when_spool_present` — hook exits 0 when spool.md exists
5. `test_stop_hook_reprompts_when_spool_missing` — block decision + 6 H2 section names in reason
6. `test_stop_hook_yields_on_stop_hook_active_true` — `stop_hook_active=true` always yields (loop guard)
7. `test_stop_hook_no_network_calls` — grep for curl/wget/nslookup/etc. (SPOOL-02)
8. `test_stop_hook_handles_malformed_stdin` — hook does not crash on invalid JSON stdin
9. `test_settings_json_has_stop_hook` — claude/settings.json has Stop hook registration

**Shipper contract (FAIL until Plan 03):**
10. `test_run_spool_shipper_function_exists` — `run_spool_shipper` in bin/claude-secure
11. `test_shipper_returns_immediately` — wall-clock < 1s with slow stub (disown pattern)
12. `test_shipper_deletes_spool_on_success` — spool.md deleted after successful publish
13. `test_shipper_logs_push_failed_with_attempt` — audit JSONL has push_failed + attempt=3
14. `test_shipper_publishes_malformed_best_effort` — broken bundle deleted on success (D-04)

**Integration (FAIL until Plan 04):**
15. `test_stale_spool_drained_at_spawn_preamble` — `run_spool_shipper_inline` in do_spawn preamble

### Task 3: test-map.json Registration

Added mappings:
- `claude/` → test-phase26.sh (appended to existing)
- `claude/hooks/` → test-phase26.sh (new specific entry)
- `claude/settings.json` → test-phase26.sh (new entry)
- `bin/claude-secure` → test-phase26.sh (appended to existing)
- Fixture paths → test-phase26.sh
- `SPOOL-01`, `SPOOL-02`, `SPOOL-03` requirement entries with full test lists

## RED State Confirmation

```
Phase 26 tests: 2 passed, 13 failed, 15 total
EXIT: 1 (non-zero — RED state confirmed)
```

Structural tests GREEN: `test_fixtures_exist`, `test_test_map_registered`
All implementation tests RED — Plans 02, 03, 04 have objective red-to-green signal.

## Testability Contracts for Plans 02/03/04

| Env Var | Used By | Contract |
|---------|---------|---------|
| `TEST_SPOOL_FILE_OVERRIDE` | stop-hook.sh (Plan 02) | If set, hook uses this path as `$SPOOL_FILE` instead of `/var/log/claude-secure/spool.md` |
| `CLAUDE_SECURE_SKIP_SPOOL_SHIPPER` | run_spool_shipper (Plan 03) | If `=1`, function returns 0 immediately without forking |
| `MOCK_PUBLISH_BUNDLE_EXIT` | shipper tests (Plan 03) | Tests define `publish_docs_bundle()` stub before sourcing bin/claude-secure; `0`=success, `1`=failure |

## Deviations from Plan

None — plan executed exactly as written.

**Note:** `tests/fixtures/profile-26-spool/.env` is gitignored by default. Used `git add -f` to force-add it — consistent with the `tests/fixtures/profile-e2e/.env` precedent in this project (Phase 17).

## Commits

| Hash | Message |
|------|---------|
| `574f430` | `test(26-01): add Wave 0 fixtures for Phase 26 stop-hook spool` |
| `134ddb5` | `test(26-01): add Wave 0 RED test harness for Phase 26 stop-hook spool` |
| `51516fd` | `test(26-01): register test-phase26.sh in test-map.json` |

## Self-Check: PASSED

All created files exist on disk. All 3 task commits confirmed in git log.
