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
  load_profile_config "legacy-alias"
  [ "${DOCS_REPO:-}" = "https://github.com/owner/legacy-test.git" ]
}

test_legacy_report_token_alias() {
  # profile-23-legacy has REPORT_REPO_TOKEN; after load_profile_config,
  # DOCS_REPO_TOKEN must be populated from REPORT_REPO_TOKEN
  install_fixture "profile-23-legacy" "legacy-token"
  source_cs
  load_profile_config "legacy-token"
  [ "${DOCS_REPO_TOKEN:-}" = "fake-phase23-legacy-token" ]
}

test_deprecation_warning_rate_limit() {
  # Calling load_profile_config twice for a legacy profile:
  # - First call: stderr contains 'deprecated' (case-insensitive)
  # - Second call: stderr does NOT contain 'deprecated'
  install_fixture "profile-23-legacy" "legacy-ratelimit"
  source_cs

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

test_init_docs_creates_layout() {
  echo "NOT-IMPLEMENTED: do_profile_init_docs (Plan 03)" >&2
  return 1
}

test_init_docs_single_commit() {
  echo "NOT-IMPLEMENTED: do_profile_init_docs (Plan 03)" >&2
  return 1
}

test_init_docs_idempotent() {
  echo "NOT-IMPLEMENTED: do_profile_init_docs (Plan 03)" >&2
  return 1
}

test_init_docs_requires_docs_repo() {
  echo "NOT-IMPLEMENTED: do_profile_init_docs (Plan 03)" >&2
  return 1
}

test_init_docs_pat_scrub_on_error() {
  echo "NOT-IMPLEMENTED: do_profile_init_docs (Plan 03)" >&2
  return 1
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
