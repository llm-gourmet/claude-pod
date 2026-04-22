#!/bin/bash
set -uo pipefail

# Phase 1 Integration Tests
# Verifies all Docker infrastructure requirements (DOCK-01 through DOCK-06, WHIT-01 through WHIT-03)
# plus settings.json accessibility check (DOCK-05b).
#
# Usage: bash tests/test-phase1.sh
# Exit 0 if all pass, exit 1 if any fail.

PASS=0
FAIL=0
TOTAL=10

report() {
  local id="$1"
  local desc="$2"
  local result="$3"

  printf "  %-8s %-60s " "$id" "$desc"
  if [ "$result" -eq 0 ]; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi
}

echo "========================================"
echo "  Phase 1 Integration Tests"
echo "========================================"
echo ""

# Ensure containers are running (they may or may not be up from Plan 01)
echo "Ensuring containers are running..."
_TMP_WS_P1=$(mktemp -d)
trap 'docker compose down -v >/dev/null 2>&1; rm -rf "$_TMP_WS_P1" 2>/dev/null || true' EXIT
docker volume rm -f claude-pod_workspace >/dev/null 2>&1 || true
WORKSPACE_PATH="$_TMP_WS_P1" \
  docker compose up -d --wait --timeout 30 || { echo "FATAL: containers failed to start"; exit 1; }
echo ""

echo "Running tests..."
echo ""

# DOCK-01: Claude container has no direct internet
! docker compose exec -T claude curl -sf --max-time 5 https://api.anthropic.com > /dev/null 2>&1
report "DOCK-01" "Claude container has no direct internet access" $?

# DOCK-02: Proxy can reach external URLs (node used -- proxy image has no curl)
# NOTE: Cannot use api.anthropic.com here -- Docker network alias maps it to the
# proxy itself on claude-internal. Use a neutral external URL instead.
docker compose exec -T proxy node -e '
  const https = require("https");
  const r = https.get("https://httpbin.org/get", {timeout: 10000}, res => {
    process.exit(res.statusCode < 500 ? 0 : 1);
  });
  r.on("error", () => process.exit(1));
  r.on("timeout", () => { r.destroy(); process.exit(1); });
' > /dev/null 2>&1
report "DOCK-02" "Proxy container can reach external URLs" $?

# DOCK-03: All 3 containers running
test "$(docker compose ps --format json | jq -s 'length')" -eq 3 > /dev/null 2>&1
report "DOCK-03" "Docker Compose runs all 3 containers" $?

# DOCK-04: Outbound connections blocked from claude (iptables OUTPUT DROP)
# DNS may resolve via Docker embedded DNS but actual connections are blocked by iptables.
# NOTE: Must use a domain NOT in the profile's secrets[].domains,
# because the claude container has HTTP_PROXY set which routes through the proxy's
# CONNECT handler that allows whitelisted domains.
! docker compose exec -T claude curl -sf --max-time 5 https://blocked-test.example.com > /dev/null 2>&1
report "DOCK-04" "Outbound connections from claude container are blocked" $?

# DOCK-05: Security files root-owned and read-only
# Hooks and settings are COPY'd in Dockerfile and genuinely root-owned.
# Profile is bind-mounted (:ro flag enforces read-only at mount level; host UID visible inside).
DOCK05_RESULT=0
docker compose exec -T claude stat -c '%U %a' /etc/claude-pod/hooks/pre-tool-use.sh 2>/dev/null | grep -q 'root 555' || DOCK05_RESULT=1
docker compose exec -T claude stat -c '%U %a' /etc/claude-pod/settings.json 2>/dev/null | grep -q 'root 444' || DOCK05_RESULT=1
docker inspect $(docker compose ps -q claude) --format '{{json .Mounts}}' 2>/dev/null | jq '.[] | select(.Destination=="/etc/claude-pod/profile.json") | .RW' 2>/dev/null | grep -q 'false' || DOCK05_RESULT=1
report "DOCK-05" "Security files are root-owned and read-only" $DOCK05_RESULT

# DOCK-05b: Settings.json accessible via symlink (not shadowed by volume)
# Symlink is at /home/claude/.claude/settings.json (non-root user, per Dockerfile)
docker compose exec -T claude cat /home/claude/.claude/settings.json 2>/dev/null | jq -e '.hooks.PreToolUse' > /dev/null 2>&1
report "DOCK-05b" "settings.json accessible via symlink (not volume-shadowed)" $?

# DOCK-06: Capabilities dropped and no-new-privileges
DOCK06_RESULT=0
docker inspect $(docker compose ps -q claude) --format '{{.HostConfig.CapDrop}}' 2>/dev/null | grep -q ALL || DOCK06_RESULT=1
docker inspect $(docker compose ps -q claude) --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -q no-new-privileges || DOCK06_RESULT=1
report "DOCK-06" "Claude container caps dropped, no-new-privileges set" $DOCK06_RESULT

# WHIT-01: Profile has secrets with correct schema
jq -e '.secrets[0] | has("redacted","env_var","domains")' config/profile.json > /dev/null 2>&1
report "WHIT-01" "Profile secrets have env_var, redacted, and domains fields" $?

# WHIT-02: Profile has workspace field
jq -e 'has("workspace")' config/profile.json > /dev/null 2>&1
report "WHIT-02" "Profile has workspace field" $?

# WHIT-03: Profile is not writable inside container
docker compose exec -T claude test ! -w /etc/claude-pod/profile.json > /dev/null 2>&1
report "WHIT-03" "Profile is read-only inside claude container" $?

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

# Clean up (also done by EXIT trap)
docker compose down -v > /dev/null 2>&1 || true

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
