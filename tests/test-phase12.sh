#!/bin/bash
# test-phase12.sh -- Integration tests for Phase 12: Profile System
# Tests PROF-01 through PROF-03, superuser mode, list, clean break
#
# Strategy: Use temp directories for all config to avoid touching real ~/.claude-secure.
# Test bin/claude-secure functions by extracting/reimplementing the function signatures
# and testing them in isolation.
#
# Usage: bash tests/test-phase12.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Global temp directory for test isolation
TEST_TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "========================================"
echo "  Phase 12 Integration Tests"
echo "  Profile System"
echo "  (PROF-01 -- PROF-03)"
echo "========================================"
echo ""

# =========================================================================
# Helper: Source profile functions from bin/claude-secure
# We source the script with __CLAUDE_SECURE_SOURCE_ONLY=1 to skip execution
# and only load function definitions.
# =========================================================================

# Set up a minimal config environment so sourcing works
_setup_source_env() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/.claude-secure/profiles"
  cat > "$tmpdir/.claude-secure/config.sh" <<EOF
APP_DIR="$PROJECT_DIR"
PLATFORM="linux"
EOF
  export HOME="$tmpdir"
  export CONFIG_DIR="$tmpdir/.claude-secure"
}

# Source bin/claude-secure functions
_source_functions() {
  local tmpdir="$1"
  _setup_source_env "$tmpdir"
  # Export APP_DIR so functions like create_profile can copy whitelist template
  # from $APP_DIR/config/whitelist.json under set -u (main dispatch normally sets
  # this via config.sh, but source-only mode bypasses that path).
  export APP_DIR="$PROJECT_DIR"
  # shellcheck source=/dev/null
  __CLAUDE_SECURE_SOURCE_ONLY=1 source "$PROJECT_DIR/bin/claude-secure"
}

# Helper: Create a valid test profile directory
create_test_profile() {
  local name="$1"
  local config_dir="$2"
  local ws_path="${3:-$TEST_TMPDIR/workspace-$name}"
  local repo="${4:-}"

  mkdir -p "$config_dir/profiles/$name"
  mkdir -p "$ws_path"

  # Build profile.json
  if [ -n "$repo" ]; then
    jq -n --arg ws "$ws_path" --arg repo "$repo" '{"workspace": $ws, "repo": $repo}' \
      > "$config_dir/profiles/$name/profile.json"
  else
    jq -n --arg ws "$ws_path" '{"workspace": $ws}' \
      > "$config_dir/profiles/$name/profile.json"
  fi

  # Create .env
  echo "ANTHROPIC_API_KEY=test-key-$name" > "$config_dir/profiles/$name/.env"
  chmod 600 "$config_dir/profiles/$name/.env"

  # Copy whitelist template
  cp "$PROJECT_DIR/config/whitelist.json" "$config_dir/profiles/$name/whitelist.json"
}

# =========================================================================
# PROF-01a: After create_profile, profile dir contains profile.json, .env, whitelist.json
# =========================================================================
test_prof_01a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"

  local pdir="$tmpdir/.claude-secure/profiles/myproj"
  [ -f "$pdir/profile.json" ] || return 1
  [ -f "$pdir/.env" ] || return 1
  [ -f "$pdir/whitelist.json" ] || return 1
  return 0
}
run_test "PROF-01a: Profile directory contains profile.json, .env, whitelist.json" test_prof_01a

# =========================================================================
# PROF-01b: profile.json is valid JSON with required workspace field
# =========================================================================
test_prof_01b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj"

  local pdir="$tmpdir/.claude-secure/profiles/myproj"
  # Valid JSON
  jq empty "$pdir/profile.json" || return 1
  # Has workspace field
  local ws
  ws=$(jq -r '.workspace // empty' "$pdir/profile.json")
  [ -n "$ws" ] || return 1
  return 0
}
run_test "PROF-01b: profile.json is valid JSON with workspace field" test_prof_01b

# =========================================================================
# PROF-01c: validate_profile_name accepts/rejects correctly
# =========================================================================
test_prof_01c_valid() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Valid names
  validate_profile_name "my-proj" || return 1
  validate_profile_name "proj1" || return 1
  validate_profile_name "a" || return 1
  validate_profile_name "1abc" || return 1
  return 0
}
run_test "PROF-01c: validate_profile_name accepts valid names" test_prof_01c_valid

test_prof_01c_invalid() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Invalid names -- each must return non-zero
  validate_profile_name "My_Proj" && return 1
  validate_profile_name "has spaces" && return 1
  # 64+ chars
  local longname
  longname=$(printf 'a%.0s' {1..64})
  validate_profile_name "$longname" && return 1
  return 0
}
run_test "PROF-01c: validate_profile_name rejects invalid names" test_prof_01c_invalid

# =========================================================================
# PROF-02a: profile.json repo field readable via jq
# =========================================================================
test_prof_02a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj" "owner/repo"

  local repo
  repo=$(jq -r '.repo' "$tmpdir/.claude-secure/profiles/myproj/profile.json")
  [ "$repo" = "owner/repo" ] || return 1
  return 0
}
run_test "PROF-02a: profile.json repo field readable via jq" test_prof_02a

# =========================================================================
# PROF-02b: resolve_profile_by_repo returns correct profile for known repo
# =========================================================================
test_prof_02b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  _setup_source_env "$tmpdir"
  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a" "owner/repo-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b" "owner/repo-b"
  _source_functions "$tmpdir"

  local result
  result=$(resolve_profile_by_repo "owner/repo-b")
  [ "$result" = "proj-b" ] || return 1
  return 0
}
run_test "PROF-02b: resolve_profile_by_repo returns correct profile" test_prof_02b

# =========================================================================
# PROF-02c: resolve_profile_by_repo returns exit 1 for unknown repo
# =========================================================================
test_prof_02c() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")

  _setup_source_env "$tmpdir"
  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a" "owner/repo-a"
  _source_functions "$tmpdir"

  resolve_profile_by_repo "nonexistent/repo" && return 1
  return 0
}
run_test "PROF-02c: resolve_profile_by_repo returns exit 1 for unknown repo" test_prof_02c

# =========================================================================
# PROF-02d: create_profile prompts for .repo and persists the value (HAPPY PATH)
# Exercises the REAL bin/claude-secure create_profile (not create_test_profile helper)
# via piped stdin. Will RED until Plan 29-02 patches bin/claude-secure with the prompt.
# =========================================================================
test_prof_02d_create_profile_prompts_for_repo() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Stdin sequence after 29-02:
  #   line 1: ""               -> accept default workspace
  #   line 2: "owner/my-repo"  -> NEW repo prompt
  #   line 3: "1"              -> auth choice = OAuth
  #   line 4: "oauth-token-xyz" -> OAuth token
  printf '\nowner/my-repo\n1\noauth-token-xyz\n' | create_profile "myproj-d" >/dev/null 2>&1

  local pdir="$CONFIG_DIR/profiles/myproj-d"
  [ -f "$pdir/profile.json" ] || return 1
  local repo
  repo=$(jq -r '.repo // empty' "$pdir/profile.json")
  [ "$repo" = "owner/my-repo" ] || return 1
  return 0
}
run_test "PROF-02d: create_profile prompts for and persists .repo field" test_prof_02d_create_profile_prompts_for_repo

# =========================================================================
# PROF-02e: create_profile skip path -- empty repo input means no .repo key
# Back-compat guard: pre-PROF-02 profiles omit .repo entirely, and skip path
# must still produce a profile with no .repo key.
# =========================================================================
test_prof_02e_create_profile_skip_repo() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Stdin sequence: workspace default, BLANK repo (skip), auth=OAuth, token
  printf '\n\n1\noauth-token-xyz\n' | create_profile "myproj-e" >/dev/null 2>&1

  local pdir="$CONFIG_DIR/profiles/myproj-e"
  [ -f "$pdir/profile.json" ] || return 1
  # Positive assertion: workspace was still written (proves flow ran to completion
  # through all 4 prompts, not that it hung at prompt 2)
  local ws
  ws=$(jq -r '.workspace // empty' "$pdir/profile.json")
  [ -n "$ws" ] || return 1
  # Skip path assertion: .repo key must be absent or empty
  local repo
  repo=$(jq -r '.repo // empty' "$pdir/profile.json")
  [ -z "$repo" ] || return 1
  # Additional guard: .env was written (proves setup_profile_auth ran — i.e. the
  # blank "skip" line was consumed by the repo prompt, not the auth choice prompt)
  [ -f "$pdir/.env" ] || return 1
  return 0
}
run_test "PROF-02e: create_profile allows skipping .repo (empty input)" test_prof_02e_create_profile_skip_repo

# =========================================================================
# PROF-02f: create_profile warns on malformed repo but still saves value verbatim
# Warn-don't-block policy (29-RESEARCH.md Pitfall 3 + Architecture Pattern 2).
# =========================================================================
test_prof_02f_create_profile_warns_on_bad_format() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local stderr_log="$tmpdir/stderr.log"
  # Capture stderr to a file; the garbage repo value must still persist
  printf '\nnot-a-valid-repo-format\n1\noauth-token-xyz\n' \
    | create_profile "myproj-f" >/dev/null 2>"$stderr_log"

  local pdir="$CONFIG_DIR/profiles/myproj-f"
  [ -f "$pdir/profile.json" ] || return 1
  # Warning string present on stderr
  grep -q 'Warning' "$stderr_log" || return 1
  # Value saved verbatim (warn-don't-block)
  local repo
  repo=$(jq -r '.repo // empty' "$pdir/profile.json")
  [ "$repo" = "not-a-valid-repo-format" ] || return 1
  return 0
}
run_test "PROF-02f: create_profile warns on bad repo format but saves" test_prof_02f_create_profile_warns_on_bad_format

# =========================================================================
# PROF-03a: validate_profile with missing profile directory -> exit 1
# =========================================================================
test_prof_03a() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local output
  output=$(validate_profile "nonexistent" 2>&1) && return 1
  echo "$output" | grep -qi "ERROR" || return 1
  return 0
}
run_test "PROF-03a: validate_profile fails on missing profile directory" test_prof_03a

# =========================================================================
# PROF-03b: validate_profile with missing profile.json -> exit 1
# =========================================================================
test_prof_03b() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  # Create profile dir but no profile.json
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"
  echo '{"secrets":[]}' > "$tmpdir/.claude-secure/profiles/badprof/whitelist.json"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03b: validate_profile fails on missing profile.json" test_prof_03b

# =========================================================================
# PROF-03c: validate_profile with invalid JSON in profile.json -> exit 1
# =========================================================================
test_prof_03c() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo "not json" > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"
  echo '{"secrets":[]}' > "$tmpdir/.claude-secure/profiles/badprof/whitelist.json"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03c: validate_profile fails on invalid JSON in profile.json" test_prof_03c

# =========================================================================
# PROF-03d: validate_profile with missing workspace field -> exit 1
# =========================================================================
test_prof_03d() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  echo '{}' > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"
  echo '{"secrets":[]}' > "$tmpdir/.claude-secure/profiles/badprof/whitelist.json"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03d: validate_profile fails on missing workspace field" test_prof_03d

# =========================================================================
# PROF-03e: validate_profile with nonexistent workspace path -> exit 1
# =========================================================================
test_prof_03e() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "/nonexistent/path/$$" '{"workspace":$ws}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"
  echo '{"secrets":[]}' > "$tmpdir/.claude-secure/profiles/badprof/whitelist.json"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03e: validate_profile fails on nonexistent workspace path" test_prof_03e

# =========================================================================
# PROF-03f: validate_profile with missing .env -> exit 1
# =========================================================================
test_prof_03f() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local ws="$tmpdir/ws-badprof"
  mkdir -p "$ws"
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "$ws" '{"workspace":$ws}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  # No .env file
  echo '{"secrets":[]}' > "$tmpdir/.claude-secure/profiles/badprof/whitelist.json"

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03f: validate_profile fails on missing .env" test_prof_03f

# =========================================================================
# PROF-03g: validate_profile with missing whitelist.json -> exit 1
# =========================================================================
test_prof_03g() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _source_functions "$tmpdir"

  local ws="$tmpdir/ws-badprof"
  mkdir -p "$ws"
  mkdir -p "$tmpdir/.claude-secure/profiles/badprof"
  jq -n --arg ws "$ws" '{"workspace":$ws}' \
    > "$tmpdir/.claude-secure/profiles/badprof/profile.json"
  echo "ANTHROPIC_API_KEY=test" > "$tmpdir/.claude-secure/profiles/badprof/.env"
  # No whitelist.json

  validate_profile "badprof" && return 1
  return 0
}
run_test "PROF-03g: validate_profile fails on missing whitelist.json" test_prof_03g

# =========================================================================
# SUPER-01: Merged whitelist contains secrets from multiple profiles
# =========================================================================
test_super_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  # Create two profiles with different whitelist secrets
  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Give them distinct whitelist entries
  cat > "$tmpdir/.claude-secure/profiles/proj-a/whitelist.json" <<'EOF'
{
  "secrets": [{"placeholder": "PH_GH", "env_var": "GITHUB_TOKEN", "allowed_domains": ["github.com"]}],
  "readonly_domains": ["google.com"]
}
EOF
  cat > "$tmpdir/.claude-secure/profiles/proj-b/whitelist.json" <<'EOF'
{
  "secrets": [{"placeholder": "PH_STRIPE", "env_var": "STRIPE_KEY", "allowed_domains": ["stripe.com"]}],
  "readonly_domains": ["stackoverflow.com"]
}
EOF

  _source_functions "$tmpdir"

  local merged
  merged=$(merge_whitelists)

  # Should contain both secrets
  echo "$merged" | jq -e '.secrets | length == 2' >/dev/null || return 1
  echo "$merged" | jq -e '.secrets[] | select(.env_var == "GITHUB_TOKEN")' >/dev/null || return 1
  echo "$merged" | jq -e '.secrets[] | select(.env_var == "STRIPE_KEY")' >/dev/null || return 1
  return 0
}
run_test "SUPER-01: Merged whitelist contains secrets from multiple profiles" test_super_01

# =========================================================================
# SUPER-02: Merged .env contains keys from multiple profiles
# =========================================================================
test_super_02() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Give them distinct env content
  echo "GITHUB_TOKEN=gh_test_a" > "$tmpdir/.claude-secure/profiles/proj-a/.env"
  echo "STRIPE_KEY=sk_test_b" > "$tmpdir/.claude-secure/profiles/proj-b/.env"

  _source_functions "$tmpdir"

  local merged_path
  merged_path=$(merge_env_files)

  # Merged file should contain both keys
  grep -q "GITHUB_TOKEN=gh_test_a" "$merged_path" || return 1
  grep -q "STRIPE_KEY=sk_test_b" "$merged_path" || return 1

  rm -f "$merged_path"
  return 0
}
run_test "SUPER-02: Merged .env contains keys from multiple profiles" test_super_02

# =========================================================================
# SUPER-03: Merged whitelist deduplicates by env_var
# =========================================================================
test_super_03() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "proj-a" "$tmpdir/.claude-secure" "$tmpdir/ws-a"
  create_test_profile "proj-b" "$tmpdir/.claude-secure" "$tmpdir/ws-b"

  # Both profiles have GITHUB_TOKEN with different placeholders
  cat > "$tmpdir/.claude-secure/profiles/proj-a/whitelist.json" <<'EOF'
{
  "secrets": [{"placeholder": "PH_GH_A", "env_var": "GITHUB_TOKEN", "allowed_domains": ["github.com"]}],
  "readonly_domains": ["google.com"]
}
EOF
  cat > "$tmpdir/.claude-secure/profiles/proj-b/whitelist.json" <<'EOF'
{
  "secrets": [{"placeholder": "PH_GH_B", "env_var": "GITHUB_TOKEN", "allowed_domains": ["api.github.com"]}],
  "readonly_domains": ["google.com"]
}
EOF

  _source_functions "$tmpdir"

  local merged
  merged=$(merge_whitelists)

  # Should deduplicate: only 1 GITHUB_TOKEN entry
  local count
  count=$(echo "$merged" | jq '[.secrets[] | select(.env_var == "GITHUB_TOKEN")] | length')
  [ "$count" -eq 1 ] || return 1

  # readonly_domains should also be deduplicated
  local domain_count
  domain_count=$(echo "$merged" | jq '[.readonly_domains[] | select(. == "google.com")] | length')
  [ "$domain_count" -eq 1 ] || return 1
  return 0
}
run_test "SUPER-03: Merged whitelist deduplicates by env_var" test_super_03

# =========================================================================
# LIST-01: list command output contains column headers
# =========================================================================
test_list_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  create_test_profile "myproj" "$tmpdir/.claude-secure" "$tmpdir/ws-myproj" "owner/repo"
  _source_functions "$tmpdir"

  local output
  output=$(list_profiles 2>&1)

  echo "$output" | grep -q "PROFILE" || return 1
  echo "$output" | grep -q "REPO" || return 1
  echo "$output" | grep -q "WORKSPACE" || return 1
  echo "$output" | grep -q "STATUS" || return 1
  return 0
}
run_test "LIST-01: list command shows PROFILE, REPO, STATUS, WORKSPACE columns" test_list_01

# =========================================================================
# NOINSTANCE-01: --instance flag produces error
# =========================================================================
test_noinstance_01() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"

  local output
  output=$(HOME="$tmpdir" bash "$PROJECT_DIR/bin/claude-secure" --instance test 2>&1) && return 1
  echo "$output" | grep -qi "no longer supported\|ERROR\|unknown" || return 1
  return 0
}
run_test "NOINSTANCE-01: --instance flag produces error" test_noinstance_01

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL total)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
