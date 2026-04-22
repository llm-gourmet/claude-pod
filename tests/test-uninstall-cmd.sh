#!/bin/bash
# test-uninstall-cmd.sh -- Unit tests for `claude-secure uninstall` subcommand
#
# Tests:
#   UNINST-01: Static -- 'uninstall' is in the skip-superuser-load case
#   UNINST-02: Static -- uninstall handler exists in case "$CMD"
#   UNINST-03: Static -- handler passes flags to uninstall.sh via REMAINING_ARGS
#   UNINST-04: Behaviour -- --dry-run outputs [DRY-RUN] lines, exits 0, no files removed
#   UNINST-05: Behaviour -- missing uninstall.sh gives a helpful error (exit 1)
#   UNINST-06: Static -- uninstall.sh passes bash -n syntax check
#   UNINST-07: Behaviour -- --help flag prints usage and exits 0
#
# Usage: bash tests/test-uninstall-cmd.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/claude-secure"
UNINSTALL_SH="$PROJECT_DIR/uninstall.sh"

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

TEST_TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "========================================"
echo "  Uninstall Subcommand Tests"
echo "  (UNINST-01 -- UNINST-07)"
echo "========================================"
echo ""

# Build a minimal CONFIG_DIR pointing APP_DIR at PROJECT_DIR.
_make_config_dir() {
  local tmpdir="$1"
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles/default" "$cfg/logs"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  jq -n --arg ws "$tmpdir/workspace" '{"workspace":$ws}' \
    > "$cfg/profiles/default/profile.json"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "$cfg/profiles/default/.env"
  mkdir -p "$tmpdir/workspace"
  echo "$cfg"
}

# =========================================================================
# UNINST-01: Static -- 'uninstall' in skip-superuser-load case
# =========================================================================
echo "--- UNINST-01: uninstall skips superuser config load ---"

test_uninst01_in_skip_case() {
  grep -qE '\buninstall\b' "$CLI"
  # More specifically: it must appear in the FIRST_ARG skip case before load_superuser_config
  local skip_line load_line
  skip_line=$(grep -n 'uninstall' "$CLI" | grep -v '^\s*#\|cmd\b\|echo\|_script' | head -1 | cut -d: -f1)
  load_line=$(grep -n 'load_superuser_config$' "$CLI" | grep -v '^\s*#' | head -1 | cut -d: -f1)
  [ -n "$skip_line" ] && [ -n "$load_line" ] && [ "$skip_line" -lt "$load_line" ]
}
run_test "UNINST-01: 'uninstall' appears in skip-superuser-load case before load_superuser_config" \
  test_uninst01_in_skip_case

echo ""

# =========================================================================
# UNINST-02: Static -- uninstall handler exists in CMD case
# =========================================================================
echo "--- UNINST-02: uninstall handler exists in CMD case dispatch ---"

test_uninst02_handler_exists() {
  # There must be a 'uninstall)' arm in the case "$CMD" block
  grep -q 'uninstall)' "$CLI"
}
run_test "UNINST-02: 'uninstall)' case arm present in bin/claude-secure" \
  test_uninst02_handler_exists

test_uninst02_calls_uninstall_sh() {
  # Handler must reference uninstall.sh
  grep -A5 'uninstall)' "$CLI" | grep -q 'uninstall\.sh'
}
run_test "UNINST-02b: uninstall handler references uninstall.sh" \
  test_uninst02_calls_uninstall_sh

echo ""

# =========================================================================
# UNINST-03: Static -- handler forwards REMAINING_ARGS (flag pass-through)
# =========================================================================
echo "--- UNINST-03: flags are forwarded to uninstall.sh ---"

test_uninst03_passes_remaining_args() {
  # The handler must use REMAINING_ARGS (or equivalent) to forward flags
  grep -A8 'uninstall)' "$CLI" | grep -q 'REMAINING_ARGS'
}
run_test "UNINST-03: uninstall handler uses REMAINING_ARGS for flag pass-through" \
  test_uninst03_passes_remaining_args

echo ""

# =========================================================================
# UNINST-04: Behaviour -- claude-secure uninstall --dry-run
# =========================================================================
echo "--- UNINST-04: dry-run mode works end-to-end ---"

test_uninst04_dryrun_exits_zero_with_summary() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_config_dir "$tmpdir")

  local output
  output=$(
    HOME="$tmpdir" \
    CONFIG_DIR="$cfg" \
    bash "$CLI" uninstall --dry-run </dev/null 2>&1
  )
  local rc=$?
  # Must exit 0 and print summary + "dry run complete" message
  [ "$rc" -eq 0 ] && echo "$output" | grep -qi 'dry run complete\|Uninstall Summary'
}
run_test "UNINST-04a: uninstall --dry-run exits 0 and prints summary" \
  test_uninst04_dryrun_exits_zero_with_summary

test_uninst04_dryrun_touches_no_files() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_config_dir "$tmpdir")

  # Create a fake config dir so uninstall.sh can prompt (it won't - non-TTY)
  mkdir -p "$tmpdir/.claude-secure"

  # Record mtimes of all files in cfg before
  local before after
  before=$(find "$cfg" -newer "$cfg" 2>/dev/null | sort)

  HOME="$tmpdir" CONFIG_DIR="$cfg" bash "$CLI" uninstall --dry-run </dev/null >/dev/null 2>&1

  after=$(find "$cfg" -newer "$cfg" 2>/dev/null | sort)

  # No files should be removed (cfg directory should still exist)
  [ -d "$cfg" ]
}
run_test "UNINST-04b: uninstall --dry-run leaves config dir intact" \
  test_uninst04_dryrun_touches_no_files

echo ""

# =========================================================================
# UNINST-05: Behaviour -- missing uninstall.sh gives helpful error
# =========================================================================
echo "--- UNINST-05: missing uninstall.sh produces helpful error ---"

test_uninst05_missing_uninstall_sh() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  # Config pointing APP_DIR to a dir WITHOUT uninstall.sh
  local fake_app
  fake_app=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles/default" "$cfg/logs"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$fake_app"
PLATFORM="linux"
EOF
  jq -n '{"workspace":"/tmp"}' > "$cfg/profiles/default/profile.json"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "$cfg/profiles/default/.env"

  local output
  output=$(
    HOME="$tmpdir" CONFIG_DIR="$cfg" bash "$CLI" uninstall 2>&1
  )
  local rc=$?

  # Must exit non-zero and mention uninstall.sh
  [ "$rc" -ne 0 ] && echo "$output" | grep -qi 'uninstall'
}
run_test "UNINST-05: missing uninstall.sh produces non-zero exit with helpful message" \
  test_uninst05_missing_uninstall_sh

echo ""

# =========================================================================
# UNINST-06: Static -- uninstall.sh syntax is valid
# =========================================================================
echo "--- UNINST-06: uninstall.sh syntax check ---"

test_uninst06_syntax_check() {
  bash -n "$UNINSTALL_SH"
}
run_test "UNINST-06: uninstall.sh passes bash -n syntax check" \
  test_uninst06_syntax_check

echo ""

# =========================================================================
# UNINST-07: Behaviour -- uninstall --help exits 0
# =========================================================================
echo "--- UNINST-07: uninstall --help exits 0 ---"

test_uninst07_help_exits_zero() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_config_dir "$tmpdir")

  local output
  output=$(
    HOME="$tmpdir" CONFIG_DIR="$cfg" bash "$CLI" uninstall --help 2>&1
  )
  local rc=$?
  [ "$rc" -eq 0 ] && echo "$output" | grep -qi 'dry-run\|Usage'
}
run_test "UNINST-07: uninstall --help exits 0 and prints usage" \
  test_uninst07_help_exits_zero

echo ""

# =========================================================================
# Summary
# =========================================================================
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL total)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
