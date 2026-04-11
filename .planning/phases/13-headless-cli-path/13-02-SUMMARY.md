---
phase: 13-headless-cli-path
plan: 02
subsystem: cli
tags: [bash, docker-compose, headless, json-output, spawn]

# Dependency graph
requires:
  - phase: 13-01
    provides: spawn argument parsing, project naming, cleanup trap
provides:
  - build_output_envelope() function wrapping Claude JSON in metadata
  - build_error_envelope() function for error cases with stderr
  - Complete spawn execution lifecycle (up -> exec -> down)
  - --dry-run mode for prompt inspection
  - --max-turns conditional forwarding from profile.json
affects: [13-03, 14-headless-webhook]

# Tech tracking
tech-stack:
  added: []
  patterns: [output-envelope-pattern, stderr-capture-to-tmpfile, docker-compose-wait]

key-files:
  created: []
  modified: [bin/claude-secure]

key-decisions:
  - "--bare flag intentionally OMITTED to preserve PreToolUse security hooks inside container"
  - "Output field validation logs WARNING (not error) for missing 'result' key since field names have LOW confidence"
  - "LOG_DIR defaults to CONFIG_DIR/logs for testability when load_profile_config not called"

patterns-established:
  - "Output envelope: {profile, event_type, timestamp, claude: <raw>} for all spawn output"
  - "Error envelope: {profile, event_type, timestamp, error: <stderr>} for failures"
  - "Stderr capture via temp file added to _CLEANUP_FILES array"

requirements-completed: [HEAD-02, HEAD-03, HEAD-04]

# Metrics
duration: 4min
completed: 2026-04-12
---

# Phase 13 Plan 02: Spawn Execution Lifecycle Summary

**Headless Claude Code execution via docker compose exec -T with JSON output envelope, max-turns forwarding, dry-run mode, and documented --bare exclusion for security**

## What Was Done

### Task 1: Implement build_output_envelope and execution lifecycle

Added two envelope functions and replaced the stub in `do_spawn()` with full execution logic:

1. `build_output_envelope()` - Wraps Claude's JSON output in metadata envelope with profile, event_type, timestamp
2. `build_error_envelope()` - Produces error JSON with stderr content on failure
3. Execution flow: `docker compose up -d --wait` -> `docker compose exec -T claude claude -p` -> envelope -> `spawn_cleanup`
4. `--dry-run` prints resolved prompt and exits without starting containers
5. `--max-turns` conditionally added from profile.json
6. Output validation warns if Claude JSON lacks expected "result" field

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Omit --bare flag | Security hooks (PreToolUse) are critical per CLAUDE.md mandate; --bare skips them |
| Use docker compose up -d --wait | More reliable than sleep-based readiness check |
| WARNING (not error) for missing output fields | Field names from docs have LOW confidence; need empirical verification |
| Default LOG_DIR from CONFIG_DIR | Ensures testability when do_spawn called without full config loading |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed unbound LOG_DIR variable in test context**
- **Found during:** Task 1 verification
- **Issue:** `set -u` (nounset) caused script termination when `LOG_DIR` was unbound in test-only execution path
- **Fix:** Added `LOG_DIR="${LOG_DIR:-$CONFIG_DIR/logs}"` defensive default before use
- **Files modified:** bin/claude-secure
- **Commit:** a1796a0

## Verification

All 16 tests pass:
- HEAD-01 (a-e): Spawn argument parsing
- HEAD-02a: build_output_envelope produces correct envelope structure
- HEAD-03 (a-b): max_turns read/absent handling
- HEAD-04 (a-b): Ephemeral project naming
- HEAD-05 (a-e): Template stubs (SKIP - Plan 03)
- DRY-RUN: --dry-run flag works correctly

## Self-Check: PASSED
