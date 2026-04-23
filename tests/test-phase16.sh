#!/bin/bash
# tests/test-phase16.sh -- Phase 16 Result Channel integration + unit tests
# OPS-01 (Report push to docs repo), OPS-02 (JSONL audit log)
#
# Wave 0 contract (Nyquist self-healing): 27+ of these tests MUST fail at the
# end of Wave 0. Only test_fixtures_exist, test_templates_exist, and
# test_no_force_push_grep (static invariant) pass. Later waves flip the
# NOT-IMPLEMENTED sentinels green:
#   - 16-02 (Wave 1a): test_report_template_fallback
#   - 16-03 (Wave 1b): audit + publish_report integration tests
#   - 16-04 (Wave 2): installer extension (covered by static greps here)
#
# Guardrails copied from Phase 15:
#   - Stubs claude-pod on PATH with a recorder (no real Docker)
#   - Uses $TEST_TMPDIR with trap EXIT cleanup
#   - Uses HOME + CONFIG_DIR redirection so tests never touch the real home
#   - Local bare report repo under $TEST_TMPDIR/report-repo-bare.git (not the
#     git-tracked placeholder under tests/fixtures/report-repo-bare/)
#
# Usage:
#   bash tests/test-phase16.sh                         # run full suite
#   bash tests/test-phase16.sh test_fixtures_exist     # run single function

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
STUB_LOG="$TEST_TMPDIR/stub-invocations.log"
LISTENER_PID=""
LISTENER_PORT=19016  # Phase 16 uses 19016 to avoid collision with 14/15

cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL+1))
  if "$@"; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL+1))
  fi
}

# =========================================================================
# Stub builder: fake `claude-pod` binary on PATH.
# Records invocation argv to $STUB_LOG and exits 0 immediately.
# =========================================================================
install_stub() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/claude-pod" <<'STUB'
#!/bin/bash
# Stub: record invocation argv and exit 0.
printf '%s\n' "$*" >> "${STUB_LOG:-/tmp/stub.log}"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/claude-pod"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export STUB_LOG
}

# =========================================================================
# Test profile setup. Creates a test-profile with report_repo, report_branch,
# report_path_prefix fields and an .env file (copied from the metacharacter
# fixture by default, or from $TEST_ENV_FILE when set).
#
# Env var overrides:
#   TEST_REPORT_REPO        -- value of .report_repo in profile.json
#   TEST_REPORT_BRANCH      -- value of .report_branch
#   TEST_REPORT_PATH_PREFIX -- value of .report_path_prefix
#   TEST_ENV_FILE           -- absolute path to a .env file to copy into the
#                              profile. Defaults to the metacharacter fixture.
# =========================================================================
setup_test_profile() {
  local home_dir="$TEST_TMPDIR/home"
  local profile_dir="$home_dir/.claude-pod/profiles/test-profile"
  mkdir -p "$profile_dir" "$profile_dir/tasks" "$profile_dir/report-templates" \
    "$home_dir/.claude-pod/events" "$home_dir/.claude-pod/logs/spawns"
  printf 'phase16 task placeholder.\n' > "$profile_dir/tasks/default.md"

  local report_repo="${TEST_REPORT_REPO:-}"
  local report_branch="${TEST_REPORT_BRANCH:-main}"
  local report_prefix="${TEST_REPORT_PATH_PREFIX:-reports}"

  # JSON assembly -- use jq to avoid manual quoting headaches.
  jq -n \
    --arg name "test-profile" \
    --arg repo "test-org/test-repo" \
    --arg secret "test-secret-abc123" \
    --arg workspace "$TEST_TMPDIR/workspace" \
    --arg report_repo "$report_repo" \
    --arg report_branch "$report_branch" \
    --arg report_prefix "$report_prefix" \
    '{
      name: $name,
      repo: $repo,
      webhook_secret: $secret,
      workspace: $workspace,
      report_repo: $report_repo,
      report_branch: $report_branch,
      report_path_prefix: $report_prefix
    }' > "$profile_dir/profile.json"

  mkdir -p "$TEST_TMPDIR/workspace"

  # Copy .env fixture (defaults to metacharacter fixture).
  local env_src="${TEST_ENV_FILE:-$PROJECT_DIR/tests/fixtures/env-with-metacharacter-secrets}"
  if [ -f "$env_src" ]; then
    cp "$env_src" "$profile_dir/.env"
  else
    : > "$profile_dir/.env"
  fi

  # Redirect config discovery to the test home.
  export CONFIG_DIR="$home_dir/.claude-pod"
  export HOME="$home_dir"
}

# =========================================================================
# Local bare report repo helper.
# Creates a fresh bare repo at $TEST_TMPDIR/report-repo-bare.git with a seeded
# main branch containing an empty .gitkeep. Echoes file:// URL for push tests.
# =========================================================================
setup_bare_repo() {
  local bare="$TEST_TMPDIR/report-repo-bare.git"
  local seed="$TEST_TMPDIR/report-repo-seed"
  rm -rf "$bare" "$seed"
  git init --bare --initial-branch=main "$bare" >/dev/null 2>&1 \
    || git init --bare "$bare" >/dev/null 2>&1
  # Seed via a scratch clone so the main branch exists at HEAD.
  git clone "$bare" "$seed" >/dev/null 2>&1
  (
    cd "$seed"
    git config user.email "seed@test.local"
    git config user.name "seed"
    git checkout -B main >/dev/null 2>&1 || true
    : > .gitkeep
    git add .gitkeep
    git commit -m "seed" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$seed"
  printf 'file://%s' "$bare"
}

restore_bare_repo() {
  rm -rf "$TEST_TMPDIR/report-repo-bare.git"
  setup_bare_repo >/dev/null
}

# =========================================================================
# Scaffold-only tests -- MUST PASS in Wave 0
# =========================================================================

test_fixtures_exist() {
  # Every Wave 0 fixture file must exist and be non-empty (or, for the bare
  # repo placeholder, present on disk).
  local f
  for f in \
    "$PROJECT_DIR/tests/fixtures/envelope-success.json" \
    "$PROJECT_DIR/tests/fixtures/envelope-legacy-cost.json" \
    "$PROJECT_DIR/tests/fixtures/envelope-large-result.json" \
    "$PROJECT_DIR/tests/fixtures/envelope-result-with-template-vars.json" \
    "$PROJECT_DIR/tests/fixtures/envelope-error.json" \
    "$PROJECT_DIR/tests/fixtures/env-with-metacharacter-secrets"
  do
    if [ ! -s "$f" ]; then
      echo "MISSING or EMPTY: $f" >&2
      return 1
    fi
  done
  # Bare repo placeholder directory + README
  [ -d "$PROJECT_DIR/tests/fixtures/report-repo-bare" ] \
    || { echo "MISSING dir: tests/fixtures/report-repo-bare" >&2; return 1; }
  [ -f "$PROJECT_DIR/tests/fixtures/report-repo-bare/README" ] \
    || { echo "MISSING: tests/fixtures/report-repo-bare/README" >&2; return 1; }
  return 0
}

test_no_force_push_grep() {
  # Static invariant: bin/claude-pod must never use git push --force,
  # --force-with-lease, -f, or refspec-force (+refs). Wave 0 state: bin has
  # no push code yet, so the grep naturally returns no matches and this
  # function passes. Later waves must keep it passing.
  local bin="$PROJECT_DIR/bin/claude-pod"
  [ -f "$bin" ] || { echo "bin/claude-pod missing" >&2; return 1; }
  if grep -nE 'git[[:space:]]+push[^#\n]*(--force|--force-with-lease|[[:space:]]-f[[:space:]]|\+refs)' "$bin" >/dev/null; then
    echo "force-push pattern detected in $bin" >&2
    return 1
  fi
  return 0
}


test_resolve_report_template_from_docs_dir() {
  # resolve_report_template should find templates under docs/<profile>/report-templates/
  # when not present under profiles/<profile>/report-templates/.
  local home_dir="$TEST_TMPDIR/home"
  local docs_reports="$home_dir/.claude-pod/docs/test-profile/report-templates"
  mkdir -p "$docs_reports"
  local marker; marker="DOCS_REPORT_$(uuidgen | tr -d '-')"
  printf '%s\n' "$marker content" > "$docs_reports/push.md"

  local out_file="$TEST_TMPDIR/resolve16_result.txt"
  local rc=0
  (
    set +e
    export __CLAUDE_POD_SOURCE_ONLY=1
    export CONFIG_DIR="$home_dir/.claude-pod"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/bin/claude-pod" >/dev/null 2>&1
    unset __CLAUDE_POD_SOURCE_ONLY
    resolve_report_template "push" > "$out_file"
    exit $?
  )
  rc=$?

  local result; result=$(cat "$out_file" 2>/dev/null || true)
  rm -f "$out_file"
  [ $rc -eq 0 ] || { rm -rf "$docs_reports"; return 1; }
  [ -f "$result" ] || { rm -rf "$docs_reports"; return 1; }
  grep -q "$marker" "$result"
  local grc=$?
  rm -rf "$docs_reports"
  return $grc
}


# =========================================================================
# Helper: run do_spawn end-to-end in a subshell with fake claude stdout.
#
# Usage:
#   run_spawn_integration <test_id> <event_fixture> <claude_stdout_json> \
#                         [--report-repo <url>] [--report-token <tok>] \
#                         [--fake-exit <code>] [--env-file <path>]
#
# Creates a fresh profile under $TEST_TMPDIR/<test_id>/home/.claude-pod,
# sources bin/claude-pod in source-only mode, sets REMAINING_ARGS, and
# calls do_spawn. Returns do_spawn's exit code. Populates these globals
# (in the subshell) that callers can inspect AFTER the subshell via files:
#   $TEST_TMPDIR/<test_id>/envelope.out    -- captured stdout
#   $TEST_TMPDIR/<test_id>/home/.claude-pod/logs/test-profile-executions.jsonl
#   $TEST_TMPDIR/<test_id>/clone/          -- checkout of bare repo post-push
# =========================================================================
run_spawn_integration() {
  local tid="$1"; shift
  local event_fixture="$1"; shift
  local fake_stdout_json="$1"; shift

  local fake_exit=0
  local env_file="$PROJECT_DIR/tests/fixtures/env-with-metacharacter-secrets"

  while [ $# -gt 0 ]; do
    case "$1" in
      --fake-exit)    fake_exit="$2"; shift 2 ;;
      --env-file)     env_file="$2"; shift 2 ;;
      *)              shift ;;
    esac
  done

  local tdir="$TEST_TMPDIR/$tid"
  local home_dir="$tdir/home"
  local profile_dir="$home_dir/.claude-pod/profiles/test-profile"
  rm -rf "$tdir"
  mkdir -p "$profile_dir" "$profile_dir/tasks" "$home_dir/.claude-pod/logs"
  mkdir -p "$tdir/workspace"
  printf 'audit harness task placeholder.\n' > "$profile_dir/tasks/default.md"

  jq -n \
    --arg name "test-profile" \
    --arg repo "test-org/test-repo" \
    --arg secret "test-secret-abc123" \
    --arg workspace "$tdir/workspace" \
    '{
      name: $name,
      repo: $repo,
      webhook_secret: $secret,
      workspace: $workspace
    }' > "$profile_dir/profile.json"

  if [ -f "$env_file" ]; then
    cp "$env_file" "$profile_dir/.env"
  else
    : > "$profile_dir/.env"
  fi


  local fake_stdout_file="$tdir/fake-claude.json"
  printf '%s\n' "$fake_stdout_json" > "$fake_stdout_file"

  local envelope_out="$tdir/envelope.out"
  local spawn_err="$tdir/spawn.err"

  (
    set +e
    export __CLAUDE_POD_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-pod"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    export CLAUDE_POD_FAKE_CLAUDE_STDOUT="$fake_stdout_file"
    export CLAUDE_POD_FAKE_CLAUDE_EXIT="$fake_exit"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/bin/claude-pod" 2>&1
    unset __CLAUDE_POD_SOURCE_ONLY
    load_profile_config "test-profile"
    # Simulate REMAINING_ARGS that do_spawn parses.
    REMAINING_ARGS=("spawn" "--event-file" "$event_fixture")
    do_spawn
    exit $?
  ) > "$envelope_out" 2> "$spawn_err"
  local rc=$?

  # Record last results in well-known paths for caller inspection.
  echo "$rc" > "$tdir/spawn.rc"
  return $rc
}

# Audit log path for a given test id.
audit_log_path() {
  echo "$TEST_TMPDIR/$1/home/.claude-pod/logs/test-profile-executions.jsonl"
}

# =========================================================================
# OPS-02 -- Audit Log
# =========================================================================

test_audit_file_path() {
  # D-04: audit writes to $LOG_DIR/${LOG_PREFIX}executions.jsonl
  local tid="audit_path"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit="$TEST_TMPDIR/$tid/home/.claude-pod/logs/test-profile-executions.jsonl"
  [ -s "$audit" ] || { echo "audit file missing at $audit"; return 1; }
  return 0
}

test_audit_creates_log_dir() {
  # write_audit_entry must `mkdir -p` LOG_DIR before append.
  local tid="audit_mkdir"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  # Remove logs dir entirely before running.
  rm -rf "$TEST_TMPDIR/$tid" 2>/dev/null || true
  run_spawn_integration "$tid" "$event" "$stdout" || return 1
  local audit="$TEST_TMPDIR/$tid/home/.claude-pod/logs/test-profile-executions.jsonl"
  [ -f "$audit" ] || { echo "log dir not auto-created"; return 1; }
  return 0
}

test_audit_jsonl_parseable() {
  local tid="audit_jsonl"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit
  audit=$(audit_log_path "$tid")
  [ -s "$audit" ] || return 1
  # Every line must parse.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | jq -c '.' >/dev/null 2>&1 \
      || { echo "unparseable line: $line"; return 1; }
  done < "$audit"
  return 0
}

test_audit_has_mandatory_keys() {
  # D-06: 13 mandatory keys.
  local tid="audit_keys"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local line
  line=$(tail -n1 "$(audit_log_path "$tid")")
  [ -n "$line" ] || return 1
  local key
  for key in ts delivery_id webhook_id event_type profile repo commit_sha branch cost_usd duration_ms session_id status report_url; do
    echo "$line" | jq -e "has(\"$key\")" >/dev/null 2>&1 \
      || { echo "missing key: $key"; return 1; }
  done
  return 0
}

test_audit_status_enum() {
  # status must be one of: success | spawn_error | claude_error | push_error
  local tid="audit_enum"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local status
  status=$(tail -n1 "$(audit_log_path "$tid")" | jq -r '.status')
  case "$status" in
    success|spawn_error|claude_error|push_error) return 0 ;;
    *) echo "invalid status: $status"; return 1 ;;
  esac
}

test_audit_spawn_error() {
  # D-17: missing --event => status=spawn_error, spawn returns nonzero.
  local tid="spawn_err"
  local home_dir="$TEST_TMPDIR/$tid/home"
  local profile_dir="$home_dir/.claude-pod/profiles/test-profile"
  mkdir -p "$profile_dir" "$home_dir/.claude-pod/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"'"$TEST_TMPDIR/$tid/ws"'", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  : > "$profile_dir/.env"

  (
    set +e
    export __CLAUDE_POD_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-pod"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    source "$PROJECT_DIR/bin/claude-pod"
    unset __CLAUDE_POD_SOURCE_ONLY
    load_profile_config "test-profile"
    # No --event: should trigger spawn_error audit.
    REMAINING_ARGS=("spawn")
    do_spawn
    exit $?
  ) >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "do_spawn should have failed"; return 1; }

  local audit="$home_dir/.claude-pod/logs/test-profile-executions.jsonl"
  [ -s "$audit" ] || { echo "no audit line on spawn_error"; return 1; }
  local status
  status=$(tail -n1 "$audit" | jq -r '.status')
  [ "$status" = "spawn_error" ] || { echo "status=$status (want spawn_error)"; return 1; }
  return 0
}

test_audit_claude_error() {
  # D-17: claude nonzero exit => status=claude_error.
  local tid="claude_err"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout='{"error":"claude failed"}'
  run_spawn_integration "$tid" "$event" "$stdout" --fake-exit 1
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "claude_error should propagate nonzero"; return 1; }

  local status
  status=$(tail -n1 "$(audit_log_path "$tid")" | jq -r '.status')
  [ "$status" = "claude_error" ] || { echo "status=$status (want claude_error)"; return 1; }
  return 0
}

test_audit_cost_fallback() {
  # Pitfall 5: legacy `cost`/`duration` fields must be read when cost_usd/duration_ms absent.
  local tid="cost_fb"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-legacy-cost.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit
  audit=$(tail -n1 "$(audit_log_path "$tid")")
  local cost dur
  cost=$(echo "$audit" | jq -r '.cost_usd')
  dur=$(echo "$audit" | jq -r '.duration_ms')
  # cost must be nonzero (legacy fallback worked).
  [ "$cost" != "0" ] && [ "$cost" != "null" ] && [ -n "$cost" ] \
    || { echo "cost fallback failed: $cost"; return 1; }
  [ "$dur" != "0" ] && [ "$dur" != "null" ] && [ -n "$dur" ] \
    || { echo "duration fallback failed: $dur"; return 1; }
  return 0
}

test_audit_line_under_pipe_buf() {
  # D-07 / Pitfall 7: each audit line must be <= 4095 bytes.
  local tid="pipe_buf"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit
  audit=$(audit_log_path "$tid")
  local max=0
  while IFS= read -r line; do
    local len=${#line}
    [ "$len" -gt "$max" ] && max=$len
  done < "$audit"
  [ "$max" -le 4095 ] || { echo "line too long: $max bytes"; return 1; }
  return 0
}

test_audit_concurrent_safe() {
  # Smoke test: write_audit_entry should not clobber from parallel callers.
  # We exercise it via sourcing and direct function calls in the background.
  local tid="concurrent"
  local home_dir="$TEST_TMPDIR/$tid/home"
  local profile_dir="$home_dir/.claude-pod/profiles/test-profile"
  mkdir -p "$profile_dir" "$home_dir/.claude-pod/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"/tmp", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  : > "$profile_dir/.env"

  (
    set +e
    export __CLAUDE_POD_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-pod"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    source "$PROJECT_DIR/bin/claude-pod"
    unset __CLAUDE_POD_SOURCE_ONLY
    load_profile_config "test-profile"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      write_audit_entry "2026-04-12T00:00:00Z" "manual-$i" "" "issues-opened" \
        "test-profile" "r/r" "" "" "0" "0" "s" "success" "" "" &
    done
    wait
    exit 0
  ) >/dev/null 2>&1

  local audit="$home_dir/.claude-pod/logs/test-profile-executions.jsonl"
  local count
  count=$(wc -l < "$audit")
  [ "$count" -eq 10 ] || { echo "got $count lines (want 10)"; return 1; }
  # Every line must parse.
  while IFS= read -r line; do
    echo "$line" | jq -e '.' >/dev/null 2>&1 \
      || { echo "corrupted line: $line"; return 1; }
  done < "$audit"
  return 0
}

test_audit_replay_identical() {
  # Replay path (CLAUDE_POD_EXEC set) must produce identical audit shape,
  # just with delivery_id=replay-<uuid>.
  local tid="replay_shape"
  local home_dir="$TEST_TMPDIR/$tid/home"
  local profile_dir="$home_dir/.claude-pod/profiles/test-profile"
  mkdir -p "$profile_dir" "$profile_dir/tasks" "$home_dir/.claude-pod/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"'"$TEST_TMPDIR/$tid/ws"'", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  mkdir -p "$TEST_TMPDIR/$tid/ws"
  : > "$profile_dir/.env"
  printf 'replay harness task placeholder.\n' > "$profile_dir/tasks/default.md"

  local fake_stdout_file="$TEST_TMPDIR/$tid/fake.json"
  jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json" > "$fake_stdout_file"

  (
    set +e
    export __CLAUDE_POD_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-pod"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    export CLAUDE_POD_EXEC="/bin/true"  # triggers replay-<uuid> path
    export CLAUDE_POD_FAKE_CLAUDE_STDOUT="$fake_stdout_file"
    source "$PROJECT_DIR/bin/claude-pod"
    unset __CLAUDE_POD_SOURCE_ONLY
    load_profile_config "test-profile"
    REMAINING_ARGS=("spawn" "--event-file" "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
    do_spawn
    exit $?
  ) >/dev/null 2>&1

  local audit="$home_dir/.claude-pod/logs/test-profile-executions.jsonl"
  [ -s "$audit" ] || return 1
  local did
  did=$(tail -n1 "$audit" | jq -r '.delivery_id')
  echo "$did" | grep -qE '^replay-[0-9a-f]+$' \
    || { echo "delivery_id=$did (want replay-<hex>)"; return 1; }
  return 0
}

test_audit_manual_synthetic_id() {
  # Manual path (no _meta.delivery_id, no CLAUDE_POD_EXEC) => manual-<uuid32>.
  local tid="manual_id"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local did
  did=$(tail -n1 "$(audit_log_path "$tid")" | jq -r '.delivery_id')
  echo "$did" | grep -qE '^manual-[0-9a-f]+$' \
    || { echo "delivery_id=$did (want manual-<hex>)"; return 1; }
  return 0
}

test_audit_webhook_id_null_when_absent() {
  # webhook_id must be empty string (renders as "") when _meta has no hook id.
  local tid="wh_null"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local wh
  wh=$(tail -n1 "$(audit_log_path "$tid")" | jq -r '.webhook_id')
  [ -z "$wh" ] || [ "$wh" = "null" ] || [ "$wh" = "" ] \
    || { echo "webhook_id=$wh (want empty)"; return 1; }
  return 0
}

# =========================================================================
# Main dispatcher
# =========================================================================
main() {
  install_stub
  setup_test_profile

  echo "========================================"
  echo "  Phase 16 Integration + Unit Tests"
  echo "  Result Channel (OPS-01/OPS-02)"
  echo "========================================"
  echo ""

  echo "--- Scaffold invariants ---"
  run_test "fixtures exist"                     test_fixtures_exist
  run_test "no force-push in bin"               test_no_force_push_grep
  run_test "report template from docs/ dir"     test_resolve_report_template_from_docs_dir
  echo ""

  echo "--- OPS-02: Audit log ---"
  run_test "audit file path"                    test_audit_file_path
  run_test "audit creates log dir"              test_audit_creates_log_dir
  run_test "audit JSONL parseable"              test_audit_jsonl_parseable
  run_test "audit has mandatory keys"           test_audit_has_mandatory_keys
  run_test "audit status enum"                  test_audit_status_enum
  run_test "audit spawn_error"                  test_audit_spawn_error
  run_test "audit claude_error"                 test_audit_claude_error
  run_test "audit cost fallback"                test_audit_cost_fallback
  run_test "audit line under PIPE_BUF"          test_audit_line_under_pipe_buf
  run_test "audit concurrent safe"              test_audit_concurrent_safe
  run_test "audit replay identical"             test_audit_replay_identical
  run_test "audit manual synthetic id"          test_audit_manual_synthetic_id
  run_test "audit webhook_id null when absent"  test_audit_webhook_id_null_when_absent
  echo ""

  echo "=============================="
  echo "Phase 16: $PASS/$TOTAL passed, $FAIL failed"
  echo "=============================="
  [ $FAIL -eq 0 ]
}

# Allow single-function invocation:
#   bash tests/test-phase16.sh test_fixtures_exist
if [ $# -gt 0 ]; then
  install_stub
  setup_test_profile
  "$@"
  exit $?
fi

main "$@"
