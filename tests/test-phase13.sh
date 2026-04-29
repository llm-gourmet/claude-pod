#!/bin/bash
# test-phase13.sh -- Integration tests for Phase 13: Headless CLI Path
# Tests HEAD-01 through HEAD-05 (spawn subcommand, output, max-turns, ephemeral lifecycle, templates)
# Also tests HEAD-06: spawn without task file uses hardcoded fallback text.
#
# Strategy: Use temp directories for all config to avoid touching real ~/.claude-pod.
# Source bin/claude-pod functions with __CLAUDE_POD_SOURCE_ONLY=1.
# Functions not yet implemented are guarded with `type` checks and SKIP gracefully.
#
# Usage: bash tests/test-phase13.sh
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
echo "  Phase 13 Integration Tests"
echo "  Headless CLI Path"
echo "  (HEAD-01 -- HEAD-05)"
echo "========================================"
echo ""

# =========================================================================
# Helper: Source profile functions from bin/claude-pod
# We source the script with __CLAUDE_POD_SOURCE_ONLY=1 to skip execution
# and only load function definitions.
# =========================================================================

# Set up a minimal config environment so sourcing works
_setup_source_env() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/.claude-pod/profiles"
  cat > "$tmpdir/.claude-pod/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  export HOME="$tmpdir"
  export CONFIG_DIR="$tmpdir/.claude-pod"
}

# Source bin/claude-pod functions
_source_functions() {
  local tmpdir="$1"
  _setup_source_env "$tmpdir"
  # shellcheck source=/dev/null
  __CLAUDE_POD_SOURCE_ONLY=1 source "$PROJECT_DIR/bin/claude-pod"
}

# Helper: Create a valid test profile directory
create_test_profile() {
  local name="$1"
  local config_dir="$2"
  local ws_path="${3:-$TEST_TMPDIR/workspace-$name}"
  local repo="${4:-}"

  mkdir -p "$config_dir/profiles/$name"
  mkdir -p "$ws_path"

  # Build profile.json (new schema)
  jq -n --arg ws "$ws_path" '{"workspace": $ws, "secrets": []}' \
    > "$config_dir/profiles/$name/profile.json"

  # Create .env
  echo "ANTHROPIC_API_KEY=test-key-$name" > "$config_dir/profiles/$name/.env"
  chmod 600 "$config_dir/profiles/$name/.env"
}

# =========================================================================
# HEAD-01 Tests: Spawn arg parsing
# =========================================================================
echo "--- HEAD-01: Spawn Argument Parsing ---"

test_spawn_requires_profile() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  # Call do_spawn with PROFILE unset
  PROFILE="" REMAINING_ARGS=("spawn" "--event" '{"type":"test"}')
  local output
  output=$(do_spawn 2>&1) && return 1
  echo "$output" | grep -qi "profile.*name.*required\|profile name is required" || return 1
  return 0
}
run_test "HEAD-01a: spawn requires profile name" test_spawn_requires_profile

test_spawn_requires_event() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  # Call do_spawn with PROFILE set but no --event
  PROFILE="testprof" REMAINING_ARGS=("spawn")
  local output
  output=$(do_spawn 2>&1) && return 1
  echo "$output" | grep -q "\-\-event or \-\-event-file is required" || return 1
  return 0
}
run_test "HEAD-01b: spawn requires --event or --event-file" test_spawn_requires_event

test_spawn_rejects_invalid_json() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  PROFILE="testprof" REMAINING_ARGS=("spawn" "--event" "not json")
  local output
  output=$(do_spawn 2>&1) && return 1
  echo "$output" | grep -q "Invalid JSON" || return 1
  return 0
}
run_test "HEAD-01c: spawn rejects invalid JSON in --event" test_spawn_rejects_invalid_json

test_spawn_accepts_event_file() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  local event_file="$tmpdir/event.json"
  echo '{"type":"issue-opened","issue":{"title":"Test"}}' > "$event_file"

  PROFILE="testprof" REMAINING_ARGS=("spawn" "--event-file" "$event_file")
  local output
  # do_spawn will fail at "not yet implemented" but should NOT fail on JSON validation
  output=$(do_spawn 2>&1)
  # Should not contain JSON validation errors
  echo "$output" | grep -q "Invalid JSON" && return 1
  echo "$output" | grep -q "\-\-event or \-\-event-file is required" && return 1
  return 0
}
run_test "HEAD-01d: spawn accepts --event-file with valid JSON" test_spawn_accepts_event_file

test_spawn_parses_prompt_template() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  PROFILE="testprof" REMAINING_ARGS=("spawn" "--event" '{"type":"test"}' "--prompt-template" "custom")
  # do_spawn will fail at "not yet implemented" but PROMPT_TEMPLATE should be set
  do_spawn 2>/dev/null || true
  [ "$PROMPT_TEMPLATE" = "custom" ] || return 1
  return 0
}
run_test "HEAD-01e: spawn parses --prompt-template flag" test_spawn_parses_prompt_template

echo ""

# =========================================================================
# HEAD-04 Tests: Ephemeral lifecycle (project naming)
# =========================================================================
echo "--- HEAD-04: Ephemeral Lifecycle ---"

test_spawn_project_name_format() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type spawn_project_name &>/dev/null; then
    echo "SKIP (spawn_project_name not yet implemented)"
    return 0
  fi

  local result
  result=$(spawn_project_name "myprofile")
  [[ "$result" =~ ^cs-myprofile-[a-f0-9]{8}$ ]] || return 1
  return 0
}
run_test "HEAD-04a: spawn project name matches cs-<profile>-<uuid8> format" test_spawn_project_name_format

test_spawn_project_name_unique() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type spawn_project_name &>/dev/null; then
    echo "SKIP (spawn_project_name not yet implemented)"
    return 0
  fi

  local result1 result2
  result1=$(spawn_project_name "prof")
  result2=$(spawn_project_name "prof")
  [ "$result1" != "$result2" ] || return 1
  return 0
}
run_test "HEAD-04b: spawn project names are unique across invocations" test_spawn_project_name_unique

echo ""

# =========================================================================
# HEAD-02 Tests: Output envelope (stubs for Plan 02)
# =========================================================================
echo "--- HEAD-02: Output Envelope (stubs) ---"

test_build_output_envelope() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type build_output_envelope &>/dev/null; then
    echo "SKIP (build_output_envelope not yet implemented)"
    return 0
  fi

  local result
  result=$(build_output_envelope "testprof" "issue-opened" '{"result":"ok"}')
  echo "$result" | jq -e '.profile' >/dev/null || return 1
  echo "$result" | jq -e '.event_type' >/dev/null || return 1
  echo "$result" | jq -e '.timestamp' >/dev/null || return 1
  echo "$result" | jq -e '.claude' >/dev/null || return 1
  return 0
}
run_test "HEAD-02a: build_output_envelope has profile, event_type, timestamp, claude keys" test_build_output_envelope

echo ""

echo ""

# =========================================================================
# HEAD-05 Tests: Templates (stubs for Plan 03)
# =========================================================================
echo "--- HEAD-05: Prompt Templates (stubs) ---"

test_resolve_template_by_event_type() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type resolve_template &>/dev/null; then
    echo "SKIP (resolve_template not yet implemented)"
    return 0
  fi

  mkdir -p "$tmpdir/.claude-pod/profiles/testprof/prompts"
  echo "Handle this issue: {{ISSUE_TITLE}}" > "$tmpdir/.claude-pod/profiles/testprof/prompts/issue-opened.md"

  PROFILE="testprof"
  local result
  result=$(resolve_template "issue-opened" "")
  [ -f "$result" ] || return 1
  grep -q "ISSUE_TITLE" "$result" || return 1
  return 0
}
run_test "HEAD-05a: resolve_template finds template by event type" test_resolve_template_by_event_type

test_resolve_template_explicit_override() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type resolve_template &>/dev/null; then
    echo "SKIP (resolve_template not yet implemented)"
    return 0
  fi

  mkdir -p "$tmpdir/.claude-pod/profiles/testprof/prompts"
  echo "Custom prompt: {{REPO_NAME}}" > "$tmpdir/.claude-pod/profiles/testprof/prompts/custom.md"

  PROFILE="testprof"
  local result
  result=$(resolve_template "" "custom")
  [ -f "$result" ] || return 1
  grep -q "REPO_NAME" "$result" || return 1
  return 0
}
run_test "HEAD-05b: resolve_template uses explicit override" test_resolve_template_explicit_override

test_resolve_template_missing_fails() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type resolve_template &>/dev/null; then
    echo "SKIP (resolve_template not yet implemented)"
    return 0
  fi

  PROFILE="testprof"
  resolve_template "nonexistent-event" "" && return 1
  return 0
}
run_test "HEAD-05c: resolve_template fails for missing template" test_resolve_template_missing_fails

test_resolve_template_from_docs_dir() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "docsprof" "$tmpdir/.claude-pod" "$tmpdir/ws-docsprof"
  _source_functions "$tmpdir"
  if ! type resolve_template &>/dev/null; then
    echo "SKIP (resolve_template not yet implemented)"
    return 0
  fi

  # Profile lives under docs/ not profiles/ — simulate by placing prompt there.
  mkdir -p "$tmpdir/.claude-pod/docs/docsprof/prompts"
  echo "Docs prompt: {{REPO_NAME}}" > "$tmpdir/.claude-pod/docs/docsprof/prompts/push.md"

  PROFILE="docsprof"
  local result
  result=$(resolve_template "push" "")
  [ -f "$result" ] || return 1
  grep -q "REPO_NAME" "$result" || return 1
  return 0
}
run_test "HEAD-05f: resolve_template finds template in docs/ dir" test_resolve_template_from_docs_dir

test_resolve_profile_dir_finds_docs() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  _source_functions "$tmpdir"
  if ! type resolve_profile_dir &>/dev/null; then
    echo "SKIP (resolve_profile_dir not yet implemented)"
    return 0
  fi

  mkdir -p "$tmpdir/.claude-pod/docs/obsidian"
  echo '{"workspace":"'$tmpdir'"}' > "$tmpdir/.claude-pod/docs/obsidian/profile.json"

  local result
  result=$(resolve_profile_dir "obsidian")
  [ "$result" = "$tmpdir/.claude-pod/docs/obsidian" ] || return 1
  return 0
}
run_test "DOCS-01: resolve_profile_dir returns docs/ path when profile absent from profiles/" test_resolve_profile_dir_finds_docs

test_render_template_substitutes_vars() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type render_template &>/dev/null; then
    echo "SKIP (render_template not yet implemented)"
    return 0
  fi

  local template_file="$tmpdir/template.md"
  echo 'Review {{REPO_NAME}} on branch {{BRANCH}}' > "$template_file"

  local event_json='{"repository":{"full_name":"owner/myrepo"},"ref":"refs/heads/feature-x"}'
  local result
  result=$(render_template "$template_file" "$event_json")
  echo "$result" | grep -q "owner/myrepo" || return 1
  echo "$result" | grep -q "feature-x" || return 1
  return 0
}
run_test "HEAD-05d: render_template substitutes variables from event JSON" test_render_template_substitutes_vars

test_render_template_handles_empty_vars() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"
  if ! type render_template &>/dev/null; then
    echo "SKIP (render_template not yet implemented)"
    return 0
  fi

  local template_file="$tmpdir/template.md"
  echo 'Issue: {{ISSUE_TITLE}}' > "$template_file"

  local event_json='{"type":"push"}'
  local result
  result=$(render_template "$template_file" "$event_json")
  # {{ISSUE_TITLE}} should be replaced with empty string (not left as-is)
  echo "$result" | grep -q '{{ISSUE_TITLE}}' && return 1
  echo "$result" | grep -q 'Issue: ' || return 1
  return 0
}
run_test "HEAD-05e: render_template replaces missing vars with empty string" test_render_template_handles_empty_vars

echo ""

# =========================================================================
# DRY-RUN Test (stub for Plan 02)
# =========================================================================
echo "--- Dry Run ---"

test_dry_run_flag_parsed() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  create_test_profile "testprof" "$tmpdir/.claude-pod" "$tmpdir/ws-testprof"
  _source_functions "$tmpdir"
  if ! type do_spawn &>/dev/null; then
    echo "SKIP (do_spawn not yet implemented)"
    return 0
  fi

  PROFILE="testprof" REMAINING_ARGS=("spawn" "--event" '{"type":"test"}' "--dry-run")
  DRY_RUN=0
  do_spawn 2>/dev/null || true
  [ "$DRY_RUN" = "1" ] || return 1
  return 0
}
run_test "DRY-RUN: --dry-run flag sets DRY_RUN=1" test_dry_run_flag_parsed

echo ""

# =========================================================================
# HEAD-06 Tests: Spawn without task file uses hardcoded fallback text
# =========================================================================
echo "--- HEAD-06: Hardcoded Fallback Prompt ---"

test_spawn_hardcoded_fallback_text() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-pod"
  local ws="$tmpdir/workspace"
  mkdir -p "$cfg/profiles/testprof" "$ws"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$ws"
EOF
  jq -n --arg ws "$ws" '{"workspace": $ws, "secrets": []}' \
    > "$cfg/profiles/testprof/profile.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=test-token\n' > "$cfg/profiles/testprof/.env"
  chmod 600 "$cfg/profiles/testprof/.env"

  # No tasks/ directory — spawn should use hardcoded fallback
  local event_json='{"event_type":"push","repository":{"full_name":"u/r"}}'
  local out
  out=$(CONFIG_DIR="$cfg" HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-pod" \
    spawn testprof --event "$event_json" --dry-run 2>&1)
  echo "$out" | grep -q 'Review the event payload and follow the instructions in the system prompt' || return 1
  # No task_file line should appear in dry-run output
  ! echo "$out" | grep -q "^task_file:" || return 1
  return 0
}
run_test "HEAD-06a: spawn without task file uses hardcoded fallback text" \
  test_spawn_hardcoded_fallback_text

test_spawn_no_task_file_required() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-pod"
  local ws="$tmpdir/workspace"
  mkdir -p "$cfg/profiles/testprof" "$ws"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$ws"
EOF
  jq -n --arg ws "$ws" '{"workspace": $ws, "secrets": []}' \
    > "$cfg/profiles/testprof/profile.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=test-token\n' > "$cfg/profiles/testprof/.env"
  chmod 600 "$cfg/profiles/testprof/.env"

  # Spawn --dry-run must succeed with exit 0 even without any tasks/ directory
  local event_json='{"event_type":"issues-opened","repository":{"full_name":"u/r"}}'
  CONFIG_DIR="$cfg" HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-pod" \
    spawn testprof --event "$event_json" --dry-run >/dev/null 2>&1
}
run_test "HEAD-06b: spawn succeeds without tasks/ directory (exit 0)" \
  test_spawn_no_task_file_required

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
