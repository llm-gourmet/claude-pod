#!/bin/bash
# tests/test-phase26.sh -- Phase 26 Stop Hook & Mandatory Reporting tests
# SPOOL-01 (stop hook verifies spool before exit, re-prompts once if missing)
# SPOOL-02 (zero network calls — doc repo outage cannot block Claude exit)
# SPOOL-03 (host-side async shipper publishes after Claude exits, never blocks spawn)
#
# Testability contracts (Plans 02/03/04 MUST honor these env vars):
#   TEST_SPOOL_FILE_OVERRIDE      - stop-hook.sh uses this path as SPOOL_FILE if set,
#                                   otherwise defaults to /var/log/claude-secure/spool.md
#   CLAUDE_SECURE_SKIP_SPOOL_SHIPPER=1 - run_spool_shipper returns 0 immediately
#                                   (existing Rule 3 deviation pattern, see Phase 16 D-23)
#   MOCK_PUBLISH_BUNDLE_EXIT      - shipper tests source a stubbed publish_docs_bundle
#                                   before sourcing bin/claude-secure so run_spool_shipper
#                                   uses the stub (0=success, 1=failure)
#
# Wave structure:
#   Wave 0 (Plan 01): test scaffold — fixtures_exist + test_map_registered GREEN,
#                     all implementation tests RED
#   Wave 1 (Plan 02): stop-hook.sh + settings.json — tests 3-9 flip to GREEN
#   Wave 2 (Plan 03): run_spool_shipper — tests 10-14 flip to GREEN
#   Wave 3 (Plan 04): spawn integration — test 15 flips to GREEN
#
# Usage:
#   bash tests/test-phase26.sh                                   # full suite
#   bash tests/test-phase26.sh test_stop_hook_script_exists      # single test

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
export CONFIG_DIR="$TEST_TMPDIR/cs-config"
export HOME="$TEST_TMPDIR/home"
export APP_DIR="$PROJECT_DIR"
mkdir -p "$CONFIG_DIR/profiles" "$HOME"

cleanup() { rm -rf "$TEST_TMPDIR"; }
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

# Helper: install a fixture profile into $CONFIG_DIR/profiles/<dest>
install_fixture() {
  local src_fixture="$1" dest_name="$2"
  local src="$PROJECT_DIR/tests/fixtures/$src_fixture"
  local dst="$CONFIG_DIR/profiles/$dest_name"
  mkdir -p "$dst"
  cp "$src/profile.json" "$dst/profile.json"
  cp "$src/.env"         "$dst/.env"
  cp "$src/whitelist.json" "$dst/whitelist.json"
  local ws="$TEST_TMPDIR/ws-$dest_name"
  mkdir -p "$ws"
  local tmp
  tmp=$(mktemp)
  jq --arg ws "$ws" '.workspace = $ws' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
}

# Helper: source bin/claude-secure in library mode
source_cs() {
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/bin/claude-secure"
  unset __CLAUDE_SECURE_SOURCE_ONLY
}

# Helper: run stop-hook.sh with a mock spool dir.
# Uses TEST_SPOOL_FILE_OVERRIDE to redirect spool path to a temp dir.
# Usage: run_stop_hook_with_mock_spool <spool_path> < <input_json>
# The spool_path can be an existing file (yields) or nonexistent path (blocks).
run_stop_hook_with_mock_spool() {
  local spool_path="$1"
  TEST_SPOOL_FILE_OVERRIDE="$spool_path" bash "$PROJECT_DIR/claude/hooks/stop-hook.sh"
}

# Helper: setup mock log dir so LOG_HOOK logging doesn't fail in tests
setup_mock_log_dir() {
  export LOG_PREFIX="test26-"
  mkdir -p "$TEST_TMPDIR/var/log/claude-secure"
  # Symlink /var/log/claude-secure to our mock if we need to test the default path
  # (not needed for most unit tests — they use TEST_SPOOL_FILE_OVERRIDE)
}

# =========================================================================
# Wave 0 GREEN tests (Plan 01 delivers fixtures + test-map entry)
# =========================================================================

test_fixtures_exist() {
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/profile.json" ]         || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/.env" ]                 || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/whitelist.json" ]       || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" ]                || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/spools/broken-missing-section.md" ]      || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" ]    || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-true.json" ]     || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/malformed.json" ]       || return 1
  return 0
}

test_test_map_registered() {
  jq -e '[.mappings[] | select(.tests[] | contains("test-phase26.sh"))] | length > 0' \
    "$PROJECT_DIR/tests/test-map.json" > /dev/null
}

# =========================================================================
# Wave 1 unit tests (Plan 02 flips these from RED to GREEN)
# =========================================================================

test_stop_hook_script_exists() {
  # FAILS in Wave 0 until Plan 02 creates claude/hooks/stop-hook.sh
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  [ -x "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  bash -n "$PROJECT_DIR/claude/hooks/stop-hook.sh" || return 1
  return 0
}

test_stop_hook_yields_when_spool_present() {
  # FAILS in Wave 0 until Plan 02 creates stop-hook.sh
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  local spool_file="$TEST_TMPDIR/spool-present-$$.md"
  touch "$spool_file"
  local output
  output=$(cat "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" | \
    run_stop_hook_with_mock_spool "$spool_file")
  local rc=$?
  rm -f "$spool_file"
  # Must exit 0
  [ "$rc" -eq 0 ] || return 1
  # Must NOT output a block decision
  if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    return 1  # should NOT have blocked when spool is present
  fi
  return 0
}

test_stop_hook_reprompts_when_spool_missing() {
  # FAILS in Wave 0 until Plan 02 creates stop-hook.sh
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  local spool_file="$TEST_TMPDIR/spool-missing-$$.md"
  # Ensure spool does NOT exist
  rm -f "$spool_file"
  local output
  output=$(cat "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" | \
    run_stop_hook_with_mock_spool "$spool_file")
  local rc=$?
  [ "$rc" -eq 0 ] || return 1
  # Must output decision=block
  echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1 || return 1
  # Reason must contain all 6 H2 headings
  local reason
  reason=$(echo "$output" | jq -r '.reason' 2>/dev/null) || return 1
  echo "$reason" | grep -q '## Goal'             || return 1
  echo "$reason" | grep -q '## Where Worked'      || return 1
  echo "$reason" | grep -q '## What Changed'      || return 1
  echo "$reason" | grep -q '## What Failed'       || return 1
  echo "$reason" | grep -q '## How to Test'       || return 1
  echo "$reason" | grep -q '## Future Findings'   || return 1
  return 0
}

test_stop_hook_yields_on_stop_hook_active_true() {
  # FAILS in Wave 0 until Plan 02 creates stop-hook.sh
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  local spool_file="$TEST_TMPDIR/spool-active-$$.md"
  # Spool does NOT exist — but stop_hook_active=true means we must yield anyway
  rm -f "$spool_file"
  local output
  output=$(cat "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-true.json" | \
    run_stop_hook_with_mock_spool "$spool_file")
  local rc=$?
  [ "$rc" -eq 0 ] || return 1
  # Must NOT block (recursion guard)
  if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    return 1  # should NOT have blocked when stop_hook_active=true
  fi
  return 0
}

test_stop_hook_no_network_calls() {
  # FAILS in Wave 0 until Plan 02 creates stop-hook.sh (file must exist to grep)
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  # SPOOL-02 invariant: zero network tool references
  if grep -Eq 'curl|wget|nslookup|getent|ping |dig |host ' \
      "$PROJECT_DIR/claude/hooks/stop-hook.sh"; then
    return 1  # found a network call — FAIL
  fi
  return 0
}

test_stop_hook_handles_malformed_stdin() {
  # FAILS in Wave 0 until Plan 02 creates stop-hook.sh
  # Pitfall 6: malformed JSON on stdin must not crash the hook
  [ -f "$PROJECT_DIR/claude/hooks/stop-hook.sh" ] || return 1
  local spool_file="$TEST_TMPDIR/spool-malformed-$$.md"
  rm -f "$spool_file"
  # Should not crash (exit must be 0; output may or may not be block decision)
  cat "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/malformed.json" | \
    run_stop_hook_with_mock_spool "$spool_file" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ]
}

test_settings_json_has_stop_hook() {
  # FAILS in Wave 0 until Plan 02 adds Stop entry to claude/settings.json
  jq -e '.hooks.Stop[0].hooks[0].command == "/etc/claude-secure/hooks/stop-hook.sh"' \
    "$PROJECT_DIR/claude/settings.json" >/dev/null 2>&1 || return 1
  # Existing PreToolUse must be preserved
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "/etc/claude-secure/hooks/pre-tool-use.sh"' \
    "$PROJECT_DIR/claude/settings.json" >/dev/null 2>&1 || return 1
  # Stop entry must NOT have a matcher field
  jq -e '.hooks.Stop[0] | has("matcher") | not' \
    "$PROJECT_DIR/claude/settings.json" >/dev/null 2>&1 || return 1
  return 0
}

# =========================================================================
# Wave 2 unit tests (Plan 03 flips these from RED to GREEN)
# =========================================================================

test_run_spool_shipper_function_exists() {
  # FAILS until Plan 03 defines run_spool_shipper in bin/claude-secure
  grep -q '^run_spool_shipper()' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q '^run_spool_shipper_inline()' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q '^_spool_shipper_loop()' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q '^_spool_audit_write()' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q 'CLAUDE_SECURE_SKIP_SPOOL_SHIPPER' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q '& disown' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q 'spool-audit.jsonl' "$PROJECT_DIR/bin/claude-secure" || return 1
  return 0
}

test_shipper_returns_immediately() {
  # Tests that run_spool_shipper returns in < 2s even when the shipper loop
  # would take longer (background fork + disown must detach immediately).
  local spool_file="$TEST_TMPDIR/spool-timing-$$.md"
  echo "## test spool" > "$spool_file"
  export LOG_DIR="$TEST_TMPDIR"
  export LOG_PREFIX="test26-timing-"
  export PROFILE="test-profile"

  # Source cs with a mock publish_docs_bundle that sleeps 5s (would block if not forked)
  local result
  result=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    # Override after source so the background subshell inherits the slow mock
    publish_docs_bundle() { sleep 5; echo "http://example.com/report"; return 0; }
    local start end
    start=$(date +%s%3N 2>/dev/null || date +%s)
    run_spool_shipper "test-session-timing-$$"
    end=$(date +%s%3N 2>/dev/null || date +%s)
    echo "$start $end"
  )
  rm -f "$spool_file"

  local start_ms end_ms elapsed_ms
  start_ms=$(echo "$result" | awk '{print $1}')
  end_ms=$(echo "$result" | awk '{print $2}')
  # If milliseconds available (13-digit), use them; otherwise seconds (10-digit)
  if [ "${#start_ms}" -ge 13 ]; then
    elapsed_ms=$(( end_ms - start_ms ))
  else
    elapsed_ms=$(( (end_ms - start_ms) * 1000 ))
  fi
  # Must return in < 2000ms (background fork should be immediate)
  [ "$elapsed_ms" -lt 2000 ] || return 1
  return 0
}

test_shipper_deletes_spool_on_success() {
  # Tests that _spool_shipper_loop deletes spool.md when publish_docs_bundle succeeds
  local spool_file="$TEST_TMPDIR/spool-delete-$$.md"
  echo "## test spool" > "$spool_file"
  export LOG_DIR="$TEST_TMPDIR"
  export LOG_PREFIX="test26-delete-"
  export PROFILE="test-profile"

  (
    # Source bin/claude-secure in library mode, then override publish_docs_bundle.
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    publish_docs_bundle() { echo "http://example.com/report"; return 0; }
    _spool_shipper_loop "$spool_file" "test-session-delete-$$"
  )

  # Spool file must be deleted on success
  [ ! -f "$spool_file" ] || { rm -f "$spool_file"; return 1; }

  # Audit file must exist with pushed status
  local audit_file="$TEST_TMPDIR/test26-delete-spool-audit.jsonl"
  [ -f "$audit_file" ] || return 1
  grep -q '"spool_status":"pushed"' "$audit_file" || return 1
  return 0
}

test_shipper_logs_push_failed_with_attempt() {
  # Tests that _spool_shipper_loop writes push_failed with attempt=3 after all retries fail
  local spool_file="$TEST_TMPDIR/spool-fail-$$.md"
  echo "## test spool" > "$spool_file"
  export LOG_DIR="$TEST_TMPDIR"
  export LOG_PREFIX="test26-fail-"
  export PROFILE="test-profile"

  (
    # Source in library mode, then override to mock.
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    publish_docs_bundle() { return 1; }
    # Override sleep to be a no-op so test runs fast (no 5s/10s wait)
    sleep() { :; }
    _spool_shipper_loop "$spool_file" "test-session-fail-$$"
  )

  # Spool file must be RETAINED on failure (for next spawn's drain)
  [ -f "$spool_file" ] || return 1
  rm -f "$spool_file"

  # Audit file must have push_failed entry with attempt=3
  local audit_file="$TEST_TMPDIR/test26-fail-spool-audit.jsonl"
  [ -f "$audit_file" ] || return 1
  grep -q '"spool_status":"push_failed"' "$audit_file" || return 1
  grep -q '"attempt":3' "$audit_file" || return 1
  return 0
}

test_shipper_publishes_malformed_best_effort() {
  # Tests D-04: broken/malformed spool files must be published anyway (best-effort)
  # The shipper must attempt publish even if verify_bundle_sections would fail.
  # (publish_docs_bundle internally calls verify_bundle_sections and may return 1,
  # but the shipper simply retries and audit-logs — it does not skip broken files.)
  local spool_file="$TEST_TMPDIR/spool-malformed-$$.md"
  # Write a spool with missing sections (malformed per verify_bundle_sections)
  echo "# Malformed report — missing all required sections" > "$spool_file"
  export LOG_DIR="$TEST_TMPDIR"
  export LOG_PREFIX="test26-malformed-"
  export PROFILE="test-profile"

  (
    # Source in library mode, then override publish_docs_bundle with mock that succeeds.
    # D-04: best-effort — publish even if file is malformed (don't skip broken reports).
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    publish_docs_bundle() { echo "http://example.com/malformed-report"; return 0; }
    _spool_shipper_loop "$spool_file" "test-session-malformed-$$"
  )

  # Spool must be deleted (publish succeeded)
  [ ! -f "$spool_file" ] || { rm -f "$spool_file"; return 1; }

  # Audit must show pushed
  local audit_file="$TEST_TMPDIR/test26-malformed-spool-audit.jsonl"
  [ -f "$audit_file" ] || return 1
  grep -q '"spool_status":"pushed"' "$audit_file" || return 1
  return 0
}

# =========================================================================
# Wave 3 integration test (Plan 04 flips this from RED to GREEN)
# =========================================================================

test_stale_spool_drained_at_spawn_preamble() {
  # FAILS until Plan 04 adds run_spool_shipper_inline call to do_spawn preamble
  grep -q 'run_spool_shipper_inline' "$PROJECT_DIR/bin/claude-secure" || return 1
  return 0
}

# =========================================================================
# Test dispatch
# =========================================================================

echo "=== Phase 26: Stop Hook & Mandatory Reporting ==="

if [ "${1:-}" != "" ]; then
  # Single-test invocation: source helpers, run the named test
  PASS=0; FAIL=0; TOTAL=0
  run_test "$1" "$1"
  echo ""
  echo "Result: $PASS passed, $FAIL failed, $TOTAL total"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

echo ""
echo "--- Wave 0: Fixtures + test-map (GREEN in Wave 0) ---"
run_test "test_fixtures_exist"          test_fixtures_exist
run_test "test_test_map_registered"     test_test_map_registered

echo ""
echo "--- Wave 1: Stop hook implementation (GREEN after Plan 02) ---"
run_test "test_stop_hook_script_exists"              test_stop_hook_script_exists
run_test "test_stop_hook_yields_when_spool_present"  test_stop_hook_yields_when_spool_present
run_test "test_stop_hook_reprompts_when_spool_missing" test_stop_hook_reprompts_when_spool_missing
run_test "test_stop_hook_yields_on_stop_hook_active_true" test_stop_hook_yields_on_stop_hook_active_true
run_test "test_stop_hook_no_network_calls"           test_stop_hook_no_network_calls
run_test "test_stop_hook_handles_malformed_stdin"    test_stop_hook_handles_malformed_stdin
run_test "test_settings_json_has_stop_hook"          test_settings_json_has_stop_hook

echo ""
echo "--- Wave 2: Spool shipper (GREEN after Plan 03) ---"
run_test "test_run_spool_shipper_function_exists"    test_run_spool_shipper_function_exists
run_test "test_shipper_returns_immediately"          test_shipper_returns_immediately
run_test "test_shipper_deletes_spool_on_success"     test_shipper_deletes_spool_on_success
run_test "test_shipper_logs_push_failed_with_attempt" test_shipper_logs_push_failed_with_attempt
run_test "test_shipper_publishes_malformed_best_effort" test_shipper_publishes_malformed_best_effort

echo ""
echo "--- Wave 3: Spawn integration (GREEN after Plan 04) ---"
run_test "test_stale_spool_drained_at_spawn_preamble" test_stale_spool_drained_at_spawn_preamble

echo ""
echo "=== Result: $PASS passed, $FAIL failed, $TOTAL total ==="
[ "$FAIL" -eq 0 ]
