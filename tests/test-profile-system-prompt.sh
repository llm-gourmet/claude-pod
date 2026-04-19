#!/bin/bash
# test-profile-system-prompt.sh -- Unit tests for `claude-secure profile <name> system-prompt` subcommands
#
# Tests:
#   PROFSP-01: Static checks — functions present
#   PROFSP-02: system-prompt set — writes to profile.json
#   PROFSP-03: system-prompt get — reads from profile.json
#   PROFSP-04: system-prompt clear — removes from profile.json
#   PROFSP-05: Error handling — bad args, missing action
#
# Usage: bash tests/test-profile-system-prompt.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/claude-secure"

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

_make_cfg() {
  local tmpdir="$1"
  local profname="${2:-testprof}"

  local cfg="$tmpdir/.claude-secure"
  local ws="$tmpdir/workspace"
  mkdir -p "$cfg/profiles/$profname" "$ws"

  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$ws"
EOF

  jq -n --arg ws "$ws" '{"workspace": $ws, "secrets": []}' \
    > "$cfg/profiles/$profname/profile.json"

  printf 'CLAUDE_CODE_OAUTH_TOKEN=test-token\n' > "$cfg/profiles/$profname/.env"
  chmod 600 "$cfg/profiles/$profname/.env"

  echo "$cfg"
}

_run_cli() {
  local cfg="$1"; shift
  CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" "$@"
}

# =========================================================================
# PROFSP-01: Static checks
# =========================================================================
echo "========================================"
echo "  Profile System Prompt CLI Tests"
echo "========================================"
echo ""
echo "--- PROFSP-01: Static checks ---"

run_test "PROFSP-01a: profile_system_prompt_set function defined in CLI" \
  grep -q "^profile_system_prompt_set()" "$CLI"

run_test "PROFSP-01b: profile_system_prompt_get function defined in CLI" \
  grep -q "^profile_system_prompt_get()" "$CLI"

run_test "PROFSP-01c: profile_system_prompt_clear function defined in CLI" \
  grep -q "^profile_system_prompt_clear()" "$CLI"

run_test "PROFSP-01d: system-prompt case present in cmd_profile" \
  grep -q "system-prompt)" "$CLI"

echo ""

# =========================================================================
# PROFSP-02: system-prompt set
# =========================================================================
echo "--- PROFSP-02: system-prompt set ---"

test_profsp02a_writes_profile_json() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof system-prompt set "You are a helpful assistant." >/dev/null
  jq -e '.system_prompt == "You are a helpful assistant."' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFSP-02a: system-prompt set writes value to profile.json" test_profsp02a_writes_profile_json

test_profsp02b_overwrites_existing() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof system-prompt set "First prompt." >/dev/null
  _run_cli "$cfg" profile testprof system-prompt set "Second prompt." >/dev/null
  jq -e '.system_prompt == "Second prompt."' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFSP-02b: system-prompt set overwrites existing value" test_profsp02b_overwrites_existing

test_profsp02c_preserves_secrets() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add API_KEY val >/dev/null
  _run_cli "$cfg" profile testprof system-prompt set "Test prompt." >/dev/null
  jq -e '.secrets[] | select(.env_var == "API_KEY")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFSP-02c: system-prompt set preserves existing secrets" test_profsp02c_preserves_secrets

echo ""

# =========================================================================
# PROFSP-03: system-prompt get
# =========================================================================
echo "--- PROFSP-03: system-prompt get ---"

test_profsp03a_get_set_value() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof system-prompt set "Hello world." >/dev/null
  local out
  out=$(_run_cli "$cfg" profile testprof system-prompt get 2>/dev/null)
  echo "$out" | grep -q "Hello world."
}
run_test "PROFSP-03a: system-prompt get returns the stored value" test_profsp03a_get_set_value

test_profsp03b_get_unset() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local out
  out=$(_run_cli "$cfg" profile testprof system-prompt get 2>/dev/null)
  echo "$out" | grep -q "no system prompt set"
}
run_test "PROFSP-03b: system-prompt get says 'no system prompt set' when unset" test_profsp03b_get_unset

echo ""

# =========================================================================
# PROFSP-04: system-prompt clear
# =========================================================================
echo "--- PROFSP-04: system-prompt clear ---"

test_profsp04a_clear_removes_field() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof system-prompt set "To be removed." >/dev/null
  _run_cli "$cfg" profile testprof system-prompt clear >/dev/null
  local val
  val=$(jq -r '.system_prompt // "ABSENT"' "$cfg/profiles/testprof/profile.json")
  [ "$val" = "ABSENT" ]
}
run_test "PROFSP-04a: system-prompt clear removes field from profile.json" test_profsp04a_clear_removes_field

test_profsp04b_clear_idempotent() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof system-prompt clear >/dev/null
}
run_test "PROFSP-04b: system-prompt clear on unset profile exits 0" test_profsp04b_clear_idempotent

test_profsp04c_clear_preserves_secrets() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add API_KEY val >/dev/null
  _run_cli "$cfg" profile testprof system-prompt set "Temp." >/dev/null
  _run_cli "$cfg" profile testprof system-prompt clear >/dev/null
  jq -e '.secrets[] | select(.env_var == "API_KEY")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFSP-04c: system-prompt clear preserves existing secrets" test_profsp04c_clear_preserves_secrets

echo ""

# =========================================================================
# PROFSP-05: Error handling
# =========================================================================
echo "--- PROFSP-05: Error handling ---"

test_profsp05a_no_action() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof system-prompt 2>/dev/null
}
run_test "PROFSP-05a: 'system-prompt' without action exits non-zero" test_profsp05a_no_action

test_profsp05b_unknown_action() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof system-prompt badcmd 2>/dev/null
}
run_test "PROFSP-05b: unknown system-prompt action exits non-zero" test_profsp05b_unknown_action

test_profsp05c_set_empty_string() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! printf '\n' | CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" \
    profile testprof system-prompt set 2>/dev/null
}
run_test "PROFSP-05c: system-prompt set with empty value (via prompt) exits non-zero" test_profsp05c_set_empty_string

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
