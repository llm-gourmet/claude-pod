#!/bin/bash
# test-profile-secret.sh -- Unit tests for `claude-pod profile <name> secret` subcommands
#
# Tests:
#   PROFS-01: Static checks — functions present, profile in skip-superuser-load case
#   PROFS-02: secret add — writes value to .env and metadata to profile.json
#   PROFS-03: secret remove — removes from .env and profile.json
#   PROFS-04: secret list — formats output correctly
#   PROFS-05: Error handling — bad args, missing profile, invalid key names
#
# Usage: bash tests/test-profile-secret.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/claude-pod"

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

# ---------------------------------------------------------------------------
# Helper: build a minimal CONFIG_DIR with one profile named $2 (default: testprof)
# Returns the CONFIG_DIR path on stdout.
# ---------------------------------------------------------------------------
_make_cfg() {
  local tmpdir="$1"
  local profname="${2:-testprof}"

  local cfg="$tmpdir/.claude-pod"
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

# Run the CLI with CONFIG_DIR pointing at a temp config, no Docker needed.
# Usage: _run_cli <cfg> [args...]
_run_cli() {
  local cfg="$1"; shift
  CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" "$@"
}

# =========================================================================
# PROFS-01: Static checks
# =========================================================================
echo "========================================"
echo "  Profile Secret CLI Tests"
echo "========================================"
echo ""
echo "--- PROFS-01: Static checks ---"

run_test "PROFS-01a: profile_secret_add function defined in CLI" \
  grep -q "^profile_secret_add()" "$CLI"

run_test "PROFS-01b: profile_secret_remove function defined in CLI" \
  grep -q "^profile_secret_remove()" "$CLI"

run_test "PROFS-01c: profile_secret_list function defined in CLI" \
  grep -q "^profile_secret_list()" "$CLI"

run_test "PROFS-01d: 'profile' in skip-superuser-load case" \
  grep -qE '\bprofile\b' <(grep -A1 'list|help|--help' "$CLI" | head -5)

echo ""

# =========================================================================
# PROFS-02: secret add
# =========================================================================
echo "--- PROFS-02: secret add ---"

test_profs02a_writes_env() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN ghp_testvalue123 \
    --redacted REDACTED_GITHUB --domains github.com,api.github.com >/dev/null
  grep -q "^GITHUB_TOKEN=ghp_testvalue123$" "$cfg/profiles/testprof/.env"
}
run_test "PROFS-02a: secret add writes value to .env" test_profs02a_writes_env

test_profs02b_writes_profile_json() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN ghp_testvalue123 \
    --redacted REDACTED_GITHUB --domains github.com,api.github.com >/dev/null
  jq -e '.secrets[] | select(.env_var == "GITHUB_TOKEN")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFS-02b: secret add writes entry to profile.json secrets[]" test_profs02b_writes_profile_json

test_profs02c_redacted_field() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN ghp_x \
    --redacted MY_CUSTOM_REDACTED >/dev/null
  jq -e '.secrets[] | select(.env_var == "GITHUB_TOKEN" and .redacted == "MY_CUSTOM_REDACTED")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFS-02c: --redacted flag stored in profile.json" test_profs02c_redacted_field

test_profs02d_default_redacted() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add NPM_TOKEN somevalue >/dev/null
  jq -e '.secrets[] | select(.env_var == "NPM_TOKEN" and .redacted == "REDACTED_NPM_TOKEN")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFS-02d: --redacted defaults to REDACTED_<KEY>" test_profs02d_default_redacted

test_profs02e_domains_array() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GH_TOKEN val \
    --domains github.com,api.github.com,raw.githubusercontent.com >/dev/null
  local count
  count=$(jq '.secrets[] | select(.env_var == "GH_TOKEN") | .domains | length' \
    "$cfg/profiles/testprof/profile.json")
  [ "$count" -eq 3 ]
}
run_test "PROFS-02e: --domains stored as JSON array in profile.json" test_profs02e_domains_array

test_profs02f_empty_domains() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add API_KEY val >/dev/null
  jq -e '.secrets[] | select(.env_var == "API_KEY") | .domains == []' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFS-02f: domains defaults to empty array when --domains omitted" test_profs02f_empty_domains

test_profs02g_env_mode_600() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add SOME_KEY val >/dev/null
  local mode
  mode=$(stat -c '%a' "$cfg/profiles/testprof/.env")
  [ "$mode" = "600" ]
}
run_test "PROFS-02g: .env has mode 600 after secret add" test_profs02g_env_mode_600

test_profs02h_upsert_env() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN original_value >/dev/null
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN updated_value >/dev/null
  local lines
  lines=$(grep -c "^GITHUB_TOKEN=" "$cfg/profiles/testprof/.env")
  [ "$lines" -eq 1 ] && grep -q "^GITHUB_TOKEN=updated_value$" "$cfg/profiles/testprof/.env"
}
run_test "PROFS-02h: secret add replaces existing key in .env (no duplicates)" test_profs02h_upsert_env

test_profs02i_upsert_profile_json() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN val --redacted FIRST >/dev/null
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN val --redacted SECOND >/dev/null
  local count
  count=$(jq '[.secrets[] | select(.env_var == "GITHUB_TOKEN")] | length' \
    "$cfg/profiles/testprof/profile.json")
  [ "$count" -eq 1 ] && \
  jq -e '.secrets[] | select(.env_var == "GITHUB_TOKEN" and .redacted == "SECOND")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null
}
run_test "PROFS-02i: secret add upserts by env_var in profile.json (no duplicates)" test_profs02i_upsert_profile_json

test_profs02j_prompt_for_value() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  printf 'prompted_value\n' | \
    CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" \
      profile testprof secret add PROMPT_KEY >/dev/null 2>&1
  grep -q "^PROMPT_KEY=prompted_value$" "$cfg/profiles/testprof/.env"
}
run_test "PROFS-02j: secret add prompts for value when omitted" test_profs02j_prompt_for_value

echo ""

# =========================================================================
# PROFS-03: secret remove
# =========================================================================
echo "--- PROFS-03: secret remove ---"

_setup_with_secret() {
  local tmpdir="$1"
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN ghp_abc \
    --redacted REDACTED_GH --domains github.com >/dev/null
  echo "$cfg"
}

test_profs03a_removes_from_env() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_setup_with_secret "$tmpdir")
  _run_cli "$cfg" profile testprof secret remove GITHUB_TOKEN >/dev/null
  ! grep -q "^GITHUB_TOKEN=" "$cfg/profiles/testprof/.env"
}
run_test "PROFS-03a: secret remove deletes key from .env" test_profs03a_removes_from_env

test_profs03b_removes_from_profile_json() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_setup_with_secret "$tmpdir")
  _run_cli "$cfg" profile testprof secret remove GITHUB_TOKEN >/dev/null
  local count
  count=$(jq '[.secrets[] | select(.env_var == "GITHUB_TOKEN")] | length' \
    "$cfg/profiles/testprof/profile.json")
  [ "$count" -eq 0 ]
}
run_test "PROFS-03b: secret remove deletes entry from profile.json secrets[]" test_profs03b_removes_from_profile_json

test_profs03c_preserves_other_secrets() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN val1 >/dev/null
  _run_cli "$cfg" profile testprof secret add NPM_TOKEN val2 >/dev/null
  _run_cli "$cfg" profile testprof secret remove GITHUB_TOKEN >/dev/null
  jq -e '.secrets[] | select(.env_var == "NPM_TOKEN")' \
    "$cfg/profiles/testprof/profile.json" >/dev/null && \
  grep -q "^NPM_TOKEN=val2$" "$cfg/profiles/testprof/.env"
}
run_test "PROFS-03c: secret remove leaves other secrets intact" test_profs03c_preserves_other_secrets

test_profs03d_remove_nonexistent_exits_cleanly() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret remove DOES_NOT_EXIST >/dev/null
}
run_test "PROFS-03d: secret remove on nonexistent key exits 0" test_profs03d_remove_nonexistent_exits_cleanly

echo ""

# =========================================================================
# PROFS-04: secret list
# =========================================================================
echo "--- PROFS-04: secret list ---"

test_profs04a_empty_list() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local out
  out=$(_run_cli "$cfg" profile testprof secret list 2>/dev/null)
  echo "$out" | grep -q "No secrets configured."
}
run_test "PROFS-04a: secret list shows 'No secrets configured.' when empty" test_profs04a_empty_list

test_profs04b_shows_header() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add GITHUB_TOKEN val \
    --redacted REDACTED_GH --domains github.com >/dev/null
  local out
  out=$(_run_cli "$cfg" profile testprof secret list 2>/dev/null)
  echo "$out" | grep -q "ENV_VAR"
}
run_test "PROFS-04b: secret list prints ENV_VAR header when secrets exist" test_profs04b_shows_header

test_profs04c_shows_env_var() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add MY_SECRET val \
    --redacted REDACTED_MY --domains example.com >/dev/null
  local out
  out=$(_run_cli "$cfg" profile testprof secret list 2>/dev/null)
  echo "$out" | grep -q "MY_SECRET"
}
run_test "PROFS-04c: secret list shows the env_var name" test_profs04c_shows_env_var

test_profs04d_shows_redacted_and_domains() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" profile testprof secret add DB_TOKEN val \
    --redacted REDACTED_DB --domains db.example.com >/dev/null
  local out
  out=$(_run_cli "$cfg" profile testprof secret list 2>/dev/null)
  echo "$out" | grep -q "REDACTED_DB" && echo "$out" | grep -q "db.example.com"
}
run_test "PROFS-04d: secret list shows redacted token and domains" test_profs04d_shows_redacted_and_domains

echo ""

# =========================================================================
# PROFS-05: Error handling
# =========================================================================
echo "--- PROFS-05: Error handling ---"

test_profs05a_no_profile_name() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" profile 2>/dev/null
}
run_test "PROFS-05a: 'profile' without name exits non-zero" test_profs05a_no_profile_name

test_profs05b_nonexistent_profile() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local out
  out=$(CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" \
    profile does-not-exist secret list 2>&1) && return 1
  echo "$out" | grep -q "not found"
}
run_test "PROFS-05b: nonexistent profile exits non-zero with 'not found'" test_profs05b_nonexistent_profile

test_profs05c_add_no_key() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof secret add 2>/dev/null
}
run_test "PROFS-05c: secret add without KEY exits non-zero" test_profs05c_add_no_key

test_profs05d_invalid_key_lowercase() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local out
  out=$(_run_cli "$cfg" profile testprof secret add github_token val 2>&1) && return 1
  echo "$out" | grep -qi "uppercase"
}
run_test "PROFS-05d: lowercase key name rejected with helpful message" test_profs05d_invalid_key_lowercase

test_profs05e_remove_no_key() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof secret remove 2>/dev/null
}
run_test "PROFS-05e: secret remove without KEY exits non-zero" test_profs05e_remove_no_key

test_profs05f_unknown_action() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof secret badcmd 2>/dev/null
}
run_test "PROFS-05f: unknown secret action exits non-zero" test_profs05f_unknown_action

test_profs05g_invalid_profile_name() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" \
    profile "UPPER_CASE" secret list 2>/dev/null
}
run_test "PROFS-05g: invalid profile name (uppercase) rejected" test_profs05g_invalid_profile_name

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
