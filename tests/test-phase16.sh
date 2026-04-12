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
#   - Stubs claude-secure on PATH with a recorder (no real Docker)
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
# Stub builder: fake `claude-secure` binary on PATH.
# Records invocation argv to $STUB_LOG and exits 0 immediately.
# =========================================================================
install_stub() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/claude-secure" <<'STUB'
#!/bin/bash
# Stub: record invocation argv and exit 0.
printf '%s\n' "$*" >> "${STUB_LOG:-/tmp/stub.log}"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/claude-secure"
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
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  mkdir -p "$profile_dir" "$profile_dir/prompts" "$profile_dir/report-templates" \
    "$home_dir/.claude-secure/events" "$home_dir/.claude-secure/logs/spawns"

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
  export CONFIG_DIR="$home_dir/.claude-secure"
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

test_templates_exist() {
  local f
  for f in \
    "$PROJECT_DIR/webhook/report-templates/issues-opened.md" \
    "$PROJECT_DIR/webhook/report-templates/issues-labeled.md" \
    "$PROJECT_DIR/webhook/report-templates/push.md" \
    "$PROJECT_DIR/webhook/report-templates/workflow_run-completed.md"
  do
    [ -s "$f" ] || { echo "MISSING or EMPTY: $f" >&2; return 1; }
    grep -q '{{RESULT_TEXT}}' "$f" \
      || { echo "no {{RESULT_TEXT}} in $f" >&2; return 1; }
  done
  return 0
}

test_no_force_push_grep() {
  # Static invariant: bin/claude-secure must never use git push --force,
  # --force-with-lease, -f, or refspec-force (+refs). Wave 0 state: bin has
  # no push code yet, so the grep naturally returns no matches and this
  # function passes. Later waves must keep it passing.
  local bin="$PROJECT_DIR/bin/claude-secure"
  [ -f "$bin" ] || { echo "bin/claude-secure missing" >&2; return 1; }
  if grep -nE 'git[[:space:]]+push[^#\n]*(--force|--force-with-lease|[[:space:]]-f[[:space:]]|\+refs)' "$bin" >/dev/null; then
    echo "force-push pattern detected in $bin" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# OPS-01 -- Report Push (all NOT IMPLEMENTED in Wave 0)
# =========================================================================

test_report_push_success() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (publish_report + do_spawn integration)"
  return 1
}

test_report_filename_format() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-12 filename <prefix>/<YYYY>/<MM>/<event>-<id8>.md)"
  return 1
}

test_commit_message_format() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-13 commit message format)"
  return 1
}

test_rebase_retry() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-14 rebase-then-retry on push rejection)"
  return 1
}

test_push_failure_audit_and_exit() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-17/D-18 audit status=report_push_failed, exit 0)"
  return 1
}

test_secret_redaction_committed() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-15 redaction pass before git add)"
  return 1
}

test_redaction_empty_value_noop() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-15 empty EMPTY_VAL must not corrupt output)"
  return 1
}

test_redaction_metacharacters() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-15 awk-from-file redaction for |, &, /, \\, \$1, etc.)"
  return 1
}

test_pat_not_leaked_on_failure() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (REPORT_REPO_TOKEN never in logs/stderr on failure)"
  return 1
}

test_report_template_fallback() {
  # Exercise the D-08 fallback chain for resolve_report_template:
  #   (a) profile override present  → profile path wins
  #   (b) no profile, env var set   → $WEBHOOK_REPORT_TEMPLATES_DIR wins
  #   (c) no profile, no env, dev   → $APP_DIR/webhook/report-templates wins
  #   (d) nothing resolves          → return 1
  local fake_home="$TEST_TMPDIR/rtf-home"
  local fake_config="$fake_home/.claude-secure"
  mkdir -p "$fake_config/profiles/test-profile/report-templates"

  # Source bin/claude-secure in source-only mode so we can call its functions.
  # Use a subshell so we don't pollute the test harness environment.
  (
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export CONFIG_DIR="$fake_config"
    export PROFILE="test-profile"
    export APP_DIR="$PROJECT_DIR"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/bin/claude-secure"
    unset __CLAUDE_SECURE_SOURCE_ONLY

    # (a) profile override
    echo "profile override" > "$fake_config/profiles/test-profile/report-templates/issues-opened.md"
    local result
    result=$(resolve_report_template issues-opened) || { echo "(a) resolver returned nonzero"; exit 1; }
    [ "$result" = "$fake_config/profiles/test-profile/report-templates/issues-opened.md" ] \
      || { echo "(a) profile override path mismatch: $result"; exit 1; }

    # (b) env var override (no profile override for this event type)
    rm "$fake_config/profiles/test-profile/report-templates/issues-opened.md"
    local env_dir="$TEST_TMPDIR/rtf-env-templates"
    mkdir -p "$env_dir"
    echo "env override" > "$env_dir/push.md"
    result=$(WEBHOOK_REPORT_TEMPLATES_DIR="$env_dir" resolve_report_template push) \
      || { echo "(b) resolver returned nonzero"; exit 1; }
    [ "$result" = "$env_dir/push.md" ] \
      || { echo "(b) env override path mismatch: $result"; exit 1; }

    # (c) dev checkout fallback (uses $APP_DIR/webhook/report-templates from the checkout)
    unset WEBHOOK_REPORT_TEMPLATES_DIR
    if [ -f "$PROJECT_DIR/webhook/report-templates/push.md" ]; then
      result=$(resolve_report_template push) || { echo "(c) resolver returned nonzero"; exit 1; }
      [ "$result" = "$PROJECT_DIR/webhook/report-templates/push.md" ] \
        || { echo "(c) dev fallback path mismatch: $result"; exit 1; }
    fi

    # (d) unresolvable event type — must return 1
    if resolve_report_template does-not-exist-event 2>/dev/null; then
      echo "(d) should have returned 1 for nonexistent template"
      exit 1
    fi

    exit 0
  )
}

test_no_report_repo_skips_push() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-02 skip push silently when report_repo empty)"
  return 1
}

test_result_text_truncation() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-16 16KB truncation of result text)"
  return 1
}

test_result_text_no_recursive_substitution() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (Pitfall 2 -- embedded {{ISSUE_TITLE}} survives)"
  return 1
}

test_crlf_and_null_stripped() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (Pitfall 4 -- CRLF + NUL removed from rendered report)"
  return 1
}

test_clone_timeout_bounded() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (clone uses --depth 1 and bounded timeout)"
  return 1
}

# =========================================================================
# OPS-02 -- Audit Log (all NOT IMPLEMENTED in Wave 0)
# =========================================================================

test_audit_file_path() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-04 \$LOG_DIR/\${LOG_PREFIX}executions.jsonl)"
  return 1
}

test_audit_creates_log_dir() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (mkdir -p LOG_DIR before append)"
  return 1
}

test_audit_jsonl_parseable() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (every line jq -c '.' parseable)"
  return 1
}

test_audit_has_mandatory_keys() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-06 all 13 mandatory keys present)"
  return 1
}

test_audit_status_enum() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (status in success|spawn_error|claude_error|report_push_failed)"
  return 1
}

test_audit_spawn_error() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-17 status=spawn_error on pre-claude failure)"
  return 1
}

test_audit_claude_error() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-17 status=claude_error on nonzero claude exit)"
  return 1
}

test_audit_cost_fallback() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (Pitfall 5 -- legacy cost/duration field read)"
  return 1
}

test_audit_line_under_pipe_buf() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-07 each JSON line <= 4096 bytes)"
  return 1
}

test_audit_concurrent_safe() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (D-07 O_APPEND + fsync, concurrent writers)"
  return 1
}

test_audit_replay_identical() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (replay spawn produces identical audit shape)"
  return 1
}

test_audit_manual_synthetic_id() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (manual-<uuid32> synthetic delivery_id)"
  return 1
}

test_audit_webhook_id_null_when_absent() {
  echo "NOT IMPLEMENTED: flipped green by 16-03 (webhook_id null when _meta has no hook id)"
  return 1
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
  run_test "templates exist"                    test_templates_exist
  run_test "no force-push in bin"               test_no_force_push_grep
  echo ""

  echo "--- OPS-01: Report push ---"
  run_test "report push success"                test_report_push_success
  run_test "report filename format"             test_report_filename_format
  run_test "commit message format"              test_commit_message_format
  run_test "rebase retry on rejection"          test_rebase_retry
  run_test "push failure audit + exit"          test_push_failure_audit_and_exit
  run_test "secret redaction committed"         test_secret_redaction_committed
  run_test "redaction empty value no-op"        test_redaction_empty_value_noop
  run_test "redaction metacharacters"           test_redaction_metacharacters
  run_test "PAT not leaked on failure"          test_pat_not_leaked_on_failure
  run_test "report template fallback chain"    test_report_template_fallback
  run_test "no report_repo skips push"          test_no_report_repo_skips_push
  run_test "result text truncation"             test_result_text_truncation
  run_test "result text no recursive subst"     test_result_text_no_recursive_substitution
  run_test "CRLF and NULL stripped"             test_crlf_and_null_stripped
  run_test "clone timeout bounded"              test_clone_timeout_bounded
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
