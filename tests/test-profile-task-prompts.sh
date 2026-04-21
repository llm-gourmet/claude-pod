#!/bin/bash
# test-profile-task-prompts.sh -- Unit tests for the profile-task-prompts
# change: file-based tasks/ + system_prompts/ resolution in the profile dir,
# plus the migrate-profile-prompts.sh script.
#
# Tests (one per 6.x task):
#   PTP-01: spawn with event-specific task file resolves correctly
#   PTP-02: spawn falls back to tasks/default.md when no event-specific file
#   PTP-03: spawn fails with clear error when no task file found
#   PTP-04: system prompt resolves from system_prompts/<event_type>.md
#   PTP-05: system prompt falls back to system_prompts/default.md
#   PTP-06: spawn proceeds without --system-prompt when no file found
#   PTP-07: --dry-run shows resolved task path and system prompt source
#   PTP-08: migration script moves system_prompt field to system_prompts/default.md
#   PTP-09: migration script is idempotent
#   PTP-10: --event-file appends payload block to prompt
#   PTP-11: empty EVENT_JSON produces no payload block (guard unit test)
#   PTP-12: --dry-run with event file shows payload block in stdout
set -uo pipefail

PASS=0; FAIL=0; TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/claude-secure"
MIGRATE="$PROJECT_DIR/scripts/migrate-profile-prompts.sh"

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

TEST_TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMPDIR"; }
trap cleanup EXIT

_make_profile() {
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

_spawn_dry_run() {
  local cfg="$1" profname="$2" event_type="$3"
  local event_json
  event_json=$(jq -nc --arg t "$event_type" '{event_type: $t, repository: {full_name: "u/r"}}')
  CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" \
    bash "$CLI" spawn "$profname" --event "$event_json" --dry-run 2>&1
}

echo "========================================"
echo "  Profile Task Prompts Tests"
echo "========================================"
echo ""

# -------------------------------------------------------------------------
# PTP-01: event-specific task file
# -------------------------------------------------------------------------
test_ptp01_event_specific_task() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks"
  printf 'PUSH TASK CONTENT\n' > "$pdir/tasks/push.md"
  printf 'DEFAULT TASK\n' > "$pdir/tasks/default.md"
  local out; out=$(_spawn_dry_run "$cfg" testprof push)
  echo "$out" | grep -q "task_file: $pdir/tasks/push.md" || return 1
  echo "$out" | grep -q 'PUSH TASK CONTENT' || return 1
}
run_test "PTP-01: event-specific task file resolves" test_ptp01_event_specific_task

# -------------------------------------------------------------------------
# PTP-02: fallback to tasks/default.md
# -------------------------------------------------------------------------
test_ptp02_default_task_fallback() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks"
  printf 'DEFAULT TASK CONTENT\n' > "$pdir/tasks/default.md"
  local out; out=$(_spawn_dry_run "$cfg" testprof issues-opened)
  echo "$out" | grep -q "task_file: $pdir/tasks/default.md" || return 1
  echo "$out" | grep -q 'DEFAULT TASK CONTENT' || return 1
}
run_test "PTP-02: falls back to tasks/default.md" test_ptp02_default_task_fallback

# -------------------------------------------------------------------------
# PTP-03: no task file -> clear error + nonzero exit
# -------------------------------------------------------------------------
test_ptp03_no_task_file_fails() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  local out rc
  out=$(_spawn_dry_run "$cfg" testprof push); rc=$?
  [ "$rc" -ne 0 ] || return 1
  echo "$out" | grep -q 'No task file found' || return 1
  echo "$out" | grep -q "Checked: $pdir/tasks/push.md" || return 1
  echo "$out" | grep -q "Checked: $pdir/tasks/default.md" || return 1
}
run_test "PTP-03: spawn fails with checked paths listed" test_ptp03_no_task_file_fails

# -------------------------------------------------------------------------
# PTP-04: system prompt event-specific file
# -------------------------------------------------------------------------
test_ptp04_system_prompt_event_specific() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks" "$pdir/system_prompts"
  printf 'task\n' > "$pdir/tasks/default.md"
  printf 'PUSH SYS PROMPT\n' > "$pdir/system_prompts/push.md"
  printf 'DEFAULT SYS PROMPT\n' > "$pdir/system_prompts/default.md"
  local out; out=$(_spawn_dry_run "$cfg" testprof push)
  echo "$out" | grep -q "system_prompt: $pdir/system_prompts/push.md" || return 1
}
run_test "PTP-04: system_prompts/<event_type>.md resolves" test_ptp04_system_prompt_event_specific

# -------------------------------------------------------------------------
# PTP-05: fallback to system_prompts/default.md
# -------------------------------------------------------------------------
test_ptp05_system_prompt_default_fallback() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks" "$pdir/system_prompts"
  printf 'task\n' > "$pdir/tasks/default.md"
  printf 'DEFAULT SYS PROMPT\n' > "$pdir/system_prompts/default.md"
  local out; out=$(_spawn_dry_run "$cfg" testprof release)
  echo "$out" | grep -q "system_prompt: $pdir/system_prompts/default.md" || return 1
}
run_test "PTP-05: falls back to system_prompts/default.md" test_ptp05_system_prompt_default_fallback

# -------------------------------------------------------------------------
# PTP-06: no system prompt file -> "none", spawn still succeeds (dry-run)
# -------------------------------------------------------------------------
test_ptp06_no_system_prompt() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks"
  printf 'task\n' > "$pdir/tasks/default.md"
  local out rc
  out=$(_spawn_dry_run "$cfg" testprof push); rc=$?
  [ "$rc" -eq 0 ] || return 1
  echo "$out" | grep -q 'system_prompt: none' || return 1
}
run_test "PTP-06: no system prompt -> 'none', spawn succeeds" test_ptp06_no_system_prompt

# -------------------------------------------------------------------------
# PTP-07: --dry-run shows both resolved paths
# -------------------------------------------------------------------------
test_ptp07_dry_run_prints_paths() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks" "$pdir/system_prompts"
  printf 'TASK\n' > "$pdir/tasks/default.md"
  printf 'SYS\n' > "$pdir/system_prompts/default.md"
  local out; out=$(_spawn_dry_run "$cfg" testprof anything)
  echo "$out" | grep -q "task_file: $pdir/tasks/default.md" || return 1
  echo "$out" | grep -q "system_prompt: $pdir/system_prompts/default.md" || return 1
  echo "$out" | grep -q '^TASK$' || return 1
}
run_test "PTP-07: --dry-run prints task path + system prompt path + content" \
  test_ptp07_dry_run_prints_paths

# -------------------------------------------------------------------------
# PTP-08: migration script: system_prompt field -> system_prompts/default.md
# -------------------------------------------------------------------------
test_ptp08_migration_moves_system_prompt() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$t/.claude-secure"
  mkdir -p "$cfg/profiles/p1"
  jq -n --arg ws "/tmp" --arg sp "Hello world." \
    '{workspace:$ws, secrets:[], system_prompt:$sp}' > "$cfg/profiles/p1/profile.json"

  CONFIG_DIR="$cfg" HOME="$t" bash "$MIGRATE" >/dev/null 2>&1 || return 1

  [ -f "$cfg/profiles/p1/system_prompts/default.md" ] || return 1
  grep -q 'Hello world.' "$cfg/profiles/p1/system_prompts/default.md" || return 1
  ! jq -e 'has("system_prompt")' "$cfg/profiles/p1/profile.json" >/dev/null || return 1
}
run_test "PTP-08: migration moves system_prompt to system_prompts/default.md" \
  test_ptp08_migration_moves_system_prompt

# -------------------------------------------------------------------------
# PTP-09: migration is idempotent (pre-existing default.md preserved; field
# stripped). Also migrates prompts/ -> tasks/ on second pass if re-seeded.
# -------------------------------------------------------------------------
test_ptp09_migration_idempotent() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$t/.claude-secure"
  mkdir -p "$cfg/profiles/p1/system_prompts"
  printf 'EXISTING\n' > "$cfg/profiles/p1/system_prompts/default.md"
  jq -n --arg ws "/tmp" --arg sp "new value" \
    '{workspace:$ws, secrets:[], system_prompt:$sp}' > "$cfg/profiles/p1/profile.json"

  # First run: strips field; does NOT overwrite existing default.md.
  CONFIG_DIR="$cfg" HOME="$t" bash "$MIGRATE" >/dev/null 2>&1 || return 1
  grep -q '^EXISTING$' "$cfg/profiles/p1/system_prompts/default.md" || return 1
  ! jq -e 'has("system_prompt")' "$cfg/profiles/p1/profile.json" >/dev/null || return 1

  # Second run: no-op, still exits 0.
  CONFIG_DIR="$cfg" HOME="$t" bash "$MIGRATE" >/dev/null 2>&1 || return 1
  grep -q '^EXISTING$' "$cfg/profiles/p1/system_prompts/default.md" || return 1

  # prompts/ -> tasks/ migration path.
  mkdir -p "$cfg/profiles/p1/prompts"
  printf 'PUSH\n' > "$cfg/profiles/p1/prompts/push.md"
  CONFIG_DIR="$cfg" HOME="$t" bash "$MIGRATE" >/dev/null 2>&1 || return 1
  [ ! -d "$cfg/profiles/p1/prompts" ] || return 1
  grep -q '^PUSH$' "$cfg/profiles/p1/tasks/push.md" || return 1
}
run_test "PTP-09: migration is idempotent" test_ptp09_migration_idempotent

# -------------------------------------------------------------------------
# PTP-10: --event-file produces prompt with payload block appended
# -------------------------------------------------------------------------
test_ptp10_event_file_appends_payload_block() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks"
  printf 'TASK CONTENT\n' > "$pdir/tasks/push.md"

  local event_file="$t/push-event.json"
  printf '{"event_type":"push","repository":{"full_name":"u/r"},"commits":[]}\n' > "$event_file"

  local out
  out=$(CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" \
    bash "$CLI" spawn testprof --event-file "$event_file" --dry-run 2>&1)

  echo "$out" | grep -q 'TASK CONTENT' || return 1
  echo "$out" | grep -qF -- '---' || return 1
  echo "$out" | grep -q 'Event Payload' || return 1
  echo "$out" | grep -qF '```json' || return 1
  echo "$out" | grep -q '"event_type"' || return 1
}
run_test "PTP-10: --event-file appends payload block to prompt" test_ptp10_event_file_appends_payload_block

# -------------------------------------------------------------------------
# PTP-11: no EVENT_JSON -> no payload block appended (unit test of guard)
# -------------------------------------------------------------------------
test_ptp11_no_event_no_payload_block() {
  local content="TASK CONTENT"
  local EVENT_JSON=""
  local event_type="unknown"
  local result="$content"
  if [ -n "${EVENT_JSON:-}" ]; then
    result+="

---
Event Payload (\`${event_type}\`):
\`\`\`json
${EVENT_JSON}
\`\`\`"
  fi
  ! echo "$result" | grep -q 'Event Payload'
}
run_test "PTP-11: empty EVENT_JSON produces no payload block" test_ptp11_no_event_no_payload_block

# -------------------------------------------------------------------------
# PTP-12: --dry-run with event file shows payload block in stdout
# -------------------------------------------------------------------------
test_ptp12_dry_run_shows_payload_block() {
  local t; t=$(mktemp -d -p "$TEST_TMPDIR"); local cfg; cfg=$(_make_profile "$t")
  local pdir="$cfg/profiles/testprof"
  mkdir -p "$pdir/tasks"
  printf 'DRY RUN TASK\n' > "$pdir/tasks/push.md"

  local event_file="$t/event.json"
  printf '{"event_type":"push","repository":{"full_name":"u/r"},"ref":"refs/heads/main"}\n' > "$event_file"

  local out
  out=$(CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" \
    bash "$CLI" spawn testprof --event-file "$event_file" --dry-run 2>&1)

  echo "$out" | grep -q 'DRY RUN TASK' || return 1
  echo "$out" | grep -q 'Event Payload (`push`)' || return 1
  echo "$out" | grep -q '"event_type"' || return 1
}
run_test "PTP-12: --dry-run with event file shows payload block in stdout" test_ptp12_dry_run_shows_payload_block

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL total)"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
