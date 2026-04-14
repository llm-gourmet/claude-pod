---
phase: 18-platform-abstraction-bash-portability
plan: 02
subsystem: installer
tags: [installer, macos, homebrew, bootstrap, platform-abstraction]
dependency-graph:
  requires:
    - 18-01 (lib/platform.sh, tests/test-phase18.sh skeleton with the two PLAT-03/PLAT-04 stubs)
  provides:
    - install.sh: macos_bootstrap_deps function (PLAT-03 + PLAT-04)
    - install.sh: __INSTALL_SOURCE_ONLY=1 source guard for unit tests
    - install.sh: legacy_detect_platform (renamed from inline detect_platform; Plan 03 retires it)
    - tests/test-phase18.sh: real PLAT-03/PLAT-04 assertions (replacing Plan 01 stubs)
  affects:
    - install.sh check_dependencies() ordering (macos brew bootstrap runs BEFORE apt-style audit)
tech-stack:
  added: []
  patterns:
    - mocked-brew-via-PATH-sandbox + CLAUDE_SECURE_PLATFORM_OVERRIDE=macos for Linux-CI macOS branch coverage
    - source-only guard pattern (__INSTALL_SOURCE_ONLY=1) mirroring bin/claude-secure
key-files:
  created:
    - .planning/phases/18-platform-abstraction-bash-portability/18-02-SUMMARY.md
  modified:
    - install.sh
    - tests/test-phase18.sh
decisions:
  - "macos_bootstrap_deps invoked from inside check_dependencies() (not main()) because jq is part of the audited apt-style command list and must be present before that audit runs"
  - "legacy_detect_platform rename keeps the existing global PLATFORM-setting behavior intact for Phase 19 callers; Plan 03 will retire it in favor of lib/platform.sh detect_platform"
  - "Mock-brew test pattern uses CLAUDE_SECURE_PLATFORM_OVERRIDE=macos + stub brew on PATH so Linux CI can exercise the macOS branch end-to-end without a real Mac"
metrics:
  duration: ~10min
  completed: 2026-04-13T09:58:00Z
  tasks: 2
  files: 2
requirements: [PLAT-03, PLAT-04]
---

# Phase 18 Plan 02: macOS Homebrew Bootstrap in install.sh Summary

## One-Liner

Wires `macos_bootstrap_deps` into `install.sh check_dependencies()` so PLAT-03 (brew detection with actionable error) and PLAT-04 (brew install bash coreutils jq + post-bootstrap verification) are end-to-end testable on Linux CI via a mocked `brew` binary on PATH plus `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos`.

## What Shipped

### install.sh patches (file-level diff)

| Section (post-patch) | Change |
|---|---|
| Top of file (line 4-6) | Added `source "$SCRIPT_DIR/lib/platform.sh"` immediately after `SCRIPT_DIR=` so the library is loaded before any function executes. The library exposes `detect_platform` which `check_dependencies()` now calls. |
| New function `macos_bootstrap_deps` (52 lines, inserted after `log_error()`) | PLAT-03 detects `command -v brew`; if missing, logs the exact `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` install command and exits 1. PLAT-04 loops `for formula in bash coreutils jq` calling `brew list --formula` (skip if installed) or `brew install`. Post-bootstrap verifies `[ -x $brew_prefix/bin/bash ]`, `[ -d $brew_prefix/opt/coreutils/libexec/gnubin ]`, and `command -v jq`; emits `Post-bootstrap verification FAILED` and exits 1 if any are missing. |
| `check_dependencies()` body | Inserted a 5-line block at the top that calls `_plat="$(detect_platform)"` and runs `macos_bootstrap_deps` if `$_plat = macos`, BEFORE the existing `command -v docker/curl/jq/uuidgen` audit. This ordering is critical because on a fresh Mac, jq is provided by `brew install jq` inside `macos_bootstrap_deps` — auditing first would always fail. |
| `detect_platform()` -> `legacy_detect_platform()` | Renamed the existing inline function (the WSL2 detection + global PLATFORM setter) to `legacy_detect_platform` so it does not shadow the lib/platform.sh `detect_platform` that `check_dependencies()` now calls. The renamed function's body is unchanged. |
| `main()` flow | One-line edit: `detect_platform` -> `legacy_detect_platform`. All other `main()` calls unchanged. |
| End-of-file guard | `if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [ "${__INSTALL_SOURCE_ONLY:-0}" != "1" ]; then main "$@"; fi`. The new guard lets unit tests source install.sh via `__INSTALL_SOURCE_ONLY=1` without triggering the full installer. Pattern mirrors `bin/claude-secure:1672-1676`. |

### tests/test-phase18.sh patches

Replaced the two Plan 01 stub functions with real implementations:

- **`test_install_bootstraps_brew_deps`**: builds a sandbox under `mktemp -d` with a stub `brew` on PATH that logs every invocation to `$sandbox/brew.log`, reports `brew list` as not-installed (so the install loop runs), and `brew --prefix` returns a fake prefix populated with `bin/bash` and `opt/coreutils/libexec/gnubin/date`. Sources install.sh under `__INSTALL_SOURCE_ONLY=1` + `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos`, calls `macos_bootstrap_deps` in a subshell, asserts the brew log contains `install bash`, `install coreutils`, AND `install jq`.
- **`test_install_verifies_post_bootstrap`**: same sandbox pattern but stub `brew` reports all formulae as already installed (`brew list` returns 0) AND the fake prefix intentionally OMITS the `opt/coreutils/libexec/gnubin` directory. Asserts `macos_bootstrap_deps` exits non-zero with stderr containing `Post-bootstrap verification FAILED` and `coreutils`.

The `run_test` invocations for both tests already exist from Plan 01 and were not modified.

## Reusable mock-brew test pattern (for downstream plans)

Future plans needing to exercise install.sh's macOS branch on Linux CI can reuse this pattern verbatim:

```bash
# 1. Sandbox + fake brew prefix
local sandbox; sandbox="$(mktemp -d)"
local fake_prefix="$sandbox/brew"
mkdir -p "$fake_prefix/bin" "$fake_prefix/opt/coreutils/libexec/gnubin" "$sandbox/bin"
touch "$fake_prefix/bin/bash"; chmod +x "$fake_prefix/bin/bash"
touch "$fake_prefix/opt/coreutils/libexec/gnubin/date"; chmod +x "$fake_prefix/opt/coreutils/libexec/gnubin/date"

# 2. Stub brew on PATH
cat > "$sandbox/bin/brew" <<STUB
#!/bin/bash
case "\$1" in
  list) exit 0 ;;     # 0=installed, 1=not-installed
  install) exit 0 ;;
  --prefix) echo "$fake_prefix"; exit 0 ;;
esac
STUB
chmod +x "$sandbox/bin/brew"

# 3. Stub jq on PATH (so command -v jq passes post-bootstrap)
cat > "$sandbox/bin/jq" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$sandbox/bin/jq"

# 4. Source install.sh in a subshell with the macOS override
local rc=0 out
out="$(
  export PATH="$sandbox/bin:$PATH"
  export __INSTALL_SOURCE_ONLY=1
  export CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  source "$REPO_ROOT/install.sh"
  macos_bootstrap_deps 2>&1
)" || rc=$?
```

The two key environment hooks are `__INSTALL_SOURCE_ONLY=1` (suppresses `main`) and `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` (forces lib/platform.sh `detect_platform` to return `macos` even on a Linux runner).

## legacy_detect_platform rename — caller audit

Confirmed via grep on the worktree at completion time:

- ONE caller of `detect_platform`: the new `check_dependencies()` branch, which intentionally calls the lib/platform.sh version.
- ONE caller of `legacy_detect_platform`: the `main()` flow, which preserves existing PLATFORM-setting behavior for downstream functions until Plan 03 retires it.
- No other source file in the worktree references the old inline `detect_platform()`.

Plan 03 will retire `legacy_detect_platform` and route every site through `lib/platform.sh detect_platform` plus the bash 4+ re-exec prologue.

## Verification Results

```
$ bash -n install.sh; echo $?
0

$ __INSTALL_SOURCE_ONLY=1 bash -c 'source ./install.sh; type macos_bootstrap_deps; type legacy_detect_platform; type detect_platform'
macos_bootstrap_deps is a function
legacy_detect_platform is a function
detect_platform is a function

$ bash tests/test-phase18.sh
PASS detect_platform linux native
PASS detect_platform override macos
PASS detect_platform override linux
PASS detect_platform override wsl2
PASS detect_platform override rejects bogus
PASS uuid_lower normalizes
PASS brew_prefix override honored
PASS idempotent sourcing
PASS bootstrap_path macos without brew fails
PASS bootstrap_path macos with fake brew ok
PASS install bootstraps brew deps (stub)        <-- now real
PASS install verifies post bootstrap (stub)     <-- now real
PASS caller prologue re-execs brew bash (stub)  <-- still STUB; Plan 03
PASS no flock in host scripts (stub)            <-- still STUB; Plan 04
PASS hook uuidgen lowercased (stub)             <-- still STUB; Plan 04
PASS phase18 full suite under macos override (stub) <-- still STUB; Plan 05
PASSED=16 FAILED=0

$ ! grep -nE 'STUB: implemented in plan 02' tests/test-phase18.sh; echo $?
0   (no Plan 02 stubs remain)
```

NOTE: the `(stub)` text in the run_test labels is a Plan 01 artifact (descriptive label only). The plan instructed not to edit run_test invocations. Plans 03/04/05 will drop the `(stub)` suffix from their corresponding labels when they replace the bodies.

All Plan 02 success criteria met.

## Deviations from Plan

None — plan executed exactly as written. The two install.sh tasks and the test-phase18.sh stub replacement landed on top of Plan 01 cleanly with no architectural surprises.

## Authentication Gates

None.

## Known Stubs

Four cross-plan handshake stubs remain in `tests/test-phase18.sh` (`test_caller_prologue_reexecs_into_brew_bash`, `test_no_flock_in_host_scripts`, `test_hook_uuidgen_is_lowercased`, `test_phase18_full_suite_under_macos_override`). These are intentional and documented in Plan 01's spec — Plans 03/04/05 will replace each in turn. They are NOT goal-blocking for Plan 02.

## Self-Check: PASSED

- install.sh: FOUND, syntax OK, contains `macos_bootstrap_deps`, `brew install`, `Homebrew is required on macOS`, the literal install URL, `for formula in bash coreutils jq`, `legacy_detect_platform`, `__INSTALL_SOURCE_ONLY`
- tests/test-phase18.sh: FOUND, executable, real `test_install_bootstraps_brew_deps` and `test_install_verifies_post_bootstrap` defined, no `STUB: implemented in plan 02` markers remain
- Commits: 38b2a9f (Task 1 install.sh) FOUND, cb3b22c (Task 2 tests) FOUND
- All 16 tests in `bash tests/test-phase18.sh` pass with `FAILED=0`
- `bash -n install.sh` exits 0
- `__INSTALL_SOURCE_ONLY=1 bash -c 'source ./install.sh; ...'` resolves all three function types
