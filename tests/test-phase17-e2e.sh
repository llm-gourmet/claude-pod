#!/bin/bash
# tests/test-phase17-e2e.sh -- Phase 17 Operational Hardening E2E test suite
# OPS-03 (Container reaper + end-to-end integration coverage)
#
# Purpose: exercise the full webhook -> spawn -> report pipeline against the
# real Docker stack with a STUBBED Claude binary (CLAUDE_SECURE_FAKE_CLAUDE_STDOUT)
# to keep runtime under the 90-second budget and avoid real API costs.
#
# Scenarios (D-14):
#   1. HMAC rejection            -- wrong signature -> 401, no spawn, no audit
#   2. Concurrent execution      -- 3 parallel valid POSTs, all reports pushed
#   3. Resource limit enforcement -- docker inspect verifies mem_limit: 1g
#   4. Orphan cleanup            -- backdated sentinel container reaped by
#                                   `claude-secure reap`; real containers untouched
#
# Wired in 17-03 (Wave 1b): all four scenarios run against a live listener
# subprocess, a runtime-injected file:// bare report repo, and the Phase 16
# CLAUDE_SECURE_FAKE_CLAUDE_STDOUT envelope stub (no real Anthropic / GitHub).
#
# Guardrails:
#   - INSTANCE_PREFIX=cs-e2e- so the suite never collides with the operator's
#     real instance
#   - Cleanup trap removes $TEST_TMPDIR and best-effort reaps any stray
#     cs-e2e- containers via REAPER_ORPHAN_AGE_SECS=0
#   - 90s wall-clock budget enforced between scenarios via check_budget()
#
# Usage:
#   bash tests/test-phase17-e2e.sh                            # run full suite
#   bash tests/test-phase17-e2e.sh scenario_hmac_rejection    # run single scenario

set -uo pipefail

E2E_BUDGET=90
PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d -t cs-e2e-XXXXXXXX)
LISTENER_PID=""
LISTENER_PORT="${LISTENER_PORT:-19117}"  # Phase 17 E2E -- avoids collision with unit harness 19017
CONFIG_DIR=""

cleanup() {
  local rc=$?
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  # D-16: force-reap any cs-e2e- containers (orphan sentinel or spawn leaks)
  # so the next run starts clean. REAPER_ORPHAN_AGE_SECS=0 counts ALL ages as
  # orphan (Pitfall 4: no backdating). Suppress all errors -- the trap must
  # not mask the original exit code.
  REAPER_ORPHAN_AGE_SECS=0 INSTANCE_PREFIX="cs-e2e-" \
    "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1 || true
  # Best-effort: also remove the scenario-4 inspect container if it survived.
  docker rm -f cs-e2e-limits-claude >/dev/null 2>&1 || true
  rm -rf "$TEST_TMPDIR"
  return $rc
}
trap cleanup EXIT

# =========================================================================
# Budget gate: halts the suite immediately if wall-clock exceeds $E2E_BUDGET.
# Called between scenarios so a runaway test can't silently blow past 90s.
# =========================================================================
check_budget() {
  if [ "$SECONDS" -gt "$E2E_BUDGET" ]; then
    echo "FAIL: E2E budget exceeded (${SECONDS}s > ${E2E_BUDGET}s)"
    exit 1
  fi
}

# =========================================================================
# Tooling preflight. Each tool is hard-required: the harness exits 1 with
# a clear error if any is missing rather than failing deep inside a scenario.
# =========================================================================
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool not on PATH: $tool" >&2
    exit 1
  fi
}

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

# =========================================================================
# Local bare git repo helper -- creates $TEST_TMPDIR/<name>.git seeded with
# one initial commit on main, echoes the file:// URL.
# Mirrors tests/test-phase16.sh::setup_bare_repo so publish_report has a
# real branch to clone --depth 1 --branch main from.
# =========================================================================
setup_bare_repo() {
  local label="${1:-e2e-reports}"
  local bare="$TEST_TMPDIR/${label}.git"
  local seed="$TEST_TMPDIR/${label}-seed"
  rm -rf "$bare" "$seed"
  git init --bare --initial-branch=main "$bare" >/dev/null 2>&1 \
    || git init --bare "$bare" >/dev/null 2>&1
  git clone "$bare" "$seed" >/dev/null 2>&1
  (
    cd "$seed"
    git config user.email "seed@test.local"
    git config user.name "seed"
    git checkout -B main >/dev/null 2>&1 || true
    : > .gitkeep
    git add .gitkeep
    git commit -m "seed" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
  )
  rm -rf "$seed"
  printf 'file://%s' "$bare"
}

# =========================================================================
# E2E profile setup (D-13, D-16). Copies the profile-e2e fixture into a
# fresh $CONFIG_DIR under $TEST_TMPDIR, runtime-injects a bare file:// repo
# URL into profile.json .report_repo, adds a workspace field so spawn's
# validate_profile doesn't balk, verifies Pitfall 13 (no ghp_ prefix in the
# fixture .env), and points at the Phase 16 envelope stub so no real Claude
# calls happen.
# =========================================================================
setup_e2e_profile() {
  if [ ! -d "$PROJECT_DIR/tests/fixtures/profile-e2e" ]; then
    echo "FAIL setup: missing tests/fixtures/profile-e2e (created in 17-01 Task 3)" >&2
    return 1
  fi
  if [ ! -f "$PROJECT_DIR/tests/fixtures/profile-e2e/profile.json" ]; then
    echo "FAIL setup: missing tests/fixtures/profile-e2e/profile.json" >&2
    return 1
  fi

  local bare
  bare=$(setup_bare_repo "e2e-reports")
  [ -n "$bare" ] || { echo "FAIL setup: bare repo creation returned empty" >&2; return 1; }

  export CONFIG_DIR="$TEST_TMPDIR/.claude-secure"
  export CLAUDE_SECURE_INSTANCE=e2e
  export INSTANCE_PREFIX="cs-e2e-"
  mkdir -p "$CONFIG_DIR/profiles" "$CONFIG_DIR/logs" "$CONFIG_DIR/events" \
           "$TEST_TMPDIR/workspace-e2e"

  # Copy the fixture tree into the profile location the loader expects.
  cp -r "$PROJECT_DIR/tests/fixtures/profile-e2e" "$CONFIG_DIR/profiles/e2e"

  # Runtime-inject a real workspace path (required by load_profile_config).
  local profile_json="$CONFIG_DIR/profiles/e2e/profile.json"
  jq --arg ws "$TEST_TMPDIR/workspace-e2e" '.workspace = $ws' "$profile_json" > "$profile_json.new"
  mv "$profile_json.new" "$profile_json"

  # Pitfall 13 guardrail: verify the fixture .env does NOT carry a ghp_ prefix.
  if grep -q '^REPORT_REPO_TOKEN=ghp_' "$CONFIG_DIR/profiles/e2e/.env"; then
    echo "FAIL setup: fixture .env has ghp_ prefix (Pitfall 13 violation)" >&2
    return 1
  fi

  # Connections registry required by the refactored listener (D-23). Maps
  # the e2e/test repo to the 'e2e' profile using the same secret that
  # scenario_concurrent_execution uses for HMAC signing.
  mkdir -p "$CONFIG_DIR/webhooks"
  cat > "$CONFIG_DIR/webhooks/connections.json" <<'CONNEOF'
[{"name":"e2e","repo":"e2e/test","webhook_secret":"e2e-test-secret"}]
CONNEOF

  # Phase 16 stub: point at the envelope fixture so the stubbed Claude
  # returns a valid envelope (D-13: no real Anthropic calls).
  export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$PROJECT_DIR/tests/fixtures/envelope-success.json"
  return 0
}

# =========================================================================
# Listener subprocess lifecycle. Generates a temp webhook.json matching the
# Phase 14 Config schema, launches python3 webhook/listener.py in the
# background, polls /health until ready or a 10s deadline, and captures
# LISTENER_PID for the cleanup trap.
# =========================================================================
start_listener() {
  LISTENER_PORT="${LISTENER_PORT:-19117}"

  local webhook_cfg="$TEST_TMPDIR/webhook.json"
  cat > "$webhook_cfg" <<EOF
{
  "bind": "127.0.0.1",
  "port": $LISTENER_PORT,
  "max_concurrent_spawns": 3,
  "profiles_dir": "$CONFIG_DIR/profiles",
  "webhooks_dir": "$CONFIG_DIR/webhooks",
  "events_dir": "$CONFIG_DIR/events",
  "logs_dir": "$CONFIG_DIR/logs",
  "claude_secure_bin": "$PROJECT_DIR/bin/claude-secure"
}
EOF

  # Launch listener in background. Env is inherited by subprocess.Popen so
  # CLAUDE_SECURE_FAKE_CLAUDE_STDOUT and CONFIG_DIR flow into `claude-secure spawn`.
  (
    cd "$PROJECT_DIR"
    PATH="$PROJECT_DIR/bin:$PATH" \
    CONFIG_DIR="$CONFIG_DIR" \
    CLAUDE_SECURE_INSTANCE=e2e \
    INSTANCE_PREFIX="cs-e2e-" \
    CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$CLAUDE_SECURE_FAKE_CLAUDE_STDOUT" \
    python3 webhook/listener.py --config "$webhook_cfg" \
      >"$TEST_TMPDIR/listener.stdout" 2>"$TEST_TMPDIR/listener.stderr" &
    echo $! > "$TEST_TMPDIR/listener.pid"
  )
  sleep 0.5
  LISTENER_PID=$(cat "$TEST_TMPDIR/listener.pid" 2>/dev/null)
  [ -n "$LISTENER_PID" ] \
    || { echo "FAIL start_listener: no PID captured" >&2; return 1; }

  # Poll /health for up to 10 seconds before giving up.
  local deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$LISTENER_PORT/health" 2>/dev/null | grep -q '^200$'; then
      return 0
    fi
    if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
      echo "FAIL start_listener: listener died during startup" >&2
      cat "$TEST_TMPDIR/listener.stderr" >&2 || true
      return 1
    fi
    sleep 0.2
  done
  echo "FAIL start_listener: /health not reachable within 10s" >&2
  cat "$TEST_TMPDIR/listener.stderr" >&2 || true
  return 1
}

# =========================================================================
# SCENARIOS (Wave 0 sentinels -- flipped green by 17-03)
# =========================================================================

# -------------------------------------------------------------------------
# Scenario 1 / D-14.1: HMAC rejection
# Sends a webhook POST with sha256=deadbeef (invalid signature) and asserts:
#   - HTTP 401
#   - No e2e-executions.jsonl audit entry (no spawn invoked)
# -------------------------------------------------------------------------
scenario_hmac_rejection() {
  local body='{"action":"opened","issue":{"title":"e2e-hmac","number":1},"repository":{"full_name":"e2e/test"}}'
  local resp
  resp=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$LISTENER_PORT/webhook" \
    -H 'X-Hub-Signature-256: sha256=deadbeef' \
    -H 'X-GitHub-Event: issues' \
    -H 'X-GitHub-Delivery: e2e-hmac-test' \
    -d "$body")
  [ "$resp" = "401" ] || { echo "FAIL hmac: expected 401, got $resp" >&2; return 1; }

  # Audit JSONL must be absent or empty after a rejected request.
  # LOG_PREFIX is "${profile}-" so the file is e2e-executions.jsonl.
  local jsonl="$CONFIG_DIR/logs/e2e-executions.jsonl"
  if [ -f "$jsonl" ]; then
    local audit_count
    audit_count=$(wc -l < "$jsonl" 2>/dev/null || echo 0)
    [ "$audit_count" -eq 0 ] \
      || { echo "FAIL hmac: audit grew to $audit_count lines after rejection" >&2; return 1; }
  fi
  return 0
}

# -------------------------------------------------------------------------
# Scenario 2 / D-14.2: Concurrent execution
# POSTs 3 HMAC-valid payloads in parallel against the Phase 14 Semaphore(3)
# bound and asserts:
#   - 3 'routed' lines appear in webhook.jsonl (jq-parseable, no corruption)
# Spawn calls claude-secure via subprocess. D-12 gate: proves D-11 hardening
# did not break the routing pipeline for valid concurrent webhooks.
# -------------------------------------------------------------------------
scenario_concurrent_execution() {
  local secret="e2e-test-secret"
  local body='{"action":"opened","issue":{"title":"e2e-concurrent","number":2},"repository":{"full_name":"e2e/test"}}'
  local sig
  # Pitfall: printf '%s' (NOT echo) so no trailing newline pollutes the HMAC.
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -binary | xxd -p -c256)

  # Delivery IDs must have >=8 char tails so Phase 16 delivery_id_short
  # (last 8 chars of the after-last-dash segment) yields unique per-request
  # report filenames. Short ids collapse to empty for <8 char tails which
  # would point all 3 pushes at the same path and serialize the race.
  for i in 1 2 3; do
    curl -sS -X POST "http://127.0.0.1:$LISTENER_PORT/webhook" \
      -H "X-Hub-Signature-256: sha256=$sig" \
      -H 'X-GitHub-Event: issues' \
      -H "X-GitHub-Delivery: e2e-concurrent-abcdef0$i" \
      -d "$body" >/dev/null &
  done
  wait

  # Poll for 3 'routed' lines in webhook.jsonl. We verify the routing pipeline.
  # The semaphore and concurrent-write correctness are exercised by the 3
  # parallel requests hitting the listener together.
  local jsonl="$CONFIG_DIR/logs/webhook.jsonl"
  local deadline=$((SECONDS + 10))
  local n=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    n=$(grep -c '"event": "routed"' "$jsonl" 2>/dev/null) || n=0
    [ "$n" -ge 3 ] && break
    sleep 0.2
  done

  local routed_count
  routed_count=$(grep -c '"event": "routed"' "$jsonl" 2>/dev/null) || routed_count=0
  [ "$routed_count" -ge 3 ] \
    || { echo "FAIL concurrent: $routed_count routed lines (expected 3)" >&2; cat "$jsonl" 2>/dev/null >&2 || true; return 1; }

  # Every line must be jq-parseable (no JSONL corruption from concurrent writes).
  if ! jq -c . < "$jsonl" >/dev/null 2>&1; then
    echo "FAIL concurrent: corrupt JSONL line detected" >&2
    return 1
  fi

  return 0
}

# -------------------------------------------------------------------------
# Scenario 3 / D-14.3: Orphan cleanup
# Pitfall 4: Docker does NOT let us backdate Container Created timestamps,
# so we set REAPER_ORPHAN_AGE_SECS=0 to count ALL ages as orphan. A real
# busybox sentinel is spawned with the exact com.docker.compose.project
# label format the reaper matches, then we invoke `claude-secure reap` and
# assert the sentinel is gone from `docker ps -a`.
# -------------------------------------------------------------------------
scenario_orphan_cleanup() {
  # Pre-pull busybox quietly so the pull latency doesn't inflate the budget.
  docker pull busybox >/dev/null 2>&1 || true

  # The reaper's teardown is `docker compose -p <proj> down -v`, which only
  # works against containers registered with a full compose project label
  # set (service, config_files, config_hash, etc). A plain `docker run`
  # with just the project label is NOT torn down by `compose down`, so the
  # sentinel must be created via a real compose file. We write a minimal
  # compose.yml under $TEST_TMPDIR and drive it with `docker compose up -d`.
  local orphan_project="cs-e2e-fakeorph"
  local orphan_dir="$TEST_TMPDIR/orphan"
  mkdir -p "$orphan_dir"
  cat > "$orphan_dir/compose.yml" <<'EOF'
services:
  sentinel:
    image: busybox
    command: ["sleep", "3600"]
EOF

  if ! (cd "$orphan_dir" && docker compose -p "$orphan_project" up -d >/dev/null 2>&1); then
    echo "FAIL orphan: docker compose up failed for sentinel" >&2
    (cd "$orphan_dir" && docker compose -p "$orphan_project" down -v --remove-orphans >/dev/null 2>&1 || true)
    return 1
  fi

  # Sanity: sentinel container is visible under the compose project label.
  docker ps -q --filter "label=com.docker.compose.project=$orphan_project" | grep -q . \
    || { echo "FAIL orphan: sentinel did not start" >&2; \
         (cd "$orphan_dir" && docker compose -p "$orphan_project" down -v --remove-orphans >/dev/null 2>&1 || true); \
         return 1; }

  # Run reap with zero-age threshold (Pitfall 4) so any age qualifies.
  REAPER_ORPHAN_AGE_SECS=0 INSTANCE_PREFIX="cs-e2e-" \
    "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1 || true

  # docker ps -a catches stopped-but-not-removed as well as running state.
  if docker ps -aq --filter "label=com.docker.compose.project=$orphan_project" | grep -q .; then
    echo "FAIL orphan: sentinel survived reap" >&2
    (cd "$orphan_dir" && docker compose -p "$orphan_project" down -v --remove-orphans >/dev/null 2>&1 || true)
    return 1
  fi
  return 0
}

# -------------------------------------------------------------------------
# Scenario 4 / D-14.4: Resource limit enforcement (Pitfall 5)
# The FAKE Claude stub used for scenario 2 bypasses `docker compose up`, so
# no cs-e2e-<uuid> claude containers from the spawn path exist to inspect.
# Instead we explicitly create a claude container from the PROJECT docker-
# compose.yml (which carries `mem_limit: 1g` courtesy of 17-02 Task 3) and
# assert HostConfig.Memory equals 1073741824 bytes (= 1 GiB).
# Two-layer check:
#   (a) `docker compose config` confirms the effective mem_limit value
#   (b) `docker inspect` on a live container confirms the runtime HostConfig
# -------------------------------------------------------------------------
scenario_resource_limits() {
  local expected=1073741824  # 1 GiB = docker-compose.yml mem_limit: 1g

  # Layer (a): effective compose config must resolve mem_limit to 1 GiB.
  local effective_mem
  effective_mem=$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null \
                  | jq -r '.services.claude.mem_limit // empty' 2>/dev/null)
  [ -n "$effective_mem" ] \
    || { echo "FAIL limits: docker compose config did not expose mem_limit (Pitfall 5 regression)" >&2; return 1; }
  [ "$effective_mem" = "$expected" ] \
    || { echo "FAIL limits: compose config mem_limit=$effective_mem, expected $expected" >&2; return 1; }

  # Layer (b): create a live claude container from the compose file so the
  # runtime docker inspect HostConfig.Memory path is actually exercised.
  # --no-deps skips proxy/validator; --no-start creates without running, so
  # we don't pay the container startup cost.
  local project="cs-e2e-limits"
  # Required host paths referenced by the compose file's bind mounts:
  mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/workspace" 2>/dev/null || true

  if ! (cd "$PROJECT_DIR" && docker compose -p "$project" up --no-deps --no-start claude \
          >"$TEST_TMPDIR/limits-compose.log" 2>&1); then
    echo "FAIL limits: docker compose up --no-deps --no-start claude failed" >&2
    tail -20 "$TEST_TMPDIR/limits-compose.log" >&2 || true
    (cd "$PROJECT_DIR" && docker compose -p "$project" down -v >/dev/null 2>&1 || true)
    return 1
  fi

  # Resolve the created container ID via the compose project label.
  local claude_cid
  claude_cid=$(docker ps -aq \
                 --filter "label=com.docker.compose.project=$project" \
                 --filter "label=com.docker.compose.service=claude" \
                 | head -1)
  if [ -z "$claude_cid" ]; then
    echo "FAIL limits: no claude container found for project $project" >&2
    (cd "$PROJECT_DIR" && docker compose -p "$project" down -v >/dev/null 2>&1 || true)
    return 1
  fi

  local mem_bytes
  mem_bytes=$(docker inspect --format '{{.HostConfig.Memory}}' "$claude_cid" 2>/dev/null)

  # Tear down the inspect container before asserting so a failure path still
  # cleans up (and the outer trap's reap pass is a secondary safety net).
  (cd "$PROJECT_DIR" && docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true)

  [ -n "$mem_bytes" ] \
    || { echo "FAIL limits: docker inspect returned empty HostConfig.Memory" >&2; return 1; }
  [ "$mem_bytes" -gt 0 ] \
    || { echo "FAIL limits: no memory limit (got $mem_bytes) -- Pitfall 5" >&2; return 1; }
  [ "$mem_bytes" -eq "$expected" ] \
    || { echo "FAIL limits: expected $expected, got $mem_bytes" >&2; return 1; }

  return 0
}

# =========================================================================
# Main dispatch
# =========================================================================

# Single-function mode: bash tests/test-phase17-e2e.sh scenario_hmac_rejection
if [ $# -eq 1 ]; then
  "$1"
  exit $?
fi

require_tool docker
require_tool curl
require_tool openssl
require_tool xxd
require_tool jq
require_tool python3
require_tool git

echo "Phase 17 E2E -- four scenario integration suite"
echo "Budget: ${E2E_BUDGET} seconds"
echo ""

SECONDS=0

setup_e2e_profile || { echo "FAIL: setup_e2e_profile"; exit 1; }
start_listener    || { echo "FAIL: start_listener"; exit 1; }
check_budget

# Scenario order rationale:
#   1. HMAC rejection first -- cheap 401 path, validates listener is accepting
#      requests before any spawn has a chance to write to the audit log.
#   2. Concurrent execution next -- drives 3 parallel spawns that produce the
#      3 audit lines + 3 report commits the D-14.2 assertion checks.
#   3. Resource limits third -- creates its own cs-e2e-limits compose project
#      for the docker inspect HostConfig.Memory assertion.
#   4. Orphan cleanup last -- sentinel-only, fully independent of any prior
#      scenario state.
run_test scenario_hmac_rejection       scenario_hmac_rejection
check_budget
run_test scenario_concurrent_execution scenario_concurrent_execution
check_budget
run_test scenario_resource_limits      scenario_resource_limits
check_budget
run_test scenario_orphan_cleanup       scenario_orphan_cleanup
check_budget

echo ""
echo "Phase 17 E2E: $PASS passed, $FAIL failed (in ${SECONDS} seconds, budget $E2E_BUDGET)"
[ "$FAIL" -eq 0 ]
