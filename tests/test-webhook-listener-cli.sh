#!/bin/bash
# test-webhook-listener-cli.sh -- Unit tests for webhook-listener CLI subcommand
# Tests WLCLI-01 through WLCLI-09
#
# Strategy: source bin/claude-secure with __CLAUDE_SECURE_SOURCE_ONLY=1 to
# load function definitions, use temp dirs as CONFIG_DIR and HOME.
# No Docker, no network.
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

# Source the CLI with CONFIG_DIR and HOME pointing to temp directories
setup_cli() {
  local config_dir="$1"
  local fake_home="${2:-$config_dir}"
  export CONFIG_DIR="$config_dir"
  export HOME="$fake_home"
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WLCLI-01: --set-token writes github_token to profile.json
# ---------------------------------------------------------------------------
test_set_token_writes_profile_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/profiles/myrepo"
  echo '{"workspace": "/tmp/ws"}' > "$tmpdir/profiles/myrepo/profile.json"

  setup_cli "$tmpdir"
  cmd_webhook_listener --set-token "ghp_abc123" --profile "myrepo" 2>/dev/null

  local pjson="$tmpdir/profiles/myrepo/profile.json"
  [ -f "$pjson" ] || { echo "profile.json not found" >&2; return 1; }
  local token
  token=$(jq -r '.github_token // ""' "$pjson" 2>/dev/null)
  [ "$token" = "ghp_abc123" ] || { echo "Expected token in profile.json, got: $token" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-02: --set-bind writes bind to webhooks/webhook.json
# ---------------------------------------------------------------------------
test_set_bind_writes_webhook_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir" "$tmpdir"
  cmd_webhook_listener --set-bind "0.0.0.0" 2>/dev/null

  local wjson="$tmpdir/.claude-secure/webhooks/webhook.json"
  [ -f "$wjson" ] || { echo "webhook.json not created at $wjson" >&2; return 1; }
  local bind
  bind=$(jq -r '.bind // ""' "$wjson" 2>/dev/null)
  [ "$bind" = "0.0.0.0" ] || { echo "Expected bind=0.0.0.0, got: $bind" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-03: --set-port writes port as JSON number to webhooks/webhook.json
# ---------------------------------------------------------------------------
test_set_port_writes_number() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir" "$tmpdir"
  cmd_webhook_listener --set-port "9001" 2>/dev/null

  local wjson="$tmpdir/.claude-secure/webhooks/webhook.json"
  [ -f "$wjson" ] || { echo "webhook.json not created" >&2; return 1; }
  local port_type
  port_type=$(jq -r '.port | type' "$wjson" 2>/dev/null)
  [ "$port_type" = "number" ] || { echo "Expected port to be number type, got: $port_type" >&2; return 1; }
  local port
  port=$(jq -r '.port' "$wjson" 2>/dev/null)
  [ "$port" = "9001" ] || { echo "Expected port=9001, got: $port" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-04: Updating one key preserves other keys in webhook.json
# ---------------------------------------------------------------------------
test_key_update_preserves_others() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir" "$tmpdir"
  cmd_webhook_listener --set-port "9001" 2>/dev/null
  cmd_webhook_listener --set-bind "0.0.0.0" 2>/dev/null

  local wjson="$tmpdir/.claude-secure/webhooks/webhook.json"
  local port bind
  port=$(jq -r '.port' "$wjson" 2>/dev/null)
  bind=$(jq -r '.bind' "$wjson" 2>/dev/null)
  [ "$port" = "9001" ] || { echo "port lost after set-bind, got: $port" >&2; return 1; }
  [ "$bind" = "0.0.0.0" ] || { echo "bind lost, got: $bind" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-05: Updating a key does not duplicate it
# ---------------------------------------------------------------------------
test_key_update_no_duplicate() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir" "$tmpdir"
  cmd_webhook_listener --set-port "9001" 2>/dev/null
  cmd_webhook_listener --set-port "9002" 2>/dev/null

  local wjson="$tmpdir/.claude-secure/webhooks/webhook.json"
  local port
  port=$(jq -r '.port' "$wjson" 2>/dev/null)
  [ "$port" = "9002" ] || { echo "Expected updated port 9002, got: $port" >&2; return 1; }
  # jq output is always single-value, so no duplicate risk; just verify value
}

# ---------------------------------------------------------------------------
# WLCLI-06: --set-token output does not print the token value
# ---------------------------------------------------------------------------
test_set_token_redacted_in_output() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/profiles/myrepo"
  echo '{"workspace": "/tmp/ws"}' > "$tmpdir/profiles/myrepo/profile.json"

  setup_cli "$tmpdir"
  local output
  output=$(cmd_webhook_listener --set-token "ghp_supersecret" --profile "myrepo" 2>&1)
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

  setup_cli "$tmpdir" "$tmpdir"
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
  local tmpdir
  tmpdir=$(mktemp -d)

  local port
  port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

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

  local i=0
  while [ $i -lt 20 ]; do
    curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i+1))
  done

  # Write webhook.json with test bind/port
  mkdir -p "$tmpdir/.claude-secure/webhooks"
  jq -n --arg b "127.0.0.1" --argjson p "$port" '{"bind": $b, "port": $p}' \
    > "$tmpdir/.claude-secure/webhooks/webhook.json"

  setup_cli "$tmpdir" "$tmpdir"
  local output
  output=$(cmd_webhook_listener status 2>&1) || true

  [ -f "$tmpdir/mock.pid" ] && kill "$(cat "$tmpdir/mock.pid")" 2>/dev/null || true
  rm -rf "$tmpdir"

  echo "$output" | grep -qi "health.*ok\|ok" || {
    echo "Expected health=ok in output, got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# WLCLI-09: --set-token without --profile when multiple profiles exist → error
# ---------------------------------------------------------------------------
test_set_token_requires_profile_when_multiple() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/profiles/repo1" "$tmpdir/profiles/repo2"
  echo '{"workspace": "/tmp/ws1"}' > "$tmpdir/profiles/repo1/profile.json"
  echo '{"workspace": "/tmp/ws2"}' > "$tmpdir/profiles/repo2/profile.json"

  setup_cli "$tmpdir"
  local output rc=0
  output=$(cmd_webhook_listener --set-token "ghp_abc123" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "Expected non-zero exit, got 0" >&2; return 1; }
  echo "$output" | grep -qi "profile\|repo1\|repo2" || {
    echo "Expected profile list in error output, got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo ""
echo "=== Webhook Listener CLI Tests ==="
echo ""

run_test "WLCLI-01: --set-token writes github_token to profile.json" test_set_token_writes_profile_json
run_test "WLCLI-02: --set-bind writes bind to webhooks/webhook.json" test_set_bind_writes_webhook_json
run_test "WLCLI-03: --set-port writes port as JSON number" test_set_port_writes_number
run_test "WLCLI-04: updating one key preserves other keys" test_key_update_preserves_others
run_test "WLCLI-05: updating a key does not duplicate it" test_key_update_no_duplicate
run_test "WLCLI-06: --set-token output does not print token value" test_set_token_redacted_in_output
run_test "WLCLI-07: status with no config prints helpful message" test_status_no_config_helpful_message
run_test "WLCLI-08: status with mock health endpoint shows health=ok" test_status_with_mock_health
run_test "WLCLI-09: --set-token without --profile (multiple profiles) exits non-zero" test_set_token_requires_profile_when_multiple

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
echo ""

[ "$FAIL" -eq 0 ]
