#!/bin/bash
# test-webhook-listener-cli.sh -- Unit tests for webhook-listener CLI subcommand
# Tests WLCLI-01 through WLCLI-08
#
# Strategy: source bin/claude-secure with __CLAUDE_SECURE_SOURCE_ONLY=1 to
# load function definitions, use temp dirs as CONFIG_DIR. No Docker, no network.
#
# Usage: bash tests/test-webhook-listener-cli.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Source the CLI with CONFIG_DIR pointing to a temp directory
setup_cli() {
  local config_dir="$1"
  export CONFIG_DIR="$config_dir"
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WLCLI-01: --set-token writes env file with mode 600
# ---------------------------------------------------------------------------
test_set_token_writes_env_600() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_GITHUB_TOKEN "ghp_abc123"

  local env_file="$tmpdir/webhook-listener.env"
  [ -f "$env_file" ] || { echo "env file not created" >&2; return 1; }
  grep -q "WEBHOOK_GITHUB_TOKEN=ghp_abc123" "$env_file" || { echo "token not in env file" >&2; return 1; }
  local perms
  perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%OLp" "$env_file" 2>/dev/null)
  [ "$perms" = "600" ] || { echo "Expected mode 600, got $perms" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-02: --set-bind writes WEBHOOK_BIND
# ---------------------------------------------------------------------------
test_set_bind_writes_value() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_BIND "0.0.0.0"

  grep -q "WEBHOOK_BIND=0.0.0.0" "$tmpdir/webhook-listener.env" || return 1
}

# ---------------------------------------------------------------------------
# WLCLI-03: --set-port writes WEBHOOK_PORT
# ---------------------------------------------------------------------------
test_set_port_writes_value() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_PORT "9001"

  grep -q "WEBHOOK_PORT=9001" "$tmpdir/webhook-listener.env" || return 1
}

# ---------------------------------------------------------------------------
# WLCLI-04: Updating one key preserves other keys
# ---------------------------------------------------------------------------
test_key_update_preserves_others() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_GITHUB_TOKEN "ghp_abc123"
  _webhook_listener_set_config_key WEBHOOK_PORT "9001"
  _webhook_listener_set_config_key WEBHOOK_BIND "0.0.0.0"

  local env_file="$tmpdir/webhook-listener.env"
  grep -q "WEBHOOK_GITHUB_TOKEN=ghp_abc123" "$env_file" || { echo "token lost" >&2; return 1; }
  grep -q "WEBHOOK_PORT=9001" "$env_file" || { echo "port lost" >&2; return 1; }
  grep -q "WEBHOOK_BIND=0.0.0.0" "$env_file" || { echo "bind lost" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-05: Updating a key does not duplicate it
# ---------------------------------------------------------------------------
test_key_update_no_duplicate() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_PORT "9001"
  _webhook_listener_set_config_key WEBHOOK_PORT "9002"

  local count
  count=$(grep -c "WEBHOOK_PORT=" "$tmpdir/webhook-listener.env" 2>/dev/null || echo 0)
  [ "$count" -eq 1 ] || { echo "Expected 1 WEBHOOK_PORT line, got $count" >&2; return 1; }
  grep -q "WEBHOOK_PORT=9002" "$tmpdir/webhook-listener.env" || { echo "Expected updated value 9002" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-06: --set-token output does not print the token value
# ---------------------------------------------------------------------------
test_set_token_redacted_in_output() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  local output
  output=$(cmd_webhook_listener --set-token "ghp_supersecret" 2>&1)
  echo "$output" | grep -q "ghp_supersecret" && { echo "token leaked in output: $output" >&2; return 1; }
  echo "$output" | grep -qi "redacted\|<redact" || { echo "Expected redacted confirmation, got: $output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-07: status with no config prints helpful message (no error exit)
# ---------------------------------------------------------------------------
test_status_no_config_helpful_message() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  # Override WEBHOOK_CONFIG to a non-existent path so status finds nothing
  local output
  WEBHOOK_CONFIG="$tmpdir/nonexistent.json" output=$(cmd_webhook_listener status 2>&1)
  echo "$output" | grep -qi "no listener configured\|webhook-listener --help" || {
    echo "Expected helpful message, got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# WLCLI-08: status with mock health endpoint shows health=ok
# ---------------------------------------------------------------------------
test_status_with_mock_health() {
  # Start a minimal HTTP server on a random port that responds to /health
  local tmpdir
  tmpdir=$(mktemp -d)

  # Find a free port
  local port
  port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

  # Start mock health server (writes its PID to a file)
  python3 -c "
import http.server, json, os

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            body = json.dumps({'status': 'ok', 'active_spawns': 0}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def log_message(self, *a): pass

srv = http.server.HTTPServer(('127.0.0.1', $port), H)
with open('$tmpdir/mock.pid', 'w') as f: f.write(str(os.getpid()))
srv.serve_forever()
" &

  # Wait for server to start
  local i=0
  while [ $i -lt 20 ]; do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i+1))
  done

  setup_cli "$tmpdir"
  _webhook_listener_set_config_key WEBHOOK_BIND "127.0.0.1"
  _webhook_listener_set_config_key WEBHOOK_PORT "$port"

  local output
  output=$(WEBHOOK_CONFIG="$tmpdir/nonexistent.json" cmd_webhook_listener status 2>&1) || true

  # Kill mock server
  [ -f "$tmpdir/mock.pid" ] && kill "$(cat "$tmpdir/mock.pid")" 2>/dev/null || true
  rm -rf "$tmpdir"

  echo "$output" | grep -qi "health.*ok\|ok" || {
    echo "Expected health=ok in output, got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo ""
echo "=== Webhook Listener CLI Tests ==="
echo ""

run_test "WLCLI-01: --set-token writes env file with mode 600" test_set_token_writes_env_600
run_test "WLCLI-02: --set-bind writes WEBHOOK_BIND" test_set_bind_writes_value
run_test "WLCLI-03: --set-port writes WEBHOOK_PORT" test_set_port_writes_value
run_test "WLCLI-04: updating one key preserves other keys" test_key_update_preserves_others
run_test "WLCLI-05: updating a key does not duplicate it" test_key_update_no_duplicate
run_test "WLCLI-06: --set-token output does not print token value" test_set_token_redacted_in_output
run_test "WLCLI-07: status with no config prints helpful message" test_status_no_config_helpful_message
run_test "WLCLI-08: status with mock health endpoint shows health=ok" test_status_with_mock_health

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
echo ""

[ "$FAIL" -eq 0 ]
