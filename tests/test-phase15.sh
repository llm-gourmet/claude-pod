#!/bin/bash
# tests/test-phase15.sh -- Phase 15 Event Handlers integration + unit tests
# HOOK-03 (Issue events), HOOK-04 (Push-to-Main), HOOK-05 (CI Failure), HOOK-07 (replay)
#
# Wave 0 expectation: many tests will FAIL until Plans 15-02 (listener filter +
# event routing), 15-03 (spawn render + replay), and 15-04 (installer
# templates copy) land. That is the Nyquist self-healing contract -- the 28
# named test functions exist up front so later waves cannot drift from the
# validation map (see .planning/phases/15-event-handlers/15-VALIDATION.md).
#
# GOTCHA (from Phase 14): Raw body MUST NOT be re-serialized before HMAC.
# GOTCHA (from Phase 14): Use `printf '%s' "$body"` NOT `echo "$body"` for HMAC
# generation -- echo adds a trailing newline that breaks digest matching.
#
# This harness stubs claude-secure on PATH with a recorder that writes argv
# to a log file. No real Docker is ever invoked by the fast path. Some tests
# deliberately invoke the REAL bin/claude-secure under --dry-run mode (e.g.
# test_workflow_template_dry_run, test_render_handles_*) -- those tests
# prepend $PROJECT_DIR/bin to PATH ahead of the stub dir.
#
# Usage:
#   bash tests/test-phase15.sh                         # run full suite
#   bash tests/test-phase15.sh test_issues_opened_routes  # run single named function

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
STUB_LOG="$TEST_TMPDIR/stub-invocations.log"
LISTENER_PID=""
LISTENER_PORT=19015  # Phase 15 uses 19015 to avoid collision with Phase 14's 19000

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

# =========================================================================
# Stub builder: fake `claude-secure` binary on PATH
# Records invocation argv to $STUB_LOG and exits 0 immediately (Phase 15
# tests do not exercise semaphore concurrency -- that lives in Phase 14).
# =========================================================================
install_stub() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/claude-secure" <<'STUB'
#!/bin/bash
# Stub: record invocation argv and exit 0.
printf '%s\n' "$*" >> "${STUB_LOG:-/tmp/stub.log}"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/claude-secure"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export STUB_LOG
}

# =========================================================================
# Test profile + listener config setup.
# Accepts optional args via env vars so individual tests can override:
#   TEST_WEBHOOK_EVENT_FILTER (JSON blob)   -- value of .webhook_event_filter
#   TEST_WEBHOOK_BOT_USERS    (JSON array)  -- value of .webhook_bot_users
#   TEST_INSTALL_PROMPTS      (space list)  -- names of event types to
#       pre-populate as profile-level override templates in
#       <profile>/prompts/<name>.md (for fallback-chain tests)
# =========================================================================
setup_test_profile() {
  local home_dir="$TEST_TMPDIR/home"
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  mkdir -p "$profile_dir" "$profile_dir/prompts" \
    "$home_dir/.claude-secure/events" "$home_dir/.claude-secure/logs/spawns"

  local filter_field=""
  if [ -n "${TEST_WEBHOOK_EVENT_FILTER:-}" ]; then
    filter_field=",\n  \"webhook_event_filter\": ${TEST_WEBHOOK_EVENT_FILTER}"
  fi
  local bot_field=""
  if [ -n "${TEST_WEBHOOK_BOT_USERS:-}" ]; then
    bot_field=",\n  \"webhook_bot_users\": ${TEST_WEBHOOK_BOT_USERS}"
  fi

  # Use printf to interpolate optional fields safely.
  printf '{\n  "name": "test-profile",\n  "repo": "test-org/test-repo",\n  "webhook_secret": "test-secret-abc123",\n  "workspace": "%s/workspace"%b%b\n}\n' \
    "$TEST_TMPDIR" "$filter_field" "$bot_field" > "$profile_dir/profile.json"

  mkdir -p "$TEST_TMPDIR/workspace"

  # Optional: install profile-level prompt overrides for fallback-chain tests.
  if [ -n "${TEST_INSTALL_PROMPTS:-}" ]; then
    local p
    for p in $TEST_INSTALL_PROMPTS; do
      install_prompts_override "$p" "# profile override for $p
EVENT_TYPE={{EVENT_TYPE}}
"
    done
  fi

  # Listener config pointing at test HOME
  cat > "$TEST_TMPDIR/webhook.json" <<JSON
{
  "bind": "127.0.0.1",
  "port": $LISTENER_PORT,
  "max_concurrent_spawns": 3,
  "profiles_dir": "$home_dir/.claude-secure/profiles",
  "events_dir": "$home_dir/.claude-secure/events",
  "logs_dir": "$home_dir/.claude-secure/logs",
  "claude_secure_bin": "$TEST_TMPDIR/bin/claude-secure"
}
JSON

  # Export CONFIG_DIR so tests invoking the REAL bin/claude-secure resolve
  # profiles under the test home, not ~/.claude-secure on the real user.
  export CONFIG_DIR="$home_dir/.claude-secure"
  export HOME="$home_dir"
}

# Helper: install a profile-level prompt override template.
# Usage: install_prompts_override <event-type> <content>
install_prompts_override() {
  local name="$1"
  local content="$2"
  local home_dir="$TEST_TMPDIR/home"
  local target="$home_dir/.claude-secure/profiles/test-profile/prompts/${name}.md"
  mkdir -p "$(dirname "$target")"
  printf '%s' "$content" > "$target"
}

# Helper: seed an event file into the test events dir with a synthetic
# <iso>-<uuid8>.json filename so replay tests can find it by substring.
# Usage: seed_event_file <substring> <fixture-path>
seed_event_file() {
  local substring="$1"
  local fixture="$2"
  local home_dir="$TEST_TMPDIR/home"
  local events_dir="$home_dir/.claude-secure/events"
  mkdir -p "$events_dir"
  local iso
  iso=$(date -u +"%Y%m%dT%H%M%SZ")
  local target="$events_dir/${iso}-${substring}.json"
  cp "$fixture" "$target"
  printf '%s' "$target"
}

start_listener() {
  # Starts webhook/listener.py with test config. Expected to be implemented
  # in Phase 14 (already shipped). Phase 15 Wave 0 only requires this to
  # stand up so routing tests can POST webhooks.
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

restart_listener() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
  fi
  start_listener
}

# =========================================================================
# HMAC helper
# GOTCHA: printf '%s' -- DO NOT use `echo` (trailing newline changes digest)
# =========================================================================
gen_sig() {
  # $1 = secret, $2 = body
  local hex
  hex=$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.* //')
  printf 'sha256=%s' "$hex"
}

# Helper: POST a JSON body as a GitHub webhook delivery. Echoes the status
# code. Required env: LISTENER_PORT. Required args: event_type, body,
# delivery_id_prefix.
post_webhook() {
  local event="$1"
  local body="$2"
  local prefix="$3"
  local sig delivery_id
  sig=$(gen_sig "test-secret-abc123" "$body")
  delivery_id="${prefix}-$(uuidgen)"
  curl -sS -o "$TEST_TMPDIR/resp.json" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$LISTENER_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: $event" \
    -H "X-GitHub-Delivery: $delivery_id" \
    -H "X-Hub-Signature-256: $sig" \
    --data-binary "$body"
}

# =========================================================================
# HOOK-03: Issue event routing (green via Plan 15-02)
# =========================================================================

test_issues_opened_routes() {
  # Green after Plan 15-02.
  local body status stub_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  status=$(post_webhook issues "$body" "issues-opened")
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  # Event file must exist with top-level event_type=issues-opened
  local ev_file
  ev_file=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || return 1
  jq -e '.event_type == "issues-opened"' "$ev_file" >/dev/null || return 1
  # Stub must record a --event-file invocation
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  grep -q -- '--event-file' "$STUB_LOG" || return 1
  return 0
}

test_issues_labeled_routes() {
  # Green after Plan 15-02.
  local body status stub_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-issues-labeled.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  status=$(post_webhook issues "$body" "issues-labeled")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  # Find the most recent event file and check its event_type
  local ev_file
  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || return 1
  jq -e '.event_type == "issues-labeled"' "$ev_file" >/dev/null || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  return 0
}

test_issues_closed_filtered() {
  # Green after Plan 15-02. Derives a closed fixture via jq from opened.
  local body status stub_before ev_before
  body=$(jq -c '.action="closed"' "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook issues "$body" "issues-closed")
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3
  # NO new event file
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  # webhook.jsonl must have a filtered entry
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'event.*filtered' "$log" || return 1
  grep -q 'issue_action_not_matched' "$log" || return 1
  # Stub must NOT have been invoked
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_default_template_issues_opened_exists() {
  # Green after Plan 15-02 (ships default templates under webhook/templates/).
  [ -f "$PROJECT_DIR/webhook/templates/issues-opened.md" ] || return 1
  grep -q '{{ISSUE_TITLE}}' "$PROJECT_DIR/webhook/templates/issues-opened.md" || return 1
  grep -q '{{ISSUE_BODY}}' "$PROJECT_DIR/webhook/templates/issues-opened.md" || return 1
  grep -q '{{REPO_NAME}}' "$PROJECT_DIR/webhook/templates/issues-opened.md" || return 1
  return 0
}

# =========================================================================
# HOOK-04: Push-to-Main event routing (green via Plan 15-02)
# =========================================================================

test_push_main_routes() {
  local body status stub_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  status=$(post_webhook push "$body" "push-main")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_file
  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  return 0
}

test_push_feature_branch_filtered() {
  local body status stub_before ev_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push-feature-branch.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook push "$body" "push-feature")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'branch_not_matched' "$log" || return 1
  grep -q 'feature/xyz' "$log" || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_push_bot_loop_filtered() {
  # This test requires the profile to list claude-bot in webhook_bot_users.
  # We mutate the profile.json in-place for this single test and reload the
  # listener so its per-request profile read picks it up.
  local home_dir="$TEST_TMPDIR/home"
  local profile="$home_dir/.claude-secure/profiles/test-profile/profile.json"
  local tmp
  tmp=$(mktemp)
  jq '. + {webhook_bot_users: ["claude-bot"]}' "$profile" > "$tmp" && mv "$tmp" "$profile"

  local body status stub_before ev_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push-bot-loop.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook push "$body" "push-botloop")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'loop_prevention' "$log" || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_push_branch_delete_no_crash() {
  # Pitfall 7 regression: head_commit=null must not crash the listener or
  # the render pipeline. Branch "old-feature" is not main → filtered.
  local body status
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-push-branch-delete.json")
  status=$(post_webhook push "$body" "push-delete")
  [ "$status" = "202" ] || { echo "expected 202 (not 500), got $status" >&2; return 1; }
  # Listener process must still be alive.
  if [ -n "$LISTENER_PID" ]; then
    kill -0 "$LISTENER_PID" 2>/dev/null || return 1
  fi
  return 0
}

# =========================================================================
# HOOK-05: Workflow run routing (green via Plan 15-02)
# =========================================================================

test_workflow_run_failure_routes() {
  local body status stub_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-workflow-run-failure.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  status=$(post_webhook workflow_run "$body" "wf-fail")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_file
  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || return 1
  jq -e '.event_type == "workflow_run-completed"' "$ev_file" >/dev/null || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  return 0
}

test_workflow_run_success_filtered() {
  local body status stub_before ev_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-workflow-run-success.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook workflow_run "$body" "wf-success")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'workflow_conclusion_not_matched' "$log" || return 1
  grep -q 'success' "$log" || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_workflow_run_in_progress_filtered() {
  local body status stub_before ev_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-workflow-run-in-progress.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook workflow_run "$body" "wf-inprog")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'workflow_action_not_completed' "$log" || return 1
  grep -q 'in_progress' "$log" || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_workflow_template_dry_run() {
  # Green after Plan 15-03. Invokes the REAL bin/claude-secure in --dry-run
  # mode against the failure fixture.
  #
  # Assertions:
  #   - exit 0
  #   - stdout contains literal "CI" (WORKFLOW_NAME from .workflow.name,
  #     NOT empty -- Pitfall 6 regression)
  #   - stdout contains the workflow_run id "289782451"
  #   - stdout contains literal "main" (BRANCH fallback from
  #     .workflow_run.head_branch -- the failure fixture has NO .ref field,
  #     so if the gated [ -s "$v_file" ] fallback in render_template is
  #     wrong, BRANCH renders empty and this assertion fails. This grep is
  #     the execution-time tripwire for the Plan 15-03 Region 2 latent bug.)
  local out rc
  out=$(PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$PROJECT_DIR/tests/fixtures/github-workflow-run-failure.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || { echo "claude-secure exited $rc" >&2; return 1; }
  printf '%s' "$out" | grep -q 'CI' || { echo "missing CI in output" >&2; return 1; }
  printf '%s' "$out" | grep -q '289782451' || { echo "missing workflow id" >&2; return 1; }
  printf '%s' "$out" | grep -q 'main' || { echo "missing main (BRANCH fallback)" >&2; return 1; }
  return 0
}

# =========================================================================
# HOOK-07: Replay subcommand (green via Plan 15-03)
# =========================================================================

test_replay_finds_single_match() {
  local ev_path stub_before rc
  ev_path=$(seed_event_file "deadbeef" "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  CLAUDE_SECURE_EXEC="$TEST_TMPDIR/bin/claude-secure" \
    "$PROJECT_DIR/bin/claude-secure" replay deadbeef >"$TEST_TMPDIR/replay1.out" 2>&1
  rc=$?
  [ $rc -eq 0 ] || { echo "replay exited $rc: $(cat "$TEST_TMPDIR/replay1.out")" >&2; return 1; }
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  return 0
}

test_replay_ambiguous_errors() {
  local home_dir="$TEST_TMPDIR/home"
  local events_dir="$home_dir/.claude-secure/events"
  mkdir -p "$events_dir"
  # Seed two event files both matching substring abcd1234
  local iso
  iso=$(date -u +"%Y%m%dT%H%M%SZ")
  cp "$PROJECT_DIR/tests/fixtures/github-issues-opened.json" \
    "$events_dir/${iso}-abcd1234.json"
  cp "$PROJECT_DIR/tests/fixtures/github-issues-opened.json" \
    "$events_dir/${iso}-abcd12349999.json"
  local rc
  CLAUDE_SECURE_EXEC="$TEST_TMPDIR/bin/claude-secure" \
    "$PROJECT_DIR/bin/claude-secure" replay abcd1234 >"$TEST_TMPDIR/replay2.out" 2>&1
  rc=$?
  [ $rc -ne 0 ] || return 1
  grep -q 'abcd1234.json' "$TEST_TMPDIR/replay2.out" || return 1
  grep -q 'abcd12349999.json' "$TEST_TMPDIR/replay2.out" || return 1
  return 0
}

test_replay_no_match_errors() {
  local rc
  CLAUDE_SECURE_EXEC="$TEST_TMPDIR/bin/claude-secure" \
    "$PROJECT_DIR/bin/claude-secure" replay zzzzzzzz >"$TEST_TMPDIR/replay3.out" 2>&1
  rc=$?
  [ $rc -ne 0 ] || return 1
  grep -q 'no event file matching' "$TEST_TMPDIR/replay3.out" || return 1
  return 0
}

test_replay_auto_profile() {
  local ev_path stub_before rc
  ev_path=$(seed_event_file "autoprof" "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  CLAUDE_SECURE_EXEC="$TEST_TMPDIR/bin/claude-secure" \
    "$PROJECT_DIR/bin/claude-secure" replay autoprof >"$TEST_TMPDIR/replay4.out" 2>&1
  rc=$?
  [ $rc -eq 0 ] || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" -gt "$stub_before" ] || return 1
  # The new invocation (last line of stub log) must include --profile test-profile.
  tail -n1 "$STUB_LOG" | grep -q -- '--profile test-profile' || return 1
  return 0
}

# =========================================================================
# Locked decision assertions (D-01 through D-22)
# =========================================================================

test_compute_event_type_cases() {
  # Green after Plan 15-02. Unit-test the listener.compute_event_type helper.
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
try:
    from listener import compute_event_type
except Exception as e:
    print(f"import failed: {e}", file=sys.stderr)
    sys.exit(1)

cases = [
    ({"X-GitHub-Event": "issues"}, {"action": "opened"}, "issues-opened"),
    ({"X-GitHub-Event": "push"}, {}, "push"),
    ({"X-GitHub-Event": "ping"}, {}, "ping"),
    ({"X-GitHub-Event": "workflow_run"}, {"action": "completed"}, "workflow_run-completed"),
]
for headers, payload, expected in cases:
    got = compute_event_type(headers, payload)
    if got != expected:
        print(f"FAIL: {headers} {payload} -> {got!r}, expected {expected!r}", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PYEOF
}

test_ping_event_filtered() {
  # Pitfall 4 regression + D-04. Ping has no action and no issue; filter
  # must reject as unsupported_event:ping. Green after Plan 15-02.
  local body status stub_before ev_before
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-ping.json")
  stub_before=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  ev_before=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  status=$(post_webhook ping "$body" "ping-test")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_after
  ev_after=$(ls "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_after" = "$ev_before" ] || return 1
  local log="$TEST_TMPDIR/home/.claude-secure/logs/webhook.jsonl"
  [ -f "$log" ] || return 1
  grep -q 'unsupported_event:ping' "$log" || return 1
  local stub_after
  stub_after=$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)
  [ "$stub_after" = "$stub_before" ] || return 1
  return 0
}

test_extract_field_truncates() {
  # Green after Plan 15-03. D-17: 8192-byte truncation with suffix.
  # Invoke via shim: source bin/claude-secure without running main, call
  # extract_payload_field against a synthetic JSON.
  local big_val fake_json out_file rc byte_len
  big_val=$(printf 'a%.0s' $(seq 1 9000))
  fake_json="$TEST_TMPDIR/big.json"
  jq -n --arg v "$big_val" '{issue: {body: $v}}' > "$fake_json"
  out_file="$TEST_TMPDIR/extracted.txt"

  # Source mode: set a sentinel so the CLI does not execute main().
  ( export CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null || true
    if ! type extract_payload_field >/dev/null 2>&1; then
      echo "extract_payload_field not defined" >&2
      exit 2
    fi
    extract_payload_field "$fake_json" '.issue.body' "" > "$out_file"
  )
  rc=$?
  [ $rc -eq 0 ] || return 1
  byte_len=$(wc -c < "$out_file")
  [ "$byte_len" -le 8300 ] || { echo "length $byte_len > 8300" >&2; return 1; }
  grep -q 'truncated' "$out_file" || return 1
  return 0
}

test_extract_field_utf8_safe() {
  # Green after Plan 15-03. D-17: no partial-codepoint cut.
  # Build 8190 ASCII + 3-byte snowman. Truncation must either keep the full
  # codepoint or cut before it -- never produce invalid UTF-8.
  local prefix snowman big_val fake_json out_file rc
  prefix=$(printf 'x%.0s' $(seq 1 8190))
  snowman=$'\xE2\x98\x83'
  big_val="${prefix}${snowman}${snowman}${snowman}${snowman}"
  fake_json="$TEST_TMPDIR/utf8.json"
  jq -n --arg v "$big_val" '{issue: {body: $v}}' > "$fake_json"
  out_file="$TEST_TMPDIR/utf8-out.txt"
  ( export CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null || true
    type extract_payload_field >/dev/null 2>&1 || exit 2
    extract_payload_field "$fake_json" '.issue.body' "" > "$out_file"
  )
  rc=$?
  [ $rc -eq 0 ] || return 1
  # Validate UTF-8 decode with python
  python3 -c "import sys; open('$out_file','rb').read().decode('utf-8')" >/dev/null 2>&1 || return 1
  return 0
}

test_render_handles_pipe_in_value() {
  # Pitfall 1 regression. Green after Plan 15-03.
  local out rc
  out=$(PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$PROJECT_DIR/tests/fixtures/github-issues-opened-with-pipe.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || { echo "spawn exited $rc" >&2; return 1; }
  printf '%s' "$out" | grep -q 'fix(api): handle | in header' || return 1
  return 0
}

test_render_handles_backslash_in_value() {
  # Pitfall 1 regression. Green after Plan 15-03.
  local out rc
  out=$(PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$PROJECT_DIR/tests/fixtures/github-issues-opened-with-pipe.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || return 1
  printf '%s' "$out" | grep -q 'path\\to\\file' || return 1
  return 0
}

test_resolve_template_fallback_chain() {
  # D-13: no profile prompts/ override → falls back to webhook/templates/.
  # Green after Plan 15-03. Remove any profile-level issues-opened override.
  local home_dir="$TEST_TMPDIR/home"
  rm -f "$home_dir/.claude-secure/profiles/test-profile/prompts/issues-opened.md"
  local out rc
  out=$(WEBHOOK_TEMPLATES_DIR="$PROJECT_DIR/webhook/templates" \
    PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$PROJECT_DIR/tests/fixtures/github-issues-opened.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || { echo "exited $rc: $out" >&2; return 1; }
  # The repo default template contains {{ISSUE_TITLE}} → renders "Test issue title"
  printf '%s' "$out" | grep -q 'Test issue title' || return 1
  return 0
}

test_explicit_template_no_default_fallback() {
  # D-13 step 1 rule: explicit --prompt-template MUST NOT fall back to defaults.
  # Green after Plan 15-03.
  local home_dir="$TEST_TMPDIR/home"
  # Ensure no profile-level "nonsense" template exists.
  rm -f "$home_dir/.claude-secure/profiles/test-profile/prompts/nonsense.md"
  local out rc
  out=$(PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --prompt-template nonsense \
    --event-file "$PROJECT_DIR/tests/fixtures/github-issues-opened.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -ne 0 ] || return 1
  printf '%s' "$out" | grep -q 'Template not found' || return 1
  return 0
}

test_webhook_templates_dir_env_var() {
  # D-15: WEBHOOK_TEMPLATES_DIR env var takes precedence over compiled default.
  # Green after Plan 15-03.
  local custom_dir="$TEST_TMPDIR/custom-templates"
  mkdir -p "$custom_dir"
  local marker="UNIQ_MARKER_$(uuidgen | tr -d -)"
  printf '%s\n' "$marker {{ISSUE_TITLE}}" > "$custom_dir/issues-opened.md"
  # Remove any profile-level override so we cascade to WEBHOOK_TEMPLATES_DIR
  local home_dir="$TEST_TMPDIR/home"
  rm -f "$home_dir/.claude-secure/profiles/test-profile/prompts/issues-opened.md"
  local out rc
  out=$(WEBHOOK_TEMPLATES_DIR="$custom_dir" \
    PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$PROJECT_DIR/tests/fixtures/github-issues-opened.json" \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || return 1
  printf '%s' "$out" | grep -q "$marker" || return 1
  return 0
}

test_install_copies_templates_dir() {
  # D-12: install.sh must copy webhook/templates/ to /opt/claude-secure.
  # Green after Plan 15-04. Grep contract against install.sh.
  grep -q 'webhook/templates' "$PROJECT_DIR/install.sh" || return 1
  grep -q 'mkdir -p /opt/claude-secure/webhook/templates' "$PROJECT_DIR/install.sh" || return 1
  return 0
}

test_event_file_has_top_level_event_type() {
  # D-02: persisted event file has BOTH .event_type and ._meta.event_type.
  # Green after Plan 15-02.
  local body status
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  status=$(post_webhook issues "$body" "top-level-check")
  [ "$status" = "202" ] || return 1
  sleep 0.3
  local ev_file
  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-secure/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || return 1
  jq -e '.event_type == "issues-opened"' "$ev_file" >/dev/null || return 1
  jq -e '._meta.event_type == "issues-opened"' "$ev_file" >/dev/null || return 1
  return 0
}

test_spawn_event_type_priority() {
  # D-03: spawn's event_type extraction priority must be
  #   .event_type // ._meta.event_type // .action
  # This test owns its setup entirely.
  #
  # (1) Ensure profile exists.
  setup_test_profile
  # (2) Create a profile-level template whose only substantive content is
  # the line `EVENT_TYPE={{EVENT_TYPE}}` (the EVENT_TYPE= prefix is the grep
  # anchor, not a token).
  install_prompts_override "priority-top" "# priority test
EVENT_TYPE={{EVENT_TYPE}}
"
  # (3) Synthesize an event file where event_type, _meta.event_type, and
  # action all differ, plus the repo so profile resolution works.
  local home_dir="$TEST_TMPDIR/home"
  local events_dir="$home_dir/.claude-secure/events"
  mkdir -p "$events_dir"
  local ev_path="$events_dir/priority-test.json"
  jq -n '{
    event_type: "priority-top",
    _meta: { event_type: "priority-mid" },
    action: "priority-bot",
    repository: { full_name: "test-org/test-repo" }
  }' > "$ev_path"
  # (4) Invoke REAL bin/claude-secure with --prompt-template priority-top
  # and --dry-run. Assert EVENT_TYPE=priority-top in output.
  local out rc
  out=$(PATH="$PROJECT_DIR/bin:$PATH" claude-secure --profile test-profile spawn \
    --event-file "$ev_path" \
    --prompt-template priority-top \
    --dry-run 2>&1)
  rc=$?
  [ $rc -eq 0 ] || { echo "spawn exited $rc: $out" >&2; return 1; }
  printf '%s' "$out" | grep -q 'EVENT_TYPE=priority-top' || { echo "expected EVENT_TYPE=priority-top, got: $out" >&2; return 1; }
  return 0
}

# =========================================================================
# Main dispatcher
# =========================================================================
main() {
  install_stub
  setup_test_profile

  echo "========================================"
  echo "  Phase 15 Integration + Unit Tests"
  echo "  Event Handlers (HOOK-03/04/05/07)"
  echo "========================================"
  echo ""

  local listener_up=0
  if start_listener; then
    listener_up=1
  else
    echo "  SKIP: listener failed to start (Wave 0 pre-implementation state)"
    echo "  Listener-dependent tests will be marked FAIL"
  fi

  # HOOK-03
  echo "--- HOOK-03: Issue events ---"
  if [ $listener_up -eq 1 ]; then
    run_test "issues opened routes"             test_issues_opened_routes
    run_test "issues labeled routes"            test_issues_labeled_routes
    run_test "issues closed filtered"           test_issues_closed_filtered
  else
    for t in test_issues_opened_routes test_issues_labeled_routes test_issues_closed_filtered; do
      TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: $t (listener not running)"
    done
  fi
  run_test "default template issues-opened"   test_default_template_issues_opened_exists
  echo ""

  # HOOK-04
  echo "--- HOOK-04: Push-to-Main ---"
  if [ $listener_up -eq 1 ]; then
    run_test "push main routes"                 test_push_main_routes
    run_test "push feature branch filtered"     test_push_feature_branch_filtered
    run_test "push bot loop filtered"           test_push_bot_loop_filtered
    run_test "push branch delete no crash"      test_push_branch_delete_no_crash
  else
    for t in test_push_main_routes test_push_feature_branch_filtered test_push_bot_loop_filtered test_push_branch_delete_no_crash; do
      TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: $t (listener not running)"
    done
  fi
  echo ""

  # HOOK-05
  echo "--- HOOK-05: Workflow run ---"
  if [ $listener_up -eq 1 ]; then
    run_test "workflow_run failure routes"      test_workflow_run_failure_routes
    run_test "workflow_run success filtered"    test_workflow_run_success_filtered
    run_test "workflow_run in_progress filt."   test_workflow_run_in_progress_filtered
  else
    for t in test_workflow_run_failure_routes test_workflow_run_success_filtered test_workflow_run_in_progress_filtered; do
      TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: $t (listener not running)"
    done
  fi
  run_test "workflow template dry-run"        test_workflow_template_dry_run
  echo ""

  # HOOK-07
  echo "--- HOOK-07: Replay subcommand ---"
  run_test "replay finds single match"        test_replay_finds_single_match
  run_test "replay ambiguous errors"          test_replay_ambiguous_errors
  run_test "replay no match errors"           test_replay_no_match_errors
  run_test "replay auto profile"              test_replay_auto_profile
  echo ""

  # Locked decisions
  echo "--- Locked decisions D-01..D-22 ---"
  run_test "compute_event_type cases"         test_compute_event_type_cases
  if [ $listener_up -eq 1 ]; then
    run_test "ping event filtered"            test_ping_event_filtered
  else
    TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: test_ping_event_filtered (listener not running)"
  fi
  run_test "extract_field truncates"          test_extract_field_truncates
  run_test "extract_field utf8-safe"          test_extract_field_utf8_safe
  run_test "render handles pipe in value"     test_render_handles_pipe_in_value
  run_test "render handles backslash in val"  test_render_handles_backslash_in_value
  run_test "resolve_template fallback chain"  test_resolve_template_fallback_chain
  run_test "explicit template no default fb"  test_explicit_template_no_default_fallback
  run_test "WEBHOOK_TEMPLATES_DIR env var"    test_webhook_templates_dir_env_var
  run_test "install copies templates dir"     test_install_copies_templates_dir
  if [ $listener_up -eq 1 ]; then
    run_test "event file has top level type" test_event_file_has_top_level_event_type
  else
    TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: test_event_file_has_top_level_event_type (listener not running)"
  fi
  run_test "spawn event_type priority"        test_spawn_event_type_priority
  echo ""

  echo "=============================="
  echo "Phase 15: $PASS/$TOTAL passed, $FAIL failed"
  echo "=============================="
  [ $FAIL -eq 0 ]
}

# Allow sourcing individual test functions for targeted runs:
#   bash tests/test-phase15.sh test_issues_opened_routes
if [ $# -gt 0 ]; then
  install_stub
  setup_test_profile
  start_listener || true
  "$@"
  exit $?
fi

main "$@"
