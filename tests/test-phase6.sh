#!/bin/bash
# test-phase6.sh -- Integration tests for Phase 6: Service Logging
# Tests LOG-01 through LOG-07
#
# Strategy: Start Docker containers with LOG_*=1 env vars and verify JSONL
# log files are created with correct structure. Then restart with LOG_*=0
# and verify no logs are created. Verify CLI logs subcommand exists.
#
# Usage: bash tests/test-phase6.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

report() {
  local id="$1"
  local desc="$2"
  local result="$3"

  printf "  %-10s %-60s " "$id" "$desc"
  if [ "$result" -eq 0 ]; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi
}

# Create temp log directories for isolation
TEST_LOG_DIR=$(mktemp -d)
TEST_LOG_DIR_DISABLED=$(mktemp -d)
TEST_WORKSPACE=$(mktemp -d)
chmod 777 "$TEST_LOG_DIR" "$TEST_LOG_DIR_DISABLED"

cleanup() {
  cd "$PROJECT_DIR"
  LOG_HOOK=0 LOG_ANTHROPIC=0 LOG_IPTABLES=0 LOG_DIR="$TEST_LOG_DIR" \
    docker compose down -v 2>/dev/null || true
  rm -rf "$TEST_LOG_DIR" "$TEST_LOG_DIR_DISABLED" 2>/dev/null || true
  rm -rf "$TEST_WORKSPACE" 2>/dev/null || true
}
trap cleanup EXIT

echo "========================================"
echo "  Phase 6 Integration Tests"
echo "  Service Logging"
echo "  (LOG-01 -- LOG-07)"
echo "========================================"
echo ""

echo "Starting services with logging enabled..."
cd "$PROJECT_DIR"
export LOG_DIR="$TEST_LOG_DIR"
export LOG_HOOK=1 LOG_ANTHROPIC=1 LOG_IPTABLES=1
export WORKSPACE_PATH="$TEST_WORKSPACE"
docker volume rm -f claude-secure_workspace >/dev/null 2>&1 || true
docker compose up -d 2>/dev/null
sleep 5  # Wait for services to initialize and validator to write startup logs

echo ""
echo "Running tests..."
echo ""

# =========================================================================
# LOG-01: Hook writes JSON log when LOG_HOOK=1
# =========================================================================
(
  cd "$PROJECT_DIR"
  # Trigger a hook execution inside the claude container
  docker compose exec -T claude bash -c \
    'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hello\"}}" | bash /etc/claude-secure/hooks/pre-tool-use.sh' \
    >/dev/null 2>&1 || true
  sleep 1
  if [ -f "$TEST_LOG_DIR/hook.jsonl" ] && [ -s "$TEST_LOG_DIR/hook.jsonl" ]; then
    exit 0
  fi
  exit 1
)
report "LOG-01" "Hook writes JSONL when LOG_HOOK=1" $?

# =========================================================================
# LOG-02: Proxy writes JSON log when LOG_ANTHROPIC=1
# =========================================================================
(
  cd "$PROJECT_DIR"
  # Make an HTTP request through the proxy
  docker compose exec -T claude curl -s http://proxy:8080/v1/messages \
    -X POST -H 'Content-Type: application/json' \
    -d '{"model":"test","messages":[]}' >/dev/null 2>&1 || true
  sleep 1
  if [ -f "$TEST_LOG_DIR/anthropic.jsonl" ] && [ -s "$TEST_LOG_DIR/anthropic.jsonl" ]; then
    exit 0
  fi
  exit 1
)
report "LOG-02" "Proxy writes JSONL when LOG_ANTHROPIC=1" $?

# =========================================================================
# LOG-03: Validator writes JSON log when LOG_IPTABLES=1
# =========================================================================
(
  # Validator logs on startup (iptables setup, DB init)
  if [ -f "$TEST_LOG_DIR/iptables.jsonl" ] && [ -s "$TEST_LOG_DIR/iptables.jsonl" ]; then
    exit 0
  fi
  exit 1
)
report "LOG-03" "Validator writes JSONL when LOG_IPTABLES=1" $?

# =========================================================================
# LOG-04: All logs in unified host directory
# =========================================================================
(
  RESULT=0
  [ -f "$TEST_LOG_DIR/hook.jsonl" ] || RESULT=1
  [ -f "$TEST_LOG_DIR/anthropic.jsonl" ] || RESULT=1
  [ -f "$TEST_LOG_DIR/iptables.jsonl" ] || RESULT=1
  exit "$RESULT"
)
report "LOG-04" "All three JSONL files in unified host directory" $?

# =========================================================================
# LOG-05: JSON structure -- all entries have ts, svc, level, msg fields
# =========================================================================
(
  LOG05_OK=0
  for f in hook.jsonl anthropic.jsonl iptables.jsonl; do
    if [ -f "$TEST_LOG_DIR/$f" ]; then
      if ! head -1 "$TEST_LOG_DIR/$f" | jq -e '.ts and .svc and .level and .msg' >/dev/null 2>&1; then
        LOG05_OK=1
      fi
    else
      LOG05_OK=1
    fi
  done
  exit "$LOG05_OK"
)
report "LOG-05" "Log entries have ts, svc, level, msg fields" $?

# Stop services for disabled test
cd "$PROJECT_DIR"
echo ""
echo "Restarting services with logging disabled..."
docker compose down -v 2>/dev/null || true

# =========================================================================
# LOG-06: No logs when flags are 0
# =========================================================================
(
  cd "$PROJECT_DIR"
  export LOG_DIR="$TEST_LOG_DIR_DISABLED"
  export LOG_HOOK=0 LOG_ANTHROPIC=0 LOG_IPTABLES=0
  export WORKSPACE_PATH="$TEST_WORKSPACE"
  docker volume rm -f claude-secure_workspace >/dev/null 2>&1 || true
  docker compose up -d 2>/dev/null
  sleep 5
  # Trigger a proxy request to give services a chance to log
  docker compose exec -T claude curl -s http://proxy:8080/v1/messages \
    -X POST -H 'Content-Type: application/json' \
    -d '{"model":"test","messages":[]}' >/dev/null 2>&1 || true
  sleep 2
  FOUND_LOGS=false
  for f in hook.jsonl anthropic.jsonl iptables.jsonl; do
    if [ -f "$TEST_LOG_DIR_DISABLED/$f" ] && [ -s "$TEST_LOG_DIR_DISABLED/$f" ]; then
      FOUND_LOGS=true
    fi
  done
  docker compose down -v 2>/dev/null || true
  if [ "$FOUND_LOGS" = "false" ]; then
    exit 0
  fi
  exit 1
)
report "LOG-06" "No JSONL files created when logging disabled" $?

# =========================================================================
# LOG-07: claude-secure logs command exists
# =========================================================================
(
  RESULT=0
  grep -q 'logs)' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  grep -q 'tail -f' "$PROJECT_DIR/bin/claude-secure" || RESULT=1
  exit "$RESULT"
)
report "LOG-07" "logs subcommand exists in CLI with tail -f" $?

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
