#!/bin/bash
# tests/test-phase17-e2e.sh -- Phase 17 Operational Hardening E2E test suite
# OPS-03 (Container reaper + end-to-end integration coverage)
#
# Purpose: exercise the full webhook -> spawn -> report pipeline against the
# real Docker stack with a STUBBED Claude binary (CLAUDE_SECURE_FAKE_CLAUDE_STDOUT)
# to keep runtime under the 90-second budget and avoid real API costs.
#
# Scenarios (D-14):
#   1. HMAC rejection            -- wrong signature -> 401, no spawn, no audit
#   2. Concurrent execution      -- 3 parallel valid POSTs, all reports pushed
#   3. Resource limit enforcement -- docker inspect verifies mem_limit: 1g
#   4. Orphan cleanup            -- backdated sentinel container reaped by
#                                   `claude-secure reap`; real containers untouched
#
# Wave 0 contract (Nyquist): all 4 scenarios + the budget gate FAIL as
# NOT IMPLEMENTED until 17-03 (Wave 1b) wires the real integration.
#
# Guardrails:
#   - INSTANCE_PREFIX=cs-e2e- so the suite never collides with the operator's
#     real instance
#   - Cleanup trap removes $TEST_TMPDIR and best-effort reaps any stray
#     cs-e2e- containers via REAPER_ORPHAN_AGE_SECS=0
#   - 90s wall-clock budget enforced between scenarios via check_budget()
#
# Usage:
#   bash tests/test-phase17-e2e.sh                            # run full suite
#   bash tests/test-phase17-e2e.sh scenario_hmac_rejection    # run single scenario

set -uo pipefail

E2E_BUDGET=90
PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d -t cs-e2e-XXXXXXXX)
LISTENER_PID=""
LISTENER_PORT=19117  # Phase 17 E2E -- avoids collision with unit harness 19017

cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  # Best-effort reaper pass: if any cs-e2e- containers survived a failing
  # scenario, force-reap them so the next run starts clean. Suppress all
  # errors -- the trap must not mask the original exit code.
  INSTANCE_PREFIX="cs-e2e-" REAPER_ORPHAN_AGE_SECS=0 \
    "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1 || true
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# =========================================================================
# Budget gate: halts the suite immediately if wall-clock exceeds $E2E_BUDGET.
# Called between scenarios so a runaway test can't silently blow past 90s.
# =========================================================================
check_budget() {
  if [ "$SECONDS" -gt "$E2E_BUDGET" ]; then
    echo "FAIL: E2E budget exceeded (${SECONDS}s > ${E2E_BUDGET}s)"
    exit 1
  fi
}

# =========================================================================
# Tooling preflight. Each tool is hard-required: the harness exits 1 with
# a clear error if any is missing rather than failing deep inside a scenario.
# =========================================================================
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool not on PATH: $tool" >&2
    exit 1
  fi
}

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL+1))
  if "$@"; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL+1))
  fi
}

# =========================================================================
# E2E profile setup. In Wave 0 this is only a presence check against the
# profile-e2e fixture tree created by 17-01 Task 3. In 17-03 this will be
# expanded to: clone the fixture to $TEST_TMPDIR/profiles/e2e, generate a
# bare report repo under $TEST_TMPDIR/report-repo-bare.git, rewrite
# profile.json report_repo to the file:// URL, start the listener on
# LISTENER_PORT, etc.
# =========================================================================
setup_e2e_profile() {
  if [ ! -d "$PROJECT_DIR/tests/fixtures/profile-e2e" ]; then
    echo "FAIL: missing tests/fixtures/profile-e2e (created in 17-01 Task 3)" >&2
    return 1
  fi
  if [ ! -f "$PROJECT_DIR/tests/fixtures/profile-e2e/profile.json" ]; then
    echo "FAIL: missing tests/fixtures/profile-e2e/profile.json" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# SCENARIOS (Wave 0 sentinels -- flipped green by 17-03)
# =========================================================================

scenario_hmac_rejection() {
  echo "NOT IMPLEMENTED: flipped green by 17-03 (E2E wiring: wrong HMAC sig -> 401, no spawn, audit unchanged)"
  return 1
}

scenario_concurrent_execution() {
  echo "NOT IMPLEMENTED: flipped green by 17-03 (3 parallel valid POSTs -> 3 audit lines + 3 reports, no jsonl corruption)"
  return 1
}

scenario_orphan_cleanup() {
  echo "NOT IMPLEMENTED: flipped green by 17-03 (uses REAPER_ORPHAN_AGE_SECS=0 per Pitfall 4; sentinel cs-e2e- container reaped)"
  return 1
}

scenario_resource_limits() {
  echo "NOT IMPLEMENTED: flipped green by 17-03 (depends on 17-02 mem_limit: 1g in docker-compose.yml; docker inspect assertion)"
  return 1
}

test_e2e_budget_under_90s() {
  echo "NOT IMPLEMENTED: flipped green by 17-03 (final assertion: SECONDS <= E2E_BUDGET after all scenarios complete)"
  return 1
}

# =========================================================================
# Main dispatch
# =========================================================================

# Single-function mode: bash tests/test-phase17-e2e.sh scenario_hmac_rejection
if [ $# -eq 1 ]; then
  "$1"
  exit $?
fi

require_tool docker
require_tool curl
require_tool openssl
require_tool xxd
require_tool jq
require_tool python3
require_tool git

echo "Phase 17 E2E -- Wave 0 scaffold (all scenarios FAIL as NOT IMPLEMENTED)"
echo "Budget: ${E2E_BUDGET} seconds"
echo ""

SECONDS=0

setup_e2e_profile || { echo "FAIL: setup_e2e_profile"; exit 1; }

run_test "hmac rejection"       scenario_hmac_rejection
check_budget
run_test "concurrent execution" scenario_concurrent_execution
check_budget
run_test "resource limits"      scenario_resource_limits
check_budget
run_test "orphan cleanup"       scenario_orphan_cleanup
check_budget
run_test "budget under 90s"     test_e2e_budget_under_90s

echo ""
echo "Phase 17 E2E: $PASS/$TOTAL passed, $FAIL failed (in ${SECONDS}s, budget ${E2E_BUDGET}s)"
[ $FAIL -eq 0 ] || exit 1
