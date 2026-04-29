#!/bin/bash
# test-list-instances.sh — Unit tests for `claude-pod list` running-instance view
# Issue #72: claude-pod list zeigt laufende Instanzen (interaktiv + headless)
#
# Tests:
#   LIST-01  list with no running containers prints "No running instances."
#   LIST-02  headless container with labels appears in list output
#   LIST-03  interactive container appears with type=interactive, empty event fields
#   LIST-04  running time is calculated correctly from started-at label
#   LIST-05  `list --profile` shows profiles, not instances
#   LIST-06  container without claude-pod.profile label does not appear in list
#
# Strategy: fake `docker` binary that returns controlled output for
# `docker ps` and `docker inspect` calls. All real docker calls are stubbed.
#
# Usage: bash tests/test-list-instances.sh
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
cleanup() { rm -rf "$TEST_TMPDIR"; }
trap cleanup EXIT

echo "========================================"
echo "  List Instances Tests (Issue #72)"
echo "  LIST-01 through LIST-06"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Helper: build a minimal CONFIG_DIR
# ---------------------------------------------------------------------------
_make_cfg() {
  local tmpdir="$1"
  local cfg="$tmpdir/.claude-pod"
  local ws="$tmpdir/workspace"
  mkdir -p "$cfg/profiles/testprof" "$ws"
  cat > "$cfg/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
DEFAULT_WORKSPACE="$ws"
EOF
  jq -n '{"workspace": "/workspace", "secrets": []}' \
    > "$cfg/profiles/testprof/profile.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=test-token\n' > "$cfg/profiles/testprof/.env"
  chmod 600 "$cfg/profiles/testprof/.env"
  echo "$cfg"
}

# ---------------------------------------------------------------------------
# Helper: write a fake docker binary that stubs ps + inspect.
#
# $1 = bin_dir  — directory where the fake `docker` script is placed
# $2 = ps_output — lines to emit for `docker ps --filter label=claude-pod.profile`
#                  (empty string = no containers)
# $3 = inspect_json — JSON to emit for `docker inspect`
# ---------------------------------------------------------------------------
_make_fake_docker() {
  local bin_dir="$1"
  local ps_output="$2"
  # Note: DO NOT use "${3:-{}}" — bash appends a literal "}" when $3 is set
  # because the closing "}" of "{}" is parsed as the expansion terminator first.
  # Use a helper variable for the default to avoid the brace-depth parsing trap.
  local _empty_obj="{}"
  local inspect_json="${3:-$_empty_obj}"
  mkdir -p "$bin_dir"

  # Write ps_output to a file so the heredoc in the fake docker can cat it.
  printf '%s' "$ps_output" > "$bin_dir/.ps_output"
  printf '%s' "$inspect_json" > "$bin_dir/.inspect_json"

  cat > "$bin_dir/docker" <<'DOCKER_EOF'
#!/bin/bash
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Intercept the specific docker calls used by list_instances.
# Pass everything else to the real docker (or swallow it).
if [ "${1:-}" = "ps" ]; then
  # list_instances calls: docker ps --filter label=claude-pod.profile --format {{.ID}}
  cat "$BIN_DIR/.ps_output"
  exit 0
fi
if [ "${1:-}" = "inspect" ]; then
  # list_instances calls: docker inspect <id> --format {{json .Config.Labels}}
  cat "$BIN_DIR/.inspect_json"
  exit 0
fi
if [ "${1:-}" = "compose" ]; then
  # Absorb docker compose calls (ls used by list_profiles status check)
  echo "[]"
  exit 0
fi
exit 0
DOCKER_EOF
  chmod +x "$bin_dir/docker"
}

# =========================================================================
# LIST-01: no running containers → "No running instances."
# =========================================================================
echo "--- LIST-01: no running containers ---"

test_list_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")
  local bin="$tmpdir/bin"

  # ps returns nothing (no containers with the label)
  _make_fake_docker "$bin" "" "{}"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$bin:$PATH" \
    bash "$CLI" list 2>/dev/null)

  printf '%s\n' "$output" | grep -q "No running instances." || return 1
  return 0
}
run_test "LIST-01: no running containers prints 'No running instances.'" test_list_01

echo ""

# =========================================================================
# LIST-02: headless container with labels appears in list output
# =========================================================================
echo "--- LIST-02: headless container in list ---"

test_list_02() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")
  local bin="$tmpdir/bin"

  # Fake container ID
  local cid="abc1234def56"
  # docker ps returns the container ID
  _make_fake_docker "$bin" "$cid" "$(jq -n \
    --arg p "my-project" \
    --arg t "headless" \
    --arg et "push" \
    --arg ei "abc123f" \
    --arg sa "2025-06-01T14:32:00Z" \
    '{
      "claude-pod.profile": $p,
      "claude-pod.type": $t,
      "claude-pod.event-type": $et,
      "claude-pod.event-id": $ei,
      "claude-pod.started-at": $sa
    }')"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$bin:$PATH" \
    bash "$CLI" list 2>/dev/null)

  # Must show the profile and type columns
  printf '%s\n' "$output" | grep -q "my-project" || return 1
  printf '%s\n' "$output" | grep -q "headless" || return 1
  # Must show event info
  printf '%s\n' "$output" | grep -q "push" || return 1
  printf '%s\n' "$output" | grep -q "abc123f" || return 1
  # Must NOT show "No running instances."
  printf '%s\n' "$output" | grep -q "No running instances." && return 1
  return 0
}
run_test "LIST-02: headless container with labels appears in list" test_list_02

echo ""

# =========================================================================
# LIST-03: interactive container appears with type=interactive, empty event fields
# =========================================================================
echo "--- LIST-03: interactive container in list ---"

test_list_03() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")
  local bin="$tmpdir/bin"

  local cid="zzz999yyy888"
  _make_fake_docker "$bin" "$cid" "$(jq -n \
    --arg p "my-other" \
    --arg t "interactive" \
    --arg sa "2025-06-01T14:30:00Z" \
    '{
      "claude-pod.profile": $p,
      "claude-pod.type": $t,
      "claude-pod.event-type": "",
      "claude-pod.event-id": "",
      "claude-pod.started-at": $sa
    }')"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$bin:$PATH" \
    bash "$CLI" list 2>/dev/null)

  printf '%s\n' "$output" | grep -q "my-other" || return 1
  printf '%s\n' "$output" | grep -q "interactive" || return 1
  # Event fields must show em-dash for empty
  printf '%s\n' "$output" | grep -q "—" || return 1
  return 0
}
run_test "LIST-03: interactive container shows type=interactive and em-dash for empty event fields" test_list_03

echo ""

# =========================================================================
# LIST-04: running time is calculated from started-at label
# =========================================================================
echo "--- LIST-04: running time calculation ---"

test_list_04() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")

  # Source functions to test calculate_running_time directly
  export APP_DIR="$PROJECT_DIR"
  __CLAUDE_POD_SOURCE_ONLY=1 source "$PROJECT_DIR/bin/claude-pod" 2>/dev/null || true
  if ! command -v calculate_running_time >/dev/null 2>&1; then
    echo "calculate_running_time function not found" >&2
    return 1
  fi

  # Test sub-minute: set started-at to 30 seconds ago
  local ts30
  ts30=$(date -u -d "30 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0  # skip if date -d unsupported
  local result30
  result30=$(calculate_running_time "$ts30")
  # Should contain 's' (seconds)
  printf '%s\n' "$result30" | grep -qE '^[0-9]+s$' || return 1

  # Test minutes range: set started-at to 3m 30s ago
  local ts3m
  ts3m=$(date -u -d "210 seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  local result3m
  result3m=$(calculate_running_time "$ts3m")
  # Should contain 'm' (minutes)
  printf '%s\n' "$result3m" | grep -q "m" || return 1

  return 0
}
run_test "LIST-04: calculate_running_time returns correct duration format" test_list_04

echo ""

# =========================================================================
# LIST-05: `list --profile` shows profiles, not instances
# =========================================================================
echo "--- LIST-05: list --profile shows profiles ---"

test_list_05() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")
  local bin="$tmpdir/bin"

  # Even if docker ps would return something, --profile should call list_profiles
  _make_fake_docker "$bin" "" "{}"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$bin:$PATH" \
    bash "$CLI" list --profile 2>/dev/null)

  # list_profiles prints PROFILE, STATUS, KEYS headers
  printf '%s\n' "$output" | grep -q "PROFILE" || return 1
  printf '%s\n' "$output" | grep -q "KEYS" || return 1
  # Must NOT show the instances table headers
  printf '%s\n' "$output" | grep -q "RUNNING" && return 1
  return 0
}
run_test "LIST-05: list --profile shows profile table, not instance table" test_list_05

echo ""

# =========================================================================
# LIST-06: container without claude-pod.profile label does not appear
# =========================================================================
echo "--- LIST-06: unlabeled container excluded ---"

test_list_06() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  local cfg
  cfg=$(_make_cfg "$tmpdir")
  local bin="$tmpdir/bin"

  # `docker ps --filter label=claude-pod.profile` only returns containers
  # that HAVE the label — so returning empty string simulates a docker daemon
  # that has other running containers but none with our label.
  _make_fake_docker "$bin" "" "{}"

  local output
  output=$(HOME="$tmpdir" CONFIG_DIR="$cfg" PATH="$bin:$PATH" \
    bash "$CLI" list 2>/dev/null)

  # Must say no running instances (the unlabeled container is excluded by docker filter)
  printf '%s\n' "$output" | grep -q "No running instances." || return 1
  return 0
}
run_test "LIST-06: container without claude-pod.profile label excluded (via docker filter)" test_list_06

echo ""

# =========================================================================
# LIST-07: docker-compose.yml contains label definitions for claude service
# =========================================================================
echo "--- LIST-07: docker-compose.yml has label definitions ---"

test_list_07() {
  local compose="$PROJECT_DIR/docker-compose.yml"
  grep -q "claude-pod.profile" "$compose" || return 1
  grep -q "claude-pod.type" "$compose" || return 1
  grep -q "claude-pod.event-type" "$compose" || return 1
  grep -q "claude-pod.event-id" "$compose" || return 1
  grep -q "claude-pod.started-at" "$compose" || return 1
  grep -q "CLAUDE_POD_LABEL_PROFILE" "$compose" || return 1
  return 0
}
run_test "LIST-07: docker-compose.yml has claude-pod label definitions" test_list_07

echo ""

# =========================================================================
# LIST-08: bin/claude-pod exports CLAUDE_POD_LABEL_* in start command
# =========================================================================
echo "--- LIST-08: start command exports label env vars ---"

test_list_08() {
  local src="$PROJECT_DIR/bin/claude-pod"
  # start) block must export label vars before docker compose up
  grep -q "CLAUDE_POD_LABEL_PROFILE" "$src" || return 1
  grep -q "CLAUDE_POD_LABEL_TYPE" "$src" || return 1
  grep -q "CLAUDE_POD_LABEL_STARTED_AT" "$src" || return 1
  # do_spawn must also export them
  local spawn_labels
  spawn_labels=$(grep -c "CLAUDE_POD_LABEL_TYPE" "$src" 2>/dev/null || echo 0)
  [ "$spawn_labels" -ge 2 ] || return 1
  return 0
}
run_test "LIST-08: start and do_spawn both export CLAUDE_POD_LABEL_* env vars" test_list_08

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
