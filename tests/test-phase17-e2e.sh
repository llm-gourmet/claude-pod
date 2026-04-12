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
LISTENER_PORT="${LISTENER_PORT:-19117}"  # Phase 17 E2E -- avoids collision with unit harness 19017
CONFIG_DIR=""

cleanup() {
  local rc=$?
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  # D-16: force-reap any cs-e2e- containers (orphan sentinel or spawn leaks)
  # so the next run starts clean. REAPER_ORPHAN_AGE_SECS=0 counts ALL ages as
  # orphan (Pitfall 4: no backdating). Suppress all errors -- the trap must
  # not mask the original exit code.
  REAPER_ORPHAN_AGE_SECS=0 INSTANCE_PREFIX="cs-e2e-" \
    "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1 || true
  # Best-effort: also remove the scenario-4 inspect container if it survived.
  docker rm -f cs-e2e-limits-claude >/dev/null 2>&1 || true
  rm -rf "$TEST_TMPDIR"
  return $rc
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
# Local bare git repo helper -- creates $TEST_TMPDIR/<name>.git seeded with
# one initial commit on main, echoes the file:// URL.
# Mirrors tests/test-phase16.sh::setup_bare_repo so publish_report has a
# real branch to clone --depth 1 --branch main from.
# =========================================================================
setup_bare_repo() {
  local label="${1:-e2e-reports}"
  local bare="$TEST_TMPDIR/${label}.git"
  local seed="$TEST_TMPDIR/${label}-seed"
  rm -rf "$bare" "$seed"
  git init --bare --initial-branch=main "$bare" >/dev/null 2>&1 \
    || git init --bare "$bare" >/dev/null 2>&1
  git clone "$bare" "$seed" >/dev/null 2>&1
  (
    cd "$seed"
    git config user.email "seed@test.local"
    git config user.name "seed"
    git checkout -B main >/dev/null 2>&1 || true
    : > .gitkeep
    git add .gitkeep
    git commit -m "seed" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$seed"
  printf 'file://%s' "$bare"
}

# =========================================================================
# E2E profile setup (D-13, D-16). Copies the profile-e2e fixture into a
# fresh $CONFIG_DIR under $TEST_TMPDIR, runtime-injects a bare file:// repo
# URL into profile.json .report_repo, adds a workspace field so spawn's
# validate_profile doesn't balk, verifies Pitfall 13 (no ghp_ prefix in the
# fixture .env), and points at the Phase 16 envelope stub so no real Claude
# calls happen.
# =========================================================================
setup_e2e_profile() {
  if [ ! -d "$PROJECT_DIR/tests/fixtures/profile-e2e" ]; then
    echo "FAIL setup: missing tests/fixtures/profile-e2e (created in 17-01 Task 3)" >&2
    return 1
  fi
  if [ ! -f "$PROJECT_DIR/tests/fixtures/profile-e2e/profile.json" ]; then
    echo "FAIL setup: missing tests/fixtures/profile-e2e/profile.json" >&2
    return 1
  fi

  local bare
  bare=$(setup_bare_repo "e2e-reports")
  [ -n "$bare" ] || { echo "FAIL setup: bare repo creation returned empty" >&2; return 1; }

  export CONFIG_DIR="$TEST_TMPDIR/.claude-secure"
  export CLAUDE_SECURE_INSTANCE=e2e
  export INSTANCE_PREFIX="cs-e2e-"
  mkdir -p "$CONFIG_DIR/profiles" "$CONFIG_DIR/logs" "$CONFIG_DIR/events" \
           "$TEST_TMPDIR/workspace-e2e"

  # Copy the fixture tree into the profile location the loader expects.
  cp -r "$PROJECT_DIR/tests/fixtures/profile-e2e" "$CONFIG_DIR/profiles/e2e"

  # Runtime-inject the bare repo file:// URL into profile.json .report_repo,
  # and add the .workspace field (required by load_profile_config) pointing
  # at a throwaway dir. jq tempfile pattern used per fixture.
  local profile_json="$CONFIG_DIR/profiles/e2e/profile.json"
  jq --arg url "$bare" --arg ws "$TEST_TMPDIR/workspace-e2e" '.report_repo = $url | .workspace = $ws' "$profile_json" > "$profile_json.new"
  mv "$profile_json.new" "$profile_json"

  # Pitfall 13 guardrail: verify the fixture .env does NOT carry a ghp_ prefix.
  if grep -q '^REPORT_REPO_TOKEN=ghp_' "$CONFIG_DIR/profiles/e2e/.env"; then
    echo "FAIL setup: fixture .env has ghp_ prefix (Pitfall 13 violation)" >&2
    return 1
  fi

  # Minimal whitelist so any accidental validate_profile call doesn't break.
  echo '{}' > "$CONFIG_DIR/profiles/e2e/whitelist.json"

  # Phase 16 stub: point at the envelope fixture so the stubbed Claude
  # returns a valid envelope (D-13: no real Anthropic calls).
  export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$PROJECT_DIR/tests/fixtures/envelope-success.json"
  return 0
}

# =========================================================================
# Listener subprocess lifecycle. Generates a temp webhook.json matching the
# Phase 14 Config schema, launches python3 webhook/listener.py in the
# background, polls /health until ready or a 10s deadline, and captures
# LISTENER_PID for the cleanup trap.
# =========================================================================
start_listener() {
  LISTENER_PORT="${LISTENER_PORT:-19117}"

  local webhook_cfg="$TEST_TMPDIR/webhook.json"
  cat > "$webhook_cfg" <<EOF
{
  "bind": "127.0.0.1",
  "port": $LISTENER_PORT,
  "max_concurrent_spawns": 3,
  "profiles_dir": "$CONFIG_DIR/profiles",
  "events_dir": "$CONFIG_DIR/events",
  "logs_dir": "$CONFIG_DIR/logs",
  "claude_secure_bin": "$PROJECT_DIR/bin/claude-secure"
}
EOF

  # Launch listener in background. Env is inherited by subprocess.Popen so
  # CLAUDE_SECURE_FAKE_CLAUDE_STDOUT and CONFIG_DIR flow into `claude-secure spawn`.
  (
    cd "$PROJECT_DIR"
    PATH="$PROJECT_DIR/bin:$PATH" \
    CONFIG_DIR="$CONFIG_DIR" \
    CLAUDE_SECURE_INSTANCE=e2e \
    INSTANCE_PREFIX="cs-e2e-" \
    CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$CLAUDE_SECURE_FAKE_CLAUDE_STDOUT" \
    python3 webhook/listener.py --config "$webhook_cfg" \
      >"$TEST_TMPDIR/listener.stdout" 2>"$TEST_TMPDIR/listener.stderr" &
    echo $! > "$TEST_TMPDIR/listener.pid"
  )
  sleep 0.5
  LISTENER_PID=$(cat "$TEST_TMPDIR/listener.pid" 2>/dev/null)
  [ -n "$LISTENER_PID" ] \
    || { echo "FAIL start_listener: no PID captured" >&2; return 1; }

  # Poll /health for up to 10 seconds before giving up.
  local deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$LISTENER_PORT/health" 2>/dev/null | grep -q '^200$'; then
      return 0
    fi
    if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
      echo "FAIL start_listener: listener died during startup" >&2
      cat "$TEST_TMPDIR/listener.stderr" >&2 || true
      return 1
    fi
    sleep 0.2
  done
  echo "FAIL start_listener: /health not reachable within 10s" >&2
  cat "$TEST_TMPDIR/listener.stderr" >&2 || true
  return 1
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
