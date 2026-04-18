#!/bin/bash
# test-bootstrap-docs.sh -- Unit tests for bootstrap-docs subcommand
# Tests BOOT-01 through BOOT-08
#
# Strategy: source bin/claude-secure with __CLAUDE_SECURE_SOURCE_ONLY=1 to
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

# Source CLI functions without executing main logic
_load_cli() {
  local cfg="$1"
  __CLAUDE_SECURE_SOURCE_ONLY=1 \
  CONFIG_DIR="$cfg" \
    bash -c "source '$PROJECT_DIR/bin/claude-secure'"
}

# Run cmd_bootstrap_docs in a subshell with an isolated CONFIG_DIR
_run_cmd() {
  local cfg="$1"; shift
  bash -c "
    __CLAUDE_SECURE_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-secure'
    cmd_bootstrap_docs $*
  "
}

echo "========================================"
echo "  Bootstrap-Docs Tests"
echo "  (BOOT-01 -- BOOT-08)"
echo "========================================"
echo ""

# =========================================================================
# BOOT-01: --set-repo writes docs-bootstrap.env with mode 600
# =========================================================================
test_set_repo_writes_env() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --set-repo https://github.com/test/vault.git >/dev/null
  local stored; stored=$(grep "^DOCS_BOOTSTRAP_REPO=" "$cfg/docs-bootstrap.env" | cut -d= -f2-)
  local mode; mode=$(stat -c "%a" "$cfg/docs-bootstrap.env")
  rm -rf "$cfg"
  [ "$stored" = "https://github.com/test/vault.git" ] && [ "$mode" = "600" ]
}
run_test "BOOT-01: --set-repo writes env file with mode 600" test_set_repo_writes_env

# =========================================================================
# BOOT-02: --set-token writes token, --set-branch writes branch
# =========================================================================
test_set_token_and_branch() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --set-token ghp_testtoken >/dev/null
  _run_cmd "$cfg" --set-branch develop >/dev/null
  local tok; tok=$(grep "^DOCS_BOOTSTRAP_TOKEN=" "$cfg/docs-bootstrap.env" | cut -d= -f2-)
  local branch; branch=$(grep "^DOCS_BOOTSTRAP_BRANCH=" "$cfg/docs-bootstrap.env" | cut -d= -f2-)
  rm -rf "$cfg"
  [ "$tok" = "ghp_testtoken" ] && [ "$branch" = "develop" ]
}
run_test "BOOT-02: --set-token and --set-branch write correct values" test_set_token_and_branch

# =========================================================================
# BOOT-03: updating one key does not overwrite others
# =========================================================================
test_set_key_preserves_others() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --set-repo https://github.com/test/vault.git >/dev/null
  _run_cmd "$cfg" --set-token ghp_abc >/dev/null
  # Update only branch
  _run_cmd "$cfg" --set-branch master >/dev/null
  local repo; repo=$(grep "^DOCS_BOOTSTRAP_REPO=" "$cfg/docs-bootstrap.env" | cut -d= -f2-)
  local tok; tok=$(grep "^DOCS_BOOTSTRAP_TOKEN=" "$cfg/docs-bootstrap.env" | cut -d= -f2-)
  rm -rf "$cfg"
  [ "$repo" = "https://github.com/test/vault.git" ] && [ "$tok" = "ghp_abc" ]
}
run_test "BOOT-03: updating one key preserves other keys" test_set_key_preserves_others

# =========================================================================
# BOOT-04: no repo configured → error exit + correct message
# =========================================================================
test_no_repo_configured_error() {
  local cfg; cfg=$(mktemp -d)
  local out rc=0
  out=$(bash -c "
    __CLAUDE_SECURE_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    source '$PROJECT_DIR/bin/claude-secure'
    cmd_bootstrap_docs projects/JAD 2>&1
  ") || rc=$?
  rm -rf "$cfg"
  echo "$out" | grep -q "docs repo not configured" && [ "$rc" -ne 0 ]
}
run_test "BOOT-04: no repo configured exits 1 with message" test_no_repo_configured_error

# =========================================================================
# BOOT-05: no path argument → usage error
# =========================================================================
test_no_path_arg_error() {
  local cfg; cfg=$(mktemp -d)
  _run_cmd "$cfg" --set-repo https://github.com/test/vault.git >/dev/null
  local rc=0
  _run_cmd "$cfg" 2>/dev/null || rc=$?
  rm -rf "$cfg"
  [ "$rc" -ne 0 ]
}
run_test "BOOT-05: no path argument exits non-zero" test_no_path_arg_error

# =========================================================================
# BOOT-06: path already exists in remote repo → error exit + correct message
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
    __CLAUDE_SECURE_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-secure'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_REPO 'file://$remote/repo.git'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_BRANCH 'main'
    cmd_bootstrap_docs projects/JAD 2>&1
  ") || rc=$?
  rm -rf "$cfg" "$remote"
  echo "$out" | grep -q "already exists" && [ "$rc" -ne 0 ]
}
run_test "BOOT-06: path already exists exits 1 with message" test_path_already_exists_error

# =========================================================================
# BOOT-07: successful end-to-end scaffold into local bare repo
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
    __CLAUDE_SECURE_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-secure'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_REPO 'file://$remote/repo.git'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_BRANCH 'main'
    cmd_bootstrap_docs projects/MYPROJECT >/dev/null 2>&1
  "

  # Verify files in remote
  local verify; verify=$(mktemp -d)
  git clone "file://$remote/repo.git" "$verify/repo" -q 2>/dev/null
  local ok=0
  for f in VISION.md GOALS.md AGREEMENTS.md TODOS.md TASKS.md \
            decisions/_template.md ideas/_template.md done/_template.md; do
    [ -f "$verify/repo/projects/MYPROJECT/$f" ] || { ok=1; break; }
  done
  rm -rf "$cfg" "$remote" "$verify"
  [ "$ok" -eq 0 ]
}
run_test "BOOT-07: end-to-end scaffold creates all files in remote repo" test_e2e_scaffold

# =========================================================================
# BOOT-08: no tmpdir remains after execution
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
    __CLAUDE_SECURE_SOURCE_ONLY=1
    CONFIG_DIR='$cfg'
    _CLEANUP_FILES=()
    cleanup() { for f in \"\${_CLEANUP_FILES[@]:-}\"; do rm -rf \"\$f\"; done; }
    trap cleanup EXIT
    source '$PROJECT_DIR/bin/claude-secure'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_REPO 'file://$remote/repo.git'
    _bootstrap_docs_set_config_key DOCS_BOOTSTRAP_BRANCH 'main'
    cmd_bootstrap_docs projects/CLEANUP >/dev/null 2>&1
  "
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "cs-bootstrap-*" 2>/dev/null | wc -l)
  rm -rf "$cfg" "$remote"
  [ "$after" -le "$before" ]
}
run_test "BOOT-08: no cs-bootstrap-* tmpdir remains after execution" test_no_tmpdir_after_run

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "========================================"
echo ""

[ "$FAIL" -eq 0 ]
