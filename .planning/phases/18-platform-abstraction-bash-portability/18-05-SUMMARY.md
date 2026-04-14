---
phase: 18-platform-abstraction-bash-portability
plan: 05
subsystem: platform-abstraction
tags: [install, bash-portability, port-01, port-02, test-01, phase-closure]
dependency-graph:
  requires: [18-02, 18-03, 18-04]
  provides:
    - "install.sh with Phase 18 prologue (bash 4+ re-exec + lib/platform.sh source + claude_secure_bootstrap_path)"
    - "install.sh main() routes through lib/platform.sh detect_platform (legacy_detect_platform removed)"
    - "tests/test-phase18.sh test_phase18_full_suite_under_macos_override — TEST-01 end-to-end proof on Linux CI"
    - "zero STUB markers remaining in tests/test-phase18.sh"
  affects:
    - "Plan 18-02 bootstrap (closes the prologue gap deferred from Plan 02)"
    - "Phase 19+ callers of detect_platform — install.sh now shares the same single source of truth"
tech-stack:
  added: []
  patterns:
    - "Bash 4+ re-exec guard prologue pattern (shared with bin/claude-secure and run-tests.sh)"
    - "Sub-suite recursive invocation with __PHASE18_SUBSUITE=1 sentinel for Linux-CI macOS coverage"
key-files:
  created: []
  modified:
    - install.sh
    - tests/test-phase18.sh
    - .planning/phases/18-platform-abstraction-bash-portability/deferred-items.md
decisions:
  - "Rewrote the [dry-run] bash 3.2 safety comment in install.sh to avoid literal [[ in first 17 lines (would false-positive the bash-safety regex)"
  - "Grep-matched against PASS human-readable report names (e.g., 'PASS detect_platform override macos') instead of function-name form ('PASS test_detect_platform_override_macos') because that's what the run_test helper actually emits"
  - "Added a new test_install_sh_has_phase18_prologue test (beyond the plan's explicit task list) to make Task 1's acceptance criteria executable under TDD RED→GREEN"
metrics:
  duration: 6min
  tasks: 2
  files: 3
  completed: 2026-04-13
---

# Phase 18 Plan 05: Final wiring + closure Summary

One-liner: install.sh now has the shared Phase 18 bash 4+ re-exec prologue, legacy_detect_platform is deleted in favor of lib/platform.sh detect_platform, and test-phase18.sh's final TEST-01 contract re-runs the full suite under CLAUDE_SECURE_PLATFORM_OVERRIDE=macos on Linux CI.

## What shipped

### install.sh

- **Shebang:** `#!/bin/bash` → `#!/usr/bin/env bash`
- **Lines 1-14:** Bash 4+ re-exec guard (PORT-02). Pure bash 3.2 syntax (no `[[ ]]`, no `${var,,}`, no `declare -A`). Checks `${BASH_VERSINFO[0]:-0} -lt 4`, re-execs into `"$(brew --prefix)/bin/bash"` if available, otherwise prints "ERROR: bash 4+ required. On macOS run: brew install bash" and exits 1.
- **Line 16:** `set -euo pipefail` (now comes AFTER the re-exec guard, as required for bash 3.2 safety).
- **Lines 21-25:** After sourcing `lib/platform.sh`, calls `claude_secure_bootstrap_path || true` (PORT-01). On macOS this prepends GNU coreutils gnubin so plain `date`/`stat`/`readlink`/`realpath` resolve to GNU versions. No-op on Linux/WSL2.
- **legacy_detect_platform() function removed entirely** (~24 lines deleted). No string reference to the name remains anywhere in install.sh.
- **main() body:** replaced the single-line `legacy_detect_platform` call with a 14-line inline block that calls `PLATFORM="$(detect_platform)"`, logs the platform, and on wsl2 preserves the Docker Desktop warning + iptables version log (inline rather than in a separate function).
- **Source-only guard** at EOF (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [ "${__INSTALL_SOURCE_ONLY:-0}" != "1" ]; then main "$@"; fi`) left untouched — Plan 02 added it and Plan 05 preserves it.

Final line count: 549 lines (was 542, +7 net after prologue add / legacy_detect_platform removal balance).

### tests/test-phase18.sh

- **New test: `test_install_sh_has_phase18_prologue`** — static assertion test that verifies install.sh has the shebang, BASH_VERSINFO guard, command -v brew path, exec brew_bash, error text, source lib/platform.sh, claude_secure_bootstrap_path call, re-exec guard ordering before `set -euo pipefail`, absence of legacy_detect_platform, presence of `PLATFORM="$(detect_platform)"`, preserved Docker Desktop warning, __INSTALL_SOURCE_ONLY guard, bash 3.2 safety in first 17 lines, and `bash -n` syntax validity. Added as the RED test for Task 1's TDD flow.
- **`test_phase18_full_suite_under_macos_override` — stub replaced** with a real subshell-based recursive invocation that:
  1. Honors the `__PHASE18_SUBSUITE=1` sentinel (early return to prevent infinite recursion).
  2. Exports `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` and `CLAUDE_SECURE_BREW_PREFIX_OVERRIDE="$REPO_ROOT/tests/fixtures/brew"`.
  3. Re-invokes `bash "$REPO_ROOT/tests/test-phase18.sh"` in a subshell and captures stdout+stderr.
  4. Asserts the subshell exits 0.
  5. Grep-asserts PASS lines for `detect_platform override macos`, `bootstrap_path macos with fake brew ok`, and `uuid_lower normalizes` (proving the macOS code paths actually ran and passed).
  6. Grep-asserts `FAILED=0` in the sub-suite output.
- **run_test line:** `"phase18 full suite under macos override (stub)"` renamed to `"phase18 full suite under macos override"` (dropping the `(stub)` suffix since it is no longer a stub).
- Final suite reports `PASSED=17 FAILED=0` (up from 15 pre-Plan-05 due to two new tests: install.sh prologue + real TEST-01 sub-suite).

Final line count: 460 lines (was 345, +115 for the new test + real sub-suite implementation).

## Phase 18 requirement coverage

| Req     | Closing Plan | Passing test(s)                                                                                                                            |
| ------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| PLAT-02 | Plan 01      | test_detect_platform_linux_native, test_detect_platform_override_{macos,linux,wsl2,rejects_bogus}                                         |
| PLAT-03 | Plan 02      | test_install_bootstraps_brew_deps (real, Plan 02)                                                                                         |
| PLAT-04 | Plan 02      | test_install_verifies_post_bootstrap (real, Plan 02)                                                                                      |
| PORT-01 | Plans 02-05  | test_bootstrap_path_macos_{with_fake_brew_succeeds,without_brew_fails_loud}, test_install_sh_has_phase18_prologue (Plan 05)               |
| PORT-02 | Plans 03+05  | test_caller_prologue_reexecs_into_brew_bash (bin/claude-secure + run-tests.sh), test_install_sh_has_phase18_prologue (install.sh, Plan 05) |
| PORT-03 | Plan 04      | test_no_flock_in_host_scripts, test_reap_mkdir_lock_{single_flight,stale_reclaim}                                                          |
| PORT-04 | Plan 04      | test_hook_uuidgen_is_lowercased                                                                                                            |
| TEST-01 | Plans 01+05  | CLAUDE_SECURE_PLATFORM_OVERRIDE mock honored by lib/platform.sh (Plan 01) + test_phase18_full_suite_under_macos_override (Plan 05)        |

All 8 Phase 18 requirements have at least one real passing test after Plan 05.

## Cross-plan dependency chain that closed in Plan 05

1. **Plan 01** introduced `lib/platform.sh` and filled test-phase18.sh with PLAT-02 / TEST-01 assertions plus five STUBs for Plans 02-05.
2. **Plan 02** added `macos_bootstrap_deps` to install.sh, renamed the inline `detect_platform` → `legacy_detect_platform` as a transitional measure, and replaced the two PLAT-03/PLAT-04 stubs with real tests.
3. **Plan 03** added the re-exec prologue to bin/claude-secure and run-tests.sh, and replaced the caller-prologue stub with a static-assertion test.
4. **Plan 04** swapped do_reap from flock to mkdir-lock, added uuidgen lowercasing to the pre-tool-use hook, and replaced the flock + uuidgen stubs with real tests.
5. **Plan 05 (this plan)** closed the remaining gaps: the install.sh prologue (deferred from Plan 02 to avoid a files_modified conflict with PLAT-03/PLAT-04), the legacy_detect_platform removal, and the TEST-01 end-to-end sub-suite that proves the whole Phase 18 contract on Linux CI.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 - Blocker] Rewrote bash 3.2 safety comment to remove literal `[[`**
- **Found during:** Task 1 GREEN
- **Issue:** The TDD RED test for Task 1 included a grep-based regex `sed -n '1,17p' install.sh | grep -qE '\[\[|\$\{[A-Z_]+,,|declare -A'` to enforce bash 3.2 safety in the prologue. The plan's suggested comment text "(no double-bracket `[[`, no var lowercasing, no declare -A)" contained a literal `[[` that the regex matched as a false positive.
- **Fix:** Reworded the comment to "no double-bracket tests, no lowercasing, no associative arrays" — same meaning, no literal `[[`. The regex is the normative check; the comment is purely documentation.
- **Files modified:** install.sh (line 4)
- **Commit:** 8650a64

**2. [Rule 3 - Blocker] Rewrote `Preserved from legacy_detect_platform` comment**
- **Found during:** Task 1 GREEN
- **Issue:** The plan's suggested inline block in main() included a comment `# Preserved from legacy_detect_platform: Docker Desktop + iptables warning on WSL2`. That comment literally contained the string `legacy_detect_platform`, which violated the acceptance criterion `! grep -q 'legacy_detect_platform' install.sh`.
- **Fix:** Rewrote the comment to `# Preserved WSL2 warnings: Docker Desktop + iptables version log`.
- **Files modified:** install.sh (main() inline WSL2 block)
- **Commit:** 8650a64

**3. [Rule 2 - Missing test coverage] Added test_install_sh_has_phase18_prologue**
- **Found during:** Task 1 (TDD)
- **Issue:** Plan Task 1 was marked `tdd="true"` and listed install.sh acceptance criteria as grep-based patterns, but no existing or proposed test in test-phase18.sh encoded those assertions. `test_caller_prologue_reexecs_into_brew_bash` only covers bin/claude-secure and run-tests.sh, not install.sh.
- **Fix:** Added a new `test_install_sh_has_phase18_prologue` test that statically asserts every install.sh acceptance criterion. Wrote it FIRST (RED), then implemented install.sh changes (GREEN). This makes TDD visible on Task 1.
- **Files modified:** tests/test-phase18.sh
- **Commit:** cc960d0 (RED), 8650a64 (GREEN)

**4. [Rule 3 - Spec mismatch] Sub-suite grep patterns use report names, not function names**
- **Found during:** Task 2
- **Issue:** The plan's suggested implementation grep-asserted strings like `PASS test_detect_platform_override_macos`. But `run_test` in test-phase18.sh emits the **name** argument (e.g. `"detect_platform override macos"`), not the function name. The grep would never match.
- **Fix:** Replaced each function-name pattern with the actual `run_test` name argument: `PASS detect_platform override macos`, `PASS bootstrap_path macos with fake brew ok`, `PASS uuid_lower normalizes`.
- **Files modified:** tests/test-phase18.sh (test_phase18_full_suite_under_macos_override)
- **Commit:** 91fb909

### Deferred issues (out of scope)

**[Scope Boundary] `test_reap_dry_run` in tests/test-phase17.sh still fails**

Pre-existing Phase 17 test failure that Plan 04 marked as deferred. During Plan 05 execution I investigated further and identified the actual root cause:

- `do_reap` uses `trap ... EXIT` for lockdir cleanup. That only fires on shell exit, not on function return.
- `test-phase17.sh`'s `run_test` wrapper invokes tests in the current shell (no subshell), so after `test_reap_whole_cycle_failure_exits_nonzero` calls do_reap, the lockdir + pidfile (containing the live shell PID) persist.
- The subsequent `test_reap_dry_run` therefore hits the lock, sees its own PID alive via `kill -0`, and early-returns with "another instance is running" — never reaching the `[dry-run]` code path.
- The `reap_orphan_projects` dry-run code path is correct (verified by direct invocation outside the test harness).

Three possible fixes (all out of Plan 05 scope): (a) convert do_reap's EXIT trap to explicit cleanup at every `return` path, (b) add per-test lockdir cleanup, or (c) wrap run_test in a subshell. All three are Phase 17 surface area. Documented in full in `deferred-items.md`.

**Impact on Plan 05 verification:** Plan 05's primary verification `bash tests/test-phase18.sh` passes (17/17). The plan also listed `bash run-tests.sh test-phase17.sh test-phase18.sh` as cross-suite verification step 3, but that check inherits the pre-existing Phase 17 failure and cannot be made green without touching Phase 17 surface area.

## Manual-only verifications still outstanding from 18-VALIDATION.md

The following can ONLY be validated on real Apple hardware and are intentionally deferred to Phase 19+ integration testing:

- **PLAT-03 brew bootstrap on real Mac:** The Linux CI `test_install_bootstraps_brew_deps` stub proves the bash control flow (installer invokes `brew install bash coreutils jq` in the right order) but cannot exercise real Homebrew.
- **PORT-02 re-exec on real Apple bash 3.2:** The Linux CI tests are static-assertion tests (grep + line ordering + `bash -n`). Linux CI already runs bash 5, so the actual `exec "$__brew_bash" "$0" "$@"` branch is never fired. Only a macOS runner with Apple's bundled `/bin/bash` (3.2.57) can prove the re-exec branch completes.

Both manual verifications are explicitly scoped to Phase 22 (end-to-end integration tests on GitHub Actions macos-14 runner, pending cost decision noted in STATE.md Blockers).

## Verification commands run

```
bash tests/test-phase18.sh                                  # 17/17 PASS
bash run-tests.sh test-phase18.sh                           # 17/17 PASS
grep -q 'legacy_detect_platform' install.sh; echo $?        # 1 (not found) — OK
grep -q 'STUB: implemented' tests/test-phase18.sh; echo $?  # 1 (not found) — OK
bash -n install.sh                                          # exit 0
__INSTALL_SOURCE_ONLY=1 source ./install.sh && type detect_platform macos_bootstrap_deps main   # all three are functions
grep -nE '^[^#]*\bflock\b' install.sh bin/claude-secure run-tests.sh lib/platform.sh claude/hooks/pre-tool-use.sh   # no matches
CLAUDE_SECURE_PLATFORM_OVERRIDE=macos __PHASE18_SUBSUITE=1 CLAUDE_SECURE_BREW_PREFIX_OVERRIDE="$(pwd)/tests/fixtures/brew" bash tests/test-phase18.sh   # 17/17 PASS (recursion guard works)
```

## Commits

- `cc960d0` test(18-05): add failing test for install.sh Phase 18 prologue
- `8650a64` feat(18-05): add Phase 18 prologue to install.sh and remove legacy_detect_platform
- `91fb909` feat(18-05): implement test_phase18_full_suite_under_macos_override

## Self-Check: PASSED

- install.sh exists and contains the prologue: FOUND
- tests/test-phase18.sh contains test_phase18_full_suite_under_macos_override with __PHASE18_SUBSUITE sentinel: FOUND
- tests/test-phase18.sh contains test_install_sh_has_phase18_prologue: FOUND
- Commit cc960d0 exists: FOUND
- Commit 8650a64 exists: FOUND
- Commit 91fb909 exists: FOUND
- bash tests/test-phase18.sh exit 0 with PASSED=17 FAILED=0: FOUND
- No `legacy_detect_platform` string in install.sh: FOUND
- No `STUB: implemented` string in tests/test-phase18.sh: FOUND
