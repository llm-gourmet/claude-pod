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
  local sandbox; sandbox="$(mktemp -d)"
  local brew_log="$sandbox/brew.log"
  local fake_prefix="$sandbox/brew"
  mkdir -p "$fake_prefix/bin" "$fake_prefix/opt/coreutils/libexec/gnubin" "$sandbox/bin"
  touch "$fake_prefix/bin/bash"; chmod +x "$fake_prefix/bin/bash"
  touch "$fake_prefix/opt/coreutils/libexec/gnubin/date"; chmod +x "$fake_prefix/opt/coreutils/libexec/gnubin/date"

  cat > "$sandbox/bin/brew" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$brew_log"
case "\$1" in
  list) exit 1 ;;
  install) exit 0 ;;
  --prefix) echo "$fake_prefix"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$sandbox/bin/brew"

  cat > "$sandbox/bin/jq" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$sandbox/bin/jq"

  local rc=0 out
  out="$(
    export PATH="$sandbox/bin:$PATH"
    export __INSTALL_SOURCE_ONLY=1
    export CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
    source "$REPO_ROOT/install.sh"
    macos_bootstrap_deps 2>&1
  )" || rc=$?

  local log_contents=""
  [ -f "$brew_log" ] && log_contents="$(cat "$brew_log")"
  rm -rf "$sandbox"

  [ "$rc" = 0 ] || { echo "macos_bootstrap_deps exited $rc; output: $out" >&2; return 1; }
  echo "$log_contents" | grep -q "install bash" || { echo "brew install bash not invoked. Log: $log_contents" >&2; return 1; }
  echo "$log_contents" | grep -q "install coreutils" || { echo "brew install coreutils not invoked. Log: $log_contents" >&2; return 1; }
  echo "$log_contents" | grep -q "install jq" || { echo "brew install jq not invoked. Log: $log_contents" >&2; return 1; }
  return 0
}

test_install_verifies_post_bootstrap() {
  local sandbox; sandbox="$(mktemp -d)"
  local fake_prefix="$sandbox/brew"
  # Intentionally CREATE bin/bash but OMIT the gnubin directory — verification must fail
  mkdir -p "$fake_prefix/bin" "$sandbox/bin"
  touch "$fake_prefix/bin/bash"; chmod +x "$fake_prefix/bin/bash"
  # NOTE: $fake_prefix/opt/coreutils/libexec/gnubin deliberately not created

  cat > "$sandbox/bin/brew" <<STUB
#!/bin/bash
case "\$1" in
  list) exit 0 ;;
  install) exit 0 ;;
  --prefix) echo "$fake_prefix"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$sandbox/bin/brew"

  cat > "$sandbox/bin/jq" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$sandbox/bin/jq"

  local rc=0 out
  out="$(
    export PATH="$sandbox/bin:$PATH"
    export __INSTALL_SOURCE_ONLY=1
    export CLAUDE_SECURE_PLATFORM_OVERRIDE=macos
    source "$REPO_ROOT/install.sh"
    macos_bootstrap_deps 2>&1
  )" || rc=$?

  rm -rf "$sandbox"

  [ "$rc" -ne 0 ] || { echo "expected macos_bootstrap_deps to fail when gnubin missing; output: $out" >&2; return 1; }
  echo "$out" | grep -q "Post-bootstrap verification FAILED" || { echo "missing 'Post-bootstrap verification FAILED' message; output: $out" >&2; return 1; }
  echo "$out" | grep -q "coreutils" || { echo "missing coreutils mention in failure list; output: $out" >&2; return 1; }
  return 0
}

test_caller_prologue_reexecs_into_brew_bash() {
  local errors=0

  # bin/claude-secure assertions
  local cs="$REPO_ROOT/bin/claude-secure"
  [ -f "$cs" ] || { echo "missing $cs" >&2; return 1; }
  head -50 "$cs" | grep -q 'BASH_VERSINFO\[0\]:-0' || { echo "bin/claude-secure missing BASH_VERSINFO re-exec test" >&2; errors=$((errors+1)); }
  head -50 "$cs" | grep -q 'exec "\$__brew_bash"' || { echo "bin/claude-secure missing exec __brew_bash" >&2; errors=$((errors+1)); }
  head -50 "$cs" | grep -q 'source.*lib/platform.sh' || { echo "bin/claude-secure missing source lib/platform.sh" >&2; errors=$((errors+1)); }
  head -50 "$cs" | grep -q 'claude_secure_bootstrap_path' || { echo "bin/claude-secure missing claude_secure_bootstrap_path call" >&2; errors=$((errors+1)); }

  # Ordering: re-exec guard MUST come before `set -euo pipefail`
  local reexec_line set_line
  reexec_line="$(grep -n 'BASH_VERSINFO\[0\]:-0' "$cs" | head -1 | cut -d: -f1)"
  set_line="$(grep -n '^set -euo pipefail' "$cs" | head -1 | cut -d: -f1)"
  if [ -z "$reexec_line" ] || [ -z "$set_line" ]; then
    echo "could not locate re-exec or set line in bin/claude-secure" >&2
    errors=$((errors+1))
  elif [ "$reexec_line" -ge "$set_line" ]; then
    echo "re-exec guard (line $reexec_line) must precede set -euo pipefail (line $set_line)" >&2
    errors=$((errors+1))
  fi

  # Syntax check
  bash -n "$cs" || { echo "bin/claude-secure failed syntax check" >&2; errors=$((errors+1)); }

  # run-tests.sh assertions
  local rt="$REPO_ROOT/run-tests.sh"
  [ -f "$rt" ] || { echo "missing $rt" >&2; return 1; }
  head -30 "$rt" | grep -q 'BASH_VERSINFO\[0\]:-0' || { echo "run-tests.sh missing BASH_VERSINFO re-exec test" >&2; errors=$((errors+1)); }
  head -30 "$rt" | grep -q 'exec "\$__brew_bash"' || { echo "run-tests.sh missing exec __brew_bash" >&2; errors=$((errors+1)); }
  head -30 "$rt" | grep -q 'source.*lib/platform.sh' || { echo "run-tests.sh missing source lib/platform.sh" >&2; errors=$((errors+1)); }
  bash -n "$rt" || { echo "run-tests.sh failed syntax check" >&2; errors=$((errors+1)); }

  [ "$errors" -eq 0 ] || return 1
  return 0
}

test_no_flock_in_host_scripts() {
  local files=(
    "$REPO_ROOT/install.sh"
    "$REPO_ROOT/bin/claude-secure"
    "$REPO_ROOT/run-tests.sh"
    "$REPO_ROOT/lib/platform.sh"
    "$REPO_ROOT/claude/hooks/pre-tool-use.sh"
  )
  local f matches
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      echo "missing expected file: $f" >&2
      return 1
    fi
    # Match `flock` only on non-comment lines. A line is a comment if its first
    # non-whitespace character is #.
    matches="$(grep -nE '^[[:space:]]*[^#[:space:]].*\bflock\b|^[[:space:]]*\bflock\b' "$f" || true)"
    if [ -n "$matches" ]; then
      echo "found flock references in $f:" >&2
      echo "$matches" >&2
      return 1
    fi
  done
  return 0
}

test_hook_uuidgen_is_lowercased() {
  local hook="$REPO_ROOT/claude/hooks/pre-tool-use.sh"
  [ -f "$hook" ] || { echo "missing $hook" >&2; return 1; }

  # Must contain the lowercased pipeline
  grep -q "uuidgen | tr '\[:upper:\]' '\[:lower:\]'" "$hook" || {
    echo "claude/hooks/pre-tool-use.sh missing uuidgen | tr lowercase pipeline" >&2
    return 1
  }

  # Must NOT contain a bare call_id=$(uuidgen) (without the tr pipe)
  if grep -nE 'call_id=\$\(uuidgen\)' "$hook"; then
    echo "found bare uuidgen without lowercase normalization" >&2
    return 1
  fi
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
