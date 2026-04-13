---
phase: 23-profile-doc-repo-binding
plan: 01
subsystem: testing
tags: [bash, shell-testing, fixtures, nyquist, tdd, phase23, profile-binding]

# Dependency graph
requires:
  - phase: 12-profile-system
    provides: validate_profile, load_profile_config, CONFIG_DIR pattern used by test harness
  - phase: 16-result-channel
    provides: test harness pattern (test-phase16.sh canonical structure), publish_report/push_with_retry for DOCS-01 stub shapes
provides:
  - Wave 0 test scaffold for Phase 23 (17 test functions, 2 green / 15 RED in Wave 0)
  - Fixture profiles: profile-23-docs (new schema) and profile-23-legacy (legacy schema)
  - test-map.json registrations for BIND-01/02/03/DOCS-01 requirements
affects: [23-02-PLAN, 23-03-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Wave 0 NOT IMPLEMENTED sentinel: declare -f <function> or explicit return 1 in stub tests"
    - "APP_DIR must be exported before source_cs in tests calling load_profile_config"
    - "Use \${VAR:-} pattern for vars expected only after Plan 02 implementation (avoids set -u crash)"
    - "install_fixture helper: redirects CONFIG_DIR, rewrites workspace with jq"
    - "Force-add .env fixtures with git add -f (gitignored by default, per Phase 17 Pitfall 13)"

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
    - tests/test-map.json

key-decisions:
  - "Wave 0 RED contract enforced via declare -f sentinel pattern rather than stub-only functions that might accidentally pass"
  - "profile-e2e fixture lacks whitelist.json -- tests needing a no-docs profile use inline jq-constructed profiles"
  - "Fake token values use fake-phase23-* prefix (not ghp_, sk-ant- etc) per Phase 17 Pitfall 13"
  - "APP_DIR exported in source_cs helper so load_profile_config can resolve its config paths"

patterns-established:
  - "NOT IMPLEMENTED guard: declare -f <new_fn> || { echo NOT IMPLEMENTED >&2; return 1; }"
  - "Inline profile creation: jq -n --arg ws ... + cp config/whitelist.json (when fixture lacks whitelist.json)"

requirements-completed: [BIND-01, BIND-02, BIND-03, DOCS-01]

# Metrics
duration: 25min
completed: 2026-04-13
---

# Phase 23 Plan 01: Profile Doc-Repo Binding Wave 0 Summary

**Wave 0 Nyquist test scaffold with 17 test functions (2 green baseline + 15 RED stubs), two fixture profiles (new docs schema + legacy alias schema), and test-map.json registration for all four Phase 23 requirements.**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-04-13
- **Completed:** 2026-04-13
- **Tasks:** 3
- **Files modified:** 8 (7 created, 1 modified)

## Accomplishments

- Created `tests/fixtures/profile-23-docs/` with new schema (docs_repo/docs_branch/docs_project_dir/docs_mode) and fake DOCS_REPO_TOKEN
- Created `tests/fixtures/profile-23-legacy/` with legacy schema (report_repo/REPORT_REPO_TOKEN) for alias-path coverage
- Wrote `tests/test-phase23.sh` with 17 test functions, exact Phase 16 harness structure, Wave 0 RED contract (2 PASS, 15 FAIL, exit non-zero)
- Registered test-phase23.sh and BIND-01/02/03/DOCS-01 requirements in tests/test-map.json

## Task Commits

1. **Task 1: Create fixture profiles** - `da7fb50` (feat)
2. **Task 2: Write test harness** - `597aedc` (test) + `ab54d81` (fix - Wave 0 RED hardening)
3. **Task 3: Register in test-map.json** - `01c51cf` (chore)

## Files Created/Modified

- `tests/test-phase23.sh` - Phase 23 bash test harness, 17 test functions, Wave 0 RED contract
- `tests/fixtures/profile-23-docs/profile.json` - New schema fixture: docs_repo, docs_branch, docs_project_dir, docs_mode
- `tests/fixtures/profile-23-docs/.env` - Fake tokens: CLAUDE_CODE_OAUTH_TOKEN, DOCS_REPO_TOKEN, GITHUB_TOKEN
- `tests/fixtures/profile-23-docs/whitelist.json` - Copy of config/whitelist.json
- `tests/fixtures/profile-23-legacy/profile.json` - Legacy schema: report_repo, report_branch, report_path_prefix
- `tests/fixtures/profile-23-legacy/.env` - Fake tokens: CLAUDE_CODE_OAUTH_TOKEN, REPORT_REPO_TOKEN
- `tests/fixtures/profile-23-legacy/whitelist.json` - Copy of config/whitelist.json
- `tests/test-map.json` - Added test-phase23.sh path mappings + BIND-01/02/03/DOCS-01 requirement entries

## Decisions Made

- Used `declare -f <function>` sentinel to enforce RED state on BIND-01/BIND-02 tests (validate_docs_binding) and DOCS-01 tests (do_profile_init_docs). Without this guard, `validate_profile` would pass for profile-23-docs even before Plan 02 adds docs validation, breaking the Nyquist RED contract.
- Used `${VAR:-}` pattern instead of `$VAR` for BIND-01/BIND-02 variable checks to prevent `set -u` crashes when DOCS_REPO etc are not yet exported by `load_profile_config`.
- Exported `APP_DIR="$PROJECT_DIR"` inside `source_cs` helper -- required by `load_profile_config` (line 208 in bin/claude-secure references APP_DIR unbound variable without it).
- Used inline jq-constructed profile for `test_no_docs_fields_ok` and `test_init_docs_requires_docs_repo` because `tests/fixtures/profile-e2e/` lacks `whitelist.json` (install_fixture helper requires it).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] APP_DIR unbound variable in source_cs**
- **Found during:** Task 2 (test harness execution)
- **Issue:** `load_profile_config` at bin/claude-secure:208 references `$APP_DIR` which is not set when sourcing in library mode via `__CLAUDE_SECURE_SOURCE_ONLY=1`. This caused `bash: APP_DIR: unbound variable` error.
- **Fix:** Added `export APP_DIR="$PROJECT_DIR"` to the `source_cs` helper before sourcing the binary.
- **Files modified:** tests/test-phase23.sh
- **Verification:** load_profile_config calls no longer crash on APP_DIR
- **Committed in:** ab54d81

**2. [Rule 1 - Bug] set -u crash on unset DOCS_REPO/DOCS_BRANCH vars**
- **Found during:** Task 2 (first test run)
- **Issue:** BIND-01/BIND-02 tests access `$DOCS_REPO`, `$DOCS_BRANCH` etc which are not yet exported by `load_profile_config` in Wave 0. The `set -uo pipefail` flag caused the script to crash rather than failing the test gracefully.
- **Fix:** Changed `[ "$VAR" = "..." ]` to `[ "${VAR:-}" = "..." ]` for all vars expected only after Plan 02.
- **Files modified:** tests/test-phase23.sh
- **Verification:** Script runs full 17 tests without crashing; fails gracefully on unimplemented tests
- **Committed in:** ab54d81

**3. [Rule 1 - Bug] profile-e2e missing whitelist.json breaks install_fixture**
- **Found during:** Task 2 (first test run)
- **Issue:** `install_fixture "profile-e2e" "..."` crashes with `cp: cannot stat .../whitelist.json: No such file or directory`. The profile-e2e fixture predates whitelist.json being part of the fixture layout.
- **Fix:** Replaced `install_fixture "profile-e2e"` calls with inline profile construction using `jq -n` + `cp config/whitelist.json`.
- **Files modified:** tests/test-phase23.sh
- **Verification:** test_no_docs_fields_ok and test_init_docs_requires_docs_repo no longer crash; test_no_docs_fields_ok is properly RED
- **Committed in:** ab54d81

---

**Total deviations:** 3 auto-fixed (3 bug fixes)
**Impact on plan:** All fixes necessary for correct Wave 0 RED contract. No scope creep.

## Issues Encountered

- `test_init_docs_pat_scrub_on_error` was accidentally passing in Wave 0 because `do_profile_init_docs` doesn't exist yet, so the function error output naturally didn't contain the PAT string. Fixed by adding `declare -f do_profile_init_docs` guard that makes it explicitly RED.

## Wave 0 Test Function Inventory

| Function | Requirement | Wave 0 State |
|----------|-------------|--------------|
| test_fixtures_exist | - | GREEN (baseline) |
| test_test_map_registered | - | GREEN (baseline) |
| test_docs_repo_url_validation | BIND-01 | RED (validate_docs_binding missing) |
| test_valid_docs_binding | BIND-01 | RED (validate_docs_binding missing) |
| test_no_docs_fields_ok | BIND-01 | RED (validate_docs_binding missing) |
| test_docs_vars_exported | BIND-01 | RED (DOCS_REPO not exported) |
| test_projected_env_omits_docs_token | BIND-02 | RED (SECRETS_FILE not projected) |
| test_projected_env_omits_legacy_token | BIND-02 | RED (SECRETS_FILE not projected) |
| test_docs_token_absent_from_container | BIND-02 | RED (integration: docker required) |
| test_legacy_report_repo_alias | BIND-03 | RED (alias not implemented) |
| test_legacy_report_token_alias | BIND-03 | RED (alias not implemented) |
| test_deprecation_warning_rate_limit | BIND-03 | RED (deprecation warning missing) |
| test_init_docs_creates_layout | DOCS-01 | RED (do_profile_init_docs missing) |
| test_init_docs_single_commit | DOCS-01 | RED (do_profile_init_docs missing) |
| test_init_docs_idempotent | DOCS-01 | RED (do_profile_init_docs missing) |
| test_init_docs_requires_docs_repo | DOCS-01 | RED (do_profile_init_docs missing) |
| test_init_docs_pat_scrub_on_error | DOCS-01 | RED (do_profile_init_docs missing) |

## Regression Status

- Phase 12 test suite: 19/19 PASS (unaffected)
- Phase 7 test suite: exits 0 (Docker build expected-fail in sandbox environment)
- Phase 16 test suite: not run (no changes to webhook/result-channel code)

## Next Phase Readiness

- Plan 02 has 12 deterministic RED targets to flip green (BIND-01 x4, BIND-02 x2, BIND-03 x3, plus partial BIND-02 integration)
- Plan 03 has 5 deterministic RED targets to flip green (DOCS-01 x5)
- Both fixtures are installed and valid — Plans 02/03 can use them without creating ad-hoc files

---
*Phase: 23-profile-doc-repo-binding*
*Completed: 2026-04-13*
