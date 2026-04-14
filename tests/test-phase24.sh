#!/bin/bash
# tests/test-phase24.sh -- Phase 24 Multi-File Publish Bundle tests
# RPT-01..05, DOCS-02 (path layout), DOCS-03 (INDEX.md append).
#
# Wave 0 contract (Nyquist self-healing): the implementation tests MUST
# fail until Plans 02 and 03 land. Only fixture/template existence tests
# pass in Wave 0: test_fixtures_exist, test_bundle_template_installed.
#
# Usage:
#   bash tests/test-phase24.sh                             # run full suite
#   bash tests/test-phase24.sh test_fixtures_exist         # run single function

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

# Helper: create a bare git repo with one seed commit, returns path.
_setup_bare_repo() {
  local bare_repo
  bare_repo=$(mktemp -d "$TEST_TMPDIR/docs-bare-XXXXXXXX")
  rm -rf "$bare_repo"
  bare_repo="${bare_repo}.git"
  local scratch
  scratch=$(mktemp -d "$TEST_TMPDIR/docs-seed-XXXXXXXX")
  git init --bare -b main "$bare_repo" -q 2>/dev/null
  git -C "$scratch" init -b main -q 2>/dev/null
  git -C "$scratch" -c user.email="test@test" -c user.name="test" \
      commit -q --allow-empty -m "init" 2>/dev/null
  git -C "$scratch" remote add origin "file://$bare_repo"
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

_count_commits() {
  local bare_repo="$1"
  git -C "$bare_repo" rev-list --count HEAD 2>/dev/null
}

# Helper: install bundle fixture profile, seed bare repo, run init-docs
# to create INDEX.md. Sets global SETUP_BARE_REPO with the bare-repo path.
# NOTE: must NOT be called via command substitution -- side effects (source_cs,
# load_profile_config) must propagate to the caller shell so publish_docs_bundle
# and the loaded globals (DOCS_REPO, PROFILE, etc) are visible to the test body.
_setup_bundle_profile() {
  local profile_name="$1"
  install_fixture "profile-24-bundle" "$profile_name"
  local bare_repo
  bare_repo=$(_setup_bare_repo)
  _patch_docs_repo "$profile_name" "$bare_repo"
  source_cs
  # In the real CLI flow, PROFILE is set by arg parsing before load_profile_config
  # runs. The test harness bypasses arg parsing, so set it explicitly here.
  export PROFILE="$profile_name"
  load_profile_config "$profile_name"
  # Seed projects/<slug>/reports/INDEX.md by running init-docs once.
  do_profile_init_docs "$profile_name" 2>/dev/null || return 1
  SETUP_BARE_REPO="$bare_repo"
}

# =========================================================================
# Wave 0 GREEN tests (Plan 01 ships fixtures + bundle.md template)
# =========================================================================

test_fixtures_exist() {
  [ -f "$PROJECT_DIR/tests/fixtures/profile-24-bundle/profile.json" ]   || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-24-bundle/.env" ]           || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-24-bundle/whitelist.json" ] || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" ]            || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/bundles/missing-section-body.md" ]  || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/bundles/exfil-body.md" ]            || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/bundles/secret-body.md" ]           || return 1
  return 0
}

test_bundle_template_installed() {
  # PASSES in Wave 0 -- Plan 01 ships the canonical bundle.md.
  local f="$PROJECT_DIR/webhook/report-templates/bundle.md"
  [ -f "$f" ] || return 1
  for section in "## Goal" "## Where Worked" "## What Changed" "## What Failed" "## How to Test" "## Future Findings"; do
    grep -qF "$section" "$f" || return 1
  done
  return 0
}

# =========================================================================
# RPT-01: verify_bundle_sections (Plan 02 flips green)
# =========================================================================

test_verify_bundle_sections() {
  source_cs
  declare -F verify_bundle_sections >/dev/null || return 1
  verify_bundle_sections "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" 2>/dev/null || return 1
  if verify_bundle_sections "$PROJECT_DIR/tests/fixtures/bundles/missing-section-body.md" 2>/dev/null; then
    return 1
  fi
  return 0
}

# =========================================================================
# RPT-04 unit: sanitize_markdown_file (Plan 02 flips green)
# =========================================================================

test_sanitize_markdown_file() {
  source_cs
  declare -F sanitize_markdown_file >/dev/null || return 1
  local tmp
  tmp=$(mktemp "$TEST_TMPDIR/sanitize-XXXXXXXX.md")
  cp "$PROJECT_DIR/tests/fixtures/bundles/exfil-body.md" "$tmp"
  sanitize_markdown_file "$tmp" 2>/dev/null || return 1
  if grep -qF '![alt](https://attacker.tld' "$tmp"; then
    echo "FAIL: external inline image NOT stripped" >&2; return 1
  fi
  if grep -qF '<!-- DOCS_REPO_TOKEN' "$tmp"; then
    echo "FAIL: HTML comment NOT stripped" >&2; return 1
  fi
  if grep -qF '<img src' "$tmp"; then
    echo "FAIL: raw HTML img tag NOT stripped" >&2; return 1
  fi
  if grep -qE '^\[exfil\]:[[:space:]]+https://attacker\.tld' "$tmp"; then
    echo "FAIL: reference-style image def NOT stripped" >&2; return 1
  fi
  return 0
}

# =========================================================================
# DOCS-02: path layout (Plan 03 flips green)
# =========================================================================

test_bundle_path_layout() {
  _setup_bundle_profile "bundle-layout" || return 1
  local bare="$SETUP_BARE_REPO"
  declare -F publish_docs_bundle >/dev/null || return 1
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-layout-001" "summary layout" "manual-layout" 2>/dev/null || return 1

  local verify_dir; verify_dir=$(mktemp -d "$TEST_TMPDIR/verify-layout-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$verify_dir" 2>/dev/null || return 1
  local year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%Y-%m-%d)
  [ -f "$verify_dir/projects/docs-bundle/reports/$year/$month/$day-sess-layout-001.md" ] || return 1
  return 0
}

test_bundle_never_overwrites() {
  _setup_bundle_profile "bundle-overwrite" || return 1
  local bare="$SETUP_BARE_REPO"
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-dup" "first" "manual-1" 2>/dev/null || return 1
  if publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
      "sess-dup" "second" "manual-2" 2>/dev/null; then
    echo "FAIL: second publish with same session-id should have failed" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# DOCS-03: INDEX.md append (Plan 03 flips green)
# =========================================================================

test_bundle_updates_index() {
  _setup_bundle_profile "bundle-index" || return 1
  local bare="$SETUP_BARE_REPO"
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-index-001" "summary one" "manual-i1" 2>/dev/null || return 1

  local verify_dir; verify_dir=$(mktemp -d "$TEST_TMPDIR/verify-index-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$verify_dir" 2>/dev/null || return 1
  local idx="$verify_dir/projects/docs-bundle/reports/INDEX.md"
  [ -f "$idx" ] || return 1
  grep -q "sess-index-001" "$idx" || return 1
  grep -q "summary one" "$idx" || return 1
  return 0
}

# =========================================================================
# RPT-02: single atomic commit + clean tree on failure (Plan 03 flips green)
# =========================================================================

test_bundle_single_commit() {
  _setup_bundle_profile "bundle-single" || return 1
  local bare="$SETUP_BARE_REPO"
  local before; before=$(_count_commits "$bare")
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-single-001" "summary single" "manual-s1" 2>/dev/null || return 1
  local after; after=$(_count_commits "$bare")
  [ "$after" -eq "$((before + 1))" ] || { echo "FAIL: expected 1 new commit, got $((after - before))" >&2; return 1; }
  return 0
}

test_bundle_failure_clean_tree() {
  _setup_bundle_profile "bundle-fail" || return 1
  local bare="$SETUP_BARE_REPO"
  local before; before=$(_count_commits "$bare")
  if publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/missing-section-body.md" \
      "sess-fail-001" "summary fail" "manual-f1" 2>/dev/null; then
    return 1
  fi
  local after; after=$(_count_commits "$bare")
  [ "$after" -eq "$before" ] || { echo "FAIL: failed bundle left $((after - before)) commits behind" >&2; return 1; }
  return 0
}

# =========================================================================
# RPT-03: secret redaction (Plan 03 flips green)
# =========================================================================

test_bundle_redacts_secrets() {
  _setup_bundle_profile "bundle-redact" || return 1
  local bare="$SETUP_BARE_REPO"
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/secret-body.md" \
    "sess-redact-001" "summary redact" "manual-r1" 2>/dev/null || return 1

  local verify_dir; verify_dir=$(mktemp -d "$TEST_TMPDIR/verify-redact-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$verify_dir" 2>/dev/null || return 1
  local year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%Y-%m-%d)
  local report="$verify_dir/projects/docs-bundle/reports/$year/$month/$day-sess-redact-001.md"
  [ -f "$report" ] || return 1
  if grep -qF "TEST_SECRET_VALUE_ABC" "$report"; then
    echo "FAIL: secret leaked to remote" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# RPT-04 integration: external image stripped (Plan 03 flips green)
# =========================================================================

test_bundle_sanitizes_external_image() {
  _setup_bundle_profile "bundle-sanitize" || return 1
  local bare="$SETUP_BARE_REPO"
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/exfil-body.md" \
    "sess-exfil-001" "summary exfil" "manual-e1" 2>/dev/null || return 1

  local verify_dir; verify_dir=$(mktemp -d "$TEST_TMPDIR/verify-exfil-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$verify_dir" 2>/dev/null || return 1
  local year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%Y-%m-%d)
  local report="$verify_dir/projects/docs-bundle/reports/$year/$month/$day-sess-exfil-001.md"
  [ -f "$report" ] || return 1
  grep -qF "attacker.tld" "$report" && { echo "FAIL: attacker.tld leaked to remote" >&2; return 1; }
  grep -qF "<img" "$report" && { echo "FAIL: raw HTML <img leaked" >&2; return 1; }
  grep -qF "<!--" "$report" && { echo "FAIL: HTML comment leaked" >&2; return 1; }
  return 0
}

# =========================================================================
# RPT-05: rebase retry + concurrent race (Plan 03 flips green)
# =========================================================================

test_bundle_push_rebase_retry() {
  _setup_bundle_profile "bundle-rebase" || return 1
  local bare="$SETUP_BARE_REPO"
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-rebase-A" "summary A" "manual-rA" 2>/dev/null || return 1
  local scratch; scratch=$(mktemp -d "$TEST_TMPDIR/scratch-foreign-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$scratch" 2>/dev/null || return 1
  echo "foreign" > "$scratch/foreign.txt"
  git -C "$scratch" -c user.email=test@test -c user.name=test add foreign.txt
  git -C "$scratch" -c user.email=test@test -c user.name=test commit -q -m "foreign"
  GIT_TERMINAL_PROMPT=0 git -C "$scratch" push -q origin main 2>/dev/null || return 1
  publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
    "sess-rebase-B" "summary B" "manual-rB" 2>/dev/null || return 1
  return 0
}

test_bundle_concurrent_race() {
  _setup_bundle_profile "bundle-race" || return 1
  local bare="$SETUP_BARE_REPO"
  local rcA rcB
  ( PROFILE=bundle-race load_profile_config bundle-race; \
    publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
      "sess-race-A" "summary A" "manual-A" 2>/dev/null ) &
  local pidA=$!
  ( PROFILE=bundle-race load_profile_config bundle-race; \
    publish_docs_bundle "$PROJECT_DIR/tests/fixtures/bundles/valid-body.md" \
      "sess-race-B" "summary B" "manual-B" 2>/dev/null ) &
  local pidB=$!
  wait $pidA; rcA=$?
  wait $pidB; rcB=$?
  [ "$rcA" -eq 0 ] || { echo "FAIL: publisher A rc=$rcA" >&2; return 1; }
  [ "$rcB" -eq 0 ] || { echo "FAIL: publisher B rc=$rcB" >&2; return 1; }

  local verify_dir; verify_dir=$(mktemp -d "$TEST_TMPDIR/verify-race-XXXXXXXX")
  GIT_TERMINAL_PROMPT=0 git clone -q "file://$bare" "$verify_dir" 2>/dev/null || return 1
  local year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%Y-%m-%d)
  [ -f "$verify_dir/projects/docs-bundle/reports/$year/$month/$day-sess-race-A.md" ] || return 1
  [ -f "$verify_dir/projects/docs-bundle/reports/$year/$month/$day-sess-race-B.md" ] || return 1
  grep -q "summary A" "$verify_dir/projects/docs-bundle/reports/INDEX.md" || return 1
  grep -q "summary B" "$verify_dir/projects/docs-bundle/reports/INDEX.md" || return 1
  return 0
}

# =========================================================================
# Main dispatch
# =========================================================================

if [ $# -gt 0 ]; then
  for test_name in "$@"; do
    run_test "$test_name" "$test_name"
  done
else
  echo "Phase 24: Multi-File Publish Bundle tests"
  echo "========================================="
  # Wave 0 GREEN
  run_test "fixtures_exist"                   test_fixtures_exist
  run_test "bundle_template_installed"        test_bundle_template_installed
  # RPT-01
  run_test "verify_bundle_sections"           test_verify_bundle_sections
  # RPT-04 unit
  run_test "sanitize_markdown_file"           test_sanitize_markdown_file
  # DOCS-02
  run_test "bundle_path_layout"               test_bundle_path_layout
  run_test "bundle_never_overwrites"          test_bundle_never_overwrites
  # DOCS-03
  run_test "bundle_updates_index"             test_bundle_updates_index
  # RPT-02
  run_test "bundle_single_commit"             test_bundle_single_commit
  run_test "bundle_failure_clean_tree"        test_bundle_failure_clean_tree
  # RPT-03
  run_test "bundle_redacts_secrets"           test_bundle_redacts_secrets
  # RPT-04 integration
  run_test "bundle_sanitizes_external_image"  test_bundle_sanitizes_external_image
  # RPT-05
  run_test "bundle_push_rebase_retry"         test_bundle_push_rebase_retry
  run_test "bundle_concurrent_race"           test_bundle_concurrent_race
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
