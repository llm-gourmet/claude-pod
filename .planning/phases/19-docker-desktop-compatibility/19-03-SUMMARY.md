---
phase: 19-docker-desktop-compatibility
plan: 03
subsystem: infra
tags: [install, macos, docker-desktop, bash, version-check, testing]

# Dependency graph
requires:
  - phase: 19-01
    provides: test-phase19.sh harness with PLAT-05 stub functions and docker version fixtures
  - phase: 18-platform-abstraction-bash-portability
    provides: lib/platform.sh detect_platform, claude_secure_bootstrap_path (GNU sort on PATH)
provides:
  - install.sh check_docker_desktop_version() function (PLAT-05)
  - Real fixture-driven PLAT-05 tests replacing stubs in tests/test-phase19.sh
affects:
  - 19-integration-tests
  - phase-22-macos-e2e

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "macOS-guarded installer check: call via [ \"$_plat\" = \"macos\" ] guard inside check_dependencies()"
    - "sort -V version comparison: printf both versions, sort -V, head -1 picks lexicographically-smallest (oldest)"
    - "Subshell isolation for exit-trapping tests: ( check_func ) 2>&1; echo \"__rc=$?\" captures exit code without killing test harness"

key-files:
  created: []
  modified:
    - install.sh
    - tests/test-phase19.sh

key-decisions:
  - "Used nested subshell pattern ( check_docker_desktop_version ) 2>&1; echo \"__rc=$?\" instead of plan's literal code to correctly capture exit 1 — exit in command substitution kills the outer $() before echo runs"
  - "check_docker_desktop_version() inserted before check_dependencies() per plan spec; call site inside existing macOS guard ensures Linux/WSL2 paths are untouched"

patterns-established:
  - "Installer macOS gate: new version checks added to check_dependencies() behind [ \"$_plat\" = \"macos\" ] guard"
  - "Bash function test via __INSTALL_SOURCE_ONLY=1: source install.sh in subshell to unit-test individual functions without triggering main()"

requirements-completed:
  - PLAT-05

# Metrics
duration: 8min
completed: 2026-04-13
---

# Phase 19 Plan 03: PLAT-05 Docker Desktop Version Gate Summary

**macOS Docker Desktop >= 4.44.3 version gate added to install.sh with three fixture-driven unit tests replacing PLAT-05 stubs**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-04-13T10:56:00Z
- **Completed:** 2026-04-13T11:04:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `check_docker_desktop_version()` to install.sh with daemon-running check, Desktop detection, and GNU sort -V version comparison against minimum 4.44.3
- Wired call into `check_dependencies()` behind `[ "$_plat" = "macos" ]` guard — Linux and WSL2 paths are unaffected
- Replaced all three PLAT-05 stub test functions in tests/test-phase19.sh with real fixture-driven assertions using `__INSTALL_SOURCE_ONLY=1` subshell isolation
- Full test suite passes: `Phase 19 tests: 6 passed, 0 failed`

## Task Commits

Each task was committed atomically:

1. **Task 1: Add check_docker_desktop_version() to install.sh** - `1788449` (feat)
2. **Task 2: Replace PLAT-05 stubs with real fixture-driven tests** - `2ce5b1d` (test)

## Files Created/Modified

- `install.sh` - Added `check_docker_desktop_version()` function (51 lines) and macOS-guarded call site in `check_dependencies()`
- `tests/test-phase19.sh` - Replaced 3 PLAT-05 stub bodies with real fixture-driven assertions

## Decisions Made

- Used nested subshell pattern `( check_docker_desktop_version ) 2>&1; echo "__rc=$?"` instead of the plan's literal code. The plan's literal version (`check_docker_desktop_version 2>&1; echo "__rc=$?"` inside `$(...)`) has a bug: `exit 1` inside a command substitution subshell terminates that subshell before `echo "__rc=$?"` runs. The nested subshell form `( func ) 2>&1` contains the `exit 1` to the inner subshell, allowing `echo "__rc=$?"` to capture the exit code correctly in the outer `$()` context.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed subshell exit-capture pattern for tests asserting exit 1**
- **Found during:** Task 2 (Replace PLAT-05 stubs)
- **Issue:** Plan's literal test code `check_docker_desktop_version 2>&1; echo "__rc=$?"` inside `$(...)` cannot capture exit 1 — the `exit 1` in `check_docker_desktop_version` terminates the entire command-substitution subshell before `echo "__rc=$?"` executes. The `test_plat05_rejects_docker_desktop_4_28_0` test would have spuriously passed (rc empty string != "1") or failed with wrong rc.
- **Fix:** Wrapped the function call in a nested subshell: `( check_docker_desktop_version ) 2>&1; echo "__rc=$?"`. The inner subshell absorbs the `exit 1`; the outer `$()` subshell continues to `echo "__rc=$?"`.
- **Files modified:** tests/test-phase19.sh
- **Verification:** `bash tests/test-phase19.sh` — 6 passed, 0 failed including the reject test
- **Committed in:** 2ce5b1d (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — Bug)
**Impact on plan:** Required fix for test correctness. The implemented test logic matches plan intent exactly; only the capture mechanism differed.

## Issues Encountered

- Worktree was based on an older commit that lacked the Phase 19 fixture files and test-phase19.sh created by Plan 01. Resolved by fetching and fast-forward merging the main repo's HEAD (commit `c42f16e`) into the worktree before beginning work.

## Next Phase Readiness

- PLAT-05 complete: install.sh will gate macOS users on Docker Desktop >= 4.44.3 before proceeding
- Phase 20 (enforcement spike) can proceed; no install.sh blockers
- Phase 22 integration tests will need live macOS hardware to exercise the macOS path end-to-end

---
*Phase: 19-docker-desktop-compatibility*
*Completed: 2026-04-13*
