#!/bin/bash
# test-phase7.sh -- Integration tests for Phase 7: Env-file Strategy
# Tests ENV-01 through ENV-05 against the live Docker environment
#
# Strategy: Create a temporary .env file with known test secrets, export
# SECRETS_FILE to point to it, then verify proxy gets secrets via env_file
# while claude container stays clean. Also tests dynamic secret addition
# and minimal .env operation.
#
# Usage: bash tests/test-phase7.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

report() {
  local id="$1"
  local desc="$2"
  local result="$3"

  printf "  %-10s %-60s " "$id" "$desc"
  if [ "$result" -eq 0 ]; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi
}

# Create temp files for test .env files
TEMP_ENV_FULL=$(mktemp)
TEMP_ENV_MINIMAL=$(mktemp)
TEMP_WORKSPACE=$(mktemp -d)

cleanup() {
  cd "$PROJECT_DIR"
  docker compose down >/dev/null 2>&1 || true
  rm -f "$TEMP_ENV_FULL" "$TEMP_ENV_MINIMAL"
  rm -rf "$TEMP_WORKSPACE"
}
trap cleanup EXIT

echo "========================================"
echo "  Phase 7 Integration Tests"
echo "  Env-file Strategy (ENV-01 -- ENV-05)"
echo "========================================"
echo ""

# --- Setup: create test .env with known secrets ---
echo "Creating test .env file..."
cat > "$TEMP_ENV_FULL" <<'EOF'
TEST_SECRET_ALPHA=alpha_secret_value_12345
GITHUB_TOKEN=ghp_test_token_for_phase7
EOF

export SECRETS_FILE="$TEMP_ENV_FULL"
export ANTHROPIC_API_KEY=sk-ant-test-phase7
export WORKSPACE_PATH="$TEMP_WORKSPACE"

echo "Building and starting containers..."
docker compose build --quiet proxy >/dev/null 2>&1 || { echo "FATAL: proxy build failed"; exit 1; }
docker compose up -d >/dev/null 2>&1 || { echo "FATAL: docker compose up failed"; exit 1; }

# Wait for proxy container to be ready
echo "Waiting for proxy container..."
READY=false
for i in $(seq 1 15); do
  if docker exec claude-proxy node -e "process.exit(0)" 2>/dev/null; then
    READY=true
    break
  fi
  sleep 1
done
if [ "$READY" != "true" ]; then
  echo "FATAL: proxy container not ready after 15s"
  docker compose logs proxy
  exit 1
fi
echo ""

echo "Running tests..."
echo ""

# =========================================================================
# ENV-01: Secrets from env_file are available in proxy container
# =========================================================================
result=$(docker compose exec -T proxy printenv TEST_SECRET_ALPHA 2>/dev/null)
test "$result" = "alpha_secret_value_12345"
report "ENV-01" "Secrets from env_file available in proxy" $?

# =========================================================================
# ENV-02: Adding new secret works without editing docker-compose.yml
# =========================================================================
# Verify TEST_SECRET_ALPHA is NOT in docker-compose.yml (proving dynamic loading)
! grep -q 'TEST_SECRET_ALPHA' docker-compose.yml
dc_check=$?
# AND it IS available in proxy (already proven by ENV-01, but verify again)
result=$(docker compose exec -T proxy printenv TEST_SECRET_ALPHA 2>/dev/null)
test "$result" = "alpha_secret_value_12345"
env_check=$?
# Both must pass
test "$dc_check" -eq 0 -a "$env_check" -eq 0
report "ENV-02" "New secret works without docker-compose.yml edit" $?

# =========================================================================
# ENV-03: Claude container HAS secret env vars (needed for tools like gh, git)
# Secrets are safe because proxy redacts them before sending to Anthropic
# =========================================================================
claude_env=$(docker compose exec -T claude env 2>/dev/null)
echo "$claude_env" | grep -q 'TEST_SECRET_ALPHA'
alpha_present=$?
echo "$claude_env" | grep -q 'GITHUB_TOKEN'
github_present=$?
test "$alpha_present" -eq 0 -a "$github_present" -eq 0
report "ENV-03" "Claude container has secret env vars for tooling" $?

# =========================================================================
# ENV-04: Proxy has secrets and whitelist for redaction
# =========================================================================
# Verify proxy has GITHUB_TOKEN from env_file
result=$(docker compose exec -T proxy printenv GITHUB_TOKEN 2>/dev/null)
test "$result" = "ghp_test_token_for_phase7"
has_token=$?
# Verify proxy can read whitelist (redaction config)
wl_check=$(docker compose exec -T proxy cat /etc/claude-secure/whitelist.json 2>/dev/null | jq -r '.secrets[0].env_var')
test "$wl_check" = "GITHUB_TOKEN"
has_whitelist=$?
test "$has_token" -eq 0 -a "$has_whitelist" -eq 0
report "ENV-04" "Proxy has secrets and whitelist for redaction" $?

# =========================================================================
# ENV-05: System works with minimal .env (auth only, no secrets)
# =========================================================================
docker compose down >/dev/null 2>&1

# Create minimal .env with only auth
echo "ANTHROPIC_API_KEY=sk-ant-test-minimal" > "$TEMP_ENV_MINIMAL"
export SECRETS_FILE="$TEMP_ENV_MINIMAL"
export ANTHROPIC_API_KEY=sk-ant-test-minimal

docker compose up -d >/dev/null 2>&1
# Wait for proxy to be ready
READY=false
for i in $(seq 1 15); do
  if docker exec claude-proxy node -e "process.exit(0)" 2>/dev/null; then
    READY=true
    break
  fi
  sleep 1
done

ENV05_RESULT=1
if [ "$READY" = "true" ]; then
  # Proxy should be running
  docker compose ps --status running --format '{{.Service}}' | grep -q proxy
  running=$?
  # Proxy should NOT have GITHUB_TOKEN
  ! docker compose exec -T proxy printenv GITHUB_TOKEN >/dev/null 2>&1
  no_github=$?
  # Proxy should NOT have TEST_SECRET_ALPHA
  ! docker compose exec -T proxy printenv TEST_SECRET_ALPHA >/dev/null 2>&1
  no_alpha=$?
  if [ "$running" -eq 0 ] && [ "$no_github" -eq 0 ] && [ "$no_alpha" -eq 0 ]; then
    ENV05_RESULT=0
  fi
fi
report "ENV-05" "System starts with auth-only .env (no secrets)" $ENV05_RESULT

# --- Summary ---
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
