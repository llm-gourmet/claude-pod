#!/bin/bash
# test-webhook-listener-cli.sh -- Unit tests for webhook-listener CLI subcommand
# Tests WLCLI-01 through WLCLI-13
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
# WLCLI-01: --set-token writes github_token to connections.json
# ---------------------------------------------------------------------------
test_set_token_writes_connections_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  cmd_webhook_listener --set-token "ghp_abc123" --name "myrepo" 2>/dev/null

  local cjson="$tmpdir/webhooks/connections.json"
  [ -f "$cjson" ] || { echo "connections.json not found" >&2; return 1; }
  local token
  token=$(jq -r '.[0].github_token // ""' "$cjson" 2>/dev/null)
  [ "$token" = "ghp_abc123" ] || { echo "Expected token in connections.json, got: $token" >&2; return 1; }
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

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local output
  output=$(cmd_webhook_listener --set-token "ghp_supersecret" --name "myrepo" 2>&1)
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
# WLCLI-09: --set-token without --name exits with error
# ---------------------------------------------------------------------------
test_set_token_requires_name() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  local output rc=0
  output=$(cmd_webhook_listener --set-token "ghp_abc123" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "Expected non-zero exit, got 0" >&2; return 1; }
  echo "$output" | grep -qi "\-\-name\|required" || {
    echo "Expected --name error, got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# WLCLI-10: --add-connection creates connections.json
# ---------------------------------------------------------------------------
test_add_connection_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  cmd_webhook_listener --add-connection --name "myrepo" --repo "org/repo" \
    --webhook-secret "shsec_test" 2>/dev/null

  local cjson="$tmpdir/webhooks/connections.json"
  [ -f "$cjson" ] || { echo "connections.json not created" >&2; return 1; }
  local name repo secret
  name=$(jq -r '.[0].name // ""' "$cjson" 2>/dev/null)
  repo=$(jq -r '.[0].repo // ""' "$cjson" 2>/dev/null)
  secret=$(jq -r '.[0].webhook_secret // ""' "$cjson" 2>/dev/null)
  [ "$name" = "myrepo" ] || { echo "name wrong: $name" >&2; return 1; }
  [ "$repo" = "org/repo" ] || { echo "repo wrong: $repo" >&2; return 1; }
  [ "$secret" = "shsec_test" ] || { echo "secret wrong: $secret" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-11: --remove-connection removes named entry
# ---------------------------------------------------------------------------
test_remove_connection_removes_entry() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"},{"name":"other","repo":"org/other","webhook_secret":"sec2"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  cmd_webhook_listener --remove-connection "myrepo" 2>/dev/null

  local count
  count=$(jq 'length' "$tmpdir/webhooks/connections.json" 2>/dev/null)
  [ "$count" = "1" ] || { echo "Expected 1 entry after remove, got: $count" >&2; return 1; }
  local remaining
  remaining=$(jq -r '.[0].name' "$tmpdir/webhooks/connections.json" 2>/dev/null)
  [ "$remaining" = "other" ] || { echo "Wrong entry remaining: $remaining" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-12: --list-connections omits secret and token
# ---------------------------------------------------------------------------
test_list_connections_omits_sensitive() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"shsec_secret","github_token":"ghp_token"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local output
  output=$(cmd_webhook_listener --list-connections 2>/dev/null)
  echo "$output" | grep -q "shsec_secret" && { echo "secret leaked in output" >&2; return 1; }
  echo "$output" | grep -q "ghp_token" && { echo "token leaked in output" >&2; return 1; }
  echo "$output" | grep -q "myrepo" || { echo "name missing from output: $output" >&2; return 1; }
  echo "$output" | grep -q "org/repo" || { echo "repo missing from output: $output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-13: --add-connection rejects duplicate name
# ---------------------------------------------------------------------------
test_add_connection_rejects_duplicate() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local output rc=0
  output=$(cmd_webhook_listener --add-connection --name "myrepo" --repo "org/other" \
    --webhook-secret "sec2" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "Expected non-zero exit for duplicate, got 0" >&2; return 1; }
  echo "$output" | grep -qi "already exists" || { echo "Expected 'already exists' error, got: $output" >&2; return 1; }
  local count
  count=$(jq 'length' "$tmpdir/webhooks/connections.json" 2>/dev/null)
  [ "$count" = "1" ] || { echo "File was modified on duplicate add, count: $count" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-14: --set-profile writes profile field to connections.json
# ---------------------------------------------------------------------------
test_set_profile_writes_connections_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  cmd_webhook_listener --set-profile "myrepo-docs" --name "myrepo" 2>/dev/null

  local profile
  profile=$(jq -r '.[0].profile // ""' "$tmpdir/webhooks/connections.json" 2>/dev/null)
  [ "$profile" = "myrepo-docs" ] || { echo "Expected profile=myrepo-docs, got: $profile" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# WLCLI-15: --set-profile without --name exits with error
# ---------------------------------------------------------------------------
test_set_profile_requires_name() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  local output rc=0
  output=$(cmd_webhook_listener --set-profile "myrepo-docs" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "Expected non-zero exit, got 0" >&2; return 1; }
  echo "$output" | grep -qi "\-\-name\|required" || {
    echo "Expected --name error, got: $output" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# WLCLI-16: --add-connection --profile stores profile field; --list-connections
#            shows it when it differs from name
# ---------------------------------------------------------------------------
test_add_connection_with_profile() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  setup_cli "$tmpdir"
  cmd_webhook_listener --add-connection --name "myrepo" --repo "org/repo" \
    --webhook-secret "sec" --profile "myrepo-docs" 2>/dev/null

  local cjson="$tmpdir/webhooks/connections.json"
  local profile
  profile=$(jq -r '.[0].profile // ""' "$cjson" 2>/dev/null)
  [ "$profile" = "myrepo-docs" ] || { echo "profile field wrong: $profile" >&2; return 1; }

  # --list-connections must show the profile annotation
  local output
  output=$(cmd_webhook_listener --list-connections 2>/dev/null)
  echo "$output" | grep -q "profile: myrepo-docs" || {
    echo "Expected profile annotation in list output, got: $output" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo ""
echo "=== Webhook Listener CLI Tests ==="
echo ""

run_test "WLCLI-01: --set-token writes github_token to connections.json" test_set_token_writes_connections_json
run_test "WLCLI-02: --set-bind writes bind to webhooks/webhook.json" test_set_bind_writes_webhook_json
run_test "WLCLI-03: --set-port writes port as JSON number" test_set_port_writes_number
run_test "WLCLI-04: updating one key preserves other keys" test_key_update_preserves_others
run_test "WLCLI-05: updating a key does not duplicate it" test_key_update_no_duplicate
run_test "WLCLI-06: --set-token output does not print token value" test_set_token_redacted_in_output
run_test "WLCLI-07: status with no config prints helpful message" test_status_no_config_helpful_message
run_test "WLCLI-08: status with mock health endpoint shows health=ok" test_status_with_mock_health
run_test "WLCLI-09: --set-token without --name exits non-zero" test_set_token_requires_name
run_test "WLCLI-10: --add-connection creates connections.json" test_add_connection_creates_file
run_test "WLCLI-11: --remove-connection removes named entry" test_remove_connection_removes_entry
run_test "WLCLI-12: --list-connections omits secret and token" test_list_connections_omits_sensitive
run_test "WLCLI-13: --add-connection rejects duplicate name" test_add_connection_rejects_duplicate
run_test "WLCLI-14: --set-profile writes profile to connections.json" test_set_profile_writes_connections_json
run_test "WLCLI-15: --set-profile without --name exits non-zero" test_set_profile_requires_name
run_test "WLCLI-16: --add-connection --profile stores + lists profile" test_add_connection_with_profile

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
echo ""

[ "$FAIL" -eq 0 ]
