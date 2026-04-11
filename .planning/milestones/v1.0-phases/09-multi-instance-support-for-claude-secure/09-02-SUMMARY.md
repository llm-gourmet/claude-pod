---
phase: 09-multi-instance-support-for-claude-secure
plan: 02
subsystem: cli
tags: [bash, docker-compose, multi-instance, cli]

# Dependency graph
requires:
  - phase: 04-installation-platform
    provides: bin/claude-secure CLI wrapper and install.sh installer
provides:
  - "--instance NAME flag on all CLI commands"
  - "Instance auto-creation with workspace prompt and auth setup"
  - "Single-to-multi-instance migration for existing users"
  - "list subcommand showing all instances with status"
  - "remove subcommand for instance cleanup"
  - "Instance-scoped config, secrets, whitelist, and logs"
  - "Installer creating instances/default/ directory structure"
affects: [09-multi-instance-support-for-claude-secure]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "COMPOSE_PROJECT_NAME=claude-{instance} for Docker Compose project isolation"
    - "Instance config at ~/.claude-secure/instances/{name}/ with config.sh, .env, whitelist.json"
    - "Global config at ~/.claude-secure/config.sh with only APP_DIR and PLATFORM"
    - "Instance-prefixed log files: {instance}-hook.jsonl, {instance}-anthropic.jsonl"

key-files:
  created: []
  modified:
    - bin/claude-secure
    - install.sh

key-decisions:
  - "Used COMPOSE_PROJECT_NAME for Docker Compose multi-instance isolation"
  - "Replaced hardcoded container name cleanup with docker compose down --remove-orphans"
  - "Instance auto-create skipped for stop/remove commands (error if instance missing)"
  - "Auth credentials can be copied from existing instance on new instance creation"

patterns-established:
  - "Instance name validation: DNS-safe regex ^[a-z0-9][a-z0-9-]*$ with 63 char max"
  - "Migration pattern: detect root .env + no instances/ dir, create instances/default/"

requirements-completed: [MULTI-01, MULTI-02, MULTI-03, MULTI-05, MULTI-07, MULTI-08, MULTI-09]

# Metrics
duration: 3min
completed: 2026-04-10
---

# Phase 9 Plan 2: CLI and Installer Multi-Instance Support Summary

**Multi-instance CLI via --instance NAME flag with auto-create, migration, list/remove commands, and installer creating instances/default/ layout**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-10T17:48:52Z
- **Completed:** 2026-04-10T17:52:03Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Refactored bin/claude-secure to require --instance NAME for all commands except list/help
- Added instance lifecycle: auto-create on first use, list with running/stopped status, remove with cleanup
- Added single-to-multi-instance migration (moves root .env to instances/default/)
- Updated install.sh to create instances/default/ with .env, config.sh, whitelist.json
- Split global config (APP_DIR, PLATFORM) from instance config (WORKSPACE_PATH)

## Task Commits

Each task was committed atomically:

1. **Task 1: Refactor bin/claude-secure for multi-instance support** - `5d6e165` (feat)
2. **Task 2: Update install.sh for multi-instance directory structure** - `ff02681` (feat)

## Files Created/Modified
- `bin/claude-secure` - Multi-instance CLI with --instance flag, list, remove, migration, instance-scoped config loading
- `install.sh` - Updated installer creating instances/default/ directory structure with split global/instance config

## Decisions Made
- Used COMPOSE_PROJECT_NAME=claude-{instance} for Docker Compose project-level isolation between instances
- Replaced hardcoded container name cleanup (claude-proxy, claude-secure, claude-validator) with docker compose down --remove-orphans
- Instance auto-create prompts for workspace path and offers to copy auth from existing instances
- stop/remove commands error if instance doesn't exist (no auto-create for destructive operations)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed create_instance to exclude current instance directory from auth copy**
- **Found during:** Task 1 (CLI refactor)
- **Issue:** The for-loop searching for existing .env files could match the instance being created
- **Fix:** Added `[ "$d" != "$idir/" ]` check to skip the current instance directory
- **Files modified:** bin/claude-secure
- **Verification:** bash -n passes, logic correct
- **Committed in:** 5d6e165 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor correctness fix. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- CLI and installer support multi-instance operation
- Ready for Plan 3: docker-compose.yml parameterization (remove hardcoded container_name, parameterize networks)
- Integration testing needed after compose changes are in place

## Known Stubs
None - all functionality is fully wired.

---
*Phase: 09-multi-instance-support-for-claude-secure*
*Completed: 2026-04-10*
