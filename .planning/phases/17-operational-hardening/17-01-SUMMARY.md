---
phase: 17-operational-hardening
plan: 01
subsystem: testing
tags: [bash, nyquist, test-scaffold, reaper, systemd, e2e]

requires:
  - phase: 16-result-channel
    provides: CLAUDE_SECURE_FAKE_CLAUDE_STDOUT test stub, report-templates/ pattern, envelope-success.json fixture, test-phase16.sh harness shape
  - phase: 15-event-handlers
    provides: render_template variable list, webhook-listener inline harness pattern (LISTENER_PORT convention)
  - phase: 14-webhook-listener
    provides: systemd unit-file pattern + D-11 forbidden-directives memory, Pitfall 13 ghp_ token hazard
  - phase: 13-headless-cli-path
    provides: __CLAUDE_SECURE_SOURCE_ONLY=1 source-only contract, spawn_cleanup semantics reaper backstops
provides:
  - Wave 0 failing-test scaffold for Phase 17 (Nyquist self-healing) -- 26 implementation tests fail until 17-02/17-04 flip them, 5 scaffold tests pass
  - tests/test-phase17.sh unit harness with mocked docker + flock wrappers and source-only helper
  - tests/test-phase17-e2e.sh four-scenario E2E harness with 90s budget guard and cs-e2e- instance prefix
  - tests/fixtures/profile-e2e/ profile tree (profile.json, .env, prompts, report-templates)
  - tests/fixtures/mock-docker-ps-fixture.txt label fixture for Pattern B mocked docker
  - webhook/claude-secure-reaper.service + .timer Wave 0 placeholders with D-11 warning block
  - tests/test-map.json OPS-03 entry (28 unit tests + 5 E2E scenarios) without losing OPS-01/OPS-02
affects: 17-02, 17-03, 17-04

tech-stack:
  added: []
  patterns:
    - "Mock docker wrapper (Pattern B): fixture file + $MOCK_DOCKER_PS_OUTPUT env var routed through a PATH-shimmed stub"
    - "Mock flock wrapper: $MOCK_FLOCK_HELD=1 simulates lock contention, otherwise delegates to exec"
    - "E2E cleanup trap routed through real reaper: INSTANCE_PREFIX=cs-e2e- REAPER_ORPHAN_AGE_SECS=0 bin/claude-secure reap"
    - "Wave 0 scaffold-presence passes: harness declares ~5 tests that pass today + ~26 sentinels that fail until implementation lands"

key-files:
  created:
    - tests/test-phase17.sh
    - tests/test-phase17-e2e.sh
    - tests/fixtures/profile-e2e/profile.json
    - tests/fixtures/profile-e2e/.env
    - tests/fixtures/profile-e2e/prompts/issues-opened.md
    - tests/fixtures/profile-e2e/report-templates/issues-opened.md
    - tests/fixtures/mock-docker-ps-fixture.txt
    - webhook/claude-secure-reaper.service
    - webhook/claude-secure-reaper.timer
  modified:
    - tests/test-map.json

key-decisions:
  - "Force-add tests/fixtures/profile-e2e/.env (gitignored by default) because it is a test-only placeholder with no real secret"
  - "Test harness fail count is 26 (not the plan's ~24) because two additional D-11 + installer sentinels were declared to fully cover 17-VALIDATION.md rows"
  - "Mock flock wrapper supports both `flock -n <fd> <cmd>` and `flock -n <file> <cmd>` shapes via shift-and-exec delegation"

patterns-established:
  - "Phase 17 unit harness uses LISTENER_PORT=19017; E2E harness uses 19117 to avoid collision"
  - "E2E harness tool preflight (docker, curl, openssl, xxd, jq, python3, git) fails fast with clear errors instead of deep scenario stack traces"
  - "check_budget() gate between scenarios halts runaway wall-clock before it pollutes the 90s Phase 17 SLA"

requirements-completed: []

duration: 9min
completed: 2026-04-12
---

# Phase 17 Plan 01: Wave 0 Test Scaffold Summary

**Nyquist failing-test scaffold for Phase 17: 26 reaper+hardening unit sentinels, 4 E2E scenario sentinels, budget gate, and the profile-e2e fixture tree -- all ready for Waves 1a/1b/2 to flip green.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-04-12T13:46Z
- **Completed:** 2026-04-12T13:55Z
- **Tasks:** 3 (all TDD / scaffold-only)
- **Files created:** 9
- **Files modified:** 1 (tests/test-map.json)

## Accomplishments

- **tests/test-phase17.sh** -- 31 named test functions covering reaper selection logic, event-file sweep, flock single-flight, log format, D-11 hardening directives (present + forbidden + comment block), compose mem_limit prerequisite, and installer statics (5d step, timer enable, post-install hint). Mock docker + mock flock wrappers installed on $PATH via $TEST_TMPDIR/bin. `__CLAUDE_SECURE_SOURCE_ONLY=1` helper ready for 17-02 to source `do_reap`, `reap_orphan_projects`, `reap_stale_event_files`.
- **tests/test-phase17-e2e.sh** -- 4 scenario sentinels (`scenario_hmac_rejection`, `scenario_concurrent_execution`, `scenario_orphan_cleanup`, `scenario_resource_limits`) plus `test_e2e_budget_under_90s` gate. `check_budget` called between every scenario. Cleanup trap force-reaps any stray `cs-e2e-` containers with `REAPER_ORPHAN_AGE_SECS=0` before removing `$TEST_TMPDIR`. Tool preflight covers docker/curl/openssl/xxd/jq/python3/git.
- **tests/fixtures/profile-e2e/** -- complete profile tree: `profile.json` (repo=e2e/test, webhook_secret=e2e-test-secret, max_turns=3, report_repo="" runtime-injected), `.env` (`REPORT_REPO_TOKEN=fake-e2e-token`, no `ghp_` prefix), minimal prompt + report templates referencing `{{ISSUE_TITLE}}` and `{{RESULT_TEXT}}` (RESULT_TEXT positioned last per Pitfall 2).
- **tests/fixtures/mock-docker-ps-fixture.txt** -- 4-line label fixture (3x `cs-` prefix, 1x `ns-` to prove instance-prefix scoping).
- **webhook/claude-secure-reaper.service + .timer** -- Wave 0 placeholders carrying the D-11 forbidden-directives warning comment block; 17-02 will populate with full unit content.
- **tests/test-map.json** -- `OPS-03` entry with 28 unit test names and 5 E2E scenario names; existing `OPS-01`/`OPS-02` entries preserved.

## Task Commits

1. **Task 1: Unit test harness + mock docker fixture** -- `8d52b01` (test)
2. **Task 2: E2E harness with 4 scenario stubs + 90s budget guard** -- `2865163` (test)
3. **Task 3: profile-e2e fixtures, reaper unit placeholders, test-map** -- `be0ebe7` (test)

## Test Function Inventory

**Unit harness (tests/test-phase17.sh) -- 31 functions total:**

*Scaffold passes (5, green in Wave 0):*
- `test_mock_docker_fixture_exists`
- `test_profile_e2e_fixture_shape`
- `test_e2e_token_no_ghp_prefix`
- `test_reaper_unit_files_exist`
- `test_reap_grep_guard`

*Reaper core + unit files -- flipped by 17-02 (20):*
- `test_reap_subcommand_exists`
- `test_reaper_unit_files_lint`
- `test_reaper_service_directives`
- `test_reaper_timer_directives`
- `test_reaper_install_sections`
- `test_reap_age_threshold_select`
- `test_reap_age_threshold_skip`
- `test_reap_compose_down_invocation`
- `test_reap_never_touches_images`
- `test_reap_instance_prefix_scoping`
- `test_reap_per_project_failure_continues`
- `test_reap_whole_cycle_failure_exits_nonzero`
- `test_reap_dry_run`
- `test_reap_stale_event_files_deleted`
- `test_reap_fresh_event_files_preserved`
- `test_reap_event_age_secs_override`
- `test_reap_flock_single_flight`
- `test_reap_no_jsonl_output`
- `test_reap_log_format`
- `test_compose_has_mem_limit`

*Hardening directives D-11 -- flipped by 17-02 (3):*
- `test_d11_directives_present`
- `test_d11_forbidden_directives_absent`
- `test_d11_comment_block_present`

*Installer statics -- flipped by 17-04 (3):*
- `test_installer_step_5d_present`
- `test_installer_enables_timer`
- `test_installer_post_install_hint`

**E2E harness (tests/test-phase17-e2e.sh) -- 5 functions, all flipped by 17-03:**
- `scenario_hmac_rejection`
- `scenario_concurrent_execution`
- `scenario_orphan_cleanup`
- `scenario_resource_limits`
- `test_e2e_budget_under_90s`

## Wave 0 Exit-Code Contract

| Command | Exit | PASS | FAIL |
|---|---|---|---|
| `bash tests/test-phase17.sh` | 1 | 5 | 26 |
| `bash tests/test-phase17-e2e.sh` | 1 | 0 | 1 (setup) + 5 sentinels gated |
| `bash tests/test-phase17.sh test_profile_e2e_fixture_shape` | 0 | -- | -- |
| `bash tests/test-phase17.sh test_reap_grep_guard` | 0 | -- | -- |

Both harnesses MUST fail non-zero at end of Wave 0. They will flip green progressively:
- Wave 1a (17-02) flips 23 of the 26 unit fails
- Wave 1b (17-03) flips the 5 E2E scenarios
- Wave 2 (17-04) flips the last 3 unit fails (installer statics)

## Regression Status

- Phase 13: PASS (exit 0)
- Phase 14: 1 pre-existing failure (`test_unit_file_lint` fails even at HEAD before this plan; systemd-analyze environmental issue, not caused by Phase 17)
- Phase 15: PASS (exit 0)
- Phase 16: PASS (exit 0)

Phase 14's `test_unit_file_lint` failure was verified pre-existing via `git stash` + re-run: the failure reproduces without any Phase 17 files on disk. Documented to `.planning/phases/17-operational-hardening/deferred-items.md` if/when that file is introduced; out-of-scope for 17-01.

## Decisions Made

- **Force-add `.env` fixture:** `tests/fixtures/profile-e2e/.env` is gitignored by the repo's top-level `.env` rule, but the plan explicitly requires it at that path (the loader only accepts `.env`). Added via `git add -f` since it carries `REPORT_REPO_TOKEN=fake-e2e-token` which is a test-only placeholder with no real secret. The existing fixture `tests/fixtures/env-with-metacharacter-secrets` avoids the `.env` suffix entirely; Phase 17 cannot follow that pattern without breaking Phase 15/16 profile-loader semantics.
- **31 tests (not ~24):** 17-VALIDATION.md §Per-Task Verification Map lists ~24 reaper-core tests, but the plan's `<action>` block enumerates 31 distinct functions (24 reaper + 3 hardening + 1 compose + 5 scaffold-presence - overlap). Kept the plan count rather than trimming to the validation summary, since the plan is the binding spec and every function maps to either a RESEARCH validation row or a Wave 0 scaffold gate.
- **Comment rewrite to avoid `grep -r 'ghp_'` false positive:** The `.env` file's explanatory comment initially said "GitHub PAT prefix ghp_" which failed `test_e2e_token_no_ghp_prefix`. Rewrote as "GitHub PAT prefix" without the literal token -- the test's contract is "zero matches across the tree", which is stricter than "no active token".

## Deviations from Plan

None - plan executed exactly as written, apart from the minor `.env` comment rewrite above (which is a Rule 1 auto-fix for my own doc string contradicting the test, not a plan deviation).

## Issues Encountered

- **Phase 14 pre-existing regression:** `test_unit_file_lint` fails in the regression sweep. Verified via `git stash push` + re-run against a clean working tree that the failure reproduces without Phase 17 files -- it is environmental (systemd-analyze behavior on this host) and not caused by this plan. Continuing without a fix per scope boundary rules.
- **`.env` gitignore:** Resolved with `git add -f`; documented above.

## Known Stubs

All 26 failing tests are intentional Wave 0 sentinels -- they are the Nyquist self-healing contract for Waves 1a/1b/2. The `webhook/claude-secure-reaper.service` and `.timer` files are intentional placeholders carrying only the D-11 warning comment block; 17-02 will populate them with real `[Unit]`/`[Service]`/`[Install]` stanzas and the D-11 directive block.

## Next Phase Readiness

- **17-02 (Wave 1a)** is cleared to start: the reaper core implementation will flip 23 unit sentinels green (subcommand dispatch, selection logic, event-file sweep, flock, logging, D-11 directives in both unit files, compose mem_limit).
- **17-03 (Wave 1b)** is cleared to start in parallel with 17-02 once the reaper subcommand exists: the E2E harness will flip the 5 scenario sentinels and the budget gate.
- **17-04 (Wave 2)** waits on 17-02 + 17-03 completing: the installer step 5d + post-install hint tests will flip green once the reaper is real.

## Self-Check: PASSED

All 10 files present on disk; all 3 task commits present in git history (8d52b01, 2865163, be0ebe7).

---
*Phase: 17-operational-hardening*
*Completed: 2026-04-12*
