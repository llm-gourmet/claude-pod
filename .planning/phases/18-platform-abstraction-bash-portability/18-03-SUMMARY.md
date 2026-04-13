---
phase: 18-platform-abstraction-bash-portability
plan: 03
subsystem: infra
tags: [bash, macos, portability, platform-detection, homebrew, re-exec]

# Dependency graph
requires:
  - phase: 18-platform-abstraction-bash-portability
    provides: lib/platform.sh (detect_platform, claude_secure_bootstrap_path)
  - phase: 18-platform-abstraction-bash-portability
    provides: install.sh macos_bootstrap_deps (Plan 02)
provides:
  - bin/claude-secure bash 4+ re-exec guard prologue
  - bin/claude-secure lib/platform.sh sourcing + PATH bootstrap on macOS
  - run-tests.sh bash 4+ re-exec guard prologue
  - run-tests.sh lib/platform.sh sourcing + PATH bootstrap on macOS
  - tests/test-phase18.sh real implementation of test_caller_prologue_reexecs_into_brew_bash
affects: [18-04, 18-05, 19-docker-desktop-compat, 20-enforcement, 21-launchd-services]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Phase 18 host-script prologue: bash 4+ re-exec guard + lib/platform.sh source + claude_secure_bootstrap_path, all bash 3.2 safe"
    - "Dev-vs-installed lib/platform.sh lookup: ../lib, ./lib, /usr/local/share/claude-secure/lib fallback chain"

key-files:
  created: []
  modified:
    - bin/claude-secure
    - run-tests.sh
    - tests/test-phase18.sh

key-decisions:
  - "install.sh prologue deferred to Plan 05 to avoid files_modified conflict with Plan 02's macos_bootstrap_deps edits"
  - "test_caller_prologue_reexecs_into_brew_bash is a static-only assertion test: Linux CI runs bash 5 natively so the runtime re-exec branch cannot be exercised; grep + line-ordering + bash -n is the testable surface"
  - "claude_secure_bootstrap_path call uses || true so a missing brew on macOS surfaces the library's stderr error but does NOT abort bin/claude-secure (install.sh has already verified brew at install time)"
  - "Triple-fallback source path for lib/platform.sh (../lib dev layout, ./lib installed-alongside-bin layout, /usr/local/share defensive) so the same bin/claude-secure works in dev checkout AND after install.sh's copy_app_files"

patterns-established:
  - "Every host-side script that starts a fresh bash invocation MUST have the Phase 18 prologue before any bash 4+ syntax parses"
  - "Line-ordering acceptance check: re-exec guard line number < set -euo pipefail line number is a verifiable static invariant"

requirements-completed: [PORT-01, PORT-02]

# Metrics
duration: 3min
completed: 2026-04-13
---

# Phase 18 Plan 03: Host-Script Re-Exec Prologue Summary

**bin/claude-secure and run-tests.sh now re-exec into brew bash 5 on Apple bash 3.2 hosts before any bash 4+ syntax parses, and source lib/platform.sh so plain `date`/`stat`/`readlink`/`realpath`/`sed`/`grep` resolve to GNU coreutils on macOS.**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-13T10:04:39Z
- **Completed:** 2026-04-13T10:07:52Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- Inserted bash 3.2 safe re-exec guard at line 1 of bin/claude-secure, ahead of `set -euo pipefail` (line 16) so the guard fires before any bash 4+ syntax in the ~1700-line body ever reaches Apple bash 3.2's parser
- Same prologue installed in run-tests.sh ahead of its `set -uo pipefail`; REPO_ROOT/lib/platform.sh path (not ../lib) because run-tests.sh lives at the repo root
- test_caller_prologue_reexecs_into_brew_bash promoted from Plan 01 stub to a real static-assertion test covering BASH_VERSINFO presence, exec-into-$__brew_bash, source lib/platform.sh, claude_secure_bootstrap_path call, line ordering (re-exec < set), and bash -n syntax checks for both scripts
- All 16 Phase 18 tests still pass (10 real + 6 stubs, with caller prologue now real instead of stub)
- Existing __CLAUDE_SECURE_SOURCE_ONLY=1 test harness pattern preserved: sourcing bin/claude-secure in a test still lands all function definitions (validate_profile_name, do_reap, etc.) after the new prologue

## Task Commits

Each task was committed atomically:

1. **Task 1: Add bash 4+ re-exec guard prologue to bin/claude-secure** - `45eea4c` (feat)
2. **Task 2: Add re-exec prologue to run-tests.sh** - `c947366` (feat)
3. **Task 3: Implement test_caller_prologue_reexecs_into_brew_bash** - `7619107` (test)

## Files Created/Modified

- `bin/claude-secure` - Lines 1-12 replaced with Phase 18 prologue (34 insertions, 1 deletion). New layout: shebang `#!/usr/bin/env bash`, re-exec guard (lines 5-14), `set -euo pipefail` (line 16), lib/platform.sh triple-fallback source (lines 21-33), claude_secure_bootstrap_path call (lines 34-36), then existing source-only block and CONFIG_DIR.
- `run-tests.sh` - Lines 1-2 replaced with same prologue pattern (23 insertions, 1 deletion). New layout: shebang `#!/usr/bin/env bash`, re-exec guard, `set -uo pipefail`, single-path source of `$__RUN_TESTS_SELF_DIR/lib/platform.sh` + bootstrap call, then existing REPO_ROOT assignment and test dispatch logic.
- `tests/test-phase18.sh` - test_caller_prologue_reexecs_into_brew_bash body replaced with 34-line real assertion implementation that grep-checks bin/claude-secure first 50 lines and run-tests.sh first 30 lines, verifies line ordering via grep -n + integer comparison, and runs bash -n syntax checks.

## Decisions Made

- **install.sh NOT included in this plan.** install.sh already has its own set -euo pipefail at the top and would also benefit from the Phase 18 prologue, BUT Plan 02 (macos_bootstrap_deps wiring) already modifies install.sh and Plan 03's files_modified declaration cannot overlap. install.sh will get the same prologue as a final cleanup touch in Plan 05, which depends on Plans 02-04 and owns the final install.sh audit.
- **Static-only test.** Linux CI cannot actually fork into brew bash 5 because it already runs bash 5 natively — the re-exec branch is a no-op in that environment. The test therefore asserts structural presence + ordering + syntax via grep and `bash -n`, not runtime behavior. macOS verification will happen in Phase 22 integration tests on real hardware.
- **`claude_secure_bootstrap_path || true`.** On Linux the function returns 0; on macOS without brew it returns 1 and prints an error. We don't want to kill bin/claude-secure unconditionally if brew goes missing post-install — install.sh has already verified brew at install time, and the library's stderr output remains visible if something breaks later. `|| true` keeps the script running so the user sees the actual failure downstream.
- **Dev-checkout and installed-layout compatibility.** bin/claude-secure uses a three-way source-file lookup: `$SELF_DIR/../lib/platform.sh` works in dev checkouts and in `$CONFIG_DIR/app/` (install.sh copies the whole repo tree); `$SELF_DIR/lib/platform.sh` handles a hypothetical future layout where lib sits next to bin; `/usr/local/share/claude-secure/lib/platform.sh` is a defensive fallback for packaged installs. No current installer path uses the second or third branch, but they cost nothing.

## Deviations from Plan

None - plan executed exactly as written.

The plan provided literal replacement blocks for all three files and acceptance criteria that were directly testable. No auto-fixes or architectural changes needed.

## Issues Encountered

None. One minor note: the Task 1 bash 3.2 safety grep (`head -50 | grep -E '\[\[|...'`) matched line 4 of the new prologue (`# This block MUST remain bash 3.2 safe (no [[ ]], no ${var,,}, no declare -A).`), but that match is in a comment describing the rule, not actual syntax, so it's a non-issue. The prologue code itself uses only POSIX `[ ]` tests.

## Verification Summary

All plan-level verification steps pass:

1. `bash tests/test-phase18.sh` exits 0 — PASSED=16 FAILED=0, "PASS caller prologue re-execs brew bash" visible (no longer marked stub)
2. `bash -n bin/claude-secure && bash -n run-tests.sh` — both exit 0
3. `__CLAUDE_SECURE_SOURCE_ONLY=1 bash -c 'source bin/claude-secure && type do_reap'` — returns "do_reap is a function"
4. `bash run-tests.sh test-phase18.sh` — exits 0, "All tests passed. Containers torn down."
5. Static ordering check — re-exec guard at line 5, `set -euo pipefail` at line 16 in bin/claude-secure (reexec < set)

Additional sanity checks performed:

- All `tests/test-phase*.sh` files pass `bash -n` (no syntax regressions in adjacent test files)
- bin/claude-secure first 50 lines contain all required markers: BASH_VERSINFO, `command -v brew`, `exec "$__brew_bash"`, "bash 4+ required. On macOS run: brew install bash", `source.*lib/platform.sh`, `claude_secure_bootstrap_path`
- run-tests.sh first 30 lines contain all required markers (same list)

## v2.0 Backward Compatibility Confirmation

All v2.0 test phases (test-phase1.sh through test-phase17.sh) continue to source bin/claude-secure cleanly under the new prologue. The `__CLAUDE_SECURE_SOURCE_ONLY=1 source bin/claude-secure` pattern used by the Phase 12-17 test harnesses still loads every function definition exactly as before — the new prologue runs BEFORE the source-only check (re-exec is a no-op on Linux bash 5), then lib/platform.sh is sourced (bootstrap is a no-op on Linux), then the existing source-only block decides whether to execute the main dispatch. Net effect on Linux: identical to pre-Phase-18 behavior.

## Self-Check: PASSED

Files verified on disk:
- bin/claude-secure ✓
- run-tests.sh ✓
- tests/test-phase18.sh ✓
- .planning/phases/18-platform-abstraction-bash-portability/18-03-SUMMARY.md ✓ (this file)

Commits verified in git log:
- 45eea4c (Task 1: feat add re-exec guard to bin/claude-secure) ✓
- c947366 (Task 2: feat add re-exec prologue to run-tests.sh) ✓
- 7619107 (Task 3: test implement test_caller_prologue_reexecs_into_brew_bash) ✓

## Next Phase Readiness

- Plan 04 (do_reap mkdir-lock cross-plan handshake + uuidgen lowercasing) can now proceed; it will touch bin/claude-secure's do_reap function and tests/test-phase17.sh, not the prologue this plan installed
- Plan 05 (final audit + install.sh prologue + full-suite macOS override run) can safely add the same prologue to install.sh because Plan 02's edits to install.sh will be upstream
- No blockers; Plans 04 and 05 are independent of each other and can run in Wave 3 after Plan 04 lands

---
*Phase: 18-platform-abstraction-bash-portability*
*Completed: 2026-04-13*
