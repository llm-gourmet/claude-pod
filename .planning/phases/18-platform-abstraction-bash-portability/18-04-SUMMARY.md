---
phase: 18-platform-abstraction-bash-portability
plan: 04
subsystem: infra
tags: [bash, macos, portability, reaper, locking, uuidgen, port-03, port-04]

# Dependency graph
requires:
  - phase: 18-platform-abstraction-bash-portability
    provides: Plan 01 test-phase17.sh rewrite expecting mkdir-lock semantics
  - phase: 18-platform-abstraction-bash-portability
    provides: Plan 01 test-phase18.sh stubs (test_no_flock_in_host_scripts, test_hook_uuidgen_is_lowercased)
  - phase: 18-platform-abstraction-bash-portability
    provides: Plan 03 host-script re-exec prologue (unchanged by this plan)
provides:
  - bin/claude-secure do_reap mkdir-based atomic lock with PID file stale reclaim (replaces flock)
  - claude/hooks/pre-tool-use.sh lowercased uuidgen normalization in register_call_id
  - tests/test-phase18.sh real PORT-03/PORT-04 assertions (stubs replaced)
  - tests/test-phase17.sh reap mkdir-lock single-flight and stale-reclaim back to green
affects: [18-05, 19-docker-desktop-compat, 20-enforcement, 21-launchd-services]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "mkdir-based atomic lock with PID file + EXIT trap for single-flight host scripts on POSIX systems without util-linux flock"
    - "Defensive uuidgen normalization: pipe through `tr '[:upper:]' '[:lower:]'` so BSD uuidgen and Linux uuid-runtime produce case-consistent output"

key-files:
  created: []
  modified:
    - bin/claude-secure
    - claude/hooks/pre-tool-use.sh
    - tests/test-phase18.sh

key-decisions:
  - "Rename reaper lock path from reaper.lock (file) to reaper.lockdir (directory) to guarantee zero ambiguity with any old flock-based version of the script — a mismatched path between old and new versions is safer than same path, different primitive"
  - "mkdir-based lock uses an EXIT trap (not RETURN) because do_reap is called from main dispatch, and EXIT covers normal return, error return, and signal delivery uniformly"
  - "PID file holds only `$$` (caller PID); liveness check via `kill -0 $holder_pid` detects stale locks without needing any additional metadata (host, boot-id, etc.) — sufficient for single-host reaper, and the reaper is always single-host by design"
  - "No chmod on lockdir — mkdir respects umask, and the systemd reaper service + operator `claude-secure reap` invocations run as the same LOG_DIR owner so chmod 666 (the prior flock pattern) was unnecessary and is dropped"
  - "PORT-04 uuidgen normalization is defensive-only: the current claude container runs Debian where uuidgen is already lowercase, but swapping the container base image to an Alpine/BSD variant would silently break validator matching without this pipeline"

patterns-established:
  - "When replacing a util-linux primitive with a portable equivalent, rename the artifact path (lockdir vs lock, etc.) to make accidental cross-version reuse impossible"
  - "Plan-01-writes-failing-test + Plan-N-closes-handshake cross-plan TDD pattern: test-phase17.sh was rewritten red in Plan 01 and went green in Plan 04 — a multi-plan RED/GREEN cycle that keeps the wave's intermediate suites red by design"

requirements-completed: [PORT-03, PORT-04]

# Metrics
duration: 3min
completed: 2026-04-13
---

# Phase 18 Plan 04: mkdir Lock and uuidgen Normalization Summary

**do_reap in bin/claude-secure now uses an mkdir-based atomic lock with a PID-file stale-reclaim path (replacing util-linux flock), and the claude container hook pipes uuidgen through tr to lowercase the call-id defensively — retiring the two macOS-incompatible primitives identified by the Phase 18 research audit.**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-13T10:10:15Z
- **Completed:** 2026-04-13T10:13:07Z
- **Tasks:** 3
- **Files touched:** 3

## Scope

Phase 18 research (PORT-03, PORT-04) identified exactly two macOS-incompatible
primitives in the production host-side code path:

1. `flock -n 9` in `bin/claude-secure :: do_reap`, which depends on util-linux
   and is not available on macOS without installing an extra brew formula.
2. Raw `uuidgen` in `claude/hooks/pre-tool-use.sh :: register_call_id`, which
   produces uppercase IDs on BSD and lowercase IDs on Linux — a latent case
   mismatch if the container base image ever swaps.

Both are single-site fixes. This plan closes both and flips the Plan 01
handshake tests from red to green.

## Changes

### Task 1 — bin/claude-secure :: do_reap mkdir lock

**Line range replaced:** lines 1651–1702 (old) → lines 1651–1719 (new).
The function signature, argument parsing (`--dry-run`, `--help`),
`REAPER_DRY_RUN` export, `reap_orphan_projects` / `reap_stale_event_files`
calls, `REAPED_COUNT` tracking, and D-10 failure-to-exit-code mapping are
all unchanged.

**Lock mechanism:**

- Old: `exec 9>"$lock_file"` + `flock -n 9` on `$LOG_DIR/reaper.lock`
- New: `mkdir "$lockdir" 2>/dev/null` on `$LOG_DIR/reaper.lockdir` + write
  `$$` to `$lockdir/pid` + EXIT trap to rmdir

**Stale reclaim path:**

- If mkdir fails, read `$lockdir/pid`
- If `kill -0 $holder_pid` succeeds → holder is live → log
  `reaper: another instance is running (pid=$holder_pid lockdir=$lockdir), skipping cycle`
  → return 0
- If `kill -0` fails → holder is dead → log
  `reaper: stale lockdir found (dead holder pid=$holder_pid), reclaiming`
  → rm pidfile + rmdir + retry mkdir → enter cycle

**Path rename:** `reaper.lock` (file) → `reaper.lockdir` (directory). The
rename is deliberate: a prior script version running with the old name
cannot accidentally share state with the new version, because they are
literally different paths. Research §Canonical Check recommended this.

**EXIT trap:**
```bash
trap "rm -f '$pidfile' 2>/dev/null || true; rmdir '$lockdir' 2>/dev/null || true" EXIT
```
Double-quoted so `$pidfile` and `$lockdir` interpolate at trap-set time
(shellcheck SC2064 disabled inline, which is the correct disposition here).
The trap handles normal return, error return, and SIGTERM/SIGINT delivery
uniformly.

### Task 2 — claude/hooks/pre-tool-use.sh :: register_call_id

Exactly one line changed (line 159):

```diff
- call_id=$(uuidgen)
+ call_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
```

No other modifications. The hook's `curl` registration payload, JSON
encoding, error handling, and logging calls are all untouched. Line count
change: +0 (same line, different pipeline). This is a defensive change
with zero runtime effect on the current Debian-based claude container.

### Task 3 — tests/test-phase18.sh :: two stub replacements

Replaced:

- `test_no_flock_in_host_scripts()` stub (returned 0 with `echo "STUB: implemented in plan 04"`) with a real grep-based assertion that scans `install.sh`, `bin/claude-secure`, `run-tests.sh`, `lib/platform.sh`, `claude/hooks/pre-tool-use.sh` for non-comment `flock` references. The regex is split into two cases (leading-content line and pure `flock` line) to guarantee only non-comment matches fire.
- `test_hook_uuidgen_is_lowercased()` stub with a grep for the exact `uuidgen | tr '[:upper:]' '[:lower:]'` pipeline plus a negative assertion against bare `call_id=$(uuidgen)`.

Both use `REPO_ROOT` (already set at top of test-phase18.sh) and require no new helpers.

## Verification

- `bash tests/test-phase18.sh` → PASSED=16 FAILED=0 (stubs replaced, new tests green).
- `bash tests/test-phase17.sh` → `PASS: reap mkdir-lock single-flight`, `PASS: reap mkdir-lock stale-reclaim`. The Phase 18 handshake is closed.
- `grep -nE '^[^#]*\bflock\b' bin/claude-secure` → no matches.
- `grep -nE '^[^#]*\bflock\b' install.sh run-tests.sh lib/platform.sh claude/hooks/pre-tool-use.sh` → no matches across all host scripts.
- `grep -q "uuidgen | tr '\[:upper:\]' '\[:lower:\]'" claude/hooks/pre-tool-use.sh` → present.
- `bash -n bin/claude-secure` → 0.
- `bash -n claude/hooks/pre-tool-use.sh` → 0.

## Commits

- `10f9fa5` feat(18-04): replace flock with mkdir-based lock in do_reap
- `882101b` feat(18-04): normalize uuidgen output to lowercase in register_call_id
- `a555b90` test(18-04): implement PORT-03 and PORT-04 test assertions

## Deviations from Plan

None. Plan executed exactly as written. No auto-fix rules triggered.

## Deferred Issues

- `tests/test-phase17.sh :: test_reap_dry_run` is FAILING with `dry-run marker missing from output`. This failure is **pre-existing** (verified via `git stash` + re-run against Plan 03's HEAD): the dry-run assertion requires a `[dry-run]` marker somewhere in do_reap's output, but the current reap pipeline only emits the marker from `reap_stale_event_files`, and the test fixture exercises the `reap_orphan_projects` branch. This is orthogonal to PORT-03 (the lock primitive swap does not touch dry-run output emission). Logged to `.planning/phases/18-platform-abstraction-bash-portability/deferred-items.md` for a future quick-fix or follow-up plan. Respecting the parallel-executor SCOPE BOUNDARY rule — not fixed here.

## Requirements Completed

- **PORT-03** — Replace flock with mkdir-based lock in do_reap. Primitive retired; stale-reclaim path implemented; tests green.
- **PORT-04** — Normalize uuidgen output to lowercase in claude container hook. Defensive normalization in place; regression tested via test-phase18.sh.

## Next Plan

**Plan 05 — Final hardening and macOS-override suite:** adds the install.sh prologue (deferred from Plan 03), implements `test_phase18_full_suite_under_macos_override`, and closes any remaining Phase 18 audit items.

## Self-Check: PASSED

- bin/claude-secure: FOUND (modified, mkdir lock in place)
- claude/hooks/pre-tool-use.sh: FOUND (modified, tr lowercase pipeline)
- tests/test-phase18.sh: FOUND (modified, stubs replaced)
- Commit 10f9fa5: FOUND
- Commit 882101b: FOUND
- Commit a555b90: FOUND
