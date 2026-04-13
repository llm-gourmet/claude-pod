#!/bin/bash
# tests/test-phase18.sh -- Phase 18 (Platform Abstraction & Bash Portability)
# Wave 0 unit tests for lib/platform.sh, plus stubs for downstream plans.
#
# Real assertions cover PLAT-02 (platform detection) and TEST-01 (mockable
# detection via CLAUDE_SECURE_PLATFORM_OVERRIDE + CLAUDE_SECURE_BREW_PREFIX_OVERRIDE).
# Stub assertions stay green so the suite is green from Wave 0 forward;
# later plans (02-05) replace each stub body with a real assertion.
#
# Usage:
#   bash tests/test-phase18.sh
#   CLAUDE_SECURE_PLATFORM_OVERRIDE=macos bash tests/test-phase18.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASSED=0
FAILED=0

report() {
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name"
    PASSED=$((PASSED+1))
  else
    echo "FAIL $name"
    FAILED=$((FAILED+1))
  fi
}

run_test() {
  local name="$1"; shift
  local rc=0
  ( "$@" ) || rc=$?
  report "$name" "$rc"
  # Reset env between tests so override flags from one test don't leak.
  unset CLAUDE_SECURE_PLATFORM_OVERRIDE CLAUDE_SECURE_BREW_PREFIX_OVERRIDE __CLAUDE_SECURE_BOOTSTRAPPED
}

# Source the library under test. Idempotent guard means re-source is safe.
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/platform.sh"

# =========================================================================
# REAL TESTS — PLAT-02 + TEST-01 (Wave 0 contract)
# =========================================================================

test_detect_platform_linux_native() {
  # On a real Linux/WSL2 host (no override), detect_platform must return
  # one of {linux, wsl2}. The exact value depends on whether /proc/version
  # contains "microsoft". On a WSL2 dev box this returns wsl2; on Linux CI
  # it returns linux. Both are correct — the test only fails if neither
  # branch fires (e.g. Darwin host running this without the macos override).
  unset CLAUDE_SECURE_PLATFORM_OVERRIDE
  local r
  r="$(detect_platform)" || return 1
  case "$r" in
    linux|wsl2) return 0 ;;
    *) echo "expected linux or wsl2, got '$r'" >&2; return 1 ;;
  esac
}

test_detect_platform_override_macos() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  local r
  r="$(detect_platform)" || return 1
  [ "$r" = "macos" ] || { echo "expected macos got '$r'" >&2; return 1; }
}

test_detect_platform_override_linux() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=linux
  local r
  r="$(detect_platform)" || return 1
  [ "$r" = "linux" ] || { echo "expected linux got '$r'" >&2; return 1; }
}

test_detect_platform_override_wsl2() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=wsl2
  local r
  r="$(detect_platform)" || return 1
  [ "$r" = "wsl2" ] || { echo "expected wsl2 got '$r'" >&2; return 1; }
}

test_detect_platform_override_rejects_bogus() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=freebsd
  local err
  err="$(detect_platform 2>&1 1>/dev/null)" && return 1
  echo "$err" | grep -q "must be one of" || { echo "missing 'must be one of' in stderr: $err" >&2; return 1; }
  echo "$err" | grep -q "linux" || { echo "missing 'linux' in stderr: $err" >&2; return 1; }
  return 0
}

test_uuid_lower_normalizes() {
  local out
  out="$(claude_secure_uuid_lower)" || return 1
  [[ "$out" =~ ^[0-9a-f-]+$ ]] || { echo "expected lowercase hex UUID, got '$out'" >&2; return 1; }
}

test_brew_prefix_override_honored() {
  CLAUDE_SECURE_BREW_PREFIX_OVERRIDE=/tmp/fake-brew
  local r
  r="$(claude_secure_brew_prefix)" || return 1
  [ "$r" = "/tmp/fake-brew" ] || { echo "expected /tmp/fake-brew got '$r'" >&2; return 1; }
}

test_idempotent_sourcing() {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/platform.sh" || return 1
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/platform.sh" || return 1
  [ "$__CLAUDE_SECURE_PLATFORM_LOADED" = "1" ] || { echo "sentinel lost after re-source" >&2; return 1; }
}

test_bootstrap_path_macos_without_brew_fails_loud() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  CLAUDE_SECURE_BREW_PREFIX_OVERRIDE=""
  unset __CLAUDE_SECURE_BOOTSTRAPPED
  local err
  err="$(PATH=/usr/bin:/bin claude_secure_bootstrap_path 2>&1 1>/dev/null)" && return 1
  echo "$err" | grep -q "Homebrew is required" || { echo "missing Homebrew error: $err" >&2; return 1; }
}

test_bootstrap_path_macos_with_fake_brew_succeeds() {
  CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
  CLAUDE_SECURE_BREW_PREFIX_OVERRIDE="$REPO_ROOT/tests/fixtures/brew"
  unset __CLAUDE_SECURE_BOOTSTRAPPED
  claude_secure_bootstrap_path || { echo "bootstrap failed unexpectedly" >&2; return 1; }
  local d
  d="$(date)"
  [ "$d" = "FAKE-GNU-DATE" ] || { echo "PATH shim did not apply, date=$d" >&2; return 1; }
}

# =========================================================================
# STUBS — replaced by later plans in Phase 18
# =========================================================================

test_install_bootstraps_brew_deps() {
  echo "STUB: implemented in plan 02"
  return 0
}

test_install_verifies_post_bootstrap() {
  echo "STUB: implemented in plan 02"
  return 0
}

test_caller_prologue_reexecs_into_brew_bash() {
  echo "STUB: implemented in plan 03"
  return 0
}

test_no_flock_in_host_scripts() {
  echo "STUB: implemented in plan 04"
  return 0
}

test_hook_uuidgen_is_lowercased() {
  echo "STUB: implemented in plan 04"
  return 0
}

test_phase18_full_suite_under_macos_override() {
  echo "STUB: implemented in plan 05"
  return 0
}

# =========================================================================
# Main dispatch
# =========================================================================

echo "Phase 18 -- Wave 0 unit tests for lib/platform.sh"
echo ""

# Real tests — PLAT-02 + TEST-01
run_test "detect_platform linux native"             test_detect_platform_linux_native
run_test "detect_platform override macos"           test_detect_platform_override_macos
run_test "detect_platform override linux"           test_detect_platform_override_linux
run_test "detect_platform override wsl2"            test_detect_platform_override_wsl2
run_test "detect_platform override rejects bogus"   test_detect_platform_override_rejects_bogus
run_test "uuid_lower normalizes"                    test_uuid_lower_normalizes
run_test "brew_prefix override honored"             test_brew_prefix_override_honored
run_test "idempotent sourcing"                      test_idempotent_sourcing
run_test "bootstrap_path macos without brew fails"  test_bootstrap_path_macos_without_brew_fails_loud
run_test "bootstrap_path macos with fake brew ok"   test_bootstrap_path_macos_with_fake_brew_succeeds

# Stubs filled in by downstream plans
run_test "install bootstraps brew deps (stub)"      test_install_bootstraps_brew_deps
run_test "install verifies post bootstrap (stub)"   test_install_verifies_post_bootstrap
run_test "caller prologue re-execs brew bash (stub)" test_caller_prologue_reexecs_into_brew_bash
run_test "no flock in host scripts (stub)"          test_no_flock_in_host_scripts
run_test "hook uuidgen lowercased (stub)"           test_hook_uuidgen_is_lowercased
run_test "phase18 full suite under macos override (stub)" test_phase18_full_suite_under_macos_override

echo ""
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
