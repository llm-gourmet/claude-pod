---
phase: 19-docker-desktop-compatibility
plan: 02
subsystem: infra
tags: [docker, python, iptables, validator, dockerfile, testing]

# Dependency graph
requires:
  - phase: 19-01
    provides: tests/test-phase19.sh with COMPAT-01 stub functions and docker version fixtures
provides:
  - validator/Dockerfile pinned to python:3.11-slim-bookworm (COMPAT-01)
  - validator/validator.py iptables_probe() startup helper with OK/FAIL logging and QEMU hint
  - tests/test-phase19.sh COMPAT-01 stubs replaced with real grep assertions
affects:
  - 19-03
  - phase-20-enforcement-spike

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "iptables probe pattern: run iptables -L at startup, log OK/FAIL before setup_default_iptables"
    - "Bookworm base image pinning: explicit -bookworm suffix on python:3.11-slim for reproducible multi-arch builds"

key-files:
  created: []
  modified:
    - validator/Dockerfile
    - validator/validator.py
    - tests/test-phase19.sh

key-decisions:
  - "python:3.11-slim-bookworm over python:3.11-slim — Bookworm ships iptables-nft via update-alternatives, matching Docker Desktop Mac's nftables kernel; multi-arch amd64+arm64 natively on Docker Hub"
  - "iptables_probe() logs but never raises — keeps existing try/except around setup_default_iptables intact for outside-Docker dev environments"
  - "Probe placed BEFORE setup_default_iptables() in __main__ — ensures operators see OK/FAIL in logs regardless of whether setup silently no-ops"

patterns-established:
  - "Startup probe pattern: separate diagnostic function before the main setup to give operators definitive signal even when setup is wrapped in try/except"

requirements-completed:
  - COMPAT-01

# Metrics
duration: 2min
completed: 2026-04-13
---

# Phase 19 Plan 02: COMPAT-01 Validator Image Pin + iptables Probe Summary

**Pinned validator base to python:3.11-slim-bookworm and added iptables_probe() startup diagnostic that logs OK/FAIL before setup_default_iptables, replacing two test stub functions with real grep assertions**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-13T10:57:28Z
- **Completed:** 2026-04-13T10:59:35Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- validator/Dockerfile base image pinned from `python:3.11-slim` to `python:3.11-slim-bookworm` — reproducible multi-arch builds, iptables-nft via update-alternatives
- iptables_probe() added to validator.py: logs "iptables probe: OK" on success, "iptables probe: FAIL rc=N stderr=..." on failure, actionable QEMU/arm64 hint on "iptables who?" errors
- Probe wired into `__main__` BEFORE `setup_default_iptables()` without removing the existing try/except fallback
- tests/test-phase19.sh COMPAT-01 stubs replaced with real grep assertions; all 6 tests still pass

## Task Commits

1. **Task 1: Pin validator base image to python:3.11-slim-bookworm** - `ff3ec76` (feat)
2. **Task 2: Add iptables_probe() to validator.py and wire it into startup** - `c2ffae7` (feat)
3. **Task 3: Replace COMPAT-01 stubs in tests/test-phase19.sh with real assertions** - `fe8a729` (feat)

## Files Created/Modified
- `validator/Dockerfile` - FROM tag changed from python:3.11-slim to python:3.11-slim-bookworm
- `validator/validator.py` - Added iptables_probe() function (35 lines) + startup call before setup_default_iptables
- `tests/test-phase19.sh` - test_compat01_base_image_pinned and test_compat01_iptables_probe_present replaced with real grep assertions

## Decisions Made
- Used `python:3.11-slim-bookworm` explicit tag — Bookworm ships iptables-nft via update-alternatives which matches Docker Desktop Mac's nftables kernel. Multi-arch (amd64+arm64) available natively, no QEMU emulation on Apple Silicon.
- Probe function never raises, returns True/False — preserves the existing `try/except` around `setup_default_iptables()` that keeps the validator runnable outside Docker for unit testing.
- "iptables who?" and "do you need to insmod" trigger extra actionable hint log line pointing at native arm64 image builds per Phase 19 research Pitfall 1.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. The test-phase19.sh file was not yet present when Task 3 started (Plan 01 was running in parallel), but it appeared before the task executed because Plan 01 completed its file creation first.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- COMPAT-01 complete: validator image is pinned and has startup diagnostics
- Plan 19-03 (PLAT-05) can now replace the three plat05 stub functions in tests/test-phase19.sh
- Phase 20 enforcement spike can reference iptables_probe() output in container logs as a diagnostic signal

---
*Phase: 19-docker-desktop-compatibility*
*Completed: 2026-04-13*
