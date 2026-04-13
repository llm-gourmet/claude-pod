#!/bin/bash
# tests/test-phase19.sh -- Phase 19 (Docker Desktop Compatibility) unit tests
# Wave 0 scaffolding. Later plans replace stub bodies with real assertions:
#   - Plan 02 (COMPAT-01): Task 2 + Task 3 verify validator/Dockerfile pin + iptables probe
#   - Plan 03 (PLAT-05):   Task 4 + Task 5 + Task 6 verify install.sh version-check logic
# Wave 0's own real assertion is Task 7 (fixtures landed).
#
# Usage:
#   bash tests/test-phase19.sh

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
  unset CLAUDE_SECURE_PLATFORM_OVERRIDE CLAUDE_SECURE_BREW_PREFIX_OVERRIDE
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/platform.sh"

# =========================================================================
# STUB TESTS — filled in by downstream plans
# =========================================================================

test_compat01_base_image_pinned() {
  # COMPAT-01: validator Dockerfile must pin the bookworm slim tag.
  grep -q "^FROM python:3.11-slim-bookworm$" "$REPO_ROOT/validator/Dockerfile" || return 1
  # And the old unpinned tag must not linger.
  if grep -q "^FROM python:3.11-slim$" "$REPO_ROOT/validator/Dockerfile"; then
    return 1
  fi
  return 0
}

test_compat01_iptables_probe_present() {
  # COMPAT-01: validator.py must define an iptables_probe helper and
  # invoke it somewhere in the file (startup path).
  grep -q "^def iptables_probe" "$REPO_ROOT/validator/validator.py" || return 1
  grep -q "iptables_probe()" "$REPO_ROOT/validator/validator.py" || return 1
  grep -q "iptables probe: OK" "$REPO_ROOT/validator/validator.py" || return 1
  return 0
}

test_plat05_parses_docker_desktop_4_44_3() {
  # Source install.sh in test mode, mock `docker` to return the 4.44.3
  # fixture for `version`, and a truthy exit for `info`. Expect rc=0.
  local out rc
  out="$(
    export __INSTALL_SOURCE_ONLY=1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/install.sh"
    docker() {
      case "$1" in
        info) return 0 ;;
        version) cat "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.44.3.txt" ;;
        *) return 0 ;;
      esac
    }
    ( check_docker_desktop_version ) 2>&1
    echo "__rc=$?"
  )"
  rc="$(echo "$out" | tail -1 | sed 's/^__rc=//')"
  [ "$rc" = "0" ] || return 1
  echo "$out" | grep -q "4.44.3 satisfies" || return 1
  return 0
}

test_plat05_rejects_docker_desktop_4_28_0() {
  # Old version must trigger exit 1 with an upgrade-url error log.
  local out rc
  out="$(
    export __INSTALL_SOURCE_ONLY=1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/install.sh"
    docker() {
      case "$1" in
        info) return 0 ;;
        version) cat "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.28.0.txt" ;;
        *) return 0 ;;
      esac
    }
    ( check_docker_desktop_version ) 2>&1
    echo "__rc=$?"
  )"
  rc="$(echo "$out" | tail -1 | sed 's/^__rc=//')"
  # Expect non-zero rc (exit 1 in the subshell captured as __rc=1)
  [ "$rc" = "1" ] || return 1
  echo "$out" | grep -q "4.28.0 is installed but >= 4.44.3" || return 1
  echo "$out" | grep -q "docs.docker.com/desktop/release-notes" || return 1
  return 0
}

test_plat05_warns_on_docker_engine() {
  # Plain Docker Engine must WARN but continue (rc=0), not exit.
  local out rc
  out="$(
    export __INSTALL_SOURCE_ONLY=1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/install.sh"
    docker() {
      case "$1" in
        info) return 0 ;;
        version) cat "$REPO_ROOT/tests/fixtures/docker-version-engine.txt" ;;
        *) return 0 ;;
      esac
    }
    ( check_docker_desktop_version ) 2>&1
    echo "__rc=$?"
  )"
  rc="$(echo "$out" | tail -1 | sed 's/^__rc=//')"
  [ "$rc" = "0" ] || return 1
  echo "$out" | grep -q "Docker Desktop not detected" || return 1
  return 0
}

# =========================================================================
# REAL TESTS — Wave 0 contract (must pass from day one)
# =========================================================================

test_wave0_fixtures_landed() {
  # Verifies Task 1 of this plan: three docker version fixtures exist.
  test -f "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.44.3.txt" || return 1
  test -f "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.28.0.txt" || return 1
  test -f "$REPO_ROOT/tests/fixtures/docker-version-engine.txt" || return 1
  grep -q "Server: Docker Desktop 4.44.3" "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.44.3.txt" || return 1
  grep -q "Server: Docker Desktop 4.28.0" "$REPO_ROOT/tests/fixtures/docker-version-desktop-4.28.0.txt" || return 1
  grep -q "Server: Docker Engine" "$REPO_ROOT/tests/fixtures/docker-version-engine.txt" || return 1
  grep -q "Docker Desktop" "$REPO_ROOT/tests/fixtures/docker-version-engine.txt" && return 1
  return 0
}

# =========================================================================
# Run all tests
# =========================================================================

echo "=== Phase 19 unit tests ==="
run_test "compat01: validator base image pinned (stub)"       test_compat01_base_image_pinned
run_test "compat01: iptables probe present (stub)"            test_compat01_iptables_probe_present
run_test "plat05: parses Docker Desktop 4.44.3 (stub)"        test_plat05_parses_docker_desktop_4_44_3
run_test "plat05: rejects Docker Desktop 4.28.0 (stub)"       test_plat05_rejects_docker_desktop_4_28_0
run_test "plat05: warns on plain Docker Engine (stub)"        test_plat05_warns_on_docker_engine
run_test "wave0: phase 19 fixtures landed"                    test_wave0_fixtures_landed

echo ""
echo "Phase 19 tests: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
