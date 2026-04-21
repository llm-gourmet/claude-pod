#!/bin/bash
# test-gh-webhook-listener-filter-cli.sh -- Unit tests for gh-webhook-listener filter CLI
# Tests WLFILTER-01 through WLFILTER-09
#
# Strategy: source bin/claude-secure with __CLAUDE_SECURE_SOURCE_ONLY=1 to
# load function definitions, use temp dirs as CONFIG_DIR and HOME.
# No Docker, no network.
#
# Usage: bash tests/test-gh-webhook-listener-filter-cli.sh
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
# WLFILTER-01: filter add stores value in skip_filters
# ---------------------------------------------------------------------------
test_filter_add_stores_value() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  cmd_gh_webhook_listener filter add "[skip-claude]" --name "myrepo" >/dev/null 2>&1

  local cjson="$tmpdir/webhooks/connections.json"
  [ -f "$cjson" ] || { echo "connections.json not found" >&2; return 1; }
  local filters
  filters=$(jq -r '.[] | select(.name=="myrepo") | .skip_filters // [] | .[]' "$cjson" 2>/dev/null)
  [ "$filters" = "[skip-claude]" ] || { echo "expected filter '[skip-claude]', got: $filters" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-02: filter add duplicate rejected
# ---------------------------------------------------------------------------
test_filter_add_duplicate_rejected() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec","skip_filters":["[skip-claude]"]}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local rc=0
  local out
  out=$(cmd_gh_webhook_listener filter add "[skip-claude]" --name "myrepo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit" >&2; return 1; }
  echo "$out" | grep -q "already exists" || { echo "expected 'already exists' in output; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-03: filter add unknown connection rejected
# ---------------------------------------------------------------------------
test_filter_add_unknown_connection() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local rc=0
  local out
  out=$(cmd_gh_webhook_listener filter add "[skip-claude]" --name "nonexistent" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit" >&2; return 1; }
  echo "$out" | grep -q "not found" || { echo "expected 'not found' in output; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-04: filter add prints coverage table
# ---------------------------------------------------------------------------
test_filter_add_prints_coverage_table() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local out
  out=$(cmd_gh_webhook_listener filter add "[skip-claude]" --name "myrepo" 2>/dev/null)
  echo "$out" | grep -q "push events" || { echo "coverage table missing 'push events'; got: $out" >&2; return 1; }
  echo "$out" | grep -q "commit message prefix" || { echo "coverage table missing 'commit message prefix'; got: $out" >&2; return 1; }
  echo "$out" | grep -q "label match" || { echo "coverage table missing 'label match'; got: $out" >&2; return 1; }
  echo "$out" | grep -q "body prefix" || { echo "coverage table missing 'body prefix'; got: $out" >&2; return 1; }
  echo "$out" | grep -q "not applicable" || { echo "coverage table missing 'not applicable'; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-05: filter list shows active filters with coverage
# ---------------------------------------------------------------------------
test_filter_list_shows_filters() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec","skip_filters":["[skip-claude]"]}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local out
  out=$(cmd_gh_webhook_listener filter list --name "myrepo" 2>/dev/null)
  echo "$out" | grep -q "skip-claude" || { echo "expected filter value in output; got: $out" >&2; return 1; }
  echo "$out" | grep -q "push events" || { echo "expected coverage table in output; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-06: filter list empty shows informational message
# ---------------------------------------------------------------------------
test_filter_list_empty() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec"}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local out
  out=$(cmd_gh_webhook_listener filter list --name "myrepo" 2>/dev/null)
  echo "$out" | grep -qi "no filters" || { echo "expected 'No filters' in output; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-07: filter list unknown connection rejected
# ---------------------------------------------------------------------------
test_filter_list_unknown_connection() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[]' > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local rc=0
  cmd_gh_webhook_listener filter list --name "nonexistent" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-08: filter remove success
# ---------------------------------------------------------------------------
test_filter_remove_success() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec","skip_filters":["[skip-claude]","other"]}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  cmd_gh_webhook_listener filter remove "[skip-claude]" --name "myrepo" >/dev/null 2>&1

  local filters
  filters=$(jq -r '.[] | select(.name=="myrepo") | .skip_filters // [] | .[]' "$tmpdir/webhooks/connections.json" 2>/dev/null)
  echo "$filters" | grep -q "\[skip-claude\]" && { echo "filter still present after remove" >&2; return 1; }
  echo "$filters" | grep -q "other" || { echo "unrelated filter was removed" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# WLFILTER-09: filter remove unknown value rejected
# ---------------------------------------------------------------------------
test_filter_remove_unknown_value() {
  local tmpdir; tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" RETURN

  mkdir -p "$tmpdir/webhooks"
  printf '%s\n' '[{"name":"myrepo","repo":"org/repo","webhook_secret":"sec","skip_filters":["other"]}]' \
    > "$tmpdir/webhooks/connections.json"

  setup_cli "$tmpdir"
  local rc=0
  local out
  out=$(cmd_gh_webhook_listener filter remove "[skip-claude]" --name "myrepo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit" >&2; return 1; }
  echo "$out" | grep -q "not found" || { echo "expected 'not found' in output; got: $out" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "========================================"
  echo "  Webhook Filter CLI Tests (WLFILTER-01..09)"
  echo "========================================"
  echo ""
  run_test "filter add stores value"               test_filter_add_stores_value
  run_test "filter add duplicate rejected"         test_filter_add_duplicate_rejected
  run_test "filter add unknown connection"         test_filter_add_unknown_connection
  run_test "filter add prints coverage table"      test_filter_add_prints_coverage_table
  run_test "filter list shows filters"             test_filter_list_shows_filters
  run_test "filter list empty"                     test_filter_list_empty
  run_test "filter list unknown connection"        test_filter_list_unknown_connection
  run_test "filter remove success"                 test_filter_remove_success
  run_test "filter remove unknown value"           test_filter_remove_unknown_value
  echo ""
  echo "========================================"
  echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
  echo "========================================"
  [ "$FAIL" -eq 0 ]
}

main "$@"
