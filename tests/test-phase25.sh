#!/bin/bash
# tests/test-phase25.sh -- Phase 25 Context Read & Read-Only Bind Mount tests
# CTX-01 (sparse shallow clone + bind mount), CTX-02 (read works, write fails),
# CTX-03 (no-docs silent skip), CTX-04 (.git/ absent from mount).
#
# Wave 0 contract (Nyquist self-healing): the implementation tests MUST fail
# until Plans 02 and 03 land. Only structural tests pass in Wave 0:
#   - test_fixtures_exist
#   - test_compose_volume_entry
#   - test_test_map_registered
# Docker-gated integration tests SKIP cleanly when docker is unavailable.
#
# IMPORTANT (from 25-RESEARCH.md Pitfall 3): git clone against file:// URLs
# silently ignores --depth and --filter. Unit tests use file:// bare repos for
# speed and isolation; the real partial-clone code path is only exercised when
# a real HTTPS remote is used in manual testing.
#
# Usage:
#   bash tests/test-phase25.sh                       # run full suite
#   bash tests/test-phase25.sh test_fixtures_exist   # run single function

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

# Helper: create a bare git repo pre-seeded with projects/test-slug/{todo,
# architecture,vision,ideas}.md + specs/. Used as a file:// docs_repo URL for
# unit tests. Mirrors Phase 23 bare-repo setup pattern.
create_seeded_bare_repo() {
  local bare="$1"
  local seed="$TEST_TMPDIR/docs-seed-$(basename "$bare")"
  git init -q --bare "$bare"
  git clone -q "$bare" "$seed"
  (
    cd "$seed" \
      && git config user.email test@example.com \
      && git config user.name test \
      && git config commit.gpgsign false \
      && mkdir -p projects/test-slug/specs \
      && echo "# Todo" > projects/test-slug/todo.md \
      && echo "# Architecture" > projects/test-slug/architecture.md \
      && echo "# Vision" > projects/test-slug/vision.md \
      && echo "# Ideas" > projects/test-slug/ideas.md \
      && touch projects/test-slug/specs/.gitkeep \
      && git add -A \
      && git commit -qm init \
      && git push -q origin HEAD:main
  )
  rm -rf "$seed"
}

# Helper: rewrite a fixture profile's docs_repo to point at a local bare repo
# URL. Also aligns docs_branch and docs_project_dir to match the seeded layout.
point_profile_at_bare() {
  local profile_dir="$1" bare="$2" slug="${3:-projects/test-slug}"
  local url="file://$bare"
  local tmp
  tmp=$(mktemp)
  jq --arg url "$url" --arg slug "$slug" \
     '.docs_repo = $url | .docs_branch = "main" | .docs_project_dir = $slug' \
     "$profile_dir/profile.json" > "$tmp"
  mv "$tmp" "$profile_dir/profile.json"
}

# =========================================================================
# Wave 0 GREEN tests (Plan 01 fixtures + test-map entry + compose volume)
# =========================================================================

test_fixtures_exist() {
  # PASSES in Wave 0 (Plan 01 delivers the fixtures)
  [ -f "$PROJECT_DIR/tests/fixtures/profile-25-docs/profile.json" ]   || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-25-docs/.env" ]           || return 1
  [ -f "$PROJECT_DIR/tests/fixtures/profile-25-docs/whitelist.json" ] || return 1
  return 0
}

test_compose_volume_entry() {
  # PASSES in Wave 0 (Plan 01 adds the volume line). Literal grep on the
  # exact compose substitution string.
  grep -Fq '${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro' \
    "$PROJECT_DIR/docker-compose.yml"
}

test_test_map_registered() {
  # PASSES in Wave 0 (Plan 01 adds the CTX-01..CTX-04 entries)
  jq -e '.["CTX-01"] and .["CTX-02"] and .["CTX-03"] and .["CTX-04"]' \
    "$PROJECT_DIR/tests/test-map.json" > /dev/null
}

# =========================================================================
# CTX-01 unit tests (Plan 02 flips these from RED to GREEN)
# =========================================================================

test_fetch_docs_context_function_exists() {
  # FAILS in Wave 0 until Plan 02 defines fetch_docs_context in bin/claude-secure
  source_cs
  declare -F fetch_docs_context >/dev/null
}

test_fetch_docs_context_clone_flags() {
  # FAILS in Wave 0 until Plan 02 adds the sparse+shallow+partial clone flags.
  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  local body
  body=$(declare -f fetch_docs_context)
  echo "$body" | grep -q -- '--depth=1'        || return 1
  echo "$body" | grep -q -- '--filter=blob:none' || return 1
  echo "$body" | grep -q -- '--sparse'         || return 1
  echo "$body" | grep -q 'sparse-checkout set' || return 1
  return 0
}

test_fetch_docs_context_exports_path() {
  # FAILS in Wave 0 until Plan 02 implements fetch_docs_context end-to-end.
  local bare="$TEST_TMPDIR/ctx-export.git"
  create_seeded_bare_repo "$bare"
  install_fixture "profile-25-docs" "ctx-test-export"
  point_profile_at_bare "$CONFIG_DIR/profiles/ctx-test-export" "$bare"
  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=ctx-test-export load_profile_config ctx-test-export 2>/dev/null || return 1
  unset AGENT_DOCS_HOST_PATH
  fetch_docs_context 2>/dev/null || return 1
  [ -n "${AGENT_DOCS_HOST_PATH:-}" ]         || return 1
  [ -d "$AGENT_DOCS_HOST_PATH" ]             || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/todo.md" ]     || return 1
  return 0
}

# =========================================================================
# CTX-03 unit tests: no-docs silent-skip guard
# =========================================================================

test_fetch_docs_context_skips_silently_when_no_docs_repo() {
  # FAILS in Wave 0 until Plan 02 implements the no-docs guard.
  local pdir="$CONFIG_DIR/profiles/no-docs-skip"
  local ws="$TEST_TMPDIR/ws-no-docs-skip"
  mkdir -p "$pdir" "$ws"
  jq -n --arg ws "$ws" '{workspace: $ws, repo: "owner/no-docs"}' > "$pdir/profile.json"
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-no-docs" > "$pdir/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$pdir/whitelist.json"

  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=no-docs-skip load_profile_config no-docs-skip 2>/dev/null || return 1
  unset AGENT_DOCS_HOST_PATH
  rm -f "$TEST_TMPDIR/skip.err"
  fetch_docs_context 2>"$TEST_TMPDIR/skip.err" || return 1
  [ -z "${AGENT_DOCS_HOST_PATH:-}" ] || return 1
  grep -q 'fetch_docs_context: skipped' "$TEST_TMPDIR/skip.err" || return 1
  return 0
}

test_fetch_docs_context_emits_one_info_line_on_skip() {
  # FAILS in Wave 0 until Plan 02 emits exactly one info line on skip path.
  local pdir="$CONFIG_DIR/profiles/no-docs-one-line"
  local ws="$TEST_TMPDIR/ws-no-docs-one-line"
  mkdir -p "$pdir" "$ws"
  jq -n --arg ws "$ws" '{workspace: $ws, repo: "owner/no-docs"}' > "$pdir/profile.json"
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-no-docs" > "$pdir/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$pdir/whitelist.json"

  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=no-docs-one-line load_profile_config no-docs-one-line 2>/dev/null || return 1
  rm -f "$TEST_TMPDIR/one-line.err"
  fetch_docs_context 2>"$TEST_TMPDIR/one-line.err" || return 1
  local count
  count=$(grep -c 'fetch_docs_context: skipped' "$TEST_TMPDIR/one-line.err" || echo 0)
  [ "$count" = "1" ]
}

test_spawn_no_docs_does_not_invoke_git() {
  # FAILS in Wave 0 until Plan 02 guards the skip path (never reaches git).
  local pdir="$CONFIG_DIR/profiles/no-docs-no-git"
  local ws="$TEST_TMPDIR/ws-no-docs-no-git"
  mkdir -p "$pdir" "$ws"
  jq -n --arg ws "$ws" '{workspace: $ws, repo: "owner/no-docs"}' > "$pdir/profile.json"
  echo "CLAUDE_CODE_OAUTH_TOKEN=fake-no-docs" > "$pdir/.env"
  echo '{"secrets":[],"readonly_domains":[]}' > "$pdir/whitelist.json"

  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=no-docs-no-git load_profile_config no-docs-no-git 2>/dev/null || return 1

  # Shim git() to drop a sentinel if it is ever called on the skip path.
  rm -f "$TEST_TMPDIR/.git-called"
  git() { touch "$TEST_TMPDIR/.git-called"; command git "$@"; }
  export -f git

  fetch_docs_context 2>/dev/null || { unset -f git; return 1; }
  unset -f git

  if [ -e "$TEST_TMPDIR/.git-called" ]; then
    echo "FAIL: git was invoked on no-docs skip path" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# CTX-04 unit tests: mount source excludes .git/, PAT scrub on failure
# =========================================================================

test_fetch_docs_context_mount_source_excludes_git() {
  # FAILS in Wave 0 until Plan 02 copies the project subdir out of the clone
  # so the mount source has no .git/ directory.
  local bare="$TEST_TMPDIR/ctx-nogit.git"
  create_seeded_bare_repo "$bare"
  install_fixture "profile-25-docs" "ctx-nogit"
  point_profile_at_bare "$CONFIG_DIR/profiles/ctx-nogit" "$bare"

  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=ctx-nogit load_profile_config ctx-nogit 2>/dev/null || return 1
  unset AGENT_DOCS_HOST_PATH
  fetch_docs_context 2>/dev/null || return 1

  [ -n "${AGENT_DOCS_HOST_PATH:-}" ]   || return 1
  [ -d "$AGENT_DOCS_HOST_PATH" ]       || return 1
  if find "$AGENT_DOCS_HOST_PATH" -name '.git' -print -quit | grep -q .; then
    echo "FAIL: .git found under mount source $AGENT_DOCS_HOST_PATH" >&2
    return 1
  fi
  [ -f "$AGENT_DOCS_HOST_PATH/todo.md" ]         || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/architecture.md" ] || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/vision.md" ]       || return 1
  [ -f "$AGENT_DOCS_HOST_PATH/ideas.md" ]        || return 1
  return 0
}

test_fetch_docs_context_pat_scrub_on_clone_error() {
  # FAILS in Wave 0 until Plan 02 scrubs DOCS_REPO_TOKEN from clone stderr.
  install_fixture "profile-25-docs" "ctx-patscrub"
  local pdir="$CONFIG_DIR/profiles/ctx-patscrub"
  local bad_url="file:///nonexistent-ctx-patscrub-xxx.git"
  local tmp
  tmp=$(mktemp)
  jq --arg url "$bad_url" \
    '.docs_repo = $url | .docs_branch = "main" | .docs_project_dir = "projects/test-slug"' \
    "$pdir/profile.json" > "$tmp" && mv "$tmp" "$pdir/profile.json"

  source_cs
  declare -F fetch_docs_context >/dev/null || return 1
  PROFILE=ctx-patscrub load_profile_config ctx-patscrub 2>/dev/null || return 1
  export DOCS_REPO_TOKEN="fake-phase25-docs-token"
  unset AGENT_DOCS_HOST_PATH
  rm -f "$TEST_TMPDIR/clone.err"
  if fetch_docs_context 2>"$TEST_TMPDIR/clone.err"; then
    echo "FAIL: fetch_docs_context unexpectedly succeeded against missing repo" >&2
    return 1
  fi
  if grep -q 'fake-phase25-docs-token' "$TEST_TMPDIR/clone.err"; then
    echo "FAIL: DOCS_REPO_TOKEN leaked into stderr" >&2
    return 1
  fi
  # Accept either the REDACTED sentinel or at least the presence of any error
  # line (Plan 02 may choose either error-reporting style; both satisfy CTX-04).
  if ! grep -q '<REDACTED:DOCS_REPO_TOKEN>' "$TEST_TMPDIR/clone.err" && \
     ! grep -qiE 'error|fatal|fail' "$TEST_TMPDIR/clone.err"; then
    echo "FAIL: no error line and no REDACTED sentinel in clone stderr" >&2
    return 1
  fi
  return 0
}

# =========================================================================
# CTX-01 / CTX-02 / CTX-04 integration tests (docker-gated)
# Plan 03 flips these GREEN; on no-docker hosts they SKIP-as-PASS.
# =========================================================================

_docker_gate_or_skip() {
  command -v docker >/dev/null 2>&1 || { echo "    skip: docker not available"; return 1; }
  docker info       >/dev/null 2>&1 || { echo "    skip: docker daemon not running"; return 1; }
  return 0
}

_spawn_ctx_background() {
  # Helper for integration tests: seed a bare repo, install fixture, point at
  # bare, and background-spawn the container. Sets $SPAWN_PID and $SPAWN_PROJECT.
  local dest="$1"
  local bare="$TEST_TMPDIR/ctx-${dest}.git"
  create_seeded_bare_repo "$bare"
  install_fixture "profile-25-docs" "$dest"
  point_profile_at_bare "$CONFIG_DIR/profiles/$dest" "$bare"
  CLAUDE_SECURE_FAKE_CLAUDE_STDOUT=/dev/null \
    CLAUDE_SECURE_FAKE_CLAUDE_EXIT=0 \
    "$PROJECT_DIR/bin/claude-secure" --profile "$dest" spawn \
      --event '{"event_type":"manual","repository":{"full_name":"owner/test"}}' \
      >/dev/null 2>&1 &
  SPAWN_PID=$!
  # Wait for the claude container to actually enter the running state.
  # Fixed sleeps race on WSL2 where docker compose up -d --wait can exceed 2s.
  source_cs
  SPAWN_PROJECT=$(spawn_project_name "$dest" 2>/dev/null || echo "cs-${dest}")
  local _i
  for _i in $(seq 1 30); do
    if docker compose -p "$SPAWN_PROJECT" ps --status=running --services 2>/dev/null \
         | grep -Fxq claude; then
      break
    fi
    if ! kill -0 "$SPAWN_PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
}

_kill_spawn() {
  if [ -n "${SPAWN_PID:-}" ]; then
    kill "$SPAWN_PID" 2>/dev/null || true
    wait "$SPAWN_PID" 2>/dev/null || true
  fi
  if [ -n "${SPAWN_PROJECT:-}" ]; then
    docker compose -p "$SPAWN_PROJECT" down --remove-orphans >/dev/null 2>&1 || true
  fi
  unset SPAWN_PID SPAWN_PROJECT
}

test_agent_docs_read_works() {
  _docker_gate_or_skip || return 0
  _spawn_ctx_background "ctx-read-test" || { _kill_spawn; return 1; }
  local out
  out=$(docker compose -p "$SPAWN_PROJECT" exec -T claude cat /agent-docs/todo.md 2>&1)
  local rc=$?
  _kill_spawn
  [ "$rc" -eq 0 ] || return 1
  echo "$out" | grep -q '# Todo'
}

test_agent_docs_write_attempt_fails_readonly() {
  _docker_gate_or_skip || return 0
  _spawn_ctx_background "ctx-rw-test" || { _kill_spawn; return 1; }
  local write_err
  write_err=$(docker compose -p "$SPAWN_PROJECT" exec -T claude \
                touch /agent-docs/written.txt 2>&1) && {
    _kill_spawn
    echo "FAIL: write to /agent-docs/written.txt unexpectedly succeeded" >&2
    return 1
  }
  _kill_spawn
  echo "$write_err" | grep -qi 'read-only file system'
}

test_agent_docs_no_git_dir_in_container() {
  _docker_gate_or_skip || return 0
  _spawn_ctx_background "ctx-nogit-test" || { _kill_spawn; return 1; }
  # Guard: if the container is not actually reachable, fail loudly instead of
  # silently passing because both exec calls return non-zero.
  if ! docker compose -p "$SPAWN_PROJECT" exec -T claude true >/dev/null 2>&1; then
    _kill_spawn
    echo "FAIL: claude container not reachable via docker compose exec" >&2
    return 1
  fi
  docker compose -p "$SPAWN_PROJECT" exec -T claude ls /agent-docs/.git >/dev/null 2>&1 && {
    _kill_spawn
    echo "FAIL: /agent-docs/.git exists inside container" >&2
    return 1
  }
  _kill_spawn
  return 0
}

# =========================================================================
# Plan 03 wiring check: do_spawn must call fetch_docs_context
# =========================================================================

test_do_spawn_calls_fetch_docs_context() {
  # FAILS in Wave 0 until Plan 03 wires fetch_docs_context into do_spawn.
  source_cs
  declare -F do_spawn >/dev/null || return 1
  declare -f do_spawn | grep -q 'fetch_docs_context'
}

# =========================================================================
# Test runner
# =========================================================================

if [ $# -gt 0 ]; then
  # Single-test invocation (for targeted re-runs during Plans 02/03)
  "$@"
  exit $?
fi

run_test "fixtures exist"                                    test_fixtures_exist
run_test "compose volume entry present"                      test_compose_volume_entry
run_test "test-map registered"                               test_test_map_registered
run_test "fetch_docs_context function exists"                test_fetch_docs_context_function_exists
run_test "fetch_docs_context clone flags"                    test_fetch_docs_context_clone_flags
run_test "fetch_docs_context exports path"                   test_fetch_docs_context_exports_path
run_test "fetch_docs_context skips silently no docs repo"    test_fetch_docs_context_skips_silently_when_no_docs_repo
run_test "fetch_docs_context emits one info line on skip"    test_fetch_docs_context_emits_one_info_line_on_skip
run_test "spawn no docs does not invoke git"                 test_spawn_no_docs_does_not_invoke_git
run_test "mount source excludes .git"                        test_fetch_docs_context_mount_source_excludes_git
run_test "pat scrub on clone error"                          test_fetch_docs_context_pat_scrub_on_clone_error
run_test "agent-docs read works (docker)"                    test_agent_docs_read_works
run_test "agent-docs write fails readonly (docker)"          test_agent_docs_write_attempt_fails_readonly
run_test "agent-docs no .git in container (docker)"          test_agent_docs_no_git_dir_in_container
run_test "do_spawn calls fetch_docs_context"                 test_do_spawn_calls_fetch_docs_context

echo
echo "Phase 25 tests: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
