---
phase: 26-stop-hook-mandatory-reporting
plan: 02
subsystem: infra
tags: [bash, hooks, stop-hook, mandatory-reporting, spool, tdd]

# Dependency graph
requires:
  - phase: 26-01
    provides: "Wave 0 RED test scaffold for stop hook + shipper tests"
provides:
  - "claude/hooks/stop-hook.sh: local-only spool verification, re-prompt on missing, SPOOL-02 network-free"
  - "claude/settings.json Stop hook registration using nested hooks array form"
  - "tests/test-phase26.sh: 15-test harness, Wave 0+1 GREEN, Wave 2+3 RED sentinels for Plans 03/04"
  - "Fixture files for stop-hook testing: profile-26-spool, spools, stop-hook-inputs"
  - "test-map.json entries routing claude/hooks/, claude/settings.json, bin/claude-secure to test-phase26.sh"
affects:
  - "26-03 (spool shipper implementation reads TEST_SPOOL_FILE_OVERRIDE + CLAUDE_SECURE_SKIP_SPOOL_SHIPPER contracts)"
  - "26-04 (spawn integration adds run_spool_shipper_inline to do_spawn preamble)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TEST_SPOOL_FILE_OVERRIDE env var for test isolation in hook scripts"
    - "stop_hook_active recursion guard pattern: jq -r '.stop_hook_active // false' 2>/dev/null || echo false"
    - "Pitfall 6 malformed-JSON fallback: 2>/dev/null || echo 'false' on jq parse"

key-files:
  created:
    - claude/hooks/stop-hook.sh
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
    - claude/settings.json
    - tests/test-map.json

key-decisions:
  - "TEST_SPOOL_FILE_OVERRIDE overrides SPOOL_FILE in stop-hook.sh — allows tests to use temp paths without /var/log mount"
  - "stop_hook_active guard uses jq // false coercion + 2>/dev/null || echo false fallback (Pitfall 6 defense)"
  - "Stop entry in settings.json has NO matcher field — Stop hooks do not support matchers per official docs"
  - "Wave 2/3 tests in test-phase26.sh are sentinel-fail (return 1) so Plans 03/04 have a green-target signal"

patterns-established:
  - "TEST_SPOOL_FILE_OVERRIDE testability contract: stop-hook.sh uses SPOOL_FILE=${TEST_SPOOL_FILE_OVERRIDE:-/var/log/claude-secure/spool.md}"
  - "CLAUDE_SECURE_SKIP_SPOOL_SHIPPER=1 escape hatch: run_spool_shipper returns 0 immediately (for Plans 03/04)"
  - "MOCK_PUBLISH_BUNDLE_EXIT env var for shipper stub (for Plans 03/04)"

requirements-completed: [SPOOL-01, SPOOL-02]

# Metrics
duration: 5min
completed: 2026-04-14
---

# Phase 26 Plan 02: Stop Hook Implementation Summary

**stop-hook.sh (56 lines): local-only spool verification with recursion guard, 6-H2 re-prompt JSON, and zero network calls; registered in settings.json under Stop event**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-14T13:19:37Z
- **Completed:** 2026-04-14T13:24:37Z
- **Tasks:** 2 (plus test scaffold creation)
- **Files modified:** 12

## Accomplishments

- Implemented `claude/hooks/stop-hook.sh` (56 lines): yields on `stop_hook_active=true`, yields when spool exists, emits `{decision:"block",reason:...}` with all 6 mandatory H2 headings when spool missing
- Registered Stop hook in `claude/settings.json` using nested hooks array form (no matcher field) alongside existing PreToolUse entry
- Created complete test harness `tests/test-phase26.sh` with 15 tests spanning all 4 waves; Wave 0 (2) and Wave 1 (7) tests are GREEN after this plan
- Created all 8 fixture files needed by test harness (profile, spools, stop-hook stdin JSON inputs)
- Updated `tests/test-map.json` to route `claude/hooks/`, `claude/settings.json`, and `bin/claude-secure` to `test-phase26.sh`

## stop-hook.sh Structure

**56 lines.** Structure:
1. Shebang + `set -euo pipefail`
2. Constants: `SPOOL_FILE="${TEST_SPOOL_FILE_OVERRIDE:-/var/log/claude-secure/spool.md}"`, `LOG_FILE=...`
3. `INPUT=$(cat)` — first operational line (single-read stdin)
4. `log()` helper (mirrors pre-tool-use.sh pattern, gated on `LOG_HOOK=1`)
5. Recursion guard: `STOP_HOOK_ACTIVE=$(... jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")` + exit 0 if true
6. Spool check: `[ -f "$SPOOL_FILE" ] && exit 0`
7. Block output: heredoc REPROMPT with all 6 H2 headings → `jq -n --arg reason "$REPROMPT" '{decision:"block",reason:$reason}'`

**TEST_SPOOL_FILE_OVERRIDE contract:** Plans 03/04 can use this to test spool-related logic without a real container log mount.

## settings.json diff

Added `Stop` key inside the existing `hooks` object:
```json
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "/etc/claude-secure/hooks/stop-hook.sh"
      }
    ]
  }
]
```
No matcher field. PreToolUse entry preserved byte-for-byte.

## Task Commits

1. **Task 1: Create claude/hooks/stop-hook.sh** (with test scaffold) - `b85f021` (feat)
2. **Task 2: Register Stop hook in claude/settings.json** - `4c9aab0` (feat)

## Test Results — Tests Now GREEN

| Test | Wave | Status |
|------|------|--------|
| test_fixtures_exist | 0 | PASS |
| test_test_map_registered | 0 | PASS |
| test_stop_hook_script_exists | 1 | PASS |
| test_stop_hook_yields_when_spool_present | 1 | PASS |
| test_stop_hook_reprompts_when_spool_missing | 1 | PASS |
| test_stop_hook_yields_on_stop_hook_active_true | 1 | PASS |
| test_stop_hook_no_network_calls | 1 | PASS |
| test_stop_hook_handles_malformed_stdin | 1 | PASS |
| test_settings_json_has_stop_hook | 1 | PASS |

## Remaining RED Tests (for Plans 03/04)

| Test | Wave | Required by |
|------|------|-------------|
| test_run_spool_shipper_function_exists | 2 | Plan 03 |
| test_shipper_returns_immediately | 2 | Plan 03 |
| test_shipper_deletes_spool_on_success | 2 | Plan 03 |
| test_shipper_logs_push_failed_with_attempt | 2 | Plan 03 |
| test_shipper_publishes_malformed_best_effort | 2 | Plan 03 |
| test_stale_spool_drained_at_spawn_preamble | 3 | Plan 04 |

## Deviations from Plan

### Auto-added: Test scaffold (Plan 01 work included)

**[Rule 3 - Blocking] Created test-phase26.sh and fixtures because Plan 01 had not yet run**
- **Found during:** Task 1 (TDD RED phase setup)
- **Issue:** Plan 02 is TDD and requires `tests/test-phase26.sh` to exist (Plan 01's output). In parallel execution, Plan 01 was not yet committed to this worktree.
- **Fix:** Created the full Wave 0 test scaffold (test-phase26.sh, 8 fixture files, test-map.json entries) as part of Plan 02 execution so the TDD workflow could proceed.
- **Files modified:** tests/test-phase26.sh, tests/fixtures/profile-26-spool/*, tests/fixtures/spools/*, tests/fixtures/stop-hook-inputs/*, tests/test-map.json
- **Committed in:** b85f021 (Task 1 commit)

**Total deviations:** 1 auto-fixed (Rule 3 blocking — parallel execution dependency)
**Impact on plan:** Required for correct TDD execution. Plan 01's agent will also produce these files; orchestrator merge will need to handle potential duplicate creation.

## Issues Encountered

- `/tmp` is read-only in sandbox environment — manual acceptance criteria tests used `$TMPDIR` instead. Test harness uses `mktemp -d` which works correctly.

## Known Stubs

Wave 2 and Wave 3 tests in `tests/test-phase26.sh` have `return 1` sentinel stubs:
- `test_shipper_returns_immediately` (line ~180): "NOT IMPLEMENTED — Plan 03 must implement timing test"
- `test_shipper_deletes_spool_on_success` (line ~186): "NOT IMPLEMENTED — Plan 03 must implement"
- `test_shipper_logs_push_failed_with_attempt` (line ~192): "NOT IMPLEMENTED — Plan 03 must implement"
- `test_shipper_publishes_malformed_best_effort` (line ~198): "NOT IMPLEMENTED — Plan 03 must implement"

These are intentional RED sentinels for future waves. They do NOT prevent Plan 02's goal from being achieved.

## Next Phase Readiness

- **Plan 03 (run_spool_shipper):** Can use `CLAUDE_SECURE_SKIP_SPOOL_SHIPPER=1` and `TEST_SPOOL_FILE_OVERRIDE` contracts from this plan. Tests 10-14 are waiting RED.
- **Plan 04 (spawn integration):** Test 15 (`test_stale_spool_drained_at_spawn_preamble`) is waiting RED for `run_spool_shipper_inline` grep.
- No Dockerfile changes needed — `COPY hooks/` glob at Dockerfile line 20 + `chmod 555 *.sh` at line 23 picks up `stop-hook.sh` automatically on next image rebuild.

---
*Phase: 26-stop-hook-mandatory-reporting*
*Completed: 2026-04-14*
