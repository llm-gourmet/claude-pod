#!/bin/bash
# tests/test-phase26.sh -- Phase 26 Stop Hook & Mandatory Reporting tests
# SPOOL-01 (stop hook enforces spool write), SPOOL-02 (zero network calls),
# SPOOL-03 (async shipper publishes spool after spawn).
#
# Wave 0 contract (Nyquist self-healing): ALL implementation tests MUST fail
# until Plans 02 and 03 land. Only structural tests pass in Wave 0:
#   - test_fixtures_exist
#   - test_test_map_registered (passes after Task 3 in Plan 01)
# All SPOOL-01/02/03 tests are RED in Wave 0 because:
#   - claude/hooks/stop-hook.sh does not yet exist (Plan 02 creates it)
#   - run_spool_shipper function does not yet exist in bin/claude-secure (Plan 03)
#   - claude/settings.json does not yet have a Stop hook entry (Plan 02)
#
# TESTABILITY CONTRACTS — Implementation plans MUST honor these env vars:
#
#   TEST_SPOOL_FILE_OVERRIDE:
#     If set, stop-hook.sh uses this path as $SPOOL_FILE instead of
#     /var/log/claude-secure/spool.md. This lets unit tests redirect the
#     spool check to a temp directory without needing container paths.
#     Plan 02 MUST check: SPOOL_FILE="${TEST_SPOOL_FILE_OVERRIDE:-/var/log/claude-secure/spool.md}"
#
#   CLAUDE_SECURE_SKIP_SPOOL_SHIPPER:
#     If set to 1, run_spool_shipper() returns 0 immediately without forking.
#     Allows unit tests that source bin/claude-secure to call do_spawn or
#     interactive spawn paths without triggering background publish.
#     Plan 03 MUST check: [ "${CLAUDE_SECURE_SKIP_SPOOL_SHIPPER:-}" = "1" ] && return 0
#
#   MOCK_PUBLISH_BUNDLE_EXIT:
#     Tests that verify shipper behavior define a shell function
#     publish_docs_bundle() before sourcing bin/claude-secure. The function
#     uses MOCK_PUBLISH_BUNDLE_EXIT (0=success, 1=failure) to simulate
#     real publish behavior. Plan 03 implementation calls publish_docs_bundle
#     as a normal shell function, so the stub takes precedence when defined first.
#
# Usage:
#   bash tests/test-phase26.sh                        # run full suite
#   bash tests/test-phase26.sh test_fixtures_exist    # run single function

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
  # Rewrite workspace to a real dir the tests own
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

# Helper: create a bare git repo for shipper tests to use as docs_repo.
# Mirrors Phase 23/24/25 bare-repo pattern.
create_bare_docs_repo() {
  local bare="$1"
  local seed="$TEST_TMPDIR/docs-seed-$(basename "$bare")"
  git init -q --bare "$bare"
  git clone -q "$bare" "$seed"
  (
    cd "$seed" \
      && git config user.email test@example.com \
      && git config user.name test \
      && git config commit.gpgsign false \
      && mkdir -p phase-26-spool \
      && echo "# Phase 26 Docs" > phase-26-spool/README.md \
      && git add -A \
      && git commit -qm init \
      && git push -q origin HEAD:main
  )
  rm -rf "$seed"
}

# Helper: rewrite a fixture profile's docs_repo to a local bare file:// URL.
point_profile_at_bare() {
  local profile_dir="$1" bare="$2"
  local url="file://$bare"
  local tmp
  tmp=$(mktemp)
  jq --arg url "$url" '.docs_repo = $url' "$profile_dir/profile.json" > "$tmp"
  mv "$tmp" "$profile_dir/profile.json"
}

# Helper: set up a mock spool directory and return path.
# Tests that run stop-hook.sh use TEST_SPOOL_FILE_OVERRIDE to redirect
# the spool file check to this directory instead of /var/log/claude-secure/.
setup_mock_spool_dir() {
  local mock_dir="$TEST_TMPDIR/mock-spool"
  mkdir -p "$mock_dir"
  echo "$mock_dir"
}

# Helper: run stop-hook.sh with TEST_SPOOL_FILE_OVERRIDE pointed at mock dir.
# Usage: run_stop_hook_with_mock_spool_dir <mock_spool_file_path> < <stdin_json>
# Returns the exit code of stop-hook.sh and captures stdout in RUN_HOOK_OUT.
run_stop_hook_with_mock_spool() {
  local mock_spool_file="$1"
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  RUN_HOOK_OUT=$(TEST_SPOOL_FILE_OVERRIDE="$mock_spool_file" bash "$hook" 2>/dev/null)
  return $?
}

# Helper: write a stub publish_docs_bundle function to a file that tests source
# before sourcing bin/claude-secure. MOCK_PUBLISH_BUNDLE_EXIT controls behavior.
# Usage: write_mock_publish_bundle <dest_file>
write_mock_publish_bundle() {
  local dest="$1"
  cat > "$dest" << 'STUB_EOF'
publish_docs_bundle() {
  local exit_code="${MOCK_PUBLISH_BUNDLE_EXIT:-0}"
  if [ "$exit_code" = "0" ]; then
    echo "file:///fake/report.md"
    return 0
  else
    return 1
  fi
}
STUB_EOF
}

# =========================================================================
# Wave 0 GREEN tests (structural — Plan 01 delivers fixtures + test-map entry)
# =========================================================================

test_fixtures_exist() {
  # PASSES in Wave 0 (Plan 01 delivers all 8 fixture files)
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/profile.json" ]          || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/.env" ]                  || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-26-spool/whitelist.json" ]        || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" ]                 || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/spools/broken-missing-section.md" ]       || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" ]     || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-true.json" ]      || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/malformed.json" ]        || return 1
  # Validate JSON shape of key fixtures
  jq -e '.stop_hook_active == false' \
    "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" >/dev/null  || return 1
  jq -e '.stop_hook_active == true' \
    "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-true.json" >/dev/null   || return 1
  # valid-bundle.md must have exactly 6 H2 sections
  local h2_count
  h2_count=$(grep -c '^## ' "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" || echo 0)
  [ "$h2_count" = "6" ] || return 1
  # broken-missing-section.md must have exactly 5 H2 sections
  h2_count=$(grep -c '^## ' "$PROJECT_DIR/tests/fixtures/spools/broken-missing-section.md" || echo 0)
  [ "$h2_count" = "5" ] || return 1
  return 0
}

test_test_map_registered() {
  # PASSES in Wave 0 after Task 3 adds test-phase26.sh to test-map.json
  jq -e '[.mappings[] | select(.tests[] | contains("test-phase26.sh"))] | length > 0' \
    "$PROJECT_DIR/tests/test-map.json" > /dev/null
}

# =========================================================================
# SPOOL-01 / SPOOL-02 stop hook contract tests (Plan 02 flips RED to GREEN)
# =========================================================================

test_stop_hook_script_exists() {
  # FAILS in Wave 0 — claude/hooks/stop-hook.sh does not yet exist.
  # Plan 02 creates claude/hooks/stop-hook.sh and registers it via Dockerfile.claude.
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] && [ -x "$hook" ]
}

test_stop_hook_yields_when_spool_present() {
  # FAILS in Wave 0 — stop-hook.sh does not exist.
  # Plan 02: pipe active-false.json + pre-create spool.md → hook must exit 0
  # and NOT output "decision":"block".
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  # Pre-create spool.md to simulate a session that already wrote its report
  echo "# Already written report" > "$mock_spool_file"

  local out
  out=$(TEST_SPOOL_FILE_OVERRIDE="$mock_spool_file" \
        bash "$hook" < "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" 2>/dev/null)
  local rc=$?

  [ "$rc" -eq 0 ] || return 1
  # Must NOT produce a block decision when spool is present
  echo "$out" | grep -q '"decision".*"block"' && return 1
  return 0
}

test_stop_hook_reprompts_when_spool_missing() {
  # FAILS in Wave 0 — stop-hook.sh does not exist.
  # Plan 02: pipe active-false.json, no spool.md → hook must output
  # {"decision":"block",...} with the 6 mandatory H2 section names in the reason.
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  # Ensure spool.md does NOT exist
  rm -f "$mock_spool_file"

  local out
  out=$(TEST_SPOOL_FILE_OVERRIDE="$mock_spool_file" \
        bash "$hook" < "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-false.json" 2>/dev/null)

  # Must output a block decision
  echo "$out" | grep -q '"decision".*"block"' || return 1
  # Must include the 6 mandatory section headings in the reason
  echo "$out" | grep -q 'Goal'          || return 1
  echo "$out" | grep -q 'Where Worked'  || return 1
  echo "$out" | grep -q 'What Changed'  || return 1
  echo "$out" | grep -q 'What Failed'   || return 1
  echo "$out" | grep -q 'How to Test'   || return 1
  echo "$out" | grep -q 'Future Findings' || return 1
  return 0
}

test_stop_hook_yields_on_stop_hook_active_true() {
  # FAILS in Wave 0 — stop-hook.sh does not exist.
  # Plan 02: when stop_hook_active=true, hook MUST yield (exit 0, no "block")
  # regardless of whether spool.md exists. This is the infinite-loop guard.
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  # Ensure spool.md does NOT exist — if hook incorrectly checks file first
  # it would block; stop_hook_active guard must fire first.
  rm -f "$mock_spool_file"

  local out
  out=$(TEST_SPOOL_FILE_OVERRIDE="$mock_spool_file" \
        bash "$hook" < "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/active-true.json" 2>/dev/null)
  local rc=$?

  [ "$rc" -eq 0 ] || return 1
  # Must NOT block when stop_hook_active=true
  echo "$out" | grep -q '"decision".*"block"' && return 1
  return 0
}

test_stop_hook_no_network_calls() {
  # FAILS in Wave 0 — stop-hook.sh does not exist.
  # Plan 02: grep the script for network tools. SPOOL-02 requires zero network calls.
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] || return 1

  # Any of these in the script body means a network call is possible
  grep -qE '\bcurl\b|\bwget\b|\bnslookup\b|\bgetent\b|\bping\b|\bdig\b' "$hook" && return 1
  return 0
}

test_stop_hook_handles_malformed_stdin() {
  # FAILS in Wave 0 — stop-hook.sh does not exist.
  # Plan 02: when stdin is not valid JSON, hook must not crash (Pitfall 6 fallback).
  # Acceptable outcomes: exit 0 with no output, or exit 0 with a safe JSON response.
  local hook="$PROJECT_DIR/claude/hooks/stop-hook.sh"
  [ -f "$hook" ] || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"

  local out rc
  out=$(TEST_SPOOL_FILE_OVERRIDE="$mock_spool_file" \
        bash "$hook" < "$PROJECT_DIR/tests/fixtures/stop-hook-inputs/malformed.json" 2>/dev/null)
  rc=$?

  # Hook must not crash with a non-zero exit due to JSON parse failure
  [ "$rc" -eq 0 ] || return 1
  return 0
}

test_settings_json_has_stop_hook() {
  # FAILS in Wave 0 — settings.json does not yet have a Stop hook entry.
  # Plan 02: adds hooks.Stop[0].hooks[0].command pointing at stop-hook.sh.
  local settings="$PROJECT_DIR/claude/settings.json"
  [ -f "$settings" ] || return 1
  jq -e '.hooks.Stop[0].hooks[0].command | contains("stop-hook.sh")' \
    "$settings" >/dev/null
}

# =========================================================================
# SPOOL-03 shipper contract tests (Plan 03 flips RED to GREEN)
# =========================================================================

test_run_spool_shipper_function_exists() {
  # FAILS in Wave 0 — run_spool_shipper is not in bin/claude-secure yet.
  # Plan 03: adds run_spool_shipper() to bin/claude-secure.
  source_cs
  declare -F run_spool_shipper >/dev/null
}

test_shipper_returns_immediately() {
  # FAILS in Wave 0 — run_spool_shipper does not exist.
  # Plan 03: disown pattern means run_spool_shipper returns < 1 second
  # even when the underlying publish takes 5+ seconds.
  source_cs
  declare -F run_spool_shipper >/dev/null || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  cp "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" "$mock_spool_file"

  local mock_file
  mock_file=$(mktemp)
  write_mock_publish_bundle "$mock_file"
  # Override publish_docs_bundle with a slow stub that sleeps 5s
  cat >> "$mock_file" << 'SLOW_EOF'
publish_docs_bundle() {
  sleep 5
  echo "file:///fake/slow-report.md"
  return 0
}
SLOW_EOF
  # shellcheck source=/dev/null
  source "$mock_file"
  rm -f "$mock_file"

  local start elapsed
  start=$(date +%s%N)
  LOG_DIR="$mock_spool_dir" run_spool_shipper "test-session-26"
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))

  # Must return in under 1000ms (1 second) regardless of publish duration
  [ "$elapsed" -lt 1000 ]
}

test_shipper_deletes_spool_on_success() {
  # FAILS in Wave 0 — run_spool_shipper does not exist.
  # Plan 03: successful publish_docs_bundle → spool.md is deleted.
  source_cs
  declare -F run_spool_shipper >/dev/null || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  cp "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" "$mock_spool_file"

  local mock_file
  mock_file=$(mktemp)
  write_mock_publish_bundle "$mock_file"
  export MOCK_PUBLISH_BUNDLE_EXIT=0
  # shellcheck source=/dev/null
  source "$mock_file"
  rm -f "$mock_file"

  LOG_DIR="$mock_spool_dir" run_spool_shipper "test-session-26"
  # Wait for background process to complete (up to 10s)
  local i
  for i in $(seq 1 20); do
    [ -f "$mock_spool_file" ] || break
    sleep 0.5
  done

  # spool.md must be deleted after successful publish
  [ ! -f "$mock_spool_file" ]
}

test_shipper_logs_push_failed_with_attempt() {
  # FAILS in Wave 0 — run_spool_shipper does not exist.
  # Plan 03: after 3 failed publish_docs_bundle attempts, audit JSONL must have
  # a line with spool_status="push_failed" and attempt=3.
  source_cs
  declare -F run_spool_shipper >/dev/null || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  local mock_audit_file="$mock_spool_dir/spool-audit.jsonl"
  cp "$PROJECT_DIR/tests/fixtures/spools/valid-bundle.md" "$mock_spool_file"
  rm -f "$mock_audit_file"

  local mock_file
  mock_file=$(mktemp)
  write_mock_publish_bundle "$mock_file"
  export MOCK_PUBLISH_BUNDLE_EXIT=1
  # shellcheck source=/dev/null
  source "$mock_file"
  rm -f "$mock_file"

  LOG_DIR="$mock_spool_dir" LOG_PREFIX="" run_spool_shipper "test-session-26"
  # Wait for background process to complete with 3 retries (up to 30s)
  local i
  for i in $(seq 1 60); do
    [ -f "$mock_audit_file" ] && break
    sleep 0.5
  done

  # Audit file must exist and contain a push_failed entry with attempt 3
  [ -f "$mock_audit_file" ] || return 1
  grep -q '"push_failed"' "$mock_audit_file"  || return 1
  grep -q '"attempt".*3'   "$mock_audit_file" || grep -q '"attempt":3' "$mock_audit_file" || return 1
  return 0
}

test_shipper_publishes_malformed_best_effort() {
  # FAILS in Wave 0 — run_spool_shipper does not exist.
  # Plan 03: even a broken bundle (missing sections) is published best-effort
  # (D-04 philosophy: broken report > no report). Spool must be deleted on success.
  source_cs
  declare -F run_spool_shipper >/dev/null || return 1

  local mock_spool_dir
  mock_spool_dir=$(setup_mock_spool_dir)
  local mock_spool_file="$mock_spool_dir/spool.md"
  # Use the broken fixture (5 sections, missing Future Findings)
  cp "$PROJECT_DIR/tests/fixtures/spools/broken-missing-section.md" "$mock_spool_file"

  local mock_file
  mock_file=$(mktemp)
  write_mock_publish_bundle "$mock_file"
  export MOCK_PUBLISH_BUNDLE_EXIT=0
  # shellcheck source=/dev/null
  source "$mock_file"
  rm -f "$mock_file"

  LOG_DIR="$mock_spool_dir" run_spool_shipper "test-session-26"
  # Wait for background process to complete (up to 10s)
  local i
  for i in $(seq 1 20); do
    [ -f "$mock_spool_file" ] || break
    sleep 0.5
  done

  # Spool must be deleted even for a malformed bundle (best-effort D-04)
  [ ! -f "$mock_spool_file" ]
}

# =========================================================================
# Integration (Plan 04 flips RED to GREEN)
# =========================================================================

test_stale_spool_drained_at_spawn_preamble() {
  # FAILS in Wave 0 — run_spool_shipper_inline does not exist in bin/claude-secure.
  # Plan 04: adds run_spool_shipper_inline to do_spawn preamble so stale spools
  # from crashed sessions are drained before a new session starts.
  source_cs
  declare -F run_spool_shipper_inline >/dev/null || return 1
  # Also verify do_spawn calls it (grep-based)
  declare -f do_spawn | grep -q 'run_spool_shipper_inline'
}

# =========================================================================
# Test runner
# =========================================================================

if [ $# -gt 0 ]; then
  # Single-test invocation (for targeted re-runs during Plans 02/03/04)
  "$@"
  exit $?
fi

run_test "fixtures exist"                              test_fixtures_exist
run_test "test-map registered"                         test_test_map_registered
run_test "stop hook script exists"                     test_stop_hook_script_exists
run_test "stop hook yields when spool present"         test_stop_hook_yields_when_spool_present
run_test "stop hook reprompts when spool missing"      test_stop_hook_reprompts_when_spool_missing
run_test "stop hook yields on stop_hook_active true"   test_stop_hook_yields_on_stop_hook_active_true
run_test "stop hook no network calls"                  test_stop_hook_no_network_calls
run_test "stop hook handles malformed stdin"           test_stop_hook_handles_malformed_stdin
run_test "settings.json has Stop hook entry"           test_settings_json_has_stop_hook
run_test "run_spool_shipper function exists"           test_run_spool_shipper_function_exists
run_test "shipper returns immediately"                 test_shipper_returns_immediately
run_test "shipper deletes spool on success"            test_shipper_deletes_spool_on_success
run_test "shipper logs push_failed with attempt 3"     test_shipper_logs_push_failed_with_attempt
run_test "shipper publishes malformed best effort"     test_shipper_publishes_malformed_best_effort
run_test "stale spool drained at spawn preamble"       test_stale_spool_drained_at_spawn_preamble

echo
echo "Phase 26 tests: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
