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

test_readme_documents_phase16() {
  # Wave 2 static invariant: README.md documents the operator onboarding
  # flow for the doc repo result channel. Phase 23 (v4.0) renamed the schema
  # from report_repo/REPORT_REPO_TOKEN to docs_repo/DOCS_REPO_TOKEN; this test
  # accepts either naming so it survives the rename without churn. The
  # semantic invariant -- that the README documents (a) the doc-repo field,
  # (b) the host-only PAT, and (c) that the PAT never leaks to the container
  # -- is preserved.
  local readme="$PROJECT_DIR/README.md"
  [ -f "$readme" ] || { echo "README.md missing" >&2; return 1; }

  # Doc repo field must be documented under either name.
  if ! grep -qE '(docs_repo|report_repo)' "$readme"; then
    echo "README.md missing doc-repo field marker (docs_repo or report_repo)" >&2
    return 1
  fi

  # Host-only PAT must be documented under either name.
  if ! grep -qE '(DOCS_REPO_TOKEN|REPORT_REPO_TOKEN)' "$readme"; then
    echo "README.md missing doc-repo PAT marker (DOCS_REPO_TOKEN or REPORT_REPO_TOKEN)" >&2
    return 1
  fi

  # At least 2 references to the PAT across either name (env var + security note).
  local tok_count
  tok_count=$(grep -cE '(DOCS_REPO_TOKEN|REPORT_REPO_TOKEN)' "$readme")
  if [ "$tok_count" -lt 2 ]; then
    echo "Expected >=2 PAT references in README.md, got $tok_count" >&2
    return 1
  fi

  # Security property: the PAT must be documented as host-only (not in container).
  # v4.0 phrasing: "never mounted into the Claude container".
  # Legacy phrasing: "force-push" security note + "host-only" token discussion.
  if ! grep -qiE '(never.*container|host[- ]only|force[- ]push)' "$readme"; then
    echo "Expected host-only / never-in-container / force-push security note in README.md" >&2
    return 1
  fi

  return 0
}

test_installer_ships_report_templates() {
  # Wave 2 static invariant: install.sh must ship webhook/report-templates/
  # to /opt/claude-secure/webhook/report-templates/ via a step mirroring 5b.
  # D-12 always-refresh: cp individual files but NEVER rm -rf the directory,
  # so operator-added custom templates survive reinstall.
  local inst="$PROJECT_DIR/install.sh"
  [ -f "$inst" ] || { echo "install.sh missing" >&2; return 1; }

  # bash -n syntax check
  if ! bash -n "$inst" 2>/dev/null; then
    echo "install.sh failed bash -n syntax check" >&2
    return 1
  fi

  # Production path referenced at least 3 times (mkdir, cp, chmod)
  local path_count
  path_count=$(grep -c '/opt/claude-secure/webhook/report-templates' "$inst")
  if [ "$path_count" -lt 3 ]; then
    echo "Expected >=3 refs to /opt/claude-secure/webhook/report-templates in install.sh, got $path_count" >&2
    return 1
  fi

  # Step 5c comment marker present
  if ! grep -q '# 5c' "$inst"; then
    echo "Expected '# 5c' step marker in install.sh" >&2
    return 1
  fi

  # NEVER rm -rf the report-templates directory (D-12 always-refresh)
  if grep -E 'rm[[:space:]]+-rf[^#]*report-templates' "$inst" >/dev/null; then
    echo "FORBIDDEN: install.sh contains 'rm -rf ... report-templates' (D-12 violation)" >&2
    return 1
  fi

  # Log line announcing the copy
  if ! grep -q 'Copied default report templates' "$inst"; then
    echo "Expected 'Copied default report templates' log line in install.sh" >&2
    return 1
  fi

  # Source directory exists in the repo checkout
  [ -d "$PROJECT_DIR/webhook/report-templates" ] || {
    echo "webhook/report-templates missing from repo checkout" >&2
    return 1
  }

  return 0
}

# =========================================================================
# Helper: run do_spawn end-to-end in a subshell with fake claude stdout.
#
# Usage:
#   run_spawn_integration <test_id> <event_fixture> <claude_stdout_json> \
#                         [--report-repo <url>] [--report-token <tok>] \
#                         [--fake-exit <code>] [--env-file <path>]
#
# Creates a fresh profile under $TEST_TMPDIR/<test_id>/home/.claude-secure,
# sources bin/claude-secure in source-only mode, sets REMAINING_ARGS, and
# calls do_spawn. Returns do_spawn's exit code. Populates these globals
# (in the subshell) that callers can inspect AFTER the subshell via files:
#   $TEST_TMPDIR/<test_id>/envelope.out    -- captured stdout
#   $TEST_TMPDIR/<test_id>/home/.claude-secure/logs/test-profile-executions.jsonl
#   $TEST_TMPDIR/<test_id>/clone/          -- checkout of bare repo post-push
# =========================================================================
run_spawn_integration() {
  local tid="$1"; shift
  local event_fixture="$1"; shift
  local fake_stdout_json="$1"; shift

  local report_repo="" report_token="" fake_exit=0
  local env_file="$PROJECT_DIR/tests/fixtures/env-with-metacharacter-secrets"

  while [ $# -gt 0 ]; do
    case "$1" in
      --report-repo)  report_repo="$2"; shift 2 ;;
      --report-token) report_token="$2"; shift 2 ;;
      --fake-exit)    fake_exit="$2"; shift 2 ;;
      --env-file)     env_file="$2"; shift 2 ;;
      *)              shift ;;
    esac
  done

  local tdir="$TEST_TMPDIR/$tid"
  local home_dir="$tdir/home"
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  rm -rf "$tdir"
  mkdir -p "$profile_dir" "$profile_dir/prompts" "$home_dir/.claude-secure/logs"
  mkdir -p "$tdir/workspace"

  jq -n \
    --arg name "test-profile" \
    --arg repo "test-org/test-repo" \
    --arg secret "test-secret-abc123" \
    --arg workspace "$tdir/workspace" \
    --arg report_repo "$report_repo" \
    --arg report_branch "main" \
    --arg report_prefix "reports" \
    '{
      name: $name,
      repo: $repo,
      webhook_secret: $secret,
      workspace: $workspace,
      report_repo: $report_repo,
      report_branch: $report_branch,
      report_path_prefix: $report_prefix
    }' > "$profile_dir/profile.json"

  if [ -f "$env_file" ]; then
    cp "$env_file" "$profile_dir/.env"
  else
    : > "$profile_dir/.env"
  fi
  # Always inject a working REPORT_REPO_TOKEN (even if env fixture has one).
  if [ -n "$report_token" ]; then
    # Strip any existing REPORT_REPO_TOKEN line, then append our own.
    grep -v '^REPORT_REPO_TOKEN=' "$profile_dir/.env" > "$profile_dir/.env.new" || true
    echo "REPORT_REPO_TOKEN=$report_token" >> "$profile_dir/.env.new"
    mv "$profile_dir/.env.new" "$profile_dir/.env"
  fi

  # Stub whitelist so validate_profile path (not taken, but defensive) works.
  printf '{"domains":["api.anthropic.com"]}\n' > "$profile_dir/whitelist.json"

  local fake_stdout_file="$tdir/fake-claude.json"
  printf '%s\n' "$fake_stdout_json" > "$fake_stdout_file"

  local envelope_out="$tdir/envelope.out"
  local spawn_err="$tdir/spawn.err"

  (
    set +e
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-secure"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$fake_stdout_file"
    export CLAUDE_SECURE_FAKE_CLAUDE_EXIT="$fake_exit"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/bin/claude-secure" 2>&1
    unset __CLAUDE_SECURE_SOURCE_ONLY
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
  echo "$TEST_TMPDIR/$1/home/.claude-secure/logs/test-profile-executions.jsonl"
}

# =========================================================================
# OPS-01 -- Report Push
# =========================================================================

test_report_push_success() {
  local tid="push_success"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  # Verify audit has status=success and a report_url.
  local audit_line
  audit_line=$(tail -n1 "$(audit_log_path "$tid")" 2>/dev/null) || return 1
  [ -n "$audit_line" ] || { echo "empty audit line"; return 1; }
  local status url
  status=$(echo "$audit_line" | jq -r '.status')
  url=$(echo "$audit_line" | jq -r '.report_url')
  [ "$status" = "success" ] || { echo "status=$status (want success)"; return 1; }
  [ -n "$url" ] && [ "$url" != "null" ] || { echo "report_url missing"; return 1; }

  # Verify file was pushed: clone and inspect.
  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  ls "$clone/reports/$y/$m/" 2>/dev/null | grep -q "issues-opened-.*\.md" \
    || { echo "pushed file not found"; return 1; }
  return 0
}

test_report_filename_format() {
  local tid="filename_format"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  # D-12: <prefix>/<YYYY>/<MM>/<event>-<id8>.md where id8 is 8 hex chars.
  local found
  found=$(find "$clone/reports/$y/$m/" -maxdepth 1 -type f -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$found" ] || { echo "no matching report file"; return 1; }
  local base="${found##*/}"
  # Strip prefix "issues-opened-" and suffix ".md"
  local id8="${base#issues-opened-}"
  id8="${id8%.md}"
  # Must be exactly 8 chars, hex.
  [ "${#id8}" -eq 8 ] || { echo "id8 length = ${#id8} (want 8): $base"; return 1; }
  echo "$id8" | grep -qE '^[0-9a-f]{8}$' || { echo "id8 not hex: $id8"; return 1; }
  return 0
}

test_commit_message_format() {
  local tid="commit_msg"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local msg
  msg=$(git -C "$clone" log --format=%s -n1)
  # D-13: "report(<event_type>): <repo> <id8>"
  echo "$msg" | grep -qE '^report\(issues-opened\): test-org/test-repo [0-9a-f]{8}$' \
    || { echo "commit msg mismatch: $msg"; return 1; }
  return 0
}

test_rebase_retry() {
  # D-14: non-fast-forward push must pull --rebase + retry once.
  # Simulate: create bare repo, push a conflicting commit to it, then run
  # spawn. push_with_retry should rebase and succeed.
  local tid="rebase_retry"
  local repo_url
  repo_url=$(setup_bare_repo)

  # Inject a conflicting commit from a separate clone.
  local conflict_clone="$TEST_TMPDIR/$tid-conflict"
  git clone --quiet "$repo_url" "$conflict_clone" >/dev/null 2>&1
  (
    cd "$conflict_clone"
    git config user.email "c@test.local"
    git config user.name "c"
    echo "conflict" > CONFLICT.md
    git add CONFLICT.md
    git commit -q -m "conflict commit"
    git push -q origin main
  )
  rm -rf "$conflict_clone"

  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  # Verify final repo has BOTH the conflict file AND the report file (rebase
  # succeeded + report landed on top).
  local clone="$TEST_TMPDIR/$tid/verify"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  [ -f "$clone/CONFLICT.md" ] || { echo "conflict file missing post-rebase"; return 1; }
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | grep -q . \
    || { echo "report file missing post-rebase"; return 1; }
  return 0
}

test_push_failure_audit_and_exit() {
  # D-17 + D-18: when push fails (bad repo URL), status must be push_error
  # and spawn must STILL exit 0 (claude itself succeeded).
  local tid="push_fail"
  local bad_url="file:///nonexistent/path/that/will/fail-$$.git"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$bad_url" --report-token "ghp_TESTFAKE123"
  local rc=$?
  # D-18: claude succeeded => spawn exits 0 even on push failure.
  [ "$rc" -eq 0 ] || { echo "spawn exited $rc (want 0 per D-18)"; return 1; }

  local audit
  audit=$(tail -n1 "$(audit_log_path "$tid")") || return 1
  local status url
  status=$(echo "$audit" | jq -r '.status')
  url=$(echo "$audit" | jq -r '.report_url')
  [ "$status" = "push_error" ] || { echo "status=$status (want push_error)"; return 1; }
  [ -z "$url" ] || [ "$url" = "null" ] || [ "$url" = "" ] \
    || { echo "report_url should be empty on push_error: $url"; return 1; }
  return 0
}

test_secret_redaction_committed() {
  # D-15: env secrets must be redacted from the pushed report body.
  local tid="redact_committed"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  # Inject a known secret into the result so it appears in the report body
  # AFTER {{RESULT_TEXT}} substitution. The env fixture has PIPE_VAL=foo|bar.
  local stdout='{"result":"pipeline says foo|bar ran","cost_usd":0.01,"duration_ms":100,"session_id":"sess-xyz"}'
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # Secret must NOT appear literally.
  if grep -q 'foo|bar' "$f"; then
    echo "secret 'foo|bar' leaked into pushed report"
    return 1
  fi
  # Redaction marker must appear.
  grep -q '<REDACTED:PIPE_VAL>' "$f" || { echo "redaction marker missing"; return 1; }
  return 0
}

test_redaction_empty_value_noop() {
  # D-15: an empty env value (EMPTY_VAL=) must NOT cause the redactor to
  # replace empty strings (which would corrupt the output).
  local tid="redact_empty"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # File must be non-empty (i.e. not every char got replaced).
  [ -s "$f" ] || { echo "file is empty -- empty-value redaction corrupted it"; return 1; }
  # <REDACTED:EMPTY_VAL> must NOT appear.
  if grep -q 'REDACTED:EMPTY_VAL' "$f"; then
    echo "empty value was incorrectly redacted"
    return 1
  fi
  return 0
}

test_redaction_metacharacters() {
  # D-15 / Pitfall 1: awk-from-file redaction must literal-replace metachars.
  local tid="redact_meta"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  # Craft result that contains multiple dangerous secrets.
  local stdout='{"result":"seen foo|bar and x&y and /etc/passwd and a\\b\\c and $1abc and [key] and *wild*","cost_usd":0.01,"duration_ms":10,"session_id":"s"}'
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # Literal secret values must all be gone.
  local leaked=0
  grep -q 'foo|bar' "$f"     && { echo "leaked PIPE_VAL"; leaked=1; }
  grep -q 'x&y' "$f"          && { echo "leaked AMP_VAL"; leaked=1; }
  grep -q '/etc/passwd' "$f"  && { echo "leaked SLASH_VAL"; leaked=1; }
  grep -q '\[key\]' "$f"      && { echo "leaked BRACKET_VAL"; leaked=1; }
  grep -q '\*wild\*' "$f"     && { echo "leaked STAR_VAL"; leaked=1; }
  [ "$leaked" -eq 0 ] || return 1
  # At least one REDACTED marker must exist.
  grep -q 'REDACTED:' "$f" || { echo "no REDACTED markers"; return 1; }
  return 0
}

test_pat_not_leaked_on_failure() {
  # Pitfall 3: REPORT_REPO_TOKEN must never appear in stderr on clone failure.
  local tid="pat_noleak"
  local bad_url="file:///nonexistent/path/that/will/fail-$$.git"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  local secret_pat="ghp_THISMUSTNEVERLEAK_ABCDEF"
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$bad_url" --report-token "$secret_pat" || true

  if grep -q "$secret_pat" "$TEST_TMPDIR/$tid/spawn.err" 2>/dev/null; then
    echo "PAT leaked to stderr"
    return 1
  fi
  if grep -q "$secret_pat" "$TEST_TMPDIR/$tid/envelope.out" 2>/dev/null; then
    echo "PAT leaked to stdout"
    return 1
  fi
  # Audit line must not contain the PAT either.
  if grep -q "$secret_pat" "$(audit_log_path "$tid")" 2>/dev/null; then
    echo "PAT leaked to audit log"
    return 1
  fi
  return 0
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
  # D-02: when REPORT_REPO is empty in profile.json, skip publish silently
  # and audit must record status=success with empty report_url.
  local tid="skip_push"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  # No --report-repo passed -> empty report_repo in profile.json.
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit
  audit=$(tail -n1 "$(audit_log_path "$tid")") || return 1
  local status url
  status=$(echo "$audit" | jq -r '.status')
  url=$(echo "$audit" | jq -r '.report_url')
  [ "$status" = "success" ] || { echo "status=$status (want success)"; return 1; }
  # report_url must be empty/null (skip).
  [ -z "$url" ] || [ "$url" = "null" ] || [ "$url" = "" ] \
    || { echo "report_url populated on skip: $url"; return 1; }
  return 0
}

test_docs_repo_field_alias_publishes() {
  # Phase 28 OPS-01 regression: a Phase 23-migrated profile (docs_repo only,
  # no report_repo key) MUST publish a report through do_spawn -> publish_report.
  # Reproduces the bug where bin/claude-secure:2077-2079 clobbers REPORT_REPO
  # with an empty string from `jq -r '.report_repo // empty'` after
  # resolve_docs_alias already back-filled it from DOCS_REPO.
  local tid="docs_alias"
  local tdir="$TEST_TMPDIR/$tid"
  local home_dir="$tdir/home"
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  rm -rf "$tdir"
  mkdir -p "$profile_dir" "$profile_dir/prompts" "$home_dir/.claude-secure/logs"
  mkdir -p "$tdir/workspace"

  # Seed bare remote (reuses existing helper).
  local repo_url
  repo_url=$(setup_bare_repo)

  # Seed projects/test-alias/ subdir so fetch_docs_context's sparse checkout
  # finds a non-empty project dir. Without this, fetch_docs_context aborts
  # do_spawn before publish_report ever runs, masking the OPS-01 bug.
  local seed_clone="$tdir/docs-seed"
  git clone --quiet "$repo_url" "$seed_clone" >/dev/null 2>&1 || {
    echo "FAIL: could not clone bare repo to seed projects/test-alias" >&2
    return 1
  }
  (
    cd "$seed_clone" || exit 1
    git config user.email "seed@test.local"
    git config user.name "seed"
    mkdir -p projects/test-alias
    printf '# test-alias project docs\n' > projects/test-alias/README.md
    git add projects/test-alias/README.md
    git commit --quiet -m "seed projects/test-alias" >/dev/null 2>&1
    git push --quiet origin main >/dev/null 2>&1
  ) || {
    echo "FAIL: could not seed projects/test-alias into bare repo" >&2
    return 1
  }
  rm -rf "$seed_clone"

  # Write profile.json with ONLY the Phase 23 canonical docs_* fields.
  # No .report_repo, no .report_branch -- this is the exact post-migration shape.
  jq -n \
    --arg name "test-profile" \
    --arg repo "test-org/test-repo" \
    --arg secret "test-secret-abc123" \
    --arg workspace "$tdir/workspace" \
    --arg docs_repo "$repo_url" \
    --arg docs_branch "main" \
    --arg docs_project_dir "projects/test-alias" \
    '{
      name: $name,
      repo: $repo,
      webhook_secret: $secret,
      workspace: $workspace,
      docs_repo: $docs_repo,
      docs_branch: $docs_branch,
      docs_project_dir: $docs_project_dir,
      report_path_prefix: "reports"
    }' > "$profile_dir/profile.json"

  # Seed DOCS_REPO_TOKEN (not REPORT_REPO_TOKEN) -- resolve_docs_alias back-fills
  # REPORT_REPO_TOKEN from DOCS_REPO_TOKEN automatically.
  printf 'DOCS_REPO_TOKEN=ghp_TESTFAKE123\n' > "$profile_dir/.env"

  # Stub whitelist so defensive validate_profile paths are satisfied.
  printf '{"domains":["api.anthropic.com"]}\n' > "$profile_dir/whitelist.json"

  # Fake claude stdout envelope (same pattern as run_spawn_integration).
  local fake_stdout_file="$tdir/fake-claude.json"
  jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json" \
    > "$fake_stdout_file"

  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local envelope_out="$tdir/envelope.out"
  local spawn_err="$tdir/spawn.err"

  (
    set +e
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-secure"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$fake_stdout_file"
    export CLAUDE_SECURE_FAKE_CLAUDE_EXIT=0
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/bin/claude-secure" 2>&1
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "test-profile"
    REMAINING_ARGS=("spawn" "--event-file" "$event")
    do_spawn
    exit $?
  ) > "$envelope_out" 2> "$spawn_err"
  local rc=$?
  [ "$rc" -eq 0 ] || {
    echo "FAIL: do_spawn exited $rc (expected 0)" >&2
    echo "--- spawn.err ---" >&2; cat "$spawn_err" >&2
    return 1
  }

  # Assertion 1 (primary): audit log last line has a non-empty report_url.
  local audit_file audit url status
  audit_file="$home_dir/.claude-secure/logs/test-profile-executions.jsonl"
  [ -f "$audit_file" ] || {
    echo "FAIL: audit log $audit_file missing" >&2; return 1
  }
  audit=$(tail -n1 "$audit_file") || return 1
  status=$(echo "$audit" | jq -r '.status')
  url=$(echo "$audit" | jq -r '.report_url')
  [ "$status" = "success" ] || {
    echo "FAIL: status=$status (want success)" >&2
    echo "audit: $audit" >&2
    return 1
  }
  [ -n "$url" ] && [ "$url" != "null" ] && [ "$url" != "" ] || {
    echo "FAIL: report_url empty -- docs_repo backfill broken (Phase 28 OPS-01)" >&2
    echo "audit: $audit" >&2
    return 1
  }

  # Assertion 2 (structural): a report file landed in the bare remote.
  local clone="$tdir/verify-clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || {
    echo "FAIL: could not clone bare remote for verification" >&2; return 1
  }
  local y m f
  y=$(date -u +%Y); m=$(date -u +%m)
  f=$(find "$clone/reports/$y/$m/" -name 'issues-opened-*.md' 2>/dev/null | head -n1)
  [ -n "$f" ] || {
    echo "FAIL: no report file landed in bare clone at reports/$y/$m/" >&2
    find "$clone" -type f 2>/dev/null >&2
    return 1
  }
  return 0
}

test_result_text_truncation() {
  # D-16: result text must be truncated at 16384 bytes when rendered.
  local tid="truncation"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  # Build a claude stdout with a 20000-char result.
  local big
  big=$(python3 -c 'print("A"*20000)')
  local stdout
  stdout=$(jq -cn --arg r "$big" '{result:$r, cost_usd:0.01, duration_ms:10, session_id:"s"}')
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # Count the A's in the file. Result text A's must be <= 16384 (truncation limit).
  # The template itself contains a handful of baseline A's ("Author", etc.) which
  # we subtract. Allow a small positive fuzz (~16 bytes) for template baseline.
  local a_count
  a_count=$(tr -cd 'A' < "$f" | wc -c)
  [ "$a_count" -le 16400 ] || { echo "A count $a_count exceeds ~16384 + template baseline"; return 1; }
  # And clearly > 10000 (we wrote 20000, want most of it retained).
  [ "$a_count" -gt 10000 ] || { echo "A count $a_count suspiciously low"; return 1; }
  # Truncation suffix must be present.
  grep -q 'truncated .* more bytes' "$f" || { echo "truncation suffix missing"; return 1; }
  return 0
}

test_result_text_no_recursive_substitution() {
  # Pitfall 2: RESULT_TEXT / ERROR_MESSAGE must be substituted LAST so that
  # any {{ISSUE_TITLE}} embedded in the result text survives as literal text,
  # not as another substitution.
  local tid="no_recursive"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout='{"result":"user said: {{ISSUE_TITLE}} is broken","cost_usd":0.01,"duration_ms":10,"session_id":"s"}'
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # Literal {{ISSUE_TITLE}} must appear as-is in the result body line.
  grep -q 'user said: {{ISSUE_TITLE}} is broken' "$f" \
    || { echo "embedded {{ISSUE_TITLE}} did not survive"; return 1; }
  return 0
}

test_crlf_and_null_stripped() {
  # Pitfall 4: CRLF and NUL bytes in claude output must not corrupt the
  # rendered report body. The python3 extractor strips NUL; \r is allowed
  # but must not cause breakage.
  local tid="crlf_null"
  local repo_url
  repo_url=$(setup_bare_repo)
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  # Use printf to inject a literal NUL + CRLF in result (python-built JSON).
  local stdout
  stdout=$(python3 -c 'import json; print(json.dumps({"result":"line1\r\nline2\x00hidden","cost_usd":0.01,"duration_ms":10,"session_id":"s"}))')
  run_spawn_integration "$tid" "$event" "$stdout" \
    --report-repo "$repo_url" --report-token "ghp_TESTFAKE123" || return 1

  local clone="$TEST_TMPDIR/$tid/clone"
  git clone --quiet "$repo_url" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  local f
  f=$(find "$clone/reports/$y/$m/" -name "issues-opened-*.md" 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "no pushed file"; return 1; }
  # File must be non-empty and jq-committed.
  [ -s "$f" ] || { echo "empty file"; return 1; }
  # NUL byte must be absent (use perl -ne for reliable NUL detection;
  # grep with $'\x00' treats NUL as empty pattern which always matches).
  if perl -ne 'exit 0 if /\0/; END { exit 1 }' "$f"; then
    echo "NUL byte leaked into rendered report"
    return 1
  fi
  # Sanity: "hidden" string should NOT appear (it came after NUL in source,
  # and the NUL was stripped, so it becomes contiguous "line2hidden" which
  # IS valid — just verify the rendered result is non-empty and parseable).
  return 0
}

test_clone_timeout_bounded() {
  # Static invariant: publish_report uses `timeout 60` + --depth 1 on clone.
  local bin="$PROJECT_DIR/bin/claude-secure"
  grep -qE 'timeout +60' "$bin" || { echo "no 'timeout 60' guard in bin"; return 1; }
  grep -qE 'clone --depth 1' "$bin" \
    || { echo "no '--depth 1' on clone"; return 1; }
  return 0
}

# =========================================================================
# OPS-02 -- Audit Log (all NOT IMPLEMENTED in Wave 0)
# =========================================================================

test_audit_file_path() {
  # D-04: audit writes to $LOG_DIR/${LOG_PREFIX}executions.jsonl
  local tid="audit_path"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  local audit="$TEST_TMPDIR/$tid/home/.claude-secure/logs/test-profile-executions.jsonl"
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
  local audit="$TEST_TMPDIR/$tid/home/.claude-secure/logs/test-profile-executions.jsonl"
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
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  mkdir -p "$profile_dir" "$home_dir/.claude-secure/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"'"$TEST_TMPDIR/$tid/ws"'", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  : > "$profile_dir/.env"
  printf '{"domains":[]}\n' > "$profile_dir/whitelist.json"

  (
    set +e
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-secure"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    source "$PROJECT_DIR/bin/claude-secure"
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "test-profile"
    # No --event: should trigger spawn_error audit.
    REMAINING_ARGS=("spawn")
    do_spawn
    exit $?
  ) >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "do_spawn should have failed"; return 1; }

  local audit="$home_dir/.claude-secure/logs/test-profile-executions.jsonl"
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
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  mkdir -p "$profile_dir" "$home_dir/.claude-secure/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"/tmp", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  : > "$profile_dir/.env"
  printf '{"domains":[]}\n' > "$profile_dir/whitelist.json"

  (
    set +e
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-secure"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    source "$PROJECT_DIR/bin/claude-secure"
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "test-profile"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      write_audit_entry "2026-04-12T00:00:00Z" "manual-$i" "" "issues-opened" \
        "test-profile" "r/r" "" "" "0" "0" "s" "success" "" "" &
    done
    wait
    exit 0
  ) >/dev/null 2>&1

  local audit="$home_dir/.claude-secure/logs/test-profile-executions.jsonl"
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
  # Replay path (CLAUDE_SECURE_EXEC set) must produce identical audit shape,
  # just with delivery_id=replay-<uuid>.
  local tid="replay_shape"
  local home_dir="$TEST_TMPDIR/$tid/home"
  local profile_dir="$home_dir/.claude-secure/profiles/test-profile"
  mkdir -p "$profile_dir" "$home_dir/.claude-secure/logs"
  jq -n '{name:"test-profile", repo:"test-org/test-repo", webhook_secret:"s", workspace:"'"$TEST_TMPDIR/$tid/ws"'", report_repo:"", report_branch:"main", report_path_prefix:"reports"}' \
    > "$profile_dir/profile.json"
  mkdir -p "$TEST_TMPDIR/$tid/ws"
  : > "$profile_dir/.env"
  printf '{"domains":[]}\n' > "$profile_dir/whitelist.json"

  local fake_stdout_file="$TEST_TMPDIR/$tid/fake.json"
  jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json" > "$fake_stdout_file"

  (
    set +e
    export __CLAUDE_SECURE_SOURCE_ONLY=1
    export APP_DIR="$PROJECT_DIR"
    export CONFIG_DIR="$home_dir/.claude-secure"
    export HOME="$home_dir"
    export PROFILE="test-profile"
    export PLATFORM="linux"
    export CLAUDE_SECURE_EXEC="/bin/true"  # triggers replay-<uuid> path
    export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$fake_stdout_file"
    source "$PROJECT_DIR/bin/claude-secure"
    unset __CLAUDE_SECURE_SOURCE_ONLY
    load_profile_config "test-profile"
    REMAINING_ARGS=("spawn" "--event-file" "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
    do_spawn
    exit $?
  ) >/dev/null 2>&1

  local audit="$home_dir/.claude-secure/logs/test-profile-executions.jsonl"
  [ -s "$audit" ] || return 1
  local did
  did=$(tail -n1 "$audit" | jq -r '.delivery_id')
  echo "$did" | grep -qE '^replay-[0-9a-f]+$' \
    || { echo "delivery_id=$did (want replay-<hex>)"; return 1; }
  return 0
}

test_audit_manual_synthetic_id() {
  # Manual path (no _meta.delivery_id, no CLAUDE_SECURE_EXEC) => manual-<uuid32>.
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
  run_test "templates exist"                    test_templates_exist
  run_test "no force-push in bin"               test_no_force_push_grep
  run_test "installer ships report templates"   test_installer_ships_report_templates
  run_test "README documents Phase 16"          test_readme_documents_phase16
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
  run_test "docs_repo field alias publishes"    test_docs_repo_field_alias_publishes
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
