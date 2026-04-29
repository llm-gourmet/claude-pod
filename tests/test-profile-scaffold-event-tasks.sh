#!/bin/bash
# test-profile-scaffold-event-tasks.sh -- Tests for the profile scaffold:
# files produced by `profile create`, system_prompts/default.md content,
# spawn --dry-run on a fresh profile, and removal of system-prompt subcommand.
#
# Tests:
#   PSET-01: profile create does NOT produce a tasks/ directory
#   PSET-02: system_prompts/default.md contains the profile name in the host path
#   PSET-03: spawn --dry-run on a fresh profile uses hardcoded fallback text
#   PSET-04: profile <name> system-prompt set exits non-zero with unknown-subcommand error
set -uo pipefail

PASS=0; FAIL=0; TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/claude-pod"

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

# Drive `profile create <name>` non-interactively by supplying stdin:
#   line 1: workspace path
#   line 2: auth choice (1 = OAuth)
#   line 3: OAuth token value
_create_profile() {
  local cfg="$1" name="$2"
  local ws
  ws="$(dirname "$cfg")/workspace"
  mkdir -p "$ws"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$ws"
EOF
  printf '%s\n%s\n%s\n' "$ws" "1" "sk-ant-oat-test-token" \
    | CONFIG_DIR="$cfg" HOME="$(dirname "$cfg")" bash "$CLI" profile create "$name" 2>/dev/null
}

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

_run_cli() {
  local cfg="$1"; shift
  CONFIG_DIR="$cfg" HOME="$TEST_TMPDIR" bash "$CLI" "$@"
}

echo "========================================"
echo "  Profile Scaffold Event Tasks Tests"
echo "========================================"
echo ""

# =========================================================================
# PSET-01: profile create does NOT produce a tasks/ directory
# =========================================================================
echo "--- PSET-01: no tasks/ directory scaffolded ---"

test_pset01_no_tasks_directory() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-pod"
  mkdir -p "$cfg/profiles"
  _create_profile "$cfg" newprof || true

  local pdir="$cfg/profiles/newprof"
  # tasks/ must NOT be created
  [ ! -d "$pdir/tasks" ]                        || return 1
  # system_prompts/default.md must still be created
  [ -f "$pdir/system_prompts/default.md" ]      || return 1
}
run_test "PSET-01: profile create does not produce tasks/ directory" test_pset01_no_tasks_directory

echo ""

# =========================================================================
# PSET-02: system_prompts/default.md contains the profile name in the host path
# =========================================================================
echo "--- PSET-02: system_prompts/default.md has profile name in host path ---"

test_pset02_system_prompt_contains_name() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-pod"
  mkdir -p "$cfg/profiles"
  _create_profile "$cfg" myprofile || true

  grep -q 'myprofile' "$cfg/profiles/myprofile/system_prompts/default.md"
}
run_test "PSET-02: system_prompts/default.md contains profile name in host path" \
  test_pset02_system_prompt_contains_name

echo ""

# =========================================================================
# PSET-03: spawn --dry-run on a fresh profile uses hardcoded fallback text
# =========================================================================
echo "--- PSET-03: spawn --dry-run uses hardcoded fallback text ---"

test_pset03_spawn_dry_run_hardcoded() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg="$tmpdir/.claude-pod"
  mkdir -p "$cfg/profiles"
  _create_profile "$cfg" freshprof || true

  local event_json
  event_json=$(jq -nc '{event_type: "push", repository: {full_name: "u/r"}}')
  local out
  out=$(CONFIG_DIR="$cfg" HOME="$tmpdir" bash "$CLI" spawn freshprof \
    --event "$event_json" --dry-run 2>&1)
  echo "$out" | grep -q 'Review the event payload and follow the instructions in the system prompt'
}
run_test "PSET-03: spawn --dry-run on fresh profile uses hardcoded fallback text" \
  test_pset03_spawn_dry_run_hardcoded

echo ""

# =========================================================================
# PSET-04: profile <name> system-prompt set exits non-zero
# =========================================================================
echo "--- PSET-04: system-prompt set exits non-zero ---"

test_pset04_system_prompt_set_exits_nonzero() {
  local tmpdir; tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg; cfg=$(_make_cfg "$tmpdir")
  ! _run_cli "$cfg" profile testprof system-prompt set "hello" 2>/dev/null
}
run_test "PSET-04: profile <name> system-prompt set exits non-zero (unknown subcommand)" \
  test_pset04_system_prompt_set_exits_nonzero

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
