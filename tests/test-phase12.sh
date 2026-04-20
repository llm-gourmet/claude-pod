#!/bin/bash
# test-phase12.sh -- Integration tests for Phase 12: Profile System
# Tests PROF-01 through PROF-03, superuser mode, list, clean break
#
# Strategy: Use temp directories for all config to avoid touching real ~/.claude-secure.
# Test bin/claude-secure functions by extracting/reimplementing the function signatures
# and testing them in isolation.
#
# Usage: bash tests/test-phase12.sh
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
  if "$@" 2>/dev/null; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Global temp directory for test isolation
TEST_TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "========================================"
echo "  Phase 12 Integration Tests"
echo "  Profile System"
echo "  (PROF-01 -- PROF-03)"
echo "========================================"
echo ""

# =========================================================================
# Helper: Source profile functions from bin/claude-secure
# We source the script with __CLAUDE_SECURE_SOURCE_ONLY=1 to skip execution
# and only load function definitions.
# =========================================================================

# Set up a minimal config environment so sourcing works
_setup_source_env() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/.claude-secure/profiles"
  cat > "$tmpdir/.claude-secure/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  export HOME="$tmpdir"
  export CONFIG_DIR="$tmpdir/.claude-secure"
}

# Source bin/claude-secure functions
_source_functions() {
  local tmpdir="$1"
  _setup_source_env "$tmpdir"
  export APP_DIR="$PROJECT_DIR"
  # shellcheck source=/dev/null
  __CLAUDE_SECURE_SOURCE_ONLY=1 source "$PROJECT_DIR/bin/claude-secure"
}

# Helper: Create a valid test profile directory
create_test_profile() {
  local name="$1"
  local config_dir="$2"
  local ws_path="${3:-$TEST_TMPDIR/workspace-$name}"
  local repo="${4:-}"

  mkdir -p "$config_dir/profiles/$name"
  mkdir -p "$ws_path"

  # Build profile.json (new schema: workspace + secrets[])
  jq -n --arg ws "$ws_path" '{"workspace": $ws, "secrets": []}' \
    > "$config_dir/profiles/$name/profile.json"

  # Create .env
  echo "ANTHROPIC_API_KEY=test-key-$name" > "$config_dir/profiles/$name/.env"
  chmod 600 "$config_dir/profiles/$name/.env"
}

# =========================================================================
# PROF-01a: After create_profile, profile dir contains profile.json and .env
# =========================================================================
test_prof_01a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"

  local pdir="$tmpdir/.claude-secure/profiles/myproj"
  [ -f "$pdir/profile.json" ] || return 1
  [ -f "$pdir/.env" ] || return 1
  [ ! -f "$pdir/whitelist.json" ] || { echo "whitelist.json should not exist in new schema" >&2; return 1; }
  return 0
}
run_test "PROF-01a: Profile directory contains profile.json and .env (no whitelist.json)" test_prof_01a

# =========================================================================
# PROF-01b: profile.json is valid JSON with required workspace field
# =========================================================================
test_prof_01b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"

  local pdir="$tmpdir/.claude-secure/profiles/myproj"
  # Valid JSON
  jq empty "$pdir/profile.json" || return 1
  # Has workspace field
  local ws
  ws=$(jq -r '.workspace // empty' "$pdir/profile.json")
  [ -n "$ws" ] || return 1
  return 0
}
run_test "PROF-01b: profile.json is valid JSON with workspace field" test_prof_01b

# =========================================================================
# PROF-01c: validate_profile_name accepts/rejects correctly
# =========================================================================
test_prof_01c_valid() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Valid names
  validate_profile_name "my-proj" || return 1
  validate_profile_name "proj1" || return 1
  validate_profile_name "a" || return 1
  validate_profile_name "1abc" || return 1
  return 0
}
run_test "PROF-01c: validate_profile_name accepts valid names" test_prof_01c_valid

test_prof_01c_invalid() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Invalid names -- each must return non-zero
  validate_profile_name "My_Proj" && return 1
  validate_profile_name "has spaces" && return 1
  # 64+ chars
  local longname
  longname=$(printf 'a%.0s' {1..64})
  validate_profile_name "$longname" && return 1
  return 0
}
run_test "PROF-01c: validate_profile_name rejects invalid names" test_prof_01c_invalid

# =========================================================================
# PROF-02a: create_profile writes workspace and empty secrets[] to profile.json
# =========================================================================
test_prof_02a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Stdin sequence: workspace default, auth=OAuth, token
  printf '\n1\noauth-token-xyz\n' | create_profile "myproj-d" >/dev/null 2>&1

  local pdir="$CONFIG_DIR/profiles/myproj-d"
  [ -f "$pdir/profile.json" ] || return 1
  local ws
  ws=$(jq -r '.workspace // empty' "$pdir/profile.json")
  [ -n "$ws" ] || return 1
  jq -e '.secrets | type == "array"' "$pdir/profile.json" >/dev/null || return 1
  [ -f "$pdir/.env" ] || return 1
  return 0
}
run_test "PROF-02a: create_profile writes workspace and secrets[] to profile.json" test_prof_02a

# =========================================================================
# PROF-02b: profile.json secrets[] schema is valid
# =========================================================================
test_prof_02b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"

  local pdir="$tmpdir/.claude-secure/profiles/myproj"
  jq -e '.secrets | type == "array"' "$pdir/profile.json" >/dev/null || return 1
  return 0
}
run_test "PROF-02b: profile.json has secrets[] array" test_prof_02b

# =========================================================================
# PROF-03a: validate_profile with missing profile directory -> exit 1
# =========================================================================
test_prof_03a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local output
  output=$(validate_profile "nonexistent" 2>&1) && return 1
  echo "$output" | grep -qi "ERROR" || return 1
  return 0
}
run_test "PROF-03a: validate_profile fails on missing profile directory" test_prof_03a

# =========================================================================
# PROF-03b: validate_profile with missing profile.json -> exit 1
# =========================================================================
test_prof_03b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Create profile dir but no profile.json
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03b: validate_profile fails on missing profile.json" test_prof_03b

# =========================================================================
# PROF-03c: validate_profile with invalid JSON in profile.json -> exit 1
# =========================================================================
test_prof_03c() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo "not json" > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03c: validate_profile fails on invalid JSON in profile.json" test_prof_03c

# =========================================================================
# PROF-03d: validate_profile with missing workspace field -> exit 1
# =========================================================================
test_prof_03d() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo '{}' > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03d: validate_profile fails on missing workspace field" test_prof_03d

# =========================================================================
# PROF-03e: validate_profile with nonexistent workspace path -> exit 1
# =========================================================================
test_prof_03e() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "/nonexistent/path/$$" '{"workspace":$ws}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03e: validate_profile fails on nonexistent workspace path" test_prof_03e

# =========================================================================
# PROF-03f: validate_profile with missing .env -> exit 1
# =========================================================================
test_prof_03f() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local ws="$tmpdir/ws-badprof"
  mkdir -p "$ws"
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "$ws" '{"workspace":$ws}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  # No .env file

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03f: validate_profile fails on missing .env" test_prof_03f

# =========================================================================
# PROF-03g: validate_profile with malformed secrets[] entry -> exit 1
# =========================================================================
test_prof_03g() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local ws="$tmpdir/ws-badprof"
  mkdir -p "$ws"
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "$ws" '{"workspace":$ws,"secrets":[{"env_var":"FOO"}]}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03g: validate_profile fails on secrets[] entry missing redacted/domains" test_prof_03g

# =========================================================================
# SUPER-01: Merged profile secrets contains entries from multiple profiles
# =========================================================================
test_super_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  # Create two profiles with different secrets
  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Give them distinct secrets entries in profile.json
  jq -n --arg ws "$tmpdir/ws-a" \
    '{"workspace":$ws,"secrets":[{"env_var":"GITHUB_TOKEN","redacted":"REDACTED_GH","domains":["github.com"]}]}' \
    > "$tmpdir/.claude-secure/profiles/proj-a/profile.json"
  jq -n --arg ws "$tmpdir/ws-b" \
    '{"workspace":$ws,"secrets":[{"env_var":"STRIPE_KEY","redacted":"REDACTED_STRIPE","domains":["stripe.com"]}]}' \
    > "$tmpdir/.claude-secure/profiles/proj-b/profile.json"

  _source_functions "$tmpdir"

  local merged
  merged=$(merge_profiles)

  # Should contain both secrets
  echo "$merged" | jq -e '.secrets | length == 2' >/dev/null || return 1
  echo "$merged" | jq -e '.secrets[] | select(.env_var == "GITHUB_TOKEN")' >/dev/null || return 1
  echo "$merged" | jq -e '.secrets[] | select(.env_var == "STRIPE_KEY")' >/dev/null || return 1
  return 0
}
run_test "SUPER-01: Merged profile secrets contains entries from multiple profiles" test_super_01

# =========================================================================
# SUPER-02: Merged .env contains keys from multiple profiles
# =========================================================================
test_super_02() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Give them distinct env content
  echo "GITHUB_TOKEN=gh_test_a" > "$tmpdir/.claude-secure/profiles/proj-a/.env"
  echo "STRIPE_KEY=sk_test_b" > "$tmpdir/.claude-secure/profiles/proj-b/.env"

  _source_functions "$tmpdir"

  local merged_path
  merged_path=$(merge_env_files)

  # Merged file should contain both keys
  grep -q "GITHUB_TOKEN=gh_test_a" "$merged_path" || return 1
  grep -q "STRIPE_KEY=sk_test_b" "$merged_path" || return 1

  rm -f "$merged_path"
  return 0
}
run_test "SUPER-02: Merged .env contains keys from multiple profiles" test_super_02

# =========================================================================
# SUPER-03: merge_profiles deduplicates by env_var
# =========================================================================
test_super_03() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Both profiles have GITHUB_TOKEN with different redacted values
  jq -n --arg ws "$tmpdir/ws-a" \
    '{"workspace":$ws,"secrets":[{"env_var":"GITHUB_TOKEN","redacted":"REDACTED_A","domains":["github.com"]}]}' \
    > "$tmpdir/.claude-secure/profiles/proj-a/profile.json"
  jq -n --arg ws "$tmpdir/ws-b" \
    '{"workspace":$ws,"secrets":[{"env_var":"GITHUB_TOKEN","redacted":"REDACTED_B","domains":["api.github.com"]}]}' \
    > "$tmpdir/.claude-secure/profiles/proj-b/profile.json"

  _source_functions "$tmpdir"

  local merged
  merged=$(merge_profiles)

  # Should deduplicate: only 1 GITHUB_TOKEN entry
  local count
  count=$(echo "$merged" | jq '[.secrets[] | select(.env_var == "GITHUB_TOKEN")] | length')
  [ "$count" -eq 1 ] || return 1
  return 0
}
run_test "SUPER-03: merge_profiles deduplicates by env_var" test_super_03

# =========================================================================
# LIST-01: list command output contains column headers
# =========================================================================
test_list_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"
  _source_functions "$tmpdir"

  local output
  output=$(list_profiles 2>&1)

  echo "$output" | grep -q "PROFILE" || return 1
  echo "$output" | grep -q "KEYS" || return 1
  echo "$output" | grep -q "WORKSPACE" || return 1
  echo "$output" | grep -q "STATUS" || return 1
  return 0
}
run_test "LIST-01: list command shows PROFILE, KEYS, STATUS, WORKSPACE columns" test_list_01

# =========================================================================
# NOINSTANCE-01: --instance flag produces error
# =========================================================================
test_noinstance_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  local output
  output=$(HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" --instance test 2>&1) && return 1
  echo "$output" | grep -qi "no longer supported\|ERROR\|unknown" || return 1
  return 0
}
run_test "NOINSTANCE-01: --instance flag produces error" test_noinstance_01

# =========================================================================
# STAT-01: status (no name) shows claude-*/cs-* containers only
# =========================================================================
test_stat_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  # Minimal config so load_superuser_config does not prompt for workspace
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$tmpdir/ws"
EOF
  mkdir -p "$tmpdir/ws"

  # Fake docker: intercepts "docker ps", passes everything else through
  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'DOCKER'
#!/bin/bash
if [ "$1" = "ps" ]; then
  printf "NAMES\tIMAGE\tCOMMAND\tCREATED AT\tSTATUS\tPORTS\n"
  printf "claude-myprofile-claude-1\tclaude-myprofile-claude\t\"cmd\"\t2026-01-01 00:00:00 +0000 UTC\tUp 5 minutes\t\n"
  printf "some-unrelated-container-1\tnginx\t\"cmd\"\t2026-01-01 00:00:00 +0000 UTC\tUp 1 hour\t\n"
  printf "cs-myprofile-abc12345-claude-1\tclaude-cs-claude\t\"cmd\"\t2026-01-01 00:00:00 +0000 UTC\tUp 3 minutes\t\n"
else
  command docker "$@"
fi
DOCKER
  chmod +x "$fake_bin/docker"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$fake_bin:$PATH" \
    bash "$PROJECT_DIR/bin/claude-secure" status 2>/dev/null)

  # claude-* and cs-* rows must appear
  echo "$output" | grep -q "claude-myprofile-claude-1" || return 1
  echo "$output" | grep -q "cs-myprofile-abc12345-claude-1" || return 1
  # Unrelated container must NOT appear
  echo "$output" | grep -q "some-unrelated-container-1" && return 1

  return 0
}
run_test "STAT-01: status (no name) filters to claude-*/cs-* containers" test_stat_01

# =========================================================================
# STOP-01: stop (no name) calls docker compose down for every profile
# =========================================================================
test_stop_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles"

  create_test_profile "alpha" "$cfg" "$tmpdir/ws-alpha"
  create_test_profile "beta"  "$cfg" "$tmpdir/ws-beta"

  local fake_bin="$tmpdir/bin"
  local down_log="$tmpdir/down.log"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<DOCKER
#!/bin/bash
if [ "\${1:-}" = "compose" ] && [ "\${2:-}" = "down" ]; then
  echo "\${COMPOSE_PROJECT_NAME:-<unset>}" >> "$down_log"
fi
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  DEFAULT_WORKSPACE="$tmpdir/ws-super" \
  HOME="$tmpdir" \
  CONFIG_DIR="$cfg" \
  PATH="$fake_bin:$PATH" \
    bash "$PROJECT_DIR/bin/claude-secure" stop 2>/dev/null

  grep -q "^claude-alpha$" "$down_log" || return 1
  grep -q "^claude-beta$"  "$down_log" || return 1
  return 0
}
run_test "STOP-01: stop (no name) calls docker compose down for each profile" test_stop_01

# =========================================================================
# STOP-02: stop <name> only stops that profile (regression)
# =========================================================================
test_stop_02() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles"

  create_test_profile "alpha" "$cfg" "$tmpdir/ws-alpha"
  create_test_profile "beta"  "$cfg" "$tmpdir/ws-beta"

  local fake_bin="$tmpdir/bin"
  local down_log="$tmpdir/down.log"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<DOCKER
#!/bin/bash
if [ "\${1:-}" = "compose" ] && [ "\${2:-}" = "down" ]; then
  echo "\${COMPOSE_PROJECT_NAME:-<unset>}" >> "$down_log"
fi
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  HOME="$tmpdir" \
  CONFIG_DIR="$cfg" \
  PATH="$fake_bin:$PATH" \
    bash "$PROJECT_DIR/bin/claude-secure" stop alpha 2>/dev/null

  # Only alpha must be stopped
  grep -q "^claude-alpha$" "$down_log" || return 1
  grep -q "^claude-beta$"  "$down_log" && return 1
  return 0
}
run_test "STOP-02: stop <name> only stops profile X, not others" test_stop_02

# =========================================================================
# SESS-01: interactive session auto-stops container after Claude exits
# =========================================================================
test_sess_01() {
  # Static check: docker compose down must follow docker compose exec in source.
  local src="$PROJECT_DIR/bin/claude-secure"
  local exec_line down_line
  exec_line=$(grep -n "docker compose exec -it claude claude" "$src" | head -1 | cut -d: -f1)
  down_line=$(grep -n "docker compose down" "$src" \
    | awk -F: -v after="$exec_line" '$1 > after {print $1; exit}')
  [ -n "$exec_line" ] || return 1
  [ -n "$down_line" ] || return 1
  # The down must be within a few lines of the exec (same *)  block)
  local gap=$(( down_line - exec_line ))
  [ "$gap" -gt 0 ] && [ "$gap" -le 5 ] || return 1
  return 0
}
run_test "SESS-01: docker compose down follows exec in interactive session block" test_sess_01

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL total)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
