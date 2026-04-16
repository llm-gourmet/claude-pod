#!/bin/bash
# tests/test-phase17.sh -- Phase 17 Operational Hardening unit tests
# OPS-03 (Container reaper + systemd hardening directives)
#
# This is the UNIT-LEVEL harness. E2E tests live in tests/test-phase17-e2e.sh.
# Wave 0 contract (Nyquist self-healing): ~24 implementation tests MUST FAIL
# at the end of Wave 0. Only the scaffold-presence tests pass:
#   - test_mock_docker_fixture_exists
#   - test_profile_e2e_fixture_shape
#   - test_e2e_token_no_ghp_prefix
#   - test_reaper_unit_files_exist
#   - test_reap_grep_guard  (passes because no reaper code exists yet)
#
# Later waves flip the NOT-IMPLEMENTED sentinels green:
#   - 17-02 (Wave 1a): reaper core, unit file directives, D-11 hardening,
#                      compose mem_limit, mkdir locking, logging, dry-run
#   - 17-04 (Wave 2):  installer step 5d + post-install hint
#
# Guardrails:
#   - Stubs `docker` on PATH (no real Docker daemon touched)
#   - __CLAUDE_SECURE_SOURCE_ONLY=1 to expose bin/claude-secure internals
#   - TEST_TMPDIR cleanup via trap EXIT, nothing touches real ~/.claude-secure
#
# Usage:
#   bash tests/test-phase17.sh                         # run full suite
#   bash tests/test-phase17.sh test_reap_dry_run       # run single function

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
LISTENER_PORT=19017  # Phase 17 unit -- avoids collision with 14/15/16 (19016)
MOCK_DOCKER_LOG="$TEST_TMPDIR/mock-docker.log"

cleanup() {
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
# Mock docker wrapper (Pattern B / Pitfall 4): installs a stub `docker`
# on PATH that reads $MOCK_DOCKER_PS_OUTPUT (or the fixture file) and
# records argv to $MOCK_DOCKER_LOG. Used by reaper unit tests to avoid
# touching a real daemon.
# =========================================================================
install_mock_docker() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/bash
# Mock docker: record argv, then echo the appropriate fixture for `ps` and
# `inspect` invocations. Other invocations (compose down, run, ...) are
# recorded but return 0 so the reaper's kill path exercises its own logic.
printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG:-/dev/null}"
case "$1 ${2:-}" in
  "ps -a"|"ps ${2:-}")
    if [ "${MOCK_DOCKER_PS_EXIT:-0}" != "0" ]; then
      exit "$MOCK_DOCKER_PS_EXIT"
    fi
    if [ -n "${MOCK_DOCKER_PS_OUTPUT:-}" ]; then
      printf '%s\n' "$MOCK_DOCKER_PS_OUTPUT"
    elif [ -f "${MOCK_DOCKER_PS_FIXTURE:-}" ]; then
      cat "$MOCK_DOCKER_PS_FIXTURE"
    else
      :
    fi
    exit 0
    ;;
  "inspect "*)
    printf '%s\n' "${MOCK_DOCKER_INSPECT_CREATED:-2000-01-01T00:00:00Z}"
    exit 0
    ;;
  "compose "*)
    # Record the compose invocation (down/up) but report success.
    if [ "${MOCK_DOCKER_COMPOSE_FAIL:-0}" != "0" ]; then
      exit "$MOCK_DOCKER_COMPOSE_FAIL"
    fi
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/docker"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export MOCK_DOCKER_LOG
  export MOCK_DOCKER_PS_FIXTURE="$PROJECT_DIR/tests/fixtures/mock-docker-ps-fixture.txt"
}

# =========================================================================
# NOTE: the lock primitive binary mock was removed in Phase 18 (PORT-03).
# do_reap now uses mkdir-based atomic locking (portable across Linux and
# macOS, which lacks util-linux). Tests pre-create the lockdir to simulate
# contention. See test_reap_mkdir_lock_single_flight below.
# =========================================================================

# =========================================================================
# Source bin/claude-secure with __CLAUDE_SECURE_SOURCE_ONLY=1 so tests can
# invoke internal functions (do_reap, reap_orphan_projects, etc.) directly.
# After 17-02 lands, these functions exist and flip the sentinels green.
# =========================================================================
source_claude_secure_for_unit_test() {
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  export CONFIG_DIR="$TEST_TMPDIR/home/.claude-secure"
  export APP_DIR="$PROJECT_DIR"
  export PROFILE="${PROFILE:-test-profile}"
  mkdir -p "$CONFIG_DIR/events" "$CONFIG_DIR/logs/spawns"
  # shellcheck disable=SC1090
  source "$PROJECT_DIR/bin/claude-secure" 2>/dev/null || true
  unset __CLAUDE_SECURE_SOURCE_ONLY
}

# =========================================================================
# SCAFFOLD-PRESENCE TESTS (MUST PASS in Wave 0)
# =========================================================================

test_mock_docker_fixture_exists() {
  local f="$PROJECT_DIR/tests/fixtures/mock-docker-ps-fixture.txt"
  [ -s "$f" ] || { echo "MISSING or EMPTY: $f" >&2; return 1; }
  if ! grep -q '^cs-' "$f"; then
    echo "fixture missing cs- prefixed lines: $f" >&2
    return 1
  fi
  return 0
}

test_profile_e2e_fixture_shape() {
  local root="$PROJECT_DIR/tests/fixtures/profile-e2e"
  [ -f "$root/profile.json" ] \
    || { echo "MISSING: $root/profile.json" >&2; return 1; }
  [ -f "$root/.env" ] \
    || { echo "MISSING: $root/.env" >&2; return 1; }
  [ -f "$root/prompts/issues-opened.md" ] \
    || { echo "MISSING: $root/prompts/issues-opened.md" >&2; return 1; }
  [ -f "$root/report-templates/issues-opened.md" ] \
    || { echo "MISSING: $root/report-templates/issues-opened.md" >&2; return 1; }
  return 0
}

test_e2e_token_no_ghp_prefix() {
  # Pitfall 13: the E2E fixture token MUST NOT carry the `ghp_` prefix,
  # because git's credential helper would treat it as a real GitHub PAT
  # and attempt live authentication on a push.
  local root="$PROJECT_DIR/tests/fixtures/profile-e2e"
  [ -d "$root" ] || { echo "MISSING dir: $root" >&2; return 1; }
  if grep -r 'ghp_' "$root" >/dev/null 2>&1; then
    echo "Found forbidden ghp_ prefix under $root" >&2
    return 1
  fi
  return 0
}

test_reaper_unit_files_exist() {
  [ -f "$PROJECT_DIR/webhook/claude-secure-reaper.service" ] \
    || { echo "MISSING: webhook/claude-secure-reaper.service" >&2; return 1; }
  [ -f "$PROJECT_DIR/webhook/claude-secure-reaper.timer" ] \
    || { echo "MISSING: webhook/claude-secure-reaper.timer" >&2; return 1; }
  return 0
}

test_reap_grep_guard() {
  # OPS-03 static invariant (Specific Idea in 17-CONTEXT.md):
  # The reaper is privileged -- paranoia about its scope is warranted.
  # Reject dangerous command shapes in bin/claude-secure:
  #   - `docker ... --force`         (untargeted docker force)
  #   - `rm -rf /opt`                 (install dir destruction)
  #   - `rm -rf /etc`                 (systemd unit destruction)
  # In Wave 0 there is no reaper code, so this naturally returns zero
  # matches and passes. Later waves must keep it passing.
  local bin="$PROJECT_DIR/bin/claude-secure"
  [ -f "$bin" ] || { echo "bin/claude-secure missing" >&2; return 1; }
  if grep -nE 'docker.*--force|rm -rf /opt|rm -rf /etc' "$bin" >/dev/null; then
    echo "Dangerous pattern detected in $bin" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# REAPER SUBCOMMAND + UNIT FILES (flipped by 17-02)
# =========================================================================

test_reap_subcommand_exists() {
  local bin="$PROJECT_DIR/bin/claude-secure"
  grep -q '^do_reap()' "$bin" || { echo "missing do_reap() in $bin" >&2; return 1; }
  grep -q '^reap_orphan_projects()' "$bin" || { echo "missing reap_orphan_projects()" >&2; return 1; }
  grep -q '^reap_stale_event_files()' "$bin" || { echo "missing reap_stale_event_files()" >&2; return 1; }
  # Dispatch case: `  reap)` followed later by `do_reap` in the case arm
  grep -qE '^[[:space:]]+reap\)[[:space:]]*$' "$bin" || { echo "missing reap) dispatch case" >&2; return 1; }
  return 0
}

test_reaper_unit_files_lint() {
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    # No systemd on this host; fall back to structural grep
    grep -q '^\[Unit\]' "$PROJECT_DIR/webhook/claude-secure-reaper.service" || return 1
    grep -q '^\[Service\]' "$PROJECT_DIR/webhook/claude-secure-reaper.service" || return 1
    grep -q '^\[Install\]' "$PROJECT_DIR/webhook/claude-secure-reaper.service" || return 1
    grep -q '^\[Unit\]' "$PROJECT_DIR/webhook/claude-secure-reaper.timer" || return 1
    grep -q '^\[Timer\]' "$PROJECT_DIR/webhook/claude-secure-reaper.timer" || return 1
    grep -q '^\[Install\]' "$PROJECT_DIR/webhook/claude-secure-reaper.timer" || return 1
    return 0
  fi
  # systemd-analyze verify emits warnings for env-specific issues (ExecStart path
  # not present in test environment); we only fail on parse errors. The exit
  # code is what matters to us -- if it's 0 or the only issues are "file not
  # found" warnings (resolved at install time), we pass. Since the ExecStart
  # binary /usr/local/bin/claude-secure won't exist on this dev host, we run
  # verify and tolerate its exit status, only requiring the files parse structurally.
  systemd-analyze verify \
    "$PROJECT_DIR/webhook/claude-secure-reaper.service" \
    "$PROJECT_DIR/webhook/claude-secure-reaper.timer" 2>&1 | \
    grep -viE 'does not exist|command .* is not executable|No such file or directory|is not installed' | \
    grep -iE '(error|invalid|bad)' && return 1
  return 0
}

test_reaper_service_directives() {
  local f="$PROJECT_DIR/webhook/claude-secure-reaper.service"
  grep -q '^Type=oneshot$' "$f" || { echo "missing Type=oneshot" >&2; return 1; }
  grep -q '^ExecStart=/usr/local/bin/claude-secure reap$' "$f" || { echo "missing ExecStart" >&2; return 1; }
  grep -q '^User=root$' "$f" || { echo "missing User=root" >&2; return 1; }
  grep -q '^Group=root$' "$f" || { echo "missing Group=root" >&2; return 1; }
  grep -q '^StandardOutput=journal$' "$f" || { echo "missing StandardOutput=journal" >&2; return 1; }
  grep -q '^StandardError=journal$' "$f" || { echo "missing StandardError=journal" >&2; return 1; }
  return 0
}

test_reaper_timer_directives() {
  local f="$PROJECT_DIR/webhook/claude-secure-reaper.timer"
  grep -q '^OnBootSec=2min$' "$f" || { echo "missing OnBootSec=2min" >&2; return 1; }
  grep -q '^OnUnitActiveSec=5min$' "$f" || { echo "missing OnUnitActiveSec=5min" >&2; return 1; }
  grep -q '^AccuracySec=30s$' "$f" || { echo "missing AccuracySec=30s" >&2; return 1; }
  grep -q '^Persistent=true$' "$f" || { echo "missing Persistent=true" >&2; return 1; }
  grep -q '^Unit=claude-secure-reaper.service$' "$f" || { echo "missing Unit= binding" >&2; return 1; }
  return 0
}

test_reaper_install_sections() {
  local svc="$PROJECT_DIR/webhook/claude-secure-reaper.service"
  local timer="$PROJECT_DIR/webhook/claude-secure-reaper.timer"
  grep -q '^WantedBy=multi-user.target$' "$svc" || { echo "service missing WantedBy=multi-user.target" >&2; return 1; }
  grep -q '^WantedBy=timers.target$' "$timer" || { echo "timer missing WantedBy=timers.target" >&2; return 1; }
  return 0
}

# =========================================================================
# REAPER SELECTION LOGIC (flipped by 17-02, unit tests with mocked docker)
# =========================================================================

test_reap_age_threshold_select() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export REAPED_COUNT=0 REAPED_ERRORS=0
  reap_orphan_projects "cs-" >/dev/null 2>&1
  local rc=$REAPED_COUNT
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS
  [ "$rc" -ge 1 ] || { echo "expected >=1 reap, got $rc" >&2; return 1; }
  return 0
}

test_reap_age_threshold_skip() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  # Created just now -> age 0, threshold huge -> skip
  export MOCK_DOCKER_INSPECT_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export REAPER_ORPHAN_AGE_SECS=99999999
  export REAPED_COUNT=0 REAPED_ERRORS=0
  reap_orphan_projects "cs-" >/dev/null 2>&1
  local rc=$REAPED_COUNT
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS
  [ "$rc" = 0 ] || { echo "expected 0 reaps, got $rc" >&2; return 1; }
  return 0
}

test_reap_compose_down_invocation() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export REAPED_COUNT=0 REAPED_ERRORS=0
  reap_orphan_projects "cs-" >/dev/null 2>&1
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS
  grep -q 'compose -p cs-test-11111111 down -v --remove-orphans --timeout 10' "$MOCK_DOCKER_LOG" \
    || { echo "no compose down invocation recorded in $MOCK_DOCKER_LOG" >&2; cat "$MOCK_DOCKER_LOG" >&2; return 1; }
  return 0
}

test_reap_never_touches_images() {
  local bin="$PROJECT_DIR/bin/claude-secure"
  local body
  body=$(awk '/^do_reap\(\)/,/^}$/' "$bin")
  if echo "$body" | grep -qE 'docker[[:space:]]+rmi|image[[:space:]]+prune|--rmi'; then
    echo "do_reap body contains forbidden image commands" >&2
    return 1
  fi
  body=$(awk '/^reap_orphan_projects\(\)/,/^}$/' "$bin")
  if echo "$body" | grep -qE 'docker[[:space:]]+rmi|image[[:space:]]+prune|--rmi'; then
    echo "reap_orphan_projects body contains forbidden image commands" >&2
    return 1
  fi
  return 0
}

test_reap_instance_prefix_scoping() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111\nns-other-44444444'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export REAPED_COUNT=0 REAPED_ERRORS=0
  reap_orphan_projects "cs-" >/dev/null 2>&1
  local rc=$REAPED_COUNT
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS
  # Must have reaped cs-test but not ns-other
  grep -q 'compose -p cs-test-11111111 down' "$MOCK_DOCKER_LOG" \
    || { echo "did not reap cs-test-11111111" >&2; return 1; }
  if grep -q 'compose -p ns-other-44444444 down' "$MOCK_DOCKER_LOG"; then
    echo "incorrectly reaped ns-other-44444444 under prefix cs-" >&2
    return 1
  fi
  return 0
}

test_reap_per_project_failure_continues() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111\ncs-test-22222222'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export MOCK_DOCKER_COMPOSE_FAIL=1
  export REAPED_COUNT=0 REAPED_ERRORS=0
  reap_orphan_projects "cs-" >/dev/null 2>&1
  local errs=$REAPED_ERRORS
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS MOCK_DOCKER_COMPOSE_FAIL
  # Both projects were attempted (errors=2), cycle continued
  [ "$errs" -ge 2 ] || { echo "expected errors>=2, got $errs" >&2; return 1; }
  grep -q 'compose -p cs-test-11111111 down' "$MOCK_DOCKER_LOG" || return 1
  grep -q 'compose -p cs-test-22222222 down' "$MOCK_DOCKER_LOG" || return 1
  return 0
}

test_reap_whole_cycle_failure_exits_nonzero() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export MOCK_DOCKER_COMPOSE_FAIL=1
  export INSTANCE_PREFIX="cs-"
  export LOG_DIR="$TEST_TMPDIR/logs" LOG_PREFIX=""
  mkdir -p "$LOG_DIR"
  local rc=0
  # Run in explicit subshell so the EXIT trap inside do_reap fires on subshell
  # exit, cleaning up the lockdir before the next test runs.
  ( do_reap ) >/dev/null 2>&1 || rc=$?
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS MOCK_DOCKER_COMPOSE_FAIL INSTANCE_PREFIX
  [ "$rc" -ne 0 ] || { echo "expected nonzero exit from whole-cycle failure, got $rc" >&2; return 1; }
  return 0
}

test_reap_dry_run() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export INSTANCE_PREFIX="cs-"
  export LOG_DIR="$TEST_TMPDIR/logs" LOG_PREFIX=""
  mkdir -p "$LOG_DIR"
  local out
  out=$(do_reap --dry-run 2>&1)
  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS INSTANCE_PREFIX
  # Dry-run: must NOT have invoked compose down
  if grep -q 'compose -p .* down' "$MOCK_DOCKER_LOG"; then
    echo "dry-run invoked compose down (forbidden)" >&2
    return 1
  fi
  echo "$out" | grep -q '\[dry-run\]' || { echo "dry-run marker missing from output" >&2; return 1; }
  return 0
}

# =========================================================================
# REAPER EVENT-FILE SWEEP (flipped by 17-02)
# =========================================================================

test_reap_stale_event_files_deleted() {
  source_claude_secure_for_unit_test
  local events="$CONFIG_DIR/events"
  mkdir -p "$events"
  local stale="$events/stale-aaaaaaaa.json"
  echo '{}' > "$stale"
  # Backdate the mtime to 2 days ago (2880 minutes).
  touch -d '2 days ago' "$stale"
  export REAPER_EVENT_AGE_SECS=86400
  export EVENTS_DELETED=0
  reap_stale_event_files >/dev/null 2>&1
  local delcount=$EVENTS_DELETED
  unset REAPER_EVENT_AGE_SECS
  [ "$delcount" -ge 1 ] || { echo "stale file not deleted, count=$delcount" >&2; return 1; }
  [ ! -e "$stale" ] || { echo "stale file still exists" >&2; return 1; }
  return 0
}

test_reap_fresh_event_files_preserved() {
  source_claude_secure_for_unit_test
  local events="$CONFIG_DIR/events"
  mkdir -p "$events"
  local fresh="$events/fresh-bbbbbbbb.json"
  echo '{}' > "$fresh"
  export REAPER_EVENT_AGE_SECS=86400
  export EVENTS_DELETED=0
  reap_stale_event_files >/dev/null 2>&1
  unset REAPER_EVENT_AGE_SECS
  [ -e "$fresh" ] || { echo "fresh file was deleted (should be preserved)" >&2; return 1; }
  rm -f "$fresh"
  return 0
}

test_reap_event_age_secs_override() {
  source_claude_secure_for_unit_test
  local events="$CONFIG_DIR/events"
  mkdir -p "$events"
  local fresh="$events/override-cccccccc.json"
  echo '{}' > "$fresh"
  # REAPER_EVENT_AGE_SECS=0 means "anything older than 0 minutes". With
  # find -mmin +0, a just-created file is NOT matched (strict inequality).
  # Backdate 2 minutes to guarantee match regardless of find semantics.
  touch -d '2 minutes ago' "$fresh"
  export REAPER_EVENT_AGE_SECS=0
  export EVENTS_DELETED=0
  reap_stale_event_files >/dev/null 2>&1
  local delcount=$EVENTS_DELETED
  unset REAPER_EVENT_AGE_SECS
  [ "$delcount" -ge 1 ] || { echo "override failed, count=$delcount" >&2; return 1; }
  return 0
}

# =========================================================================
# REAPER FLOCK + LOGGING (flipped by 17-02)
# =========================================================================

test_reap_mkdir_lock_single_flight() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=$'cs-test-11111111'
  export MOCK_DOCKER_INSPECT_CREATED="2000-01-01T00:00:00Z"
  export REAPER_ORPHAN_AGE_SECS=0
  export INSTANCE_PREFIX="cs-"
  export LOG_DIR="$TEST_TMPDIR/logs" LOG_PREFIX=""
  mkdir -p "$LOG_DIR"

  # Simulate another running reaper: pre-create the lockdir with a live PID.
  local lockdir="$LOG_DIR/reaper.lockdir"
  mkdir -p "$lockdir"
  # Use a long-lived background sleep PID as the "live holder"
  sleep 30 &
  local holder=$!
  echo "$holder" > "$lockdir/pid"

  local out rc=0
  out=$(do_reap 2>&1) || rc=$?

  # Cleanup the simulated holder
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$lockdir" 2>/dev/null || true

  unset MOCK_DOCKER_PS_OUTPUT MOCK_DOCKER_INSPECT_CREATED REAPER_ORPHAN_AGE_SECS INSTANCE_PREFIX

  [ "$rc" = 0 ] || { echo "lock-held do_reap should exit 0, got $rc" >&2; echo "$out" >&2; return 1; }
  echo "$out" | grep -qi 'another instance is running' || { echo "missing 'another instance is running' log line" >&2; echo "$out" >&2; return 1; }
  if grep -q 'compose -p .* down' "$MOCK_DOCKER_LOG"; then
    echo "lock-held reaper still invoked compose down" >&2
    return 1
  fi
  return 0
}

test_reap_mkdir_lock_stale_reclaim() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=""
  export INSTANCE_PREFIX="cs-"
  export LOG_DIR="$TEST_TMPDIR/logs" LOG_PREFIX=""
  mkdir -p "$LOG_DIR"

  # Pre-create lockdir with a dead PID.
  local lockdir="$LOG_DIR/reaper.lockdir"
  mkdir -p "$lockdir"
  # Find a definitely-dead PID: spawn a no-op, capture pid, wait for exit.
  (true) &
  local dead=$!
  wait "$dead" 2>/dev/null || true
  echo "$dead" > "$lockdir/pid"

  local out rc=0
  out=$(do_reap 2>&1) || rc=$?

  # After successful reclaim, do_reap should have rmdir'd the lockdir on exit
  unset MOCK_DOCKER_PS_OUTPUT INSTANCE_PREFIX

  [ "$rc" = 0 ] || { echo "stale-reclaim do_reap should exit 0, got $rc" >&2; echo "$out" >&2; return 1; }
  echo "$out" | grep -qi 'stale lock\|reclaim' || { echo "missing stale-reclaim log line" >&2; echo "$out" >&2; return 1; }
  echo "$out" | grep -qi 'cycle start' || { echo "did not enter cycle after reclaim" >&2; echo "$out" >&2; return 1; }
  return 0
}

test_reap_no_jsonl_output() {
  local bin="$PROJECT_DIR/bin/claude-secure"
  local body
  body=$(awk '/^do_reap\(\)/,/^}$/' "$bin")
  if echo "$body" | grep -q '>>'; then
    echo "do_reap body contains >> redirect (JSONL write forbidden)" >&2
    return 1
  fi
  return 0
}

test_reap_log_format() {
  source_claude_secure_for_unit_test
  : > "$MOCK_DOCKER_LOG"
  export MOCK_DOCKER_PS_OUTPUT=""
  export REAPER_ORPHAN_AGE_SECS=0
  export INSTANCE_PREFIX="cs-"
  export LOG_DIR="$TEST_TMPDIR/logs" LOG_PREFIX=""
  mkdir -p "$LOG_DIR"
  local out
  out=$(do_reap 2>&1)
  unset MOCK_DOCKER_PS_OUTPUT REAPER_ORPHAN_AGE_SECS INSTANCE_PREFIX
  echo "$out" | grep -q '^reaper: cycle start prefix=' || { echo "missing cycle start line" >&2; echo "$out" >&2; return 1; }
  echo "$out" | grep -q '^reaper: cycle end killed=' || { echo "missing cycle end line" >&2; echo "$out" >&2; return 1; }
  return 0
}

# =========================================================================
# HARDENING DIRECTIVES D-11/D-12 (flipped by 17-02)
# =========================================================================

test_d11_directives_present() {
  local files=(
    "$PROJECT_DIR/webhook/claude-secure-reaper.service"
    "$PROJECT_DIR/webhook/claude-secure-webhook.service"
  )
  local directives=(
    ProtectKernelTunables
    ProtectKernelModules
    ProtectKernelLogs
    ProtectControlGroups
    RestrictNamespaces
    LockPersonality
    RestrictRealtime
    RestrictSUIDSGID
    MemoryDenyWriteExecute
  )
  local f d
  for f in "${files[@]}"; do
    for d in "${directives[@]}"; do
      grep -q "^${d}=true$" "$f" || { echo "MISSING $d=true in $f" >&2; return 1; }
    done
    grep -q '^SystemCallArchitectures=native$' "$f" || { echo "MISSING SystemCallArchitectures=native in $f" >&2; return 1; }
  done
  return 0
}

test_d11_forbidden_directives_absent() {
  local files=(
    "$PROJECT_DIR/webhook/claude-secure-reaper.service"
    "$PROJECT_DIR/webhook/claude-secure-webhook.service"
  )
  local forbidden='^(NoNewPrivileges|ProtectSystem|PrivateTmp|CapabilityBoundingSet|ProtectHome|PrivateDevices)='
  local f
  for f in "${files[@]}"; do
    if grep -qE "$forbidden" "$f"; then
      echo "FORBIDDEN directive in $f" >&2
      grep -nE "$forbidden" "$f" >&2
      return 1
    fi
  done
  return 0
}

test_d11_comment_block_present() {
  local files=(
    "$PROJECT_DIR/webhook/claude-secure-reaper.service"
    "$PROJECT_DIR/webhook/claude-secure-webhook.service"
  )
  local f
  for f in "${files[@]}"; do
    # Comment block must reference each forbidden directive name so operators
    # understand why they are excluded.
    local d
    for d in NoNewPrivileges ProtectSystem PrivateTmp CapabilityBoundingSet ProtectHome PrivateDevices; do
      grep -q "^#.*${d}" "$f" || { echo "comment block in $f missing mention of $d" >&2; return 1; }
    done
  done
  return 0
}

# =========================================================================
# COMPOSE PREREQUISITE (flipped by 17-02)
# =========================================================================

test_compose_has_mem_limit() {
  local f="$PROJECT_DIR/docker-compose.yml"
  grep -q '^    mem_limit: 1g$' "$f" || { echo "missing mem_limit: 1g under claude service" >&2; return 1; }
  # Defensive: ensure we didn't use deploy.resources (Swarm-only, silently ignored)
  if grep -q '^[[:space:]]*deploy:' "$f"; then
    echo "docker-compose.yml uses deploy: stanza (Pitfall 5: Swarm-only)" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# INSTALLER STATICS (flipped by 17-04)
# =========================================================================

test_installer_step_5d_present() {
  local installer="$PROJECT_DIR/install.sh"
  if [ ! -f "$installer" ]; then
    echo "install.sh missing"
    return 1
  fi
  # Step 5d must cp BOTH the reaper .service and .timer into /etc/systemd/system/
  # and chmod them 644. We assert the literal destination paths and a # 5d. header.
  if ! grep -q '^  # 5d\. ' "$installer"; then
    echo "missing step 5d comment header"
    return 1
  fi
  if ! grep -q '/etc/systemd/system/claude-secure-reaper\.service' "$installer"; then
    echo "missing /etc/systemd/system/claude-secure-reaper.service path"
    return 1
  fi
  if ! grep -q '/etc/systemd/system/claude-secure-reaper\.timer' "$installer"; then
    echo "missing /etc/systemd/system/claude-secure-reaper.timer path"
    return 1
  fi
  # Both unit files must be chmodded 644
  local chmod_count
  chmod_count=$(grep -c 'sudo chmod 644 /etc/systemd/system/claude-secure-reaper' "$installer")
  if [ "$chmod_count" -lt 2 ]; then
    echo "expected 2 chmod 644 lines for reaper unit+timer, got $chmod_count"
    return 1
  fi
  # Both unit files must be cp'd from $app_dir/webhook/
  local cp_count
  cp_count=$(grep -c 'sudo cp .*claude-secure-reaper' "$installer")
  if [ "$cp_count" -lt 2 ]; then
    echo "expected 2 cp lines for reaper unit+timer, got $cp_count"
    return 1
  fi
  return 0
}

test_installer_enables_timer() {
  local installer="$PROJECT_DIR/install.sh"
  if [ ! -f "$installer" ]; then
    echo "install.sh missing"
    return 1
  fi
  # Must enable the timer via systemctl, subject to the WSL2 gate.
  # Expect at least two references to 'enable --now claude-secure-reaper.timer':
  # 1. The real enable call
  # 2. The WSL2 manual-instructions fallback log_warn
  local enable_count
  enable_count=$(grep -c 'enable --now claude-secure-reaper\.timer' "$installer")
  if [ "$enable_count" -lt 2 ]; then
    echo "expected >=2 'enable --now claude-secure-reaper.timer', got $enable_count"
    return 1
  fi
  # WSL2 gate reuse: wsl2_no_systemd must be referenced near the new enable
  # block (guards against someone adding an unconditional enable).
  if ! awk '/^install_webhook_service\(\)/,/^\}/' "$installer" \
       | grep -q 'wsl2_no_systemd'; then
    echo "wsl2_no_systemd gate missing inside install_webhook_service"
    return 1
  fi
  # is-active check on the timer after enable
  if ! grep -q 'systemctl is-active --quiet claude-secure-reaper\.timer' "$installer"; then
    echo "missing is-active check for claude-secure-reaper.timer"
    return 1
  fi
  return 0
}

test_installer_post_install_hint() {
  local installer="$PROJECT_DIR/install.sh"
  if [ ! -f "$installer" ]; then
    echo "install.sh missing"
    return 1
  fi
  # D-18: installer prints the exact `journalctl -u claude-secure-reaper -f`
  # hint so operators know how to tail reaper activity.
  if ! grep -q 'journalctl -u claude-secure-reaper -f' "$installer"; then
    echo "missing 'journalctl -u claude-secure-reaper -f' post-install hint"
    return 1
  fi
  # Cadence hint: '5 minutes' must appear in the hint for operator context.
  if ! grep -q 'runs every 5 minutes' "$installer"; then
    echo "missing 'runs every 5 minutes' cadence hint"
    return 1
  fi
  return 0
}

# =========================================================================
# Main dispatch
# =========================================================================

# Single-function mode: bash tests/test-phase17.sh test_reap_dry_run
if [ $# -eq 1 ]; then
  "$1"
  exit $?
fi

install_mock_docker

echo "Phase 17 -- Wave 0 unit scaffold"
echo "Most tests FAIL with NOT IMPLEMENTED until Waves 1a/2 land."
echo ""

# Scaffold-presence passes
run_test "mock docker fixture exists"        test_mock_docker_fixture_exists
run_test "profile-e2e fixture shape"         test_profile_e2e_fixture_shape
run_test "e2e token no ghp prefix"           test_e2e_token_no_ghp_prefix
run_test "reaper unit files exist"           test_reaper_unit_files_exist
run_test "reap grep guard"                   test_reap_grep_guard

# Reaper subcommand + unit files (17-02)
run_test "reap subcommand exists"            test_reap_subcommand_exists
run_test "reaper unit files lint"            test_reaper_unit_files_lint
run_test "reaper service directives"         test_reaper_service_directives
run_test "reaper timer directives"           test_reaper_timer_directives
run_test "reaper install sections"           test_reaper_install_sections

# Reaper selection logic (17-02)
run_test "reap age threshold select"         test_reap_age_threshold_select
run_test "reap age threshold skip"           test_reap_age_threshold_skip
run_test "reap compose down invocation"      test_reap_compose_down_invocation
run_test "reap never touches images"         test_reap_never_touches_images
run_test "reap instance prefix scoping"      test_reap_instance_prefix_scoping
run_test "reap per-project failure continues" test_reap_per_project_failure_continues
run_test "reap whole cycle failure nonzero"  test_reap_whole_cycle_failure_exits_nonzero
run_test "reap dry-run"                      test_reap_dry_run

# Reaper event-file sweep (17-02)
run_test "reap stale event files deleted"    test_reap_stale_event_files_deleted
run_test "reap fresh event files preserved"  test_reap_fresh_event_files_preserved
run_test "reap event age secs override"      test_reap_event_age_secs_override

# Reaper mkdir-lock + logging (17-02 + Phase 18 PORT-03)
run_test "reap mkdir-lock single-flight"  test_reap_mkdir_lock_single_flight
run_test "reap mkdir-lock stale-reclaim"  test_reap_mkdir_lock_stale_reclaim
run_test "reap no jsonl output"              test_reap_no_jsonl_output
run_test "reap log format"                   test_reap_log_format

# Hardening directives D-11/D-12 (17-02)
run_test "d11 directives present"            test_d11_directives_present
run_test "d11 forbidden directives absent"   test_d11_forbidden_directives_absent
run_test "d11 comment block present"         test_d11_comment_block_present

# Compose prerequisite (17-02)
run_test "compose has mem_limit"             test_compose_has_mem_limit

# Installer statics (17-04)
run_test "installer step 5d present"         test_installer_step_5d_present
run_test "installer enables timer"           test_installer_enables_timer
run_test "installer post-install hint"       test_installer_post_install_hint

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[ $FAIL -eq 0 ] || exit 1
