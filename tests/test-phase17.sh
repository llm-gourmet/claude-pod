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
#                      compose mem_limit, flock, logging, dry-run
#   - 17-04 (Wave 2):  installer step 5d + post-install hint
#
# Guardrails:
#   - Stubs `docker` and `flock` on PATH (no real Docker daemon touched)
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
MOCK_FLOCK_LOG="$TEST_TMPDIR/mock-flock.log"

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
# Mock flock wrapper: emulates lock contention when MOCK_FLOCK_HELD=1.
# Records argv to $MOCK_FLOCK_LOG.
# =========================================================================
install_mock_flock() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_FLOCK_LOG:-/dev/null}"
if [ "${MOCK_FLOCK_HELD:-0}" = "1" ]; then
  # Emulate `flock -n` failing to acquire the lock.
  exit 1
fi
# Delegate the command to bash; `flock -n <fd> command...` shape support.
# For simplicity the mock ignores the lock FD entirely.
shift_count=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|-x|-s|-u|-E*) shift; shift_count=$((shift_count+1));;
    -*)              shift; shift_count=$((shift_count+1));;
    *) break;;
  esac
done
# Swallow the FD / lockfile token if any remains.
if [ $# -gt 0 ] && { [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" != *" "* && -e "$1" ]]; }; then
  shift
fi
if [ $# -gt 0 ]; then
  exec "$@"
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/flock"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export MOCK_FLOCK_LOG
}

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
  echo "NOT IMPLEMENTED: flipped green by 17-02 (reap) dispatch + do_reap"
  return 1
}

test_reaper_unit_files_lint() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (systemd-analyze verify)"
  return 1
}

test_reaper_service_directives() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (Type=oneshot + ExecStart=/usr/local/bin/claude-secure reap)"
  return 1
}

test_reaper_timer_directives() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (OnBootSec=2min + OnUnitActiveSec=5min + Persistent=true)"
  return 1
}

test_reaper_install_sections() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (service WantedBy=multi-user.target, timer WantedBy=timers.target)"
  return 1
}

# =========================================================================
# REAPER SELECTION LOGIC (flipped by 17-02, unit tests with mocked docker)
# =========================================================================

test_reap_age_threshold_select() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (REAPER_ORPHAN_AGE_SECS=0 selects mock project)"
  return 1
}

test_reap_age_threshold_skip() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (REAPER_ORPHAN_AGE_SECS=999999 skips all)"
  return 1
}

test_reap_compose_down_invocation() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (docker mock records compose -p <proj> down -v --remove-orphans --timeout 10)"
  return 1
}

test_reap_never_touches_images() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (do_reap body contains no docker rmi | image prune | --rmi)"
  return 1
}

test_reap_instance_prefix_scoping() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (INSTANCE_PREFIX-scoped matching)"
  return 1
}

test_reap_per_project_failure_continues() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (injected failing mock project, next project still reaped)"
  return 1
}

test_reap_whole_cycle_failure_exits_nonzero() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (docker ps exit 1 -> do_reap returns nonzero)"
  return 1
}

test_reap_dry_run() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (claude-secure reap --dry-run)"
  return 1
}

# =========================================================================
# REAPER EVENT-FILE SWEEP (flipped by 17-02)
# =========================================================================

test_reap_stale_event_files_deleted() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (find -mmin +N on CONFIG_DIR/events)"
  return 1
}

test_reap_fresh_event_files_preserved() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (fresh events survive reap)"
  return 1
}

test_reap_event_age_secs_override() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (REAPER_EVENT_AGE_SECS=0 -> even fresh deleted)"
  return 1
}

# =========================================================================
# REAPER FLOCK + LOGGING (flipped by 17-02)
# =========================================================================

test_reap_flock_single_flight() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (flock -n exits 0 silently with 'lock held' line)"
  return 1
}

test_reap_no_jsonl_output() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (do_reap body contains no >> JSONL redirect)"
  return 1
}

test_reap_log_format() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (reaper: cycle start prefix=... + cycle end killed=...)"
  return 1
}

# =========================================================================
# HARDENING DIRECTIVES D-11/D-12 (flipped by 17-02)
# =========================================================================

test_d11_directives_present() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (all 10 D-11 directives in BOTH webhook + reaper unit files)"
  return 1
}

test_d11_forbidden_directives_absent() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (0 forbidden D-11 directives: NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet, ProtectHome, PrivateDevices)"
  return 1
}

test_d11_comment_block_present() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (DO NOT add comment block listing 6 forbidden directives in both unit files)"
  return 1
}

# =========================================================================
# COMPOSE PREREQUISITE (flipped by 17-02)
# =========================================================================

test_compose_has_mem_limit() {
  echo "NOT IMPLEMENTED: flipped green by 17-02 (docker-compose.yml mem_limit: 1g under claude service)"
  return 1
}

# =========================================================================
# INSTALLER STATICS (flipped by 17-04)
# =========================================================================

test_installer_step_5d_present() {
  echo "NOT IMPLEMENTED: flipped green by 17-04 (install.sh step 5d copies reaper unit + timer)"
  return 1
}

test_installer_enables_timer() {
  echo "NOT IMPLEMENTED: flipped green by 17-04 (install.sh enables claude-secure-reaper.timer)"
  return 1
}

test_installer_post_install_hint() {
  echo "NOT IMPLEMENTED: flipped green by 17-04 (install.sh prints journalctl -u claude-secure-reaper -f hint)"
  return 1
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
install_mock_flock

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

# Reaper flock + logging (17-02)
run_test "reap flock single-flight"          test_reap_flock_single_flight
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
