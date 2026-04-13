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
  export APP_DIR="$PROJECT_DIR"
  export __CLAUDE_SECURE_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/bin/claude-secure"
  unset __CLAUDE_SECURE_SOURCE_ONLY
}

# =============================================================================
# Wave 0 GREEN tests (Plan 01 delivers the fixtures and test-map registration)
# =============================================================================

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

# =============================================================================
# BIND-01: docs_repo schema validation + field export (Plan 02 flips green)
# =============================================================================

test_docs_repo_url_validation() {
  # Install profile-23-docs with a MALFORMED docs_repo (ftp://bad)
  install_fixture "profile-23-docs" "docs-bind"
  local dst="$CONFIG_DIR/profiles/docs-bind"
  local tmp
  tmp=$(mktemp)
  jq '.docs_repo = "ftp://bad"' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
  source_cs
  # validate_profile docs-bind must exit NON-zero
  validate_profile "docs-bind" 2>/dev/null
  local rc=$?
  [ "$rc" -ne 0 ] || return 1
}

test_valid_docs_binding() {
  # Install profile-23-docs unmodified; validate_profile must exit ZERO AND
  # validate_docs_binding (the Plan 02 addition) must also exist and exit ZERO.
  install_fixture "profile-23-docs" "docs-bind-valid"
  source_cs
  validate_profile "docs-bind-valid" 2>/dev/null || return 1
  # validate_docs_binding is the new function Plan 02 adds; until then, NOT IMPLEMENTED
  declare -f validate_docs_binding >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: validate_docs_binding" >&2; return 1; }
  validate_docs_binding "docs-bind-valid" 2>/dev/null
}

test_no_docs_fields_ok() {
  # A profile with no docs_* fields must still validate cleanly (back-compat).
  # After Plan 02 adds validate_docs_binding, it must also pass cleanly for
  # profiles with no docs_* fields (validate_docs_binding is a no-op when absent).
  # Build a minimal inline profile (profile-e2e fixture lacks whitelist.json).
  local dst="$CONFIG_DIR/profiles/no-docs-compat"
  local ws="$TEST_TMPDIR/ws-no-docs-compat"
  mkdir -p "$dst" "$ws"
  jq -n --arg ws "$ws" '{"workspace": $ws, "repo": "owner/test"}' > "$dst/profile.json"
  cp "$PROJECT_DIR/config/whitelist.json" "$dst/whitelist.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=fake-compat\n' > "$dst/.env"
  source_cs
  validate_profile "no-docs-compat" 2>/dev/null || return 1
  # validate_docs_binding is the Plan 02 addition; until then, NOT IMPLEMENTED
  declare -f validate_docs_binding >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: validate_docs_binding" >&2; return 1; }
  validate_docs_binding "no-docs-compat" 2>/dev/null
}

test_docs_vars_exported() {
  # Install profile-23-docs, load config, assert all four BIND-01 vars exported
  install_fixture "profile-23-docs" "docs-bind-vars"
  source_cs
  load_profile_config "docs-bind-vars" 2>/dev/null || return 1
  [ "${DOCS_REPO:-}"        = "https://github.com/owner/docs-test.git" ] || return 1
  [ "${DOCS_BRANCH:-}"      = "main" ]                                    || return 1
  [ "${DOCS_PROJECT_DIR:-}" = "projects/docs-test" ]                      || return 1
  [ "${DOCS_MODE:-}"        = "report_only" ]                             || return 1
}

# =============================================================================
# BIND-02: DOCS_REPO_TOKEN host-only, not projected into container .env
# (Plan 02 flips green)
# =============================================================================

test_projected_env_omits_docs_token() {
  # After load_profile_config, $SECRETS_FILE must NOT contain DOCS_REPO_TOKEN
  # but MUST contain CLAUDE_CODE_OAUTH_TOKEN and GITHUB_TOKEN
  install_fixture "profile-23-docs" "docs-bind-proj"
  source_cs
  load_profile_config "docs-bind-proj" 2>/dev/null || return 1
  local sf="${SECRETS_FILE:-}"
  [ -n "$sf" ] || return 1                                        # SECRETS_FILE must be set
  grep -q '^DOCS_REPO_TOKEN=' "$sf" && return 1                  # must be absent
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$sf" || return 1          # must be present
  grep -q '^GITHUB_TOKEN=' "$sf" || return 1                     # must be present
  return 0
}

test_projected_env_omits_legacy_token() {
  # After load_profile_config for legacy profile, $SECRETS_FILE must NOT
  # contain REPORT_REPO_TOKEN
  install_fixture "profile-23-legacy" "legacy-proj"
  source_cs
  load_profile_config "legacy-proj" 2>/dev/null || return 1
  local sf="${SECRETS_FILE:-}"
  [ -n "$sf" ] || return 1                                        # SECRETS_FILE must be set
  grep -q '^REPORT_REPO_TOKEN=' "$sf" && return 1                # must be absent
  return 0
}

test_docs_token_absent_from_container() {
  # Integration: requires docker compose; Plan 02 implements live container check
  echo "INTEGRATION: requires docker compose; Plan 02 implements" >&2
  return 1
}

# =============================================================================
# BIND-03: Legacy report_repo / REPORT_REPO_TOKEN alias resolution
# (Plan 02 flips green)
# =============================================================================

test_legacy_report_repo_alias() {
  # Legacy profile: load_profile_config must resolve report_repo -> DOCS_REPO
  install_fixture "profile-23-legacy" "legacy-alias"
  source_cs
  load_profile_config "legacy-alias" 2>/dev/null || return 1
  [ "${DOCS_REPO:-}" = "https://github.com/owner/legacy-test.git" ]
}

test_legacy_report_token_alias() {
  # Legacy profile: load_profile_config must resolve REPORT_REPO_TOKEN -> DOCS_REPO_TOKEN
  install_fixture "profile-23-legacy" "legacy-token-alias"
  source_cs
  load_profile_config "legacy-token-alias" 2>/dev/null || return 1
  [ "${DOCS_REPO_TOKEN:-}" = "fake-phase23-legacy-token" ]
}

test_deprecation_warning_rate_limit() {
  # Calling load_profile_config twice on a legacy profile:
  #   - FIRST call: stderr must contain "deprecated" (case-insensitive)
  #   - SECOND call: stderr must NOT contain "deprecated"
  install_fixture "profile-23-legacy" "legacy-depr"
  source_cs

  local stderr1
  local stderr2
  stderr1=$(load_profile_config "legacy-depr" 2>&1 >/dev/null) || true
  stderr2=$(load_profile_config "legacy-depr" 2>&1 >/dev/null) || true

  echo "$stderr1" | grep -qi "deprecated" || return 1
  echo "$stderr2" | grep -qi "deprecated" && return 1
  return 0
}

# =============================================================================
# DOCS-01: profile init-docs subcommand (Plan 03 flips green)
# =============================================================================

_setup_docs_bare_repo() {
  # Creates a local bare repo at $TEST_TMPDIR/docs-bare.git with one seed commit.
  # Returns the file:// URI of the bare repo.
  local bare_dir="$TEST_TMPDIR/docs-bare.git"
  git init --bare -b main "$bare_dir" >/dev/null 2>&1
  # Seed one commit via a temp clone
  local seed_dir="$TEST_TMPDIR/docs-seed"
  git clone "$bare_dir" "$seed_dir" >/dev/null 2>&1
  git -C "$seed_dir" config user.email "test@test.com"
  git -C "$seed_dir" config user.name "Test"
  echo "seed" > "$seed_dir/seed.txt"
  git -C "$seed_dir" add seed.txt
  git -C "$seed_dir" commit -m "seed" >/dev/null 2>&1
  git -C "$seed_dir" push origin main >/dev/null 2>&1
  echo "file://$bare_dir"
}

test_init_docs_creates_layout() {
  # Setup bare repo, point profile at it, run do_profile_init_docs,
  # verify all six layout files exist in the bare repo.
  # do_profile_init_docs is the Plan 03 addition; until then, NOT IMPLEMENTED.
  source_cs
  declare -f do_profile_init_docs >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: do_profile_init_docs" >&2; return 1; }
  local repo_uri
  repo_uri=$(_setup_docs_bare_repo)
  install_fixture "profile-23-docs" "docs-init-layout"
  local dst="$CONFIG_DIR/profiles/docs-init-layout"
  local tmp
  tmp=$(mktemp)
  jq --arg uri "$repo_uri" '.docs_repo = $uri' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
  source_cs
  do_profile_init_docs "docs-init-layout" 2>/dev/null || return 1
  # Clone the bare to a verify dir
  local verify_dir="$TEST_TMPDIR/verify-layout"
  git clone "$repo_uri" "$verify_dir" >/dev/null 2>&1
  [ -f "$verify_dir/projects/docs-test/todo.md" ]        || return 1
  [ -f "$verify_dir/projects/docs-test/architecture.md" ] || return 1
  [ -f "$verify_dir/projects/docs-test/vision.md" ]       || return 1
  [ -f "$verify_dir/projects/docs-test/ideas.md" ]        || return 1
  [ -f "$verify_dir/projects/docs-test/specs/.gitkeep" ]  || return 1
  [ -f "$verify_dir/projects/docs-test/reports/INDEX.md" ] || return 1
}

test_init_docs_single_commit() {
  # After init-docs, clone must have exactly 2 commits (1 seed + 1 init-docs).
  # do_profile_init_docs is the Plan 03 addition; until then, NOT IMPLEMENTED.
  source_cs
  declare -f do_profile_init_docs >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: do_profile_init_docs" >&2; return 1; }
  local repo_uri
  repo_uri=$(_setup_docs_bare_repo)
  install_fixture "profile-23-docs" "docs-init-single"
  local dst="$CONFIG_DIR/profiles/docs-init-single"
  local tmp
  tmp=$(mktemp)
  jq --arg uri "$repo_uri" '.docs_repo = $uri' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
  source_cs
  do_profile_init_docs "docs-init-single" 2>/dev/null || return 1
  local verify_dir="$TEST_TMPDIR/verify-single"
  git clone "$repo_uri" "$verify_dir" >/dev/null 2>&1
  local count
  count=$(git -C "$verify_dir" log --oneline | wc -l)
  [ "$count" -eq 2 ]
}

test_init_docs_idempotent() {
  # Running do_profile_init_docs twice must:
  #   - Second run exits 0
  #   - No new commit added (total still 2)
  # do_profile_init_docs is the Plan 03 addition; until then, NOT IMPLEMENTED.
  source_cs
  declare -f do_profile_init_docs >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: do_profile_init_docs" >&2; return 1; }
  local repo_uri
  repo_uri=$(_setup_docs_bare_repo)
  install_fixture "profile-23-docs" "docs-init-idem"
  local dst="$CONFIG_DIR/profiles/docs-init-idem"
  local tmp
  tmp=$(mktemp)
  jq --arg uri "$repo_uri" '.docs_repo = $uri' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
  source_cs
  do_profile_init_docs "docs-init-idem" 2>/dev/null || return 1
  do_profile_init_docs "docs-init-idem" 2>/dev/null || return 1
  local verify_dir="$TEST_TMPDIR/verify-idem"
  git clone "$repo_uri" "$verify_dir" >/dev/null 2>&1
  local count
  count=$(git -C "$verify_dir" log --oneline | wc -l)
  [ "$count" -eq 2 ]
}

test_init_docs_requires_docs_repo() {
  # A profile with no docs_repo -- do_profile_init_docs must exit NON-zero
  # and stderr must mention docs_repo.
  # do_profile_init_docs is the Plan 03 addition; until then, NOT IMPLEMENTED.
  source_cs
  declare -f do_profile_init_docs >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: do_profile_init_docs" >&2; return 1; }
  # Build an inline profile (profile-e2e lacks whitelist.json).
  local dst="$CONFIG_DIR/profiles/no-docs-init"
  local ws="$TEST_TMPDIR/ws-no-docs-init"
  mkdir -p "$dst" "$ws"
  jq -n --arg ws "$ws" '{"workspace": $ws, "repo": "owner/test"}' > "$dst/profile.json"
  cp "$PROJECT_DIR/config/whitelist.json" "$dst/whitelist.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=fake-nodocs\n' > "$dst/.env"
  source_cs
  local stderr_out
  stderr_out=$(do_profile_init_docs "no-docs-init" 2>&1 >/dev/null) || true
  # Must have exited non-zero
  do_profile_init_docs "no-docs-init" 2>/dev/null && return 1
  # stderr must mention docs_repo
  echo "$stderr_out" | grep -q 'docs_repo' || return 1
  return 0
}

test_init_docs_pat_scrub_on_error() {
  # DOCS_REPO_TOKEN (a distinctive literal) must NOT appear in stderr on failure.
  # do_profile_init_docs is the Plan 03 addition; until then, NOT IMPLEMENTED.
  source_cs
  declare -f do_profile_init_docs >/dev/null 2>&1 || { echo "NOT IMPLEMENTED: do_profile_init_docs" >&2; return 1; }
  install_fixture "profile-23-docs" "docs-init-scrub"
  local dst="$CONFIG_DIR/profiles/docs-init-scrub"
  local tmp
  tmp=$(mktemp)
  # Invalid remote -> will fail
  jq '.docs_repo = "file:///nonexistent/nowhere.git"' "$dst/profile.json" > "$tmp" && mv "$tmp" "$dst/profile.json"
  # Inject a distinctive fake PAT into .env
  echo "DOCS_REPO_TOKEN=SECRETFAKEPAT-12345" >> "$dst/.env"
  local stderr_out
  stderr_out=$(do_profile_init_docs "docs-init-scrub" 2>&1 >/dev/null) || true
  # PAT must NOT appear in stderr
  echo "$stderr_out" | grep -q 'SECRETFAKEPAT-12345' && return 1
  return 0
}

# =============================================================================
# Main dispatch: full suite or single-test mode
# =============================================================================

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
