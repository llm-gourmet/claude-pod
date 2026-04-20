#!/bin/bash
# test-cli-commands.sh -- Tests for CLI commands not covered elsewhere
#
# Tests:
#   CLI-01: --profile flag rejected with helpful message
#   CLI-02: profile create <name> creates profile and exits without containers
#   CLI-03: profile create <name> no-ops if profile already exists
#   CLI-04: profile <name> (bare) shows info for existing profile
#   CLI-05: profile <name> (bare) exits non-zero for unknown profile
#   CLI-06: remove <name> stops containers and deletes profile config
#   CLI-07: logs <name> exits non-zero for unknown profile
#   CLI-08: help shows profile create in output
#
# Usage: bash tests/test-cli-commands.sh
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
cleanup() { rm -rf "$TEST_TMPDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: build a minimal CONFIG_DIR with one profile
# ---------------------------------------------------------------------------
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

echo "========================================"
echo "  CLI Command Tests"
echo "========================================"
echo ""

# =========================================================================
# CLI-01: --profile flag is rejected
# =========================================================================
echo "--- CLI-01: --profile flag rejected ---"

test_cli01_profile_flag_rejected() {
  local output
  output=$(bash "$CLI" --profile myapp 2>&1) && return 1
  echo "$output" | grep -qi "profile create" || return 1
  return 0
}
run_test "CLI-01a: --profile flag exits non-zero" test_cli01_profile_flag_rejected

test_cli01_profile_flag_hint() {
  local output
  output=$(bash "$CLI" --profile myapp 2>&1) || true
  echo "$output" | grep -qi "profile create myapp" || return 1
  return 0
}
run_test "CLI-01b: --profile flag hint includes the profile name" test_cli01_profile_flag_hint

echo ""

# =========================================================================
# CLI-02: profile create <name> creates profile and exits
# =========================================================================
echo "--- CLI-02: profile create ---"

test_cli02_creates_profile() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles" "$tmpdir/ws"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$tmpdir/ws"
EOF

  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'DOCKER'
#!/bin/bash
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  # Inputs: workspace path, auth method 2=API key, key, empty base URL
  printf '%s\n%s\n%s\n%s\n' "$tmpdir/ws" "2" "test-key-dummy" "" | \
    CONFIG_DIR="$cfg" HOME="$tmpdir" PATH="$fake_bin:$PATH" \
      bash "$CLI" profile create newprof >/dev/null 2>&1

  [ -f "$cfg/profiles/newprof/profile.json" ] || return 1
  [ -f "$cfg/profiles/newprof/.env" ] || return 1
}
run_test "CLI-02a: profile create writes profile.json and .env" test_cli02_creates_profile

test_cli02_no_containers() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local docker_log="$tmpdir/docker.log"
  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin" "$tmpdir/.claude-secure/profiles" "$tmpdir/ws"
  cat > "$tmpdir/.claude-secure/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$tmpdir/ws"
EOF
  cat > "$fake_bin/docker" <<DOCKER
#!/bin/bash
echo "\$*" >> "$docker_log"
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  printf '%s\n%s\n%s\n%s\n' "$tmpdir/ws" "2" "test-key-dummy" "" | \
    CONFIG_DIR="$tmpdir/.claude-secure" HOME="$tmpdir" PATH="$fake_bin:$PATH" \
      bash "$CLI" profile create newprof >/dev/null 2>&1

  if [ -f "$docker_log" ] && grep -q "compose up" "$docker_log"; then
    return 1
  fi
  return 0
}
run_test "CLI-02b: profile create does not invoke docker compose up" test_cli02_no_containers

test_cli02_hint_shown() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin" "$tmpdir/.claude-secure/profiles" "$tmpdir/ws"
  cat > "$tmpdir/.claude-secure/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$tmpdir/ws"
EOF
  cat > "$fake_bin/docker" <<'DOCKER'
#!/bin/bash
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  local output
  output=$(printf '%s\n%s\n%s\n%s\n' "$tmpdir/ws" "2" "test-key-dummy" "" | \
    CONFIG_DIR="$tmpdir/.claude-secure" HOME="$tmpdir" PATH="$fake_bin:$PATH" \
      bash "$CLI" profile create newprof 2>&1)

  echo "$output" | grep -q "start newprof" || return 1
}
run_test "CLI-02c: profile create hints to run start after creation" test_cli02_hint_shown

echo ""

# =========================================================================
# CLI-03: profile create no-ops if profile already exists
# =========================================================================
echo "--- CLI-03: profile create (existing) ---"

test_cli03_noop_existing() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local original_mtime
  original_mtime=$(stat -c %Y "$cfg/profiles/testprof/profile.json")

  local output
  output=$(_run_cli "$cfg" profile create testprof 2>&1)
  echo "$output" | grep -qi "already exists" || return 1

  # profile.json must not be modified
  local new_mtime
  new_mtime=$(stat -c %Y "$cfg/profiles/testprof/profile.json")
  [ "$original_mtime" = "$new_mtime" ] || return 1
}
run_test "CLI-03a: profile create on existing profile prints 'already exists' and exits 0" test_cli03_noop_existing

echo ""

# =========================================================================
# CLI-04: profile <name> (bare) shows info
# =========================================================================
echo "--- CLI-04: profile <name> bare info ---"

test_cli04_shows_workspace() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local ws="$tmpdir/workspace"
  local output
  output=$(_run_cli "$cfg" profile testprof 2>&1) || return 1
  echo "$output" | grep -q "workspace\|$ws" || return 1
}
run_test "CLI-04a: profile <name> shows workspace path" test_cli04_shows_workspace

test_cli04_shows_secret_count() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  # Add a secret entry to profile.json
  jq '.secrets += [{"env_var":"GITHUB_TOKEN","redacted":"REDACTED_GITHUB","domains":["github.com"]}]' \
    "$cfg/profiles/testprof/profile.json" > "$cfg/profiles/testprof/profile.json.tmp" \
    && mv "$cfg/profiles/testprof/profile.json.tmp" "$cfg/profiles/testprof/profile.json"
  local output
  output=$(_run_cli "$cfg" profile testprof 2>&1) || return 1
  echo "$output" | grep -qE "secret|1" || return 1
}
run_test "CLI-04b: profile <name> shows secret count" test_cli04_shows_secret_count

echo ""

# =========================================================================
# CLI-05: profile <name> (bare) exits non-zero for unknown profile
# =========================================================================
echo "--- CLI-05: profile <name> unknown ---"

test_cli05_unknown_profile() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  local output
  output=$(_run_cli "$cfg" profile doesnotexist 2>&1) && return 1
  echo "$output" | grep -qi "not found" || return 1
  echo "$output" | grep -qi "profile create doesnotexist" || return 1
  return 0
}
run_test "CLI-05a: profile <name> on unknown profile exits non-zero with hint" test_cli05_unknown_profile

echo ""

# =========================================================================
# CLI-06: remove <name> deletes profile config
# =========================================================================
echo "--- CLI-06: remove <name> ---"

test_cli06_remove_deletes_config() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")

  # Stub docker so compose down is a no-op
  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<'DOCKER'
#!/bin/bash
exit 0
DOCKER
  chmod +x "$fake_bin/docker"

  # remove prompts for confirmation — feed 'y'
  printf 'y\n' | CONFIG_DIR="$cfg" HOME="$tmpdir" PATH="$fake_bin:$PATH" \
    bash "$CLI" remove testprof >/dev/null 2>&1

  [ ! -d "$cfg/profiles/testprof" ] || return 1
}
run_test "CLI-06a: remove deletes profile directory" test_cli06_remove_deletes_config

test_cli06_remove_requires_name() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" remove 2>/dev/null && return 1
  return 0
}
run_test "CLI-06b: remove without name exits non-zero" test_cli06_remove_requires_name

echo ""

# =========================================================================
# CLI-07: logs <name> exits non-zero for unknown profile
# =========================================================================
echo "--- CLI-07: logs <name> ---"

test_cli07_logs_unknown_profile() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  _run_cli "$cfg" logs doesnotexist 2>/dev/null && return 1
  return 0
}
run_test "CLI-07a: logs on unknown profile exits non-zero" test_cli07_logs_unknown_profile

echo ""

# =========================================================================
# CLI-08: help output
# =========================================================================
echo "--- CLI-08: help ---"

test_cli08_help_shows_profile_create() {
  local output
  output=$(bash "$CLI" help 2>&1) || true
  echo "$output" | grep -q "profile create" || return 1
}
run_test "CLI-08a: help shows 'profile create'" test_cli08_help_shows_profile_create

test_cli08_help_no_profile_flag() {
  local output
  output=$(bash "$CLI" help 2>&1) || true
  echo "$output" | grep -qE "^\s+--profile" && return 1
  return 0
}
run_test "CLI-08b: help does not show removed --profile flag" test_cli08_help_no_profile_flag

test_cli08_help_shows_start() {
  local output
  output=$(bash "$CLI" help 2>&1) || true
  echo "$output" | grep -q "start" || return 1
}
run_test "CLI-08c: help shows start command" test_cli08_help_shows_start

echo ""

# =========================================================================
# Summary
# =========================================================================
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"
[ "$FAIL" -eq 0 ]
