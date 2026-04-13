---
phase: 23-profile-doc-repo-binding
plan: 02
subsystem: profile
tags: [bash, security, env-projection, token-management, deprecation, docker-compose]

requires:
  - phase: 23-profile-doc-repo-binding
    provides: Plan 01 test fixtures (profile-23-docs, profile-23-legacy), test-phase23.sh RED scaffolding

provides:
  - validate_docs_binding() function for BIND-01 schema validation
  - project_env_for_containers() for BIND-02 host-only token projection
  - emit_deprecation_warning() with per-profile sentinel rate-limiting
  - resolve_docs_alias() for BIND-03 legacy report_repo alias resolution
  - All four DOCS_* exports in load_profile_config
  - REPORT_* back-fill for Phase 16 publish_report compatibility

affects:
  - 23-03 (DOCS-01 init-docs: depends on DOCS_REPO, DOCS_PROJECT_DIR exports)
  - 24 (publish bundle: uses DOCS_REPO_TOKEN via host env, not container env)
  - 16 (Phase 16 back-compat: REPORT_REPO / REPORT_REPO_TOKEN still populated via back-fill)

tech-stack:
  added: []
  patterns:
    - "Host-only token projection: _HOST_ONLY_VARS array + project_env_for_containers() filters .env before docker-compose sees it"
    - "Per-session sentinel pattern: ${TMPDIR}/cs-deprecation-warned-${profile} for rate-limited warnings"
    - "Alias resolution: prefer new names (docs_*), fall back to legacy (report_*), back-fill legacy from new for Phase 16 compat"
    - "Opt-out validation semantics: validate_docs_binding() returns 0 silently when no docs_repo is set"

key-files:
  created:
    - tests/test-phase23.sh
    - tests/fixtures/profile-23-docs/profile.json
    - tests/fixtures/profile-23-docs/.env
    - tests/fixtures/profile-23-docs/whitelist.json
    - tests/fixtures/profile-23-legacy/profile.json
    - tests/fixtures/profile-23-legacy/.env
    - tests/fixtures/profile-23-legacy/whitelist.json
  modified:
    - bin/claude-secure
    - tests/test-map.json

key-decisions:
  - "Plan 01 scaffolding absorbed into Plan 02 execution because Plan 01 was still in-flight in a parallel worktree — all prerequisite fixtures and test harness created before Plan 02 implementation"
  - "test_no_docs_fields_ok uses inline profile creation instead of profile-e2e fixture because profile-e2e lacks .env and whitelist.json in worktree"
  - "test_legacy_* tests unset DOCS_REPO_TOKEN/REPORT_REPO_TOKEN before call to prevent cross-test pollution from earlier docs-profile tests in same session"
  - "test_deprecation_warning_rate_limit clears sentinel before test to prevent false failures from stale sentinel files across test runs"
  - "Phase 16 test_report_template_fallback pre-existing failure in worktree is due to .git being a file (not dir) in git worktrees — unrelated to Phase 23 changes; passes in main repo"

patterns-established:
  - "project_env_for_containers: creates filtered mktemp copy, appended to _CLEANUP_FILES, chmod 600"
  - "emit_deprecation_warning: tty-aware ([ -t 2 ]), sentinel in TMPDIR not TEST_TMPDIR"
  - "resolve_docs_alias called AFTER set -a; source .env in load_profile_config to access sourced tokens"

requirements-completed: [BIND-01, BIND-02, BIND-03]

duration: 17min
completed: 2026-04-13
---

# Phase 23 Plan 02: Profile-Doc-Repo Binding Schema + Security Summary

**BIND-01/02/03 implemented: validate_docs_binding (URL/token validation), project_env_for_containers (host-only token projection filtering DOCS_REPO_TOKEN from docker-compose env_file), and resolve_docs_alias (legacy report_repo/REPORT_REPO_TOKEN backcompat with rate-limited deprecation warning)**

## Performance

- **Duration:** 17 min
- **Started:** 2026-04-13T18:26:48Z
- **Completed:** 2026-04-13T18:44:37Z
- **Tasks:** 3 (+ Plan 01 prerequisite work absorbed)
- **Files modified:** 9

## Accomplishments

- Added `validate_docs_binding()` with opt-out semantics (no docs_repo = pass), fail-closed on malformed HTTPS URL, insecure protocol, path traversal, missing project_dir, or absent token
- Added `project_env_for_containers()` using `LC_ALL=C grep -Ev` with anchored ERE to strip `DOCS_REPO_TOKEN` and `REPORT_REPO_TOKEN` from the file mounted into docker containers — these tokens now stay strictly on the host
- Added `resolve_docs_alias()` that exports `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_MODE`, `DOCS_REPO_TOKEN` and back-fills `REPORT_REPO`, `REPORT_BRANCH`, `REPORT_REPO_TOKEN` for Phase 16 back-compat
- Added `emit_deprecation_warning()` with `cs-deprecation-warned-${profile}` sentinel in `$TMPDIR` for exact once-per-session semantics
- All 11 BIND-* tests green; 6 remaining RED (5 DOCS-01 stubs + docker-compose integration stub for Plan 03)

## Function Signatures and Locations

| Function | Line (bin/claude-secure) | Called From |
|---|---|---|
| `validate_docs_binding(name)` | 88 | `validate_profile()` line 79 |
| `project_env_for_containers(src)` | 142 | `load_profile_config()` line 397 |
| `emit_deprecation_warning(profile)` | 174 | `resolve_docs_alias()` line 258 |
| `resolve_docs_alias(name)` | 199 | `load_profile_config()` line 416 |

## Exports Added to load_profile_config

**New exports (line 416 — resolve_docs_alias call):**
- `DOCS_REPO` — from `docs_repo` field or `report_repo` alias
- `DOCS_BRANCH` — from `docs_branch` field or `report_branch` alias (default: "main")
- `DOCS_PROJECT_DIR` — from `docs_project_dir` field
- `DOCS_MODE` — from `docs_mode` field (default: "report_only")
- `DOCS_REPO_TOKEN` — from `.env` `DOCS_REPO_TOKEN` or `REPORT_REPO_TOKEN` alias

**Back-fills (Phase 16 compatibility):**
- `REPORT_REPO` — back-filled from `DOCS_REPO` when not set
- `REPORT_BRANCH` — back-filled from `DOCS_BRANCH` when not set
- `REPORT_REPO_TOKEN` — back-filled from `DOCS_REPO_TOKEN` when not set

## Test State After Plan

| Suite | GREEN | RED | Notes |
|-------|-------|-----|-------|
| test-phase23.sh | 11 | 6 | 6 RED = 5 DOCS-01 stubs + docs_token_absent_from_container |
| test-phase12.sh | 19 | 0 | Full regression pass |
| test-phase16.sh (main repo) | 33 | 0 | Full pass in main repo |
| test-phase16.sh (worktree) | 32 | 1 | Pre-existing: worktree .git is a file, not dir — unrelated to Phase 23 |
| test-phase7.sh | N/A | N/A | Docker not available in CI environment (pre-existing) |

## Task Commits

Each task was committed atomically:

1. **Fixtures + test scaffolding (Plan 01 prereqs + Task 1)** - `046c7fa` (feat)
2. **Fixture .env files** - `d5f4c08` (feat)
3. **Task 1: validate_docs_binding** - included in 046c7fa
4. **Task 2: project_env_for_containers + BIND-02** - `046998d` (feat)
5. **Task 3: resolve_docs_alias + emit_deprecation_warning + BIND-03** - `cefc881` (feat)

## Files Created/Modified

- `bin/claude-secure` — 4 new functions added (~145 lines); validate_profile extended; load_profile_config extended
- `tests/test-phase23.sh` — 17-test harness for Phase 23 (2 green Wave 0 baseline + 15 RED implementation stubs)
- `tests/test-map.json` — BIND-01/02/03/DOCS-01 requirement entries + path mappings for Phase 23
- `tests/fixtures/profile-23-docs/{profile.json,.env,whitelist.json}` — new-schema fixture
- `tests/fixtures/profile-23-legacy/{profile.json,.env,whitelist.json}` — legacy alias fixture

## Decisions Made

- Plan 01 scaffolding absorbed into Plan 02 because Plan 01 was still in-flight in a parallel worktree (all prerequisite fixtures and test harness created before Plan 02 implementation began)
- `test_no_docs_fields_ok` uses inline profile creation instead of `profile-e2e` fixture because `profile-e2e` lacks `.env` and `whitelist.json` files
- Cross-test pollution fix: `unset DOCS_REPO_TOKEN REPORT_REPO_TOKEN` before BIND-03 legacy tests to prevent token values from docs-profile tests contaminating legacy-alias assertions
- Sentinel cleanup in `test_deprecation_warning_rate_limit` prevents stale sentinels from previous test run iterations

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] profile-e2e fixture missing .env and whitelist.json**
- **Found during:** Task 1 test_no_docs_fields_ok
- **Issue:** `install_fixture "profile-e2e" ...` fails because profile-e2e has no .env or whitelist.json
- **Fix:** Changed `test_no_docs_fields_ok` to create a minimal inline profile instead of using profile-e2e
- **Files modified:** tests/test-phase23.sh
- **Verification:** test_no_docs_fields_ok passes
- **Committed in:** cefc881 (Task 3 commit)

**2. [Rule 1 - Bug] Cross-test environment pollution in BIND-03 tests**
- **Found during:** Task 3 full-suite run
- **Issue:** test_legacy_report_token_alias and test_deprecation_warning_rate_limit fail in full-suite context because DOCS_REPO_TOKEN is set by earlier docs-profile tests; also stale sentinel files persist across test-script invocations
- **Fix:** Added `unset DOCS_REPO_TOKEN REPORT_REPO_TOKEN` before BIND-03 tests; added `rm -f sentinel` in deprecation rate-limit test
- **Files modified:** tests/test-phase23.sh
- **Verification:** All 11 BIND-* tests pass in full-suite run
- **Committed in:** cefc881 (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (2 Rule 1 - Bug)
**Impact on plan:** Both auto-fixes necessary for test correctness. No scope creep.

## Issues Encountered

- **Phase 16 `test_report_template_fallback` pre-existing worktree failure:** In git worktrees, `.git` is a file (not directory), so `[ -d "$APP_DIR/.git" ]` in `_resolve_default_templates_dir` fails, causing fallback to `/opt/claude-secure/` instead of `$PROJECT_DIR`. This is unrelated to Phase 23 changes and passes in the main repo checkout (33/33 green). Documented as pre-existing infrastructure constraint.

## Known Stubs

- `tests/test-phase23.sh` `test_docs_token_absent_from_container`: stub with `return 1` — requires `docker compose` for live container env dump check; Plan 03 will implement gated by `command -v docker`
- `tests/test-phase23.sh` `test_init_docs_*` (5 tests): stub with `NOT-IMPLEMENTED` — Plan 03 implements `do_profile_init_docs` subcommand

## Next Phase Readiness

- Phase 23 Plan 03 (DOCS-01 init-docs subcommand) has all prerequisites in place: `DOCS_REPO`, `DOCS_PROJECT_DIR`, `DOCS_REPO_TOKEN` all exported by `load_profile_config` via `resolve_docs_alias`
- Token security invariant confirmed: `DOCS_REPO_TOKEN` and `REPORT_REPO_TOKEN` are absent from `$SECRETS_FILE` (the projected .env that docker-compose reads), but present in host bash environment for `publish_report` / `init-docs`
- Phase 16 back-compat confirmed: `REPORT_REPO`, `REPORT_BRANCH`, `REPORT_REPO_TOKEN` are back-filled so `publish_report` and `push_with_retry` continue to work with new-schema profiles

---
*Phase: 23-profile-doc-repo-binding*
*Completed: 2026-04-13*
