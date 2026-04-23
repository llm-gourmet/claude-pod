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

cleanup() {
  cd "$PROJECT_DIR"
  docker compose down -v 2>/dev/null || true
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
export LOG_HOOK=1 LOG_ANTHROPIC=1 LOG_IPTABLES=1
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
    'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hello\"}}" | bash /etc/claude-pod/hooks/pre-tool-use.sh' \
    >/dev/null 2>&1 || true
  sleep 1
  docker compose exec -T claude test -s /var/log/claude-pod/hook.jsonl 2>/dev/null
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
  docker compose exec -T proxy test -s /var/log/claude-pod/anthropic.jsonl 2>/dev/null
)
report "LOG-02" "Proxy writes JSONL when LOG_ANTHROPIC=1" $?

# =========================================================================
# LOG-03: Validator writes JSON log when LOG_IPTABLES=1
# =========================================================================
(
  cd "$PROJECT_DIR"
  # Validator logs on startup (iptables setup, DB init)
  docker compose exec -T validator test -s /var/log/claude-pod/iptables.jsonl 2>/dev/null
)
report "LOG-03" "Validator writes JSONL when LOG_IPTABLES=1" $?

# =========================================================================
# LOG-04: All three JSONL files exist inside their respective containers
# =========================================================================
(
  cd "$PROJECT_DIR"
  RESULT=0
  docker compose exec -T claude   test -s /var/log/claude-pod/hook.jsonl     2>/dev/null || RESULT=1
  docker compose exec -T proxy    test -s /var/log/claude-pod/anthropic.jsonl 2>/dev/null || RESULT=1
  docker compose exec -T validator test -s /var/log/claude-pod/iptables.jsonl  2>/dev/null || RESULT=1
  exit "$RESULT"
)
report "LOG-04" "All three JSONL files exist inside their containers" $?

# =========================================================================
# LOG-05: JSON structure -- all entries have ts, svc, level, msg fields
# =========================================================================
(
  cd "$PROJECT_DIR"
  LOG05_OK=0
  if ! docker compose exec -T claude head -1 /var/log/claude-pod/hook.jsonl 2>/dev/null \
      | jq -e '.ts and .svc and .level and .msg' >/dev/null 2>&1; then
    LOG05_OK=1
  fi
  if ! docker compose exec -T proxy head -1 /var/log/claude-pod/anthropic.jsonl 2>/dev/null \
      | jq -e '.ts and .svc and .level and .msg' >/dev/null 2>&1; then
    LOG05_OK=1
  fi
  if ! docker compose exec -T validator head -1 /var/log/claude-pod/iptables.jsonl 2>/dev/null \
      | jq -e '.ts and .svc and .level and .msg' >/dev/null 2>&1; then
    LOG05_OK=1
  fi
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
  export LOG_HOOK=0 LOG_ANTHROPIC=0 LOG_IPTABLES=0
  docker compose up -d 2>/dev/null
  sleep 5
  # Trigger a proxy request to give services a chance to log
  docker compose exec -T claude curl -s http://proxy:8080/v1/messages \
    -X POST -H 'Content-Type: application/json' \
    -d '{"model":"test","messages":[]}' >/dev/null 2>&1 || true
  sleep 2
  FOUND_LOGS=false
  if docker compose exec -T claude test -s /var/log/claude-pod/hook.jsonl 2>/dev/null; then
    FOUND_LOGS=true
  fi
  if docker compose exec -T proxy test -s /var/log/claude-pod/anthropic.jsonl 2>/dev/null; then
    FOUND_LOGS=true
  fi
  if docker compose exec -T validator test -s /var/log/claude-pod/iptables.jsonl 2>/dev/null; then
    FOUND_LOGS=true
  fi
  docker compose down -v 2>/dev/null || true
  if [ "$FOUND_LOGS" = "false" ]; then
    exit 0
  fi
  exit 1
)
report "LOG-06" "No JSONL files created when logging disabled" $?

# =========================================================================
# LOG-07: claude-pod logs command exists
# =========================================================================
(
  RESULT=0
  grep -q 'logs)' "$PROJECT_DIR/bin/claude-pod" || RESULT=1
  grep -q 'tail -f' "$PROJECT_DIR/bin/claude-pod" || RESULT=1
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
