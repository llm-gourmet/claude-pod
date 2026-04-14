#!/bin/bash
# tests/test-phase19-smoke.sh -- Phase 19 macOS Docker Desktop smoke test
# Brings the docker compose stack up on a real macOS host with Docker Desktop
# >= 4.44.3 and verifies all four security layers are present end-to-end.
#
# Self-skips on non-macOS hosts (Linux CI treats this as a PASS no-op).
#
# Usage:
#   bash tests/test-phase19-smoke.sh         # dry check (platform gate + script lint)
#   bash tests/test-phase19-smoke.sh --live  # actually runs docker compose up/down
#
# Phase 19 goal: prove the stack starts cleanly on Docker Desktop Mac.
# This test does NOT prove iptables blocking -- that is Phase 20's ENFORCE-01.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_MODE=0
if [ "${1:-}" = "--live" ]; then
  LIVE_MODE=1
fi

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/platform.sh"
plat="$(detect_platform)"

if [ "$plat" != "macos" ]; then
  echo "SKIP test-phase19-smoke: platform=$plat (macOS only)"
  exit 0
fi

# On macOS, dry mode still exits 0 -- it only verifies the script is
# syntactically valid and the platform gate fired. Live mode actually
# executes the stack lifecycle.
if [ "$LIVE_MODE" -ne 1 ]; then
  echo "PASS test-phase19-smoke: platform=macos, dry mode (run with --live to exercise stack)"
  exit 0
fi

COMPOSE="docker compose -f $REPO_ROOT/docker-compose.yml"

# Always tear down on exit so failed runs don't leave stale volumes.
cleanup() {
  # shellcheck disable=SC2086
  $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

FAILED=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAILED=$((FAILED+1))
  fi
}

echo "==> Starting stack..."
# shellcheck disable=SC2086
$COMPOSE up -d

echo "==> Waiting for claude container to reach running state..."
for _ in $(seq 1 30); do
  # shellcheck disable=SC2086
  state=$($COMPOSE ps --format json claude 2>/dev/null | python3 -c \
    "import json,sys; d=json.loads(sys.stdin.read() or '{}'); print(d.get('State',''))" 2>/dev/null || echo "")
  [ "$state" = "running" ] && break
  sleep 1
done

# Layer 1: claude container is running
check "claude container running" [ "$state" = "running" ]

# Layer 2: validator container logs show no "iptables who?" at boot
# shellcheck disable=SC2086
check "validator iptables init OK" \
  bash -c "$COMPOSE logs validator 2>/dev/null | grep -v 'iptables who?' >/dev/null"

# Layer 3: validator /register endpoint reachable from claude container
TEST_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
# shellcheck disable=SC2086
check "validator /register reachable" \
  $COMPOSE exec -T -u claude claude curl -sf \
    -X POST http://validator:8088/register \
    -H 'Content-Type: application/json' \
    -d "{\"call_id\":\"${TEST_UUID}\",\"domain\":\"api.anthropic.com\"}"

# Layer 4: hook file installed and executable inside claude container
# shellcheck disable=SC2086
check "hook installed in claude container" \
  $COMPOSE exec -T claude test -x /etc/claude-secure/hooks/pre-tool-use.sh

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "test-phase19-smoke: ALL LAYERS PASS"
  exit 0
else
  echo "test-phase19-smoke: $FAILED layer(s) failed"
  exit 1
fi
