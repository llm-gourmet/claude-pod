#!/bin/bash
# tests/test-phase23.sh -- Phase 23 Profile <-> Doc Repo Binding tests
# BIND-01 (schema validation), BIND-02 (host-only token projection),
# BIND-03 (legacy report_repo alias), DOCS-01 (init-docs subcommand).
#
# Wave 0 contract (Nyquist self-healing): the implementation tests MUST
# fail until Plans 02 and 03 land. Only fixture existence tests pass in
# Wave 0; those are: test_fixtures_exist, test_test_map_registered.
#
# Usage:
#   bash tests/test-phase23.sh                       # run full suite
#   bash tests/test-phase23.sh test_fixtures_exist   # run single function

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
export CONFIG_DIR="$TEST_TMPDIR/cs-config"
export HOME="$TEST_TMPDIR/home"
export APP_DIR="$PROJECT_DIR"
mkdir -p "$CONFIG_DIR/profiles" "$HOME"

cleanup() { rm -rf "$TEST_TMPDIR"; }
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

# Helper: install a fixture profile into $CONFIG_DIR/profiles/<dest>
install_fixture() {
  local src_fixture="$1" dest_name="$2"
  local src="$PROJECT_DIR/tests/fixtures/$src_fixture"
  local dst="$CONFIG_DIR/profiles/$dest_name"
  mkdir -p "$dst"
  cp "$src/profile.json" "$dst/profile.json"
  cp "$src/.env"         "$dst/.env"
  cp "$src/whitelist.json" "$dst/whitelist.json"
  # Rewrite workspace to a real dir the tests own
  local ws="$TEST_TMPDIR/ws-$dest_name"
  mkdir -p "$ws"
  local tmp
  tmp=$(mktemp)
  jq --arg ws "$ws" '.workspace = $ws' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
}

# Helper: source bin/claude-secure in library mode
source_cs() {
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/bin/claude-secure"
  unset __CLAUDE_SECURE_SOURCE_ONLY
}

# =========================================================================
# Wave 0 GREEN tests (Plan 01 fixtures + test-map entry)
# =========================================================================

test_fixtures_exist() {
  # PASSES in Wave 0 (Plan 01 delivers the fixtures)
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-docs/profile.json" ]   || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-docs/.env" ]           || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-docs/whitelist.json" ] || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-legacy/profile.json" ] || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-legacy/.env" ]         || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-23-legacy/whitelist.json" ] || return 1
  return 0
}

test_test_map_registered() {
  # PASSES in Wave 0 (Plan 01 adds the entry)
  grep -q 'test-phase23.sh' "$PROJECT_DIR/tests/test-map.json"
}

# =========================================================================
# BIND-01 tests: validate_docs_binding (Plan 02 flips green)
# =========================================================================

test_docs_repo_url_validation() {
  # install profile-23-docs with a MALFORMED docs_repo (ftp://bad)
  # validate_profile should return non-zero
  install_fixture "profile-23-docs" "docs-bind"
  # Rewrite docs_repo to a bad URL
  local tmp
  tmp=$(mktemp)
  jq '.docs_repo = "ftp://bad"' "$CONFIG_DIR/profiles/docs-bind/profile.json" > "$tmp" \
    && mv "$tmp" "$CONFIG_DIR/profiles/docs-bind/profile.json"
  source_cs
  ! validate_profile "docs-bind" 2>/dev/null
}

test_valid_docs_binding() {
  # install profile-23-docs unmodified, validate_profile should return 0
  install_fixture "profile-23-docs" "docs-bind-valid"
  source_cs
  validate_profile "docs-bind-valid" 2>/dev/null
}

test_no_docs_fields_ok() {
  # Create a minimal profile with NO docs_* fields -- validate_profile must still pass (back-compat)
  local dst="$CONFIG_DIR/profiles/no-docs-compat"
  local ws="$TEST_TMPDIR/ws-no-docs-compat"
  mkdir -p "$dst" "$ws"
  # Profile with no docs fields at all
  jq -n --arg ws "$ws" '{"workspace": $ws, "repo": "owner/no-docs-test"}' > "$dst/profile.json"
  # Minimal .env (no DOCS_REPO_TOKEN or REPORT_REPO_TOKEN)
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-phase23-no-docs-oauth" > "$dst/.env"
  # Minimal whitelist.json
  echo '{"secrets":[],"readonly_domains":[]}' > "$dst/whitelist.json"
  source_cs
  validate_profile "no-docs-compat" 2>/dev/null
}

test_docs_vars_exported() {
  # After load_profile_config, DOCS_REPO/BRANCH/PROJECT_DIR/MODE must be exported
  install_fixture "profile-23-docs" "docs-vars"
  source_cs
  load_profile_config "docs-vars"
  [ "${DOCS_REPO:-}" = "https://github.com/owner/docs-test.git" ] || return 1
  [ "${DOCS_BRANCH:-}" = "main" ] || return 1
  [ "${DOCS_PROJECT_DIR:-}" = "projects/docs-test" ] || return 1
  [ "${DOCS_MODE:-}" = "report_only" ] || return 1
  return 0
}

# =========================================================================
# BIND-02 tests: projected env omits host-only tokens (Plan 02 flips green)
# =========================================================================

test_projected_env_omits_docs_token() {
  # After load_profile_config, $SECRETS_FILE must NOT contain DOCS_REPO_TOKEN
  # but MUST contain CLAUDE_CODE_OAUTH_TOKEN and GITHUB_TOKEN
  install_fixture "profile-23-docs" "docs-proj"
  source_cs
  load_profile_config "docs-proj"
  # DOCS_REPO_TOKEN must be absent from the projected file
  if grep -q '^DOCS_REPO_TOKEN=' "$SECRETS_FILE" 2>/dev/null; then
    echo "FAIL: DOCS_REPO_TOKEN found in projected SECRETS_FILE" >&2
    return 1
  fi
  # CLAUDE_CODE_OAUTH_TOKEN must be present
  if ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$SECRETS_FILE" 2>/dev/null; then
    echo "FAIL: CLAUDE_CODE_OAUTH_TOKEN missing from projected SECRETS_FILE" >&2
    return 1
  fi
  # GITHUB_TOKEN must be present
  if ! grep -q '^GITHUB_TOKEN=' "$SECRETS_FILE" 2>/dev/null; then
    echo "FAIL: GITHUB_TOKEN missing from projected SECRETS_FILE" >&2
    return 1
  fi
  return 0
}

test_projected_env_omits_legacy_token() {
  # After load_profile_config legacy, $SECRETS_FILE must NOT contain REPORT_REPO_TOKEN
  install_fixture "profile-23-legacy" "legacy-proj"
  source_cs
  load_profile_config "legacy-proj"
  if grep -q '^REPORT_REPO_TOKEN=' "$SECRETS_FILE" 2>/dev/null; then
    echo "FAIL: REPORT_REPO_TOKEN found in projected SECRETS_FILE" >&2
    return 1
  fi
  return 0
}

test_docs_token_absent_from_container() {
  # Stub: requires docker compose; Plan 02 can implement gated by `command -v docker`
  echo "INTEGRATION: requires docker compose; Plan 02 implements" >&2
  return 1
}

# =========================================================================
# BIND-03 tests: alias resolution + deprecation warning (Plan 02 flips green)
# =========================================================================

test_legacy_report_repo_alias() {
  # profile-23-legacy has report_repo; after load_profile_config, DOCS_REPO
  # must equal the legacy report_repo value
  install_fixture "profile-23-legacy" "legacy-alias"
  source_cs
  # Unset vars potentially polluted by prior tests in the same session.
  unset DOCS_REPO DOCS_REPO_TOKEN REPORT_REPO_TOKEN 2>/dev/null || true
  load_profile_config "legacy-alias"
  [ "${DOCS_REPO:-}" = "https://github.com/owner/legacy-test.git" ]
}

test_legacy_report_token_alias() {
  # profile-23-legacy has REPORT_REPO_TOKEN; after load_profile_config,
  # DOCS_REPO_TOKEN must be populated from REPORT_REPO_TOKEN
  install_fixture "profile-23-legacy" "legacy-token"
  source_cs
  # Unset token vars potentially polluted by prior tests in the same session.
  unset DOCS_REPO_TOKEN REPORT_REPO_TOKEN 2>/dev/null || true
  load_profile_config "legacy-token"
  [ "${DOCS_REPO_TOKEN:-}" = "fake-phase23-legacy-token" ]
}

test_deprecation_warning_rate_limit() {
  # Calling load_profile_config twice for a legacy profile:
  # - First call: stderr contains 'deprecated' (case-insensitive)
  # - Second call: stderr does NOT contain 'deprecated'
  install_fixture "profile-23-legacy" "legacy-ratelimit"
  source_cs

  # Clear any stale sentinel from previous test runs so the first call always fires.
  rm -f "${TMPDIR:-/tmp}/cs-deprecation-warned-legacy-ratelimit"
  # Unset token vars potentially polluted by prior tests in the same session.
  unset DOCS_REPO_TOKEN REPORT_REPO_TOKEN DOCS_REPO DOCS_BRANCH 2>/dev/null || true

  local stderr1 stderr2
  stderr1=$(load_profile_config "legacy-ratelimit" 2>&1 >/dev/null)
  stderr2=$(load_profile_config "legacy-ratelimit" 2>&1 >/dev/null)

  if ! echo "$stderr1" | grep -qi "deprecated"; then
    echo "FAIL: First call did not emit deprecation warning" >&2
    echo "  stderr1: $stderr1" >&2
    return 1
  fi
  if echo "$stderr2" | grep -qi "deprecated"; then
    echo "FAIL: Second call emitted deprecation warning (should be rate-limited)" >&2
    echo "  stderr2: $stderr2" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# DOCS-01 tests: init-docs subcommand (Plan 03 flips green)
# =========================================================================

# Helper: create a bare git repo with one seed commit, returns path.
# Sets up an askpass helper so push_with_retry's file:// remote works.
_setup_bare_repo() {
  local bare_repo
  bare_repo=$(mktemp -d "$TEST_TMPDIR/docs-bare-XXXXXXXX")
  rm -rf "$bare_repo"  # mktemp creates a dir; git init --bare needs a clean path
  bare_repo="${bare_repo}.git"
  local scratch
  scratch=$(mktemp -d "$TEST_TMPDIR/docs-seed-XXXXXXXX")
  git init --bare -b main "$bare_repo" -q 2>/dev/null
  git -C "$scratch" init -b main -q 2>/dev/null
  git -C "$scratch" -c user.email="test@test" -c user.name="test" \
      commit -q --allow-empty -m "init" 2>/dev/null
  git -C "$scratch" remote add origin "file://$bare_repo"
  # push to bare; use --no-verify to bypass missing hooks on empty repo
  GIT_TERMINAL_PROMPT=0 git -C "$scratch" push -q origin main 2>/dev/null
  rm -rf "$scratch"
  echo "$bare_repo"
}

# Helper: patch fixture profile docs_repo to point at a local bare repo.
_patch_docs_repo() {
  local profile_name="$1" bare_repo="$2"
  local cfg="$CONFIG_DIR/profiles/$profile_name/profile.json"
  local tmp
  tmp=$(mktemp)
  jq --arg r "file://$bare_repo" '.docs_repo = $r' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# Helper: after do_profile_init_docs, create an askpass helper in the clone
# dir that push_with_retry expects. Because init-docs creates its own askpass,
# we just need REPORT_REPO_TOKEN exported so push_with_retry can use it.
# (resolve_docs_alias already back-fills REPORT_REPO_TOKEN from DOCS_REPO_TOKEN.)
_count_commits() {
  local bare_repo="$1"
  git -C "$bare_repo" rev-list --count HEAD 2>/dev/null
}

test_init_docs_creates_layout() {
  local bare_repo
  bare_repo=$(_setup_bare_repo)
  install_fixture "profile-23-docs" "docs-init"
  _patch_docs_repo "docs-init" "$bare_repo"
  source_cs
  load_profile_config "docs-init"
  do_profile_init_docs "docs-init" 2>/dev/null || return 1

  # Clone bare to verify files exist
  local verify_dir="$TEST_TMPDIR/verify-layout-$$"
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare_repo" "$verify_dir" 2>/dev/null || return 1
  local proj="$verify_dir/projects/docs-test"
  [ -f "$proj/todo.md" ]          || return 1
  [ -f "$proj/architecture.md" ]  || return 1
  [ -f "$proj/vision.md" ]        || return 1
  [ -f "$proj/ideas.md" ]         || return 1
  [ -f "$proj/reports/INDEX.md" ] || return 1
  [ -f "$proj/specs/.gitkeep" ]   || return 1
  return 0
}

test_init_docs_single_commit() {
  local bare_repo
  bare_repo=$(_setup_bare_repo)
  local seed_count
  seed_count=$(_count_commits "$bare_repo")
  install_fixture "profile-23-docs" "docs-single"
  _patch_docs_repo "docs-single" "$bare_repo"
  source_cs
  load_profile_config "docs-single"
  do_profile_init_docs "docs-single" 2>/dev/null || return 1

  local after_count
  after_count=$(_count_commits "$bare_repo")
  # Exactly one new commit on top of the seed
  [ "$after_count" -eq "$((seed_count + 1))" ] || return 1
  return 0
}

test_init_docs_idempotent() {
  local bare_repo
  bare_repo=$(_setup_bare_repo)
  install_fixture "profile-23-docs" "docs-idempotent"
  _patch_docs_repo "docs-idempotent" "$bare_repo"
  source_cs
  load_profile_config "docs-idempotent"
  do_profile_init_docs "docs-idempotent" 2>/dev/null || return 1
  local count_after_first
  count_after_first=$(_count_commits "$bare_repo")

  # Second call must exit 0 and add zero commits
  do_profile_init_docs "docs-idempotent" 2>/dev/null || return 1
  local count_after_second
  count_after_second=$(_count_commits "$bare_repo")
  [ "$count_after_second" -eq "$count_after_first" ] || return 1
  return 0
}

test_init_docs_requires_docs_repo() {
  # A profile with no docs_repo must exit non-zero with stderr mentioning docs_repo
  local dst="$CONFIG_DIR/profiles/docs-no-repo"
  local ws="$TEST_TMPDIR/ws-docs-no-repo"
  mkdir -p "$dst" "$ws"
  jq -n --arg ws "$ws" '{"workspace": $ws, "repo": "owner/no-docs"}' > "$dst/profile.json"
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-no-docs-oauth" > "$dst/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$dst/whitelist.json"
  source_cs
  local stderr_out
  stderr_out=$(do_profile_init_docs "docs-no-repo" 2>&1) && return 1  # must fail
  echo "$stderr_out" | grep -q 'docs_repo' || return 1
  return 0
}

test_init_docs_pat_scrub_on_error() {
  # With a bad docs_repo URL and a fake PAT, stderr must NOT echo the PAT literal.
  local dst="$CONFIG_DIR/profiles/docs-bad-url"
  local ws="$TEST_TMPDIR/ws-docs-bad-url"
  mkdir -p "$dst" "$ws"
  jq -n --arg ws "$ws" '{"workspace": $ws, "repo": "owner/bad-url",
    "docs_repo": "https://127.0.0.1:1/repo-doesnt-exist.git",
    "docs_branch": "main", "docs_project_dir": "projects/bad-url"}' > "$dst/profile.json"
  # Inject a distinctive fake PAT
  printf 'CLAUDE_CODE_OAUTH_TOKEN=fake-scrub-oauth\nDOCS_REPO_TOKEN=SECRETFAKEPAT-12345\n' > "$dst/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$dst/whitelist.json"
  source_cs
  local stderr_out
  stderr_out=$(do_profile_init_docs "docs-bad-url" 2>&1) || true
  if echo "$stderr_out" | grep -q 'SECRETFAKEPAT-12345'; then
    echo "FAIL: PAT leaked in stderr" >&2
    echo "  stderr: $stderr_out" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# Main dispatch
# =========================================================================

if [ $# -gt 0 ]; then
  # Single-test mode
  for test_name in "$@"; do
    run_test "$test_name" "$test_name"
  done
else
  echo "Phase 23: Profile <-> Doc Repo Binding tests"
  echo "============================================"
  # Wave 0 green
  run_test "fixtures_exist"                   test_fixtures_exist
  run_test "test_map_registered"              test_test_map_registered
  # BIND-01
  run_test "docs_repo_url_validation"         test_docs_repo_url_validation
  run_test "valid_docs_binding"               test_valid_docs_binding
  run_test "no_docs_fields_ok"                test_no_docs_fields_ok
  run_test "docs_vars_exported"               test_docs_vars_exported
  # BIND-02
  run_test "projected_env_omits_docs_token"   test_projected_env_omits_docs_token
  run_test "projected_env_omits_legacy_token" test_projected_env_omits_legacy_token
  run_test "docs_token_absent_from_container" test_docs_token_absent_from_container
  # BIND-03
  run_test "legacy_report_repo_alias"         test_legacy_report_repo_alias
  run_test "legacy_report_token_alias"        test_legacy_report_token_alias
  run_test "deprecation_warning_rate_limit"   test_deprecation_warning_rate_limit
  # DOCS-01
  run_test "init_docs_creates_layout"         test_init_docs_creates_layout
  run_test "init_docs_single_commit"          test_init_docs_single_commit
  run_test "init_docs_idempotent"             test_init_docs_idempotent
  run_test "init_docs_requires_docs_repo"     test_init_docs_requires_docs_repo
  run_test "init_docs_pat_scrub_on_error"     test_init_docs_pat_scrub_on_error
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
