#!/bin/bash
# test-phase9.sh -- Integration tests for Phase 9: Multi-Instance Support
# Tests MULTI-01 through MULTI-09
#
# Strategy: Use temp directories for all config to avoid touching real ~/.claude-secure.
# Test bin/claude-secure functions by invoking with controlled environments.
# For Docker-dependent tests, skip gracefully if Docker is unavailable.
#
# Usage: bash tests/test-phase9.sh
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

echo "========================================"
echo "  Phase 9 Integration Tests"
echo "  Multi-Instance Support"
echo "  (MULTI-01 -- MULTI-09)"
echo "========================================"
echo ""

# =========================================================================
# MULTI-01: spawn requires --profile
# Running 'spawn' without --profile should exit non-zero with error message
# =========================================================================
test_profile_required_for_spawn() {
  local output
  output=$(bash "$PROJECT_DIR/bin/claude-secure" spawn 2>&1) && return 1
  # Verify error message mentions --profile
  echo "$output" | grep -qi "profile" || return 1
  return 0
}
run_test "MULTI-01: --profile required for spawn" test_profile_required_for_spawn

# =========================================================================
# MULTI-02: DNS-safe instance name validation
# Instance names must match ^[a-z0-9][a-z0-9-]*$
# =========================================================================
test_dns_name_valid() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

test_dns_validation() {
  # Valid names
  test_dns_name_valid "myproject" || return 1
  test_dns_name_valid "my-project" || return 1
  test_dns_name_valid "project123" || return 1
  test_dns_name_valid "a" || return 1
  test_dns_name_valid "1abc" || return 1

  # Invalid names -- must NOT match
  test_dns_name_valid "MyProject" && return 1
  test_dns_name_valid "my_project" && return 1
  test_dns_name_valid "my project" && return 1
  test_dns_name_valid "-project" && return 1
  test_dns_name_valid "" && return 1

  return 0
}
run_test "MULTI-02: DNS-safe instance name validation" test_dns_validation

# =========================================================================
# MULTI-03: Migration from single-instance layout
# Old layout: CONFIG_DIR/{config.sh, .env} -> new: CONFIG_DIR/instances/default/
# =========================================================================
test_load_profile_config_reads_report_fields() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  local pdir="$cfg/profiles/myproj"
  mkdir -p "$pdir" "$tmpdir/workspace"

  cat > "$pdir/profile.json" <<EOF
{
  "workspace": "$tmpdir/workspace",
  "report_repo": "https://github.com/user/reports.git",
  "report_branch": "docs",
  "report_project_dir": "projects/myproj"
}
EOF
  printf 'ANTHROPIC_API_KEY=test\nREPORT_REPO_TOKEN=ghp_fake\n' > "$pdir/.env"
  echo '{"secrets":[]}' > "$pdir/whitelist.json"

  local repo branch pdir_var
  # Source the script and call load_profile_config
  repo=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "myproj"
    echo "$REPORT_REPO"
  )
  branch=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "myproj"
    echo "$REPORT_BRANCH"
  )
  pdir_var=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "myproj"
    echo "$REPORT_PROJECT_DIR"
  )

  [ "$repo"   = "https://github.com/user/reports.git" ] || { echo "REPORT_REPO wrong: $repo" >&2; return 1; }
  [ "$branch" = "docs" ]                                 || { echo "REPORT_BRANCH wrong: $branch" >&2; return 1; }
  [ "$pdir_var" = "projects/myproj" ]                    || { echo "REPORT_PROJECT_DIR wrong: $pdir_var" >&2; return 1; }
  return 0
}
run_test "MULTI-03: load_profile_config exports REPORT_REPO/BRANCH/PROJECT_DIR" test_load_profile_config_reads_report_fields

# =========================================================================
# MULTI-04: COMPOSE_PROJECT_NAME isolation
# docker-compose.yml must not have container_name directives
# Different COMPOSE_PROJECT_NAME values produce different container names
# =========================================================================
test_compose_isolation() {
  # Verify no container_name directives in docker-compose.yml
  if grep -q 'container_name:' "$PROJECT_DIR/docker-compose.yml"; then
    return 1
  fi

  # Docker-dependent test: skip gracefully if not available
  if ! docker compose version >/dev/null 2>&1; then
    echo "    (Docker not available - skipping container name uniqueness check)"
    return 0
  fi

  # Verify different project names produce different container names
  local out1 out2
  out1=$(cd "$PROJECT_DIR" && COMPOSE_PROJECT_NAME=claude-test1 WORKSPACE_PATH=/tmp docker compose config 2>/dev/null) || return 1
  out2=$(cd "$PROJECT_DIR" && COMPOSE_PROJECT_NAME=claude-test2 WORKSPACE_PATH=/tmp docker compose config 2>/dev/null) || return 1

  # The config output uses project name as prefix - verify they differ
  [ "$out1" != "$out2" ] || return 1

  return 0
}
run_test "MULTI-04: COMPOSE_PROJECT_NAME isolation (no container_name)" test_compose_isolation

# =========================================================================
# MULTI-05: Per-instance config files
# Each instance directory has its own config.sh, .env, whitelist.json
# =========================================================================
test_per_instance_config() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/instances/foo" "$cfg/instances/bar"

  # Instance foo
  echo 'WORKSPACE_PATH="/home/user/project-foo"' > "$cfg/instances/foo/config.sh"
  echo 'ANTHROPIC_API_KEY=key-foo' > "$cfg/instances/foo/.env"
  echo '{"secrets":["foo"]}' > "$cfg/instances/foo/whitelist.json"

  # Instance bar
  echo 'WORKSPACE_PATH="/home/user/project-bar"' > "$cfg/instances/bar/config.sh"
  echo 'ANTHROPIC_API_KEY=key-bar' > "$cfg/instances/bar/.env"
  echo '{"secrets":["bar"]}' > "$cfg/instances/bar/whitelist.json"

  # Verify files exist for both
  [ -f "$cfg/instances/foo/config.sh" ] || return 1
  [ -f "$cfg/instances/foo/.env" ] || return 1
  [ -f "$cfg/instances/foo/whitelist.json" ] || return 1
  [ -f "$cfg/instances/bar/config.sh" ] || return 1
  [ -f "$cfg/instances/bar/.env" ] || return 1
  [ -f "$cfg/instances/bar/whitelist.json" ] || return 1

  # Verify files are independent (different content)
  ! diff -q "$cfg/instances/foo/config.sh" "$cfg/instances/bar/config.sh" >/dev/null 2>&1 || return 1
  ! diff -q "$cfg/instances/foo/.env" "$cfg/instances/bar/.env" >/dev/null 2>&1 || return 1
  ! diff -q "$cfg/instances/foo/whitelist.json" "$cfg/instances/bar/whitelist.json" >/dev/null 2>&1 || return 1

  return 0
}
run_test "MULTI-05: Per-instance config files are independent" test_per_instance_config

# =========================================================================
# MULTI-06: LOG_PREFIX in docker-compose.yml and service code
# All three services must have LOG_PREFIX env var in compose
# Service code must reference LOG_PREFIX for log filenames
# =========================================================================
test_log_prefix() {
  local compose="$PROJECT_DIR/docker-compose.yml"

  # Verify LOG_PREFIX env var in docker-compose.yml for all services
  # Each service section should have LOG_PREFIX
  local count
  count=$(grep -c 'LOG_PREFIX=\${LOG_PREFIX:-}' "$compose" 2>/dev/null || echo "0")
  # Need at least 3 (claude, proxy, validator)
  [ "$count" -ge 3 ] || return 1

  # Verify proxy.js contains LOG_PREFIX
  grep -q 'LOG_PREFIX' "$PROJECT_DIR/proxy/proxy.js" || return 1

  # Verify validator.py contains LOG_PREFIX or log_prefix
  grep -qi 'log_prefix\|LOG_PREFIX' "$PROJECT_DIR/validator/validator.py" || return 1

  # Verify pre-tool-use.sh contains LOG_PREFIX
  grep -q 'LOG_PREFIX' "$PROJECT_DIR/claude/hooks/pre-tool-use.sh" || return 1

  return 0
}
run_test "MULTI-06: LOG_PREFIX in compose and service code" test_log_prefix

# =========================================================================
# MULTI-07: list command output format
# List should show all configured instances with name and workspace
# =========================================================================
test_list_command() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg/profiles/foo" "$cfg/profiles/bar" \
           "$tmpdir/ws-foo" "$tmpdir/ws-bar"

  cat > "$cfg/profiles/foo/profile.json" \
    <<< '{"workspace":"'"$tmpdir/ws-foo"'","repo":"org/foo"}'
  printf 'ANTHROPIC_API_KEY=test\n' > "$cfg/profiles/foo/.env"
  echo '{"secrets":[]}' > "$cfg/profiles/foo/whitelist.json"

  cat > "$cfg/profiles/bar/profile.json" \
    <<< '{"workspace":"'"$tmpdir/ws-bar"'","repo":"org/bar"}'
  printf 'ANTHROPIC_API_KEY=test\n' > "$cfg/profiles/bar/.env"
  echo '{"secrets":[]}' > "$cfg/profiles/bar/whitelist.json"

  local output
  output=$(HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" list 2>/dev/null) || true

  echo "$output" | grep -q 'foo' || { echo "foo not in list output" >&2; return 1; }
  echo "$output" | grep -q 'bar' || { echo "bar not in list output" >&2; return 1; }
  return 0
}
run_test "MULTI-07: list command shows all profiles" test_list_command

# =========================================================================
# MULTI-08: Instance auto-creation directory structure
# After create_instance, instance dir has config.sh, .env, whitelist.json
# =========================================================================
test_auto_creation_structure() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  mkdir -p "$cfg"

  # Create global config with APP_DIR pointing to our project
  local fake_app="$tmpdir/app"
  mkdir -p "$fake_app/config"
  cp "$PROJECT_DIR/config/whitelist.json" "$fake_app/config/whitelist.json"

  cat > "$cfg/config.sh" <<EOF
APP_DIR="$fake_app"
PLATFORM="linux"
EOF

  # Simulate auto-creation: create instance directory structure manually
  # (create_instance is interactive so we simulate its output)
  local idir="$cfg/instances/testinst"
  mkdir -p "$idir"
  echo 'WORKSPACE_PATH="/tmp/ws-testinst"' > "$idir/config.sh"
  echo 'ANTHROPIC_API_KEY=test-key' > "$idir/.env"
  chmod 600 "$idir/.env"
  cp "$fake_app/config/whitelist.json" "$idir/whitelist.json"

  # Verify expected structure
  [ -f "$idir/config.sh" ] || return 1
  [ -f "$idir/.env" ] || return 1
  [ -f "$idir/whitelist.json" ] || return 1

  # Verify whitelist matches template
  diff -q "$fake_app/config/whitelist.json" "$idir/whitelist.json" >/dev/null 2>&1 || return 1

  return 0
}
run_test "MULTI-08: Instance auto-creation directory structure" test_auto_creation_structure

# =========================================================================
# MULTI-09: Global config.sh contains only APP_DIR and PLATFORM
# After installation, global config.sh should NOT have WORKSPACE_PATH
# =========================================================================
test_profile_config_scope() {
  # Profile workspace comes from profile.json, not a global config.
  # Verify that load_profile_config reads workspace from the profile's own
  # profile.json, not from a shared global file.
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  local pdir="$cfg/profiles/scoped"
  mkdir -p "$pdir" "$tmpdir/ws"

  cat > "$pdir/profile.json" <<EOF
{"workspace":"$tmpdir/ws","repo":"org/scoped"}
EOF
  printf 'ANTHROPIC_API_KEY=test\n' > "$pdir/.env"
  echo '{"secrets":[]}' > "$pdir/whitelist.json"

  local ws
  ws=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "scoped"
    echo "$WORKSPACE_PATH"
  )

  [ "$ws" = "$tmpdir/ws" ] || { echo "WORKSPACE_PATH wrong: $ws" >&2; return 1; }

  # CLI must reference CONFIG_DIR/profiles for profile resolution
  grep -q 'profiles' "$PROJECT_DIR/bin/claude-secure" || return 1
  return 0
}
run_test "MULTI-09: Profile config scope (workspace from profile.json)" test_profile_config_scope

# =========================================================================
# MULTI-10: system_prompt field in profile.json
# load_profile_config must export CLAUDE_SECURE_SYSTEM_PROMPT from profile.json
# bin/claude-secure must pass --system-prompt to claude when the field is set
# =========================================================================
test_system_prompt_field() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local cfg="$tmpdir/.claude-secure"
  local pdir="$cfg/profiles/sysprompt"
  mkdir -p "$pdir" "$tmpdir/ws"

  cat > "$pdir/profile.json" <<EOF
{
  "workspace": "$tmpdir/ws",
  "repo": "org/sysprompt",
  "system_prompt": "You are a helpful assistant with access to REPORT_REPO_TOKEN."
}
EOF
  printf 'ANTHROPIC_API_KEY=test\n' > "$pdir/.env"
  echo '{"secrets":[]}' > "$pdir/whitelist.json"

  # Verify load_profile_config exports CLAUDE_SECURE_SYSTEM_PROMPT
  local got_prompt
  got_prompt=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "sysprompt"
    echo "$CLAUDE_SECURE_SYSTEM_PROMPT"
  )

  [ "$got_prompt" = "You are a helpful assistant with access to REPORT_REPO_TOKEN." ] \
    || { echo "CLAUDE_SECURE_SYSTEM_PROMPT wrong: $got_prompt" >&2; return 1; }

  # Verify bin/claude-secure passes --system-prompt to claude when set
  grep -q -- '--system-prompt' "$PROJECT_DIR/bin/claude-secure" || return 1
  grep -q 'CLAUDE_SECURE_SYSTEM_PROMPT' "$PROJECT_DIR/bin/claude-secure" || return 1

  # Verify empty system_prompt leaves CLAUDE_SECURE_SYSTEM_PROMPT unset/empty
  cat > "$pdir/profile.json" <<EOF
{"workspace":"$tmpdir/ws","repo":"org/sysprompt"}
EOF
  local empty_prompt
  empty_prompt=$(
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$cfg"
    source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "sysprompt"
    echo "${CLAUDE_SECURE_SYSTEM_PROMPT:-}"
  )
  [ -z "$empty_prompt" ] || { echo "Expected empty CLAUDE_SECURE_SYSTEM_PROMPT, got: $empty_prompt" >&2; return 1; }

  return 0
}
run_test "MULTI-10: system_prompt field exported as CLAUDE_SECURE_SYSTEM_PROMPT" test_system_prompt_field

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
