#!/bin/bash
# tests/test-webhook-spawn.sh -- Webhook spawn subprocess tests
# Tasks 4.3-4.6: verify that _spawn_worker actually calls claude-pod spawn
# and logs the correct events.
#
# Uses a stub claude-pod binary that records argv. Exit-code is controlled
# per-test via the STUB_EXIT_CODE env var (default 0).

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
STUB_LOG="$TEST_TMPDIR/stub-invocations.log"
LISTENER_PID=""
LISTENER_PORT=19030  # unique port to avoid collision with other test suites

cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

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

install_stub() {
  local exit_code="${1:-0}"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/claude-pod" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${STUB_LOG:-/tmp/stub.log}"
printf 'CONFIG_DIR=%s\n' "\${CONFIG_DIR:-}" >> "\${STUB_LOG:-/tmp/stub.log}"
exit ${exit_code}
STUB
  chmod +x "$TEST_TMPDIR/bin/claude-pod"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export STUB_LOG
}

setup_test_profile() {
  local home_dir="$TEST_TMPDIR/home"
  local webhooks_dir="$home_dir/.claude-pod/webhooks"
  mkdir -p "$home_dir/.claude-pod/profiles/test-profile" \
    "$webhooks_dir" \
    "$home_dir/.claude-pod/events" \
    "$home_dir/.claude-pod/logs"
  cat > "$home_dir/.claude-pod/profiles/test-profile/profile.json" <<JSON
{
  "workspace": "$TEST_TMPDIR/workspace",
  "secrets": []
}
JSON
  cat > "$webhooks_dir/connections.json" <<JSON
[
  {
    "name": "test-profile",
    "repo": "test-org/test-repo",
    "webhook_secret": "test-secret-abc123"
  }
]
JSON
  chmod 600 "$webhooks_dir/connections.json"
  mkdir -p "$TEST_TMPDIR/workspace"
  cat > "$TEST_TMPDIR/webhook.json" <<JSON
{
  "bind": "127.0.0.1",
  "port": $LISTENER_PORT,
  "max_concurrent_spawns": 3,
  "profiles_dir": "$home_dir/.claude-pod/profiles",
  "webhooks_dir": "$webhooks_dir",
  "events_dir": "$home_dir/.claude-pod/events",
  "logs_dir": "$home_dir/.claude-pod/logs",
  "claude_pod_bin": "$TEST_TMPDIR/bin/claude-pod",
  "config_dir": "$home_dir/.claude-pod"
}
JSON
}

start_listener() {
  if [ ! -f "$PROJECT_DIR/webhook/listener.py" ]; then
    return 1
  fi
  python3 "$PROJECT_DIR/webhook/listener.py" --config "$TEST_TMPDIR/webhook.json" \
    >"$TEST_TMPDIR/listener.stdout" 2>"$TEST_TMPDIR/listener.stderr" &
  LISTENER_PID=$!
  local i=0
  while [ $i -lt 20 ]; do
    if curl -sSf "http://127.0.0.1:$LISTENER_PORT/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.1; i=$((i+1))
  done
  return 1
}

gen_sig() {
  local hex
  hex=$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.* //')
  printf 'sha256=%s' "$hex"
}

post_push() {
  local body sig delivery_id
  body="$1"
  delivery_id="${2:-spawn-test-$(uuidgen)}"
  sig=$(gen_sig "test-secret-abc123" "$body")
  curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$LISTENER_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: push" \
    -H "X-GitHub-Delivery: $delivery_id" \
    -H "X-Hub-Signature-256: $sig" \
    --data-binary "$body"
  printf '\n%s' "$delivery_id"
}

# ---------------------------------------------------------------------------
# 4.3: valid push → claude-pod spawn called with --event-file
# ---------------------------------------------------------------------------
test_spawn_called_with_event_file() {
  local body status delivery_id out
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  delivery_id="spawn43-$(uuidgen)"
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  # Stub log must contain: spawn test-profile --event-file <path>
  grep -q 'spawn test-profile --event-file' "$STUB_LOG" 2>/dev/null || \
    { echo "stub not called with spawn + --event-file" >&2; return 1; }
  # The --event-file argument must point to an existing file
  local ev_arg
  ev_arg=$(grep 'spawn test-profile --event-file' "$STUB_LOG" | head -n1 | sed 's/.*--event-file //')
  [ -f "$ev_arg" ] || { echo "event-file arg $ev_arg does not exist" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# 4.4: spawn exit 0 → spawn_done in webhook.jsonl
# ---------------------------------------------------------------------------
test_spawn_exit_0_logs_spawn_done() {
  local body delivery_id status out
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  delivery_id="spawn44-$(uuidgen)"
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  local log="$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl"
  grep -q '"spawn_start"' "$log" 2>/dev/null || { echo "no spawn_start in log" >&2; return 1; }
  grep -q '"spawn_done"' "$log" 2>/dev/null || { echo "no spawn_done in log" >&2; return 1; }
  grep -q "$delivery_id" "$log" 2>/dev/null || { echo "delivery_id not in log" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# 4.5: spawn exit non-0 → spawn_error in webhook.jsonl
# ---------------------------------------------------------------------------
test_spawn_exit_nonzero_logs_spawn_error() {
  # Reinstall stub with exit code 1
  install_stub 1

  local body delivery_id status out
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  delivery_id="spawn45-$(uuidgen)"
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  local log="$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl"
  grep -q '"spawn_error"' "$log" 2>/dev/null || { echo "no spawn_error in log" >&2; return 1; }
  grep -q '"exit_code": 1' "$log" 2>/dev/null || { echo "no exit_code:1 in log" >&2; return 1; }
  grep -q "$delivery_id" "$log" 2>/dev/null || { echo "delivery_id not in log" >&2; return 1; }

  # Restore exit-0 stub for remaining tests
  install_stub 0
  return 0
}

# ---------------------------------------------------------------------------
# 4.6: spawn log file exists after spawn with correct content
# ---------------------------------------------------------------------------
test_spawn_log_file_written() {
  local body delivery_id status out
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  delivery_id="spawn46-$(uuidgen)"
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  local logs_dir="$TEST_TMPDIR/home/.claude-pod/logs"
  # Spawn log filename: spawn-<delivery_id[:12]>.log
  local short="${delivery_id:0:12}"
  local log_file="$logs_dir/spawn-${short}.log"
  [ -f "$log_file" ] || { echo "spawn log file $log_file not found" >&2; return 1; }
  return 0
}

set_skip_filter() {
  local filter="$1"
  local home_dir="$TEST_TMPDIR/home"
  local webhooks_dir="$home_dir/.claude-pod/webhooks"
  cat > "$webhooks_dir/connections.json" <<JSON
[{"name":"test-profile","repo":"test-org/test-repo","webhook_secret":"test-secret-abc123","skip_filters":["$filter"]}]
JSON
  chmod 600 "$webhooks_dir/connections.json"
}

clear_skip_filters() {
  local home_dir="$TEST_TMPDIR/home"
  local webhooks_dir="$home_dir/.claude-pod/webhooks"
  cat > "$webhooks_dir/connections.json" <<JSON
[{"name":"test-profile","repo":"test-org/test-repo","webhook_secret":"test-secret-abc123"}]
JSON
  chmod 600 "$webhooks_dir/connections.json"
}

# ---------------------------------------------------------------------------
# Filter skip: push with ALL [skip-claude]-prefixed commits → skipped, no spawn
# ---------------------------------------------------------------------------
test_filter_all_prefixed_skips_spawn() {
  set_skip_filter "[skip-claude]"
  local delivery_id="filt-all-$(uuidgen)"
  local body; body=$(printf '%s' '{
    "ref":"refs/heads/main",
    "repository":{"id":1000001,"name":"test-repo","full_name":"test-org/test-repo","owner":{"login":"test-org"}},
    "pusher":{"name":"bot","email":"bot@example.com"},
    "commits":[
      {"id":"aaa1","message":"[skip-claude] auto-update","author":{"name":"bot","email":"bot@example.com"}},
      {"id":"aaa2","message":"[skip-claude] another","author":{"name":"bot","email":"bot@example.com"}}
    ]
  }')
  local out status
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "200" ] || { echo "expected HTTP 200 (skipped), got $status" >&2; return 1; }
  sleep 0.3
  local log="$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl"
  grep -q '"skipped"' "$log" 2>/dev/null || { echo "no 'skipped' event in log" >&2; return 1; }
  grep "$delivery_id" "$log" 2>/dev/null | grep -q '"spawn_start"' && \
    { echo "spawn_start logged despite filter match" >&2; return 1; }
  clear_skip_filters
  return 0
}

# ---------------------------------------------------------------------------
# Filter skip: mixed push (one prefixed, one not) → still spawns
# ---------------------------------------------------------------------------
test_filter_mixed_commits_spawns() {
  set_skip_filter "[skip-claude]"
  local delivery_id="filt-mix-$(uuidgen)"
  local body; body=$(printf '%s' '{
    "ref":"refs/heads/main",
    "repository":{"id":1000001,"name":"test-repo","full_name":"test-org/test-repo","owner":{"login":"test-org"}},
    "pusher":{"name":"user","email":"user@example.com"},
    "commits":[
      {"id":"bbb1","message":"[skip-claude] auto-update","author":{"name":"bot","email":"bot@example.com"}},
      {"id":"bbb2","message":"Fix real bug","author":{"name":"user","email":"user@example.com"}}
    ]
  }')
  local out status
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected HTTP 202 (spawn), got $status" >&2; return 1; }
  sleep 0.3
  local log="$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl"
  grep "$delivery_id" "$log" 2>/dev/null | grep -q '"spawn_start"' || \
    { echo "spawn_start not found for mixed push" >&2; return 1; }
  clear_skip_filters
  return 0
}

# ---------------------------------------------------------------------------
# Filter skip: skip_filters empty → all events spawn normally
# ---------------------------------------------------------------------------
test_filter_empty_filters_spawns() {
  clear_skip_filters
  local delivery_id="filt-empty-$(uuidgen)"
  local body; body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  local out status
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected HTTP 202, got $status" >&2; return 1; }
  sleep 0.3
  local log="$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl"
  grep "$delivery_id" "$log" 2>/dev/null | grep -q '"spawn_start"' || \
    { echo "spawn_start not found for empty-filter push" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# config_dir propagated as CONFIG_DIR env to spawn subprocess (regression: VPS
# service runs as root, $HOME differs from installing user → "not installed")
# ---------------------------------------------------------------------------
test_config_dir_passed_to_spawn() {
  local home_dir="$TEST_TMPDIR/home"
  local body delivery_id status out
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  delivery_id="cfgdir-$(uuidgen)"
  out=$(post_push "$body" "$delivery_id")
  status=$(printf '%s' "$out" | head -n1)
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  grep -q "CONFIG_DIR=$home_dir/.claude-pod" "$STUB_LOG" 2>/dev/null || \
    { echo "CONFIG_DIR not set or wrong in stub log" >&2; cat "$STUB_LOG" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  install_stub 0
  setup_test_profile

  echo "========================================"
  echo "  Webhook Spawn Tests (tasks 4.3-4.6)"
  echo "========================================"
  echo ""

  if ! start_listener; then
    echo "  SKIP: listener failed to start"
    for t in test_spawn_called_with_event_file \
              test_spawn_exit_0_logs_spawn_done \
              test_spawn_exit_nonzero_logs_spawn_error \
              test_spawn_log_file_written \
              test_config_dir_passed_to_spawn \
              test_filter_all_prefixed_skips_spawn \
              test_filter_mixed_commits_spawns \
              test_filter_empty_filters_spawns; do
      TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: $t (listener not running)"
    done
  else
    run_test "spawn called with --event-file"      test_spawn_called_with_event_file
    run_test "spawn exit 0 → spawn_done"           test_spawn_exit_0_logs_spawn_done
    run_test "spawn exit 1 → spawn_error"          test_spawn_exit_nonzero_logs_spawn_error
    run_test "spawn log file written"              test_spawn_log_file_written
    run_test "config_dir propagated as CONFIG_DIR" test_config_dir_passed_to_spawn
    run_test "filter: all prefixed → skipped"      test_filter_all_prefixed_skips_spawn
    run_test "filter: mixed commits → spawns"      test_filter_mixed_commits_spawns
    run_test "filter: empty filters → spawns"      test_filter_empty_filters_spawns
  fi

  echo ""
  echo "========================================"
  echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
  echo "========================================"
  [ "$FAIL" -eq 0 ]
}

if [ $# -gt 0 ]; then
  install_stub 0
  setup_test_profile
  start_listener || true
  "$@"
  exit $?
fi

main "$@"
