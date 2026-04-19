#!/usr/bin/env bash
# Phase 18 PORT-02: bash 4+ re-exec guard.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  if command -v brew >/dev/null 2>&1; then
    __brew_bash="$(brew --prefix 2>/dev/null)/bin/bash"
    if [ -x "$__brew_bash" ]; then
      exec "$__brew_bash" "$0" "$@"
    fi
  fi
  echo "ERROR: bash 4+ required. On macOS run: brew install bash" >&2
  exit 1
fi

set -uo pipefail

# Phase 18 PORT-01: source the platform library and bootstrap PATH on macOS.
__RUN_TESTS_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$__RUN_TESTS_SELF_DIR/lib/platform.sh" ]; then
  # shellcheck source=lib/platform.sh
  source "$__RUN_TESTS_SELF_DIR/lib/platform.sh"
  if command -v claude_secure_bootstrap_path >/dev/null 2>&1; then
    claude_secure_bootstrap_path || true
  fi
fi

# claude-secure test runner
# Convenience wrapper for running integration tests manually.
# chmod +x run-tests.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEST_DIR="$REPO_ROOT/tests"
TEST_ENV="$REPO_ROOT/tests/test.env"
TEST_PROFILE=$(mktemp)
cp "$REPO_ROOT/config/profile.json" "$TEST_PROFILE"
chmod 666 "$TEST_PROFILE"
trap 'rm -f "$TEST_PROFILE"' EXIT

echo ""
echo "========================================"
echo "  claude-secure test runner"
echo "========================================"

# Determine which tests to run
SELECTED_TESTS=()

if [ $# -gt 0 ]; then
  # Specific tests requested -- validate they exist
  for arg in "$@"; do
    if [ ! -f "$TEST_DIR/$arg" ]; then
      echo "ERROR: Test script not found: $arg"
      echo "Available: $(ls "$TEST_DIR"/test-phase*.sh 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
      exit 1
    fi
    SELECTED_TESTS+=("$arg")
  done
else
  # No args -- run all tests
  for t in "$TEST_DIR"/test-phase*.sh; do
    [ -f "$t" ] && SELECTED_TESTS+=("$(basename "$t")")
  done
fi

if [ ${#SELECTED_TESTS[@]} -eq 0 ]; then
  echo "No test suites found."
  exit 1
fi

echo "Instance: claude-test (isolated)"
echo "Suites:   ${#SELECTED_TESTS[@]} selected"
echo ""

# Set up isolated test instance (same env as pre-push hook)
export COMPOSE_PROJECT_NAME="claude-test"
export COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
export SECRETS_FILE="$TEST_ENV"
export PROFILE_PATH="$TEST_PROFILE"
export WORKSPACE_PATH="${TMPDIR:-/tmp}/claude-test-workspace"
export LOG_DIR="${TMPDIR:-/tmp}/claude-test-logs"
export LOG_HOOK=0

mkdir -p "$WORKSPACE_PATH" "$LOG_DIR"

# Run each suite with clean container state
SUITE_RESULTS=()
TOTAL_FAILED=0
TOTAL_PASSED=0
FATAL=0
RESULTS_FILE=$(mktemp)
trap 'rm -f "$TEST_PROFILE" "$RESULTS_FILE"' EXIT

for test_script in "${SELECTED_TESTS[@]}"; do
  test_name="${test_script%.sh}"
  echo "--- $test_name ---"

  docker compose down --volumes --remove-orphans --timeout 5 2>/dev/null || true

  # Each test script handles its own container startup (build + up + health checks),
  # so we only tear down between suites -- no redundant up here.
  TEST_OUTPUT=$(bash "$TEST_DIR/$test_script" 2>&1)
  TEST_EXIT=$?
  echo "$TEST_OUTPUT"
  echo "$TEST_OUTPUT" | grep -E '(PASS|FAIL)$' >> "$RESULTS_FILE"

  if [ "$TEST_EXIT" -eq 0 ]; then
    SUITE_RESULTS+=("$test_name PASS")
    ((TOTAL_PASSED++))
  else
    SUITE_RESULTS+=("$test_name FAIL")
    ((TOTAL_FAILED++))
  fi
  echo ""
done

# Teardown on success, leave running on failure
if [ "$TOTAL_FAILED" -eq 0 ] && [ "$FATAL" -eq 0 ]; then
  docker compose down --volumes --remove-orphans --timeout 5 2>/dev/null
  echo "========================================"
  echo "  All tests passed. Containers torn down."
  echo "========================================"
  exit 0
fi

# Summary table on failure
echo ""
echo "========================================"
echo "  Test Results"
echo "========================================"
echo ""
printf "  %-20s %s\n" "Suite" "Status"
printf "  %-20s %s\n" "-------------------" "------"
for result in "${SUITE_RESULTS[@]}"; do
  suite="${result% *}"
  status="${result##* }"
  printf "  %-20s %s\n" "$suite" "$status"
done

FAILED_LINES=$(grep -E 'FAIL$' "$RESULTS_FILE" 2>/dev/null || true)
if [ -n "$FAILED_LINES" ]; then
  echo ""
  echo "  Failed requirements:"
  echo "$FAILED_LINES"
fi

echo ""
echo "Containers left running for debugging:"
echo "  docker compose -p claude-test exec claude bash"
echo ""
echo "Tear down manually:"
echo "  docker compose -p claude-test down --volumes"
exit 1
