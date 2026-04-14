---
phase: 25-context-read-bind-mount
plan: 04
subsystem: testing
tags: [bash, docker, test-harness, phase25, WSL2]

# Dependency graph
requires:
  - phase: 25-context-read-bind-mount
    provides: "Plans 02/03 delivered fetch_docs_context, do_spawn wiring, and docker-gated integration tests"
provides:
  - "Container-ready poll loop in _spawn_ctx_background replacing fixed sleep 2"
  - "Explicit exec-reachability guard in test_agent_docs_no_git_dir_in_container"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Poll-until-ready pattern: bounded retry (30 x 0.5s) with docker compose ps --status=running --services instead of fixed sleep"
    - "Liveness probe guard: exec -T <service> true before boolean-chain exec assertions to convert silent false-positive into loud failure"

key-files:
  created: []
  modified:
    - tests/test-phase25.sh

key-decisions:
  - "Poll loop uses docker compose ps --status=running --services | grep -Fxq claude (not docker ps or --status=healthy) for compose-project-scoped visibility; claude service has no healthcheck so healthy never fires"
  - "Poll loop does not return non-zero on timeout; caller's existing || { _kill_spawn; return 1; } chains handle failure via exec-level check"
  - "exec guard uses `true` (cheapest liveness probe: proves container alive AND exec functional AND PATH resolves) — no output, no side effects"

patterns-established:
  - "Wait-for-container pattern: use bounded poll over ps --status=running rather than fixed sleep in test harness helpers"
  - "False-positive guard: always add an explicit exec-reachability check before any boolean-chain exec assertion that would pass on exec failure"

requirements-completed:
  - CTX-01
  - CTX-02
  - CTX-04

# Metrics
duration: 5min
completed: 2026-04-14
---

# Phase 25 Plan 04: Test Harness Race Fix Summary

**Container-ready poll loop and exec-health guard in test-phase25.sh close WSL2 false-negative and false-positive races in docker-gated integration tests**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-14T00:00:00Z
- **Completed:** 2026-04-14T00:05:00Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Replaced fixed `sleep 2` in `_spawn_ctx_background` with a 30-attempt x 0.5s bounded poll loop that exits as soon as `docker compose ps --status=running --services` shows `claude` in the running state (or the background spawn process dies)
- Added an exec-reachability guard (`exec -T claude true`) to `test_agent_docs_no_git_dir_in_container` so an unreachable container now fails loudly with a FAIL message instead of silently passing through the boolean-chain
- All three Wave 0 structural tests (`test_fixtures_exist`, `test_compose_volume_entry`, `test_test_map_registered`) verified green; `bash -n` syntax check passes; `sleep 2` removed; required patterns confirmed present

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace fixed-sleep race with poll loop and exec-health guard** - `15bcb6e` (fix)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `tests/test-phase25.sh` - Replaced `sleep 2` with container-ready poll loop in `_spawn_ctx_background`; added exec-reachability guard in `test_agent_docs_no_git_dir_in_container`

## Decisions Made
- Poll loop uses `docker compose ps --status=running --services | grep -Fxq claude` rather than `docker ps` for compose-project-scoped visibility; `--status=healthy` deliberately avoided since the claude service has no healthcheck defined
- Poll loop does NOT return non-zero on timeout — caller's existing `|| { _kill_spawn; return 1; }` chains already handle failure via their own exec-level assertions
- Used `true` as the exec liveness probe — cheapest possible command that proves container is alive, exec is functional, and PATH resolves inside the container

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 25 UAT gap is closed: test harness no longer races on WSL2
- Full suite should report 15 passed, 0 failed, 15 total on a docker-running WSL2 host
- No blockers for phase completion

---
*Phase: 25-context-read-bind-mount*
*Completed: 2026-04-14*
