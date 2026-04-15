#!/bin/bash
# test-update-cmd.sh -- Unit tests for `claude-secure update` and `upgrade` subcommands
#
# Regression tests for the two bugs fixed in fix-update-cmd:
#   UPD-01: update/upgrade skip load_superuser_config (no merge_env_files →
#           no "Permission denied" on root-owned .env files)
#   UPD-02: update uses `sudo git -C` so it works when APP_DIR is root-owned
#
# Strategy:
#   - UPD-01a/b: static grep of source to verify both invariants are present
#   - UPD-02/03: behaviour tests — run `bin/claude-secure update` against a
#     synthetic CONFIG_DIR with an unreadable .env and mock git/docker binaries;
#     assert exit 0 and no "Permission denied" in output
#
# Usage: bash tests/test-update-cmd.sh
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
  # Restore any 000-permission files so rm -rf can delete them
  find "$TEST_TMPDIR" -perm 000 -exec chmod 600 {} \; 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "========================================"
echo "  Update / Upgrade Subcommand Tests"
echo "  (UPD-01 -- UPD-03)"
echo "========================================"
echo ""

# =========================================================================
# Helpers
# =========================================================================

# Build a minimal CONFIG_DIR + config.sh + one profile.
# If mode=unreadable, chmod 000 the profile .env after creation.
_make_config_dir() {
  local tmpdir="$1"
  local mode="${2:-readable}"     # readable | unreadable

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles/default" "$cfg/logs"

  # config.sh – tells the CLI where APP_DIR is
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$tmpdir/workspace"
EOF

  mkdir -p "$tmpdir/workspace"

  # Minimal profile
  jq -n --arg ws "$tmpdir/workspace" '{"workspace":$ws}' \
    > "$cfg/profiles/default/profile.json"
  cp "$PROJECT_DIR/config/whitelist.json" "$cfg/profiles/default/whitelist.json"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "$cfg/profiles/default/.env"

  if [ "$mode" = "unreadable" ]; then
    chmod 000 "$cfg/profiles/default/.env"
  fi

  echo "$cfg"
}

# Populate $tmpdir/bin with stub git and docker that succeed silently.
_make_mock_bin() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/bin"
  printf '#!/bin/sh\nexit 0\n' > "$tmpdir/bin/git"
  printf '#!/bin/sh\nexit 0\n' > "$tmpdir/bin/docker"
  printf '#!/bin/sh\nexit 0\n' > "$tmpdir/bin/sudo"
  chmod +x "$tmpdir/bin/git" "$tmpdir/bin/docker" "$tmpdir/bin/sudo"
}

# =========================================================================
# UPD-01a: Static – update AND upgrade are in the skip-superuser-load case
# =========================================================================
echo "--- UPD-01: superuser load is skipped for update/upgrade ---"

test_upd01a_update_in_skip_case() {
  # The case pattern must include both 'update' and 'upgrade' before the *) arm
  # that calls load_superuser_config.  A single grep over the source is
  # authoritative because the behaviour test below can only catch regression
  # when an unreadable .env is present.
  grep -qE 'update\|upgrade\)' "$CLI" || \
  grep -qE '\bupdate\b.*\bupgrade\b' "$CLI"
}
run_test "UPD-01a: 'update' and 'upgrade' appear in skip-superuser-load case" \
  test_upd01a_update_in_skip_case

test_upd01b_update_before_load_call() {
  # Ensure the skip case comes before the load_superuser_config call in file order
  local skip_line load_line
  skip_line=$(grep -n 'update|upgrade' "$CLI" | grep -v '^\s*#' | head -1 | cut -d: -f1)
  load_line=$(grep -n 'load_superuser_config$' "$CLI" | grep -v '^\s*#' | head -1 | cut -d: -f1)
  [ -n "$skip_line" ] && [ -n "$load_line" ] && [ "$skip_line" -lt "$load_line" ]
}
run_test "UPD-01b: skip case appears before load_superuser_config call" \
  test_upd01b_update_before_load_call

echo ""

# =========================================================================
# UPD-02: Static – update command uses `sudo git -C` not bare `git pull`
# =========================================================================
echo "--- UPD-02: update uses sudo git -C for git pull ---"

test_upd02a_uses_sudo_git() {
  grep -q 'sudo git -C' "$CLI"
}
run_test "UPD-02a: update body contains 'sudo git -C'" test_upd02a_uses_sudo_git

test_upd02b_no_bare_cd_git_pull() {
  # The old pattern 'cd "$APP_DIR" && git pull' must no longer exist
  ! grep -q 'cd.*APP_DIR.*&&.*git pull' "$CLI"
}
run_test "UPD-02b: old 'cd \$APP_DIR && git pull' pattern is gone" \
  test_upd02b_no_bare_cd_git_pull

echo ""

# =========================================================================
# UPD-03: Behaviour – update exits 0 even with an unreadable .env
# =========================================================================
echo "--- UPD-03: update succeeds with unreadable profile .env ---"

test_upd03_unreadable_env_no_permission_denied() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _make_mock_bin "$tmpdir"
  _make_config_dir "$tmpdir" "unreadable" > /dev/null

  local output
  output=$(
    HOME="$tmpdir" \
    CONFIG_DIR="$tmpdir/.claude-secure" \
    PATH="$tmpdir/bin:$PATH" \
    bash "$CLI" update 2>&1
  )
  local rc=$?

  # Must not print "Permission denied"
  if echo "$output" | grep -q "Permission denied"; then
    echo "  output contained 'Permission denied': $output" >&2
    return 1
  fi
  # Must exit 0
  [ $rc -eq 0 ]
}
run_test "UPD-03a: update exits 0 with 000-permission .env" \
  test_upd03_unreadable_env_no_permission_denied

test_upd03_no_default_workspace_prompt() {
  # update must not prompt for DEFAULT_WORKSPACE even when it is absent from
  # config.sh (i.e. load_superuser_config is fully bypassed).
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _make_mock_bin "$tmpdir"

  local cfg
  cfg=$(mktemp -d -p "$TEST_TMPDIR")
  mkdir -p "$cfg/profiles/default" "$cfg/logs"
  # config.sh without DEFAULT_WORKSPACE – triggers the read -rp prompt if
  # load_superuser_config is accidentally invoked
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  jq -n '{"workspace":"/tmp"}' > "$cfg/profiles/default/profile.json"
  cp "$PROJECT_DIR/config/whitelist.json" "$cfg/profiles/default/whitelist.json"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "$cfg/profiles/default/.env"

  local output
  output=$(
    HOME="$tmpdir" \
    CONFIG_DIR="$cfg" \
    PATH="$tmpdir/bin:$PATH" \
    bash "$CLI" update </dev/null 2>&1
  )
  local rc=$?

  # If load_superuser_config ran it would print the workspace prompt
  if echo "$output" | grep -q "Default workspace for superuser mode"; then
    echo "  output contained superuser prompt — load_superuser_config was called" >&2
    return 1
  fi
  [ $rc -eq 0 ]
}
run_test "UPD-03b: update never prints 'Default workspace for superuser mode' prompt" \
  test_upd03_no_default_workspace_prompt

echo ""

# =========================================================================
# UPD-04: Behaviour – upgrade also skips superuser load
# =========================================================================
echo "--- UPD-04: upgrade also skips superuser load ---"

test_upd04_upgrade_no_prompt() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _make_mock_bin "$tmpdir"
  # Add a mock claude binary so 'docker compose build --no-cache --pull claude'
  # succeeds via the stub docker
  local cfg
  cfg=$(mktemp -d -p "$TEST_TMPDIR")
  mkdir -p "$cfg/profiles/default" "$cfg/logs"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  jq -n '{"workspace":"/tmp"}' > "$cfg/profiles/default/profile.json"
  cp "$PROJECT_DIR/config/whitelist.json" "$cfg/profiles/default/whitelist.json"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "$cfg/profiles/default/.env"
  chmod 000 "$cfg/profiles/default/.env"

  local output
  output=$(
    HOME="$tmpdir" \
    CONFIG_DIR="$cfg" \
    PATH="$tmpdir/bin:$PATH" \
    bash "$CLI" upgrade </dev/null 2>&1
  )
  local rc=$?

  if echo "$output" | grep -q "Default workspace for superuser mode"; then
    echo "  upgrade triggered superuser prompt" >&2
    return 1
  fi
  if echo "$output" | grep -q "Permission denied"; then
    echo "  upgrade hit Permission denied on .env" >&2
    return 1
  fi
  [ $rc -eq 0 ]
}
run_test "UPD-04: upgrade skips superuser load (no prompt, no permission error)" \
  test_upd04_upgrade_no_prompt

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
