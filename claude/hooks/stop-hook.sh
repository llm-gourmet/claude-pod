#!/bin/bash
# stop-hook.sh -- Stop hook for claude-secure mandatory reporting (SPOOL-01, SPOOL-02).
# Zero network calls (SPOOL-02): does not invoke any external network commands.
# Re-prompts Claude once if spool is missing; yields on stop_hook_active=true to
# prevent infinite loops (SPOOL-04 success criterion).
#
# Testability contract (Plan 26-01 documents this):
#   TEST_SPOOL_FILE_OVERRIDE -- if set, use this path as SPOOL_FILE instead of the
#                               default /var/log/claude-secure/spool.md.
set -euo pipefail

# --- Constants ---
SPOOL_FILE="${TEST_SPOOL_FILE_OVERRIDE:-/var/log/claude-secure/spool.md}"
LOG_FILE="/var/log/claude-secure/${LOG_PREFIX:-}hook.log"

# --- Read stdin immediately (single-read stream) ---
INPUT=$(cat)

# --- Logging helper ---
log() {
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    echo "[$(date -Iseconds)] stop-hook: $*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# --- Recursion guard ---
# When Claude responds to our re-prompt, the Stop hook fires again with
# stop_hook_active=true. We MUST yield immediately to prevent an infinite loop.
# Pitfall 6: malformed JSON falls back to "false" via 2>/dev/null || echo "false".
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  log "yielding (stop_hook_active=true)"
  exit 0
fi

# --- Spool present? Yield ---
if [ -f "$SPOOL_FILE" ]; then
  log "yielding (spool exists: $SPOOL_FILE)"
  exit 0
fi

# --- Spool missing: block exit with re-prompt ---
log "blocking (spool missing); emitting re-prompt decision"
REPROMPT=$(cat <<'EOF'
Write your session report to /var/log/claude-secure/spool.md before exiting.
Use these exact section headings (H2 markdown):
## Goal
## Where Worked
## What Changed
## What Failed
## How to Test
## Future Findings
EOF
)
jq -n --arg reason "$REPROMPT" '{decision: "block", reason: $reason}'
exit 0
