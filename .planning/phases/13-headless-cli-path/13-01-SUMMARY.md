---
phase: 13-headless-cli-path
plan: 01
subsystem: cli
tags: [bash, spawn, docker-compose, headless, ephemeral]

# Dependency graph
requires:
  - phase: 12-profile-system
    provides: validate_profile, load_profile_config, profile.json structure
provides:
  - spawn subcommand skeleton with arg parsing and input validation
  - spawn_project_name() for ephemeral Docker Compose project naming
  - spawn_cleanup() for trap-based container teardown
  - test scaffold covering HEAD-01 through HEAD-05
affects: [13-02-PLAN, 13-03-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: [source-then-guard test pattern for incremental function implementation]

key-files:
  created: [tests/test-phase13.sh]
  modified: [bin/claude-secure, tests/test-map.json]

key-decisions:
  - "Type guards in tests must come AFTER sourcing bin/claude-secure, not before"
  - "do_spawn() wraps all spawn logic in a function for local variable scoping and testability"

patterns-established:
  - "Source-then-guard: source functions first, then type-check for SKIP -- enables incremental implementation across plans"
  - "Spawn arg parsing uses indexed REMAINING_ARGS iteration to support paired flags (--event VALUE)"

requirements-completed: [HEAD-01, HEAD-04]

# Metrics
duration: 5min
completed: 2026-04-11
---

# Phase 13 Plan 01: Spawn Subcommand Skeleton Summary

**spawn subcommand with --event/--event-file/--prompt-template/--dry-run parsing, cs-profile-uuid8 ephemeral naming, and 16-test scaffold for HEAD-01 through HEAD-05**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-11T21:53:12Z
- **Completed:** 2026-04-11T21:58:08Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 16 integration tests covering all Phase 13 requirements (HEAD-01 through HEAD-05) with SKIP guards for unimplemented functions
- spawn subcommand validates --profile requirement, JSON validity, event-file existence, and parses all spawn-specific flags
- Ephemeral project naming (cs-profile-uuid8) ensures container isolation between concurrent spawn runs
- Trap-based cleanup with docker compose down -v for automatic teardown on any exit path

## Task Commits

Each task was committed atomically:

1. **Task 1: Create test-phase13.sh test scaffold** - `d2eb526` (test)
2. **Task 2: Implement spawn subcommand with arg parsing, validation, and ephemeral project naming** - `a82a43b` (feat)

## Files Created/Modified
- `tests/test-phase13.sh` - 16 integration tests for HEAD-01 through HEAD-05 with source-then-guard SKIP pattern
- `bin/claude-secure` - spawn_project_name(), spawn_cleanup(), do_spawn() functions and spawn case in command dispatch
- `tests/test-map.json` - Added test-phase13.sh mappings for bin/claude-secure and self

## Decisions Made
- Type guards in tests must come AFTER sourcing bin/claude-secure (not before) so functions are available for the check
- do_spawn() wraps all spawn logic as a function rather than inline case body, enabling local variables and unit testability

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed test type-guard ordering**
- **Found during:** Task 2 (verification)
- **Issue:** Tests checked `type do_spawn` before sourcing bin/claude-secure, so functions were never found even after implementation
- **Fix:** Restructured all test functions to source first, then type-check
- **Files modified:** tests/test-phase13.sh
- **Verification:** All HEAD-01 and HEAD-04 tests now run real assertions instead of SKIP
- **Committed in:** a82a43b (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Essential fix -- without it, tests would always SKIP and never validate the implementation.

## Issues Encountered
None beyond the test ordering fix documented above.

## User Setup Required
None - no external service configuration required.

## Known Stubs
- `do_spawn()` returns error "spawn execution not yet implemented" after validation -- Plan 02 implements execution lifecycle
- HEAD-02 (build_output_envelope), HEAD-05 (resolve_template, render_template) test stubs SKIP -- Plans 02 and 03 implement these functions

## Next Phase Readiness
- spawn entry point and validation complete; Plans 02 and 03 can build execution lifecycle and template rendering on top
- All test hooks in place -- implementing functions in Plans 02/03 will automatically activate the corresponding test assertions

---
*Phase: 13-headless-cli-path*
*Completed: 2026-04-11*
