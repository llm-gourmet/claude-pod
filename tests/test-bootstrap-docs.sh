#!/bin/bash
# test-bootstrap-docs.sh -- Unit tests for bootstrap-docs subcommand
# Tests BOOT-01 through BOOT-15
#
# Strategy: source bin/claude-pod with __CLAUDE_POD_SOURCE_ONLY=1 to
# load function definitions, use temp dirs as CONFIG_DIR and local bare repos
# as git remote. No Docker, no real credentials needed.
#
# Usage: bash tests/test-bootstrap-docs.sh
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

# Run cmd_bootstrap_docs in a subshell with an isolated CONFIG_DIR
_run_cmd() {
  local cfg="$1"; shift
  bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs $*
  "
}

echo "========================================"
echo "  Bootstrap-Docs Tests"
echo "  (BOOT-01 -- BOOT-15)"
echo "========================================"
echo ""

# =========================================================================
# BOOT-01: --add-connection creates connections.json with mode 600
# =========================================================================
test_add_connection_creates_file() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local f="$cfg/docs-bootstrap/connections.json"
  local mode; mode=$(stat -c "%a" "$f")
  local dir_mode; dir_mode=$(stat -c "%a" "$cfg/docs-bootstrap")
  rm -rf "$cfg"
  [ "$mode" = "600" ] && [ "$dir_mode" = "700" ]
}
run_test "BOOT-01: --add-connection creates file mode 600, dir mode 700" test_add_connection_creates_file

# =========================================================================
# BOOT-02: --add-connection stores correct fields; branch defaults to main
# =========================================================================
test_add_connection_fields() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local f="$cfg/docs-bootstrap/connections.json"
  local name repo branch
  name=$(jq -r '.[0].name' "$f")
  repo=$(jq -r '.[0].repo' "$f")
  branch=$(jq -r '.[0].branch' "$f")
  rm -rf "$cfg"
  [ "$name" = "work-docs" ] && [ "$repo" = "https://github.com/org/docs" ] && [ "$branch" = "main" ]
}
run_test "BOOT-02: --add-connection stores name/repo/branch; branch defaults to main" test_add_connection_fields

# =========================================================================
# BOOT-03: --add-connection with explicit --branch stores that branch
# =========================================================================
test_add_connection_explicit_branch() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name kb \
    --repo https://github.com/user/kb --token ghp_yyy --branch dev >/dev/null
  local branch; branch=$(jq -r '.[0].branch' "$cfg/docs-bootstrap/connections.json")
  rm -rf "$cfg"
  [ "$branch" = "dev" ]
}
run_test "BOOT-03: --add-connection --branch stores explicit branch" test_add_connection_explicit_branch

# =========================================================================
# BOOT-04: --add-connection rejects duplicate name
# =========================================================================
test_add_connection_duplicate() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --add-connection --name work-docs \
      --repo https://github.com/org/docs2 --token ghp_yyy 2>&1
  ") || rc=$?
  local count; count=$(jq 'length' "$cfg/docs-bootstrap/connections.json")
  rm -rf "$cfg"
  echo "$out" | grep -q "already exists" && [ "$rc" -ne 0 ] && [ "$count" -eq 1 ]
}
run_test "BOOT-04: --add-connection duplicate name exits 1 with message, file unchanged" test_add_connection_duplicate

# =========================================================================
# BOOT-05: --add-connection missing required args exits non-zero
# =========================================================================
test_add_connection_missing_args() {
  local cfg; cfg=$(mktemp -d)
  local rc=0
  _run_cmd "$cfg" --add-connection --name work-docs --repo https://github.com/org/docs \
    2>/dev/null || rc=$?
  rm -rf "$cfg"
  [ "$rc" -ne 0 ]
}
run_test "BOOT-05: --add-connection missing --token exits non-zero" test_add_connection_missing_args

# =========================================================================
# BOOT-06: --remove-connection removes known connection
# =========================================================================
test_remove_connection_success() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  _run_cmd "$cfg" --add-connection --name personal \
    --repo https://github.com/user/kb --token ghp_yyy >/dev/null
  _run_cmd "$cfg" --remove-connection work-docs >/dev/null
  local count; count=$(jq 'length' "$cfg/docs-bootstrap/connections.json")
  local remaining; remaining=$(jq -r '.[0].name' "$cfg/docs-bootstrap/connections.json")
  rm -rf "$cfg"
  [ "$count" -eq 1 ] && [ "$remaining" = "personal" ]
}
run_test "BOOT-06: --remove-connection removes the named connection" test_remove_connection_success

# =========================================================================
# BOOT-07: --remove-connection unknown name exits 1 with message
# =========================================================================
test_remove_connection_unknown() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --remove-connection nonexistent 2>&1
  ") || rc=$?
  rm -rf "$cfg"
  echo "$out" | grep -q "not found" && [ "$rc" -ne 0 ]
}
run_test "BOOT-07: --remove-connection unknown name exits 1 with message" test_remove_connection_unknown

# =========================================================================
# BOOT-08: --list-connections shows name/repo/branch, no token
# =========================================================================
test_list_connections_output() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_secret --branch main >/dev/null
  local out
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --list-connections 2>&1
  ")
  rm -rf "$cfg"
  echo "$out" | grep -q "work-docs" && \
  echo "$out" | grep -q "https://github.com/org/docs" && \
  echo "$out" | grep -q "main" && \
  ! echo "$out" | grep -q "ghp_secret"
}
run_test "BOOT-08: --list-connections shows name/repo/branch, not token" test_list_connections_output

# =========================================================================
# BOOT-09: --list-connections with no connections prints empty message
# =========================================================================
test_list_connections_empty() {
  local cfg; cfg=$(mktemp -d)
  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --list-connections 2>&1
  ") || rc=$?
  rm -rf "$cfg"
  echo "$out" | grep -q "No connections configured" && [ "$rc" -eq 0 ]
}
run_test "BOOT-09: --list-connections empty prints message and exits 0" test_list_connections_empty

# =========================================================================
# BOOT-10: bootstrap without --connection exits 1 with error + hint
# =========================================================================
test_missing_connection_flag() {
  local cfg; cfg=$(mktemp -d)
  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs projects/JAD 2>&1
  ") || rc=$?
  rm -rf "$cfg"
  echo "$out" | grep -q "\\-\\-connection.*required" && [ "$rc" -ne 0 ]
}
run_test "BOOT-10: missing --connection exits 1 with error" test_missing_connection_flag

# =========================================================================
# BOOT-11: bootstrap with unknown --connection name exits 1 with message
# =========================================================================
test_unknown_connection_name() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --connection nosuchname projects/JAD 2>&1
  ") || rc=$?
  rm -rf "$cfg"
  echo "$out" | grep -q "not found" && [ "$rc" -ne 0 ]
}
run_test "BOOT-11: --connection unknown name exits 1 with message" test_unknown_connection_name

# =========================================================================
# BOOT-12: no path argument → usage error
# =========================================================================
test_no_path_arg_error() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --add-connection --name work-docs \
    --repo https://github.com/org/docs --token ghp_xxx >/dev/null
  local rc=0
  _run_cmd "$cfg" --connection work-docs 2>/dev/null || rc=$?
  rm -rf "$cfg"
  [ "$rc" -ne 0 ]
}
run_test "BOOT-12: no path argument exits non-zero" test_no_path_arg_error

# =========================================================================
# BOOT-13: path already exists in remote repo → error exit + correct message
# =========================================================================
test_path_already_exists_error() {
  local cfg; cfg=$(mktemp -d)
  local remote; remote=$(mktemp -d)

  git -c init.defaultBranch=main init --bare "$remote/repo.git" -q
  local work; work=$(mktemp -d)
  git -c init.defaultBranch=main init "$work" -q
  git -C "$work" -c user.email=t@t -c user.name=T commit --allow-empty -m "init" -q
  git -C "$work" push "$remote/repo.git" HEAD:main -q 2>/dev/null

  # Pre-create the target path
  local clone; clone=$(mktemp -d)
  git clone "file://$remote/repo.git" "$clone/repo" -q 2>/dev/null
  mkdir -p "$clone/repo/projects/JAD"
  touch "$clone/repo/projects/JAD/.keep"
  git -C "$clone/repo" add projects/JAD
  git -C "$clone/repo" -c user.email=t@t -c user.name=T commit -m "pre" -q
  git -C "$clone/repo" push origin main -q 2>/dev/null
  rm -rf "$clone" "$work"

  local out rc=0
  out=$(bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --add-connection --name testconn \
      --repo 'file://$remote/repo.git' --token dummy-token --branch main >/dev/null
    cmd_bootstrap_docs --connection testconn projects/JAD 2>&1
  ") || rc=$?
  rm -rf "$cfg" "$remote"
  echo "$out" | grep -q "already exists" && [ "$rc" -ne 0 ]
}
run_test "BOOT-13: path already exists exits 1 with message" test_path_already_exists_error

# =========================================================================
# BOOT-14: successful end-to-end scaffold into local bare repo
# =========================================================================
test_e2e_scaffold() {
  local cfg; cfg=$(mktemp -d)
  local remote; remote=$(mktemp -d)

  git -c init.defaultBranch=main init --bare "$remote/repo.git" -q
  local work; work=$(mktemp -d)
  git -c init.defaultBranch=main init "$work" -q
  git -C "$work" -c user.email=t@t -c user.name=T commit --allow-empty -m "init" -q
  git -C "$work" push "$remote/repo.git" HEAD:main -q 2>/dev/null
  rm -rf "$work"

  bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --add-connection --name testconn \
      --repo 'file://$remote/repo.git' --token dummy-token --branch main >/dev/null
    cmd_bootstrap_docs --connection testconn projects/MYPROJECT >/dev/null 2>&1
  "

  # Verify files in remote
  local verify; verify=$(mktemp -d)
  git clone "file://$remote/repo.git" "$verify/repo" -q 2>/dev/null
  local ok=0
  for f in VISION.md AGREEMENTS.md TODOS.md TASKS.md \
            decisions/_template.md ideas/_template.md done/_template.md; do
    [ -f "$verify/repo/projects/MYPROJECT/$f" ] || { ok=1; break; }
  done
  rm -rf "$cfg" "$remote" "$verify"
  [ "$ok" -eq 0 ]
}
run_test "BOOT-14: end-to-end scaffold creates all files in remote repo" test_e2e_scaffold

# =========================================================================
# BOOT-15: no tmpdir remains after execution
# =========================================================================
test_no_tmpdir_after_run() {
  local cfg; cfg=$(mktemp -d)
  local remote; remote=$(mktemp -d)

  git -c init.defaultBranch=main init --bare "$remote/repo.git" -q
  local work; work=$(mktemp -d)
  git -c init.defaultBranch=main init "$work" -q
  git -C "$work" -c user.email=t@t -c user.name=T commit --allow-empty -m "init" -q
  git -C "$work" push "$remote/repo.git" HEAD:main -q 2>/dev/null
  rm -rf "$work"

  local before after
  before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "cs-bootstrap-*" 2>/dev/null | wc -l)
  bash -c "
    __CLAUDE_POD_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-pod'
    cmd_bootstrap_docs --add-connection --name testconn \
      --repo 'file://$remote/repo.git' --token dummy-token --branch main >/dev/null
    cmd_bootstrap_docs --connection testconn projects/CLEANUP >/dev/null 2>&1
  "
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "cs-bootstrap-*" 2>/dev/null | wc -l)
  rm -rf "$cfg" "$remote"
  [ "$after" -le "$before" ]
}
run_test "BOOT-15: no cs-bootstrap-* tmpdir remains after execution" test_no_tmpdir_after_run

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"
echo ""

[ "$FAIL" -eq 0 ]
