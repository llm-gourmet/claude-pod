---
phase: 15-event-handlers
plan: 01
subsystem: testing
tags: [bash, jq, pytest-style-bash, github-webhooks, fixtures, nyquist-self-healing]

# Dependency graph
requires:
  - phase: 14-webhook-listener
    provides: webhook/listener.py + tests/test-phase14.sh harness pattern (install_stub, setup_test_profile, start_listener, gen_sig, printf '%s' HMAC)
  - phase: 13-headless-cli-path
    provides: bin/claude-secure spawn, resolve_template, render_template, --event-file, --dry-run
provides:
  - 9 GitHub webhook fixtures (3 regression fixtures for Pitfalls 1/4/7)
  - tests/test-phase15.sh with 28 named test functions (Wave 0 self-healing scaffold)
  - tests/test-map.json updated with webhook/templates/ path mapping
affects: [15-02-event-routing, 15-03-spawn-render-replay, 15-04-installer-templates]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Nyquist self-healing test scaffold: 28 named functions exist up front, many RED today, transition GREEN as Plans 15-02/15-03/15-04 ship"
    - "Test harness isolation: inline-copy (not source) Phase 14 helpers so test-phase15.sh runs standalone"
    - "Listener port 19015 (Phase 14 uses 19000) -- fixed ports per phase to avoid collisions"
    - "setup_test_profile accepts env-var overrides (TEST_WEBHOOK_EVENT_FILTER, TEST_WEBHOOK_BOT_USERS, TEST_INSTALL_PROMPTS)"
    - "seed_event_file helper: synthetic <iso>-<uuid8>.json filenames for replay substring-match tests"
    - "install_prompts_override helper: writes profile-level template overrides for fallback-chain tests"

key-files:
  created:
    - "tests/test-phase15.sh"
    - "tests/fixtures/github-issues-labeled.json"
    - "tests/fixtures/github-push-feature-branch.json"
    - "tests/fixtures/github-push-bot-loop.json"
    - "tests/fixtures/github-push-branch-delete.json"
    - "tests/fixtures/github-workflow-run-failure.json"
    - "tests/fixtures/github-workflow-run-success.json"
    - "tests/fixtures/github-workflow-run-in-progress.json"
    - "tests/fixtures/github-ping.json"
    - "tests/fixtures/github-issues-opened-with-pipe.json"
    - ".planning/phases/15-event-handlers/deferred-items.md"
  modified:
    - "tests/test-map.json"

key-decisions:
  - "Inline-copy (not source) Phase 14 harness helpers so test-phase15.sh is self-contained -- matches Phase 14 Plan 01 precedent"
  - "LISTENER_PORT=19015 (not 19000) to permit concurrent Phase 14+15 test runs"
  - "Stub claude-secure exits 0 immediately (no sleep 1.0) -- Phase 15 tests do not exercise semaphore concurrency (that lives in Phase 14)"
  - "Multi-mode PATH strategy: stub on PATH for HOOK-03/04/05 routing tests; real bin/claude-secure prepended for dry-run/replay/render tests"
  - "test_spawn_event_type_priority owns its setup end-to-end: creates profile-level prompts/priority-top.md with EVENT_TYPE={{EVENT_TYPE}} anchor, synthesizes event file with conflicting event_type/._meta.event_type/.action values"
  - "test_workflow_template_dry_run asserts stdout contains 'main' as the BRANCH fallback tripwire for the Plan 15-03 Region 2 latent bug (gated substitution)"
  - "seed_event_file accepts substring arg and embeds it in filename so replay tests can find by substring (matches D-22 delivery-id substring contract)"
  - "Phase 14 test_unit_file_lint pre-existing failure documented in deferred-items.md (out of scope for 15-01)"

patterns-established:
  - "Plan 15-01 = Wave 0 test scaffold (creates RED tests, later waves turn GREEN)"
  - "Fixtures encode regression pitfalls: ping (Pitfall 4), branch-delete/null head_commit (Pitfall 7), pipe+backslash (Pitfall 1), workflow.name=CI (Pitfall 6)"
  - "Every named test function has a non-trivial body -- never return 0/1 stubs -- so RED failures are informative"

requirements-completed: []  # HOOK-03/04/05/07 acceptance criteria require Plans 15-02/15-03/15-04 production code

# Metrics
duration: 8min
completed: 2026-04-12
---

# Phase 15 Plan 01: Wave 0 Test Scaffold Summary

**28-test Nyquist self-healing harness with 9 regression fixtures encoding Pitfalls 1/4/7, establishing the red-green contract for Phase 15 event handlers**

## Performance

- **Duration:** ~8 min
- **Tasks:** 3
- **Files created:** 11
- **Files modified:** 1 (tests/test-map.json)

## Accomplishments

- Locked the 28-row test contract from 15-VALIDATION.md before any production code changes. Every HOOK-03/04/05/07 behavior and every locked decision (D-01..D-22) is now expressed as a named bash function that later plans point their `<verify>` blocks at.
- Created 9 GitHub webhook fixtures — minimal-but-sufficient payload shapes matching GitHub's wire format, with `repository.full_name=test-org/test-repo` so they resolve through the existing Phase 14 test profile.
- Encoded three high-risk regression pitfalls as fixtures: ping (Pitfall 4 — no action/issue), branch-delete (Pitfall 7 — null head_commit), pipe-in-issue (Pitfall 1 — sed escape bug with literal `|` and `\`).
- Updated test-map.json: new `webhook/templates/` → `test-phase15.sh` mapping, plus `test-phase15.sh` added to `bin/claude-secure`, `webhook/`, `install.sh`, and self-referential entries.
- Phase 13 regression suite: 16/16 green after changes. Phase 14 regression suite: 15/16 (pre-existing `test_unit_file_lint` failure, documented as out-of-scope).

## Task Commits

1. **Task 1: Create 9 Phase 15 fixture files** — `a518a5c` (test)
2. **Task 2: Create tests/test-phase15.sh with 28 named test functions** — `3e70c24` (test)
3. **Task 3: Update tests/test-map.json with Phase 15 entries** — `bd6abee` (test)

## Files Created/Modified

### Fixtures (all in tests/fixtures/)
- `github-issues-labeled.json` — `action=labeled`, `issue.labels=[{name:bug},{name:triage}]`, top-level `label.name=bug`
- `github-push-feature-branch.json` — `ref=refs/heads/feature/xyz`, for push filter rejection
- `github-push-bot-loop.json` — `ref=refs/heads/main`, `pusher.name=claude-bot`, for loop_prevention test
- `github-push-branch-delete.json` — `deleted=true`, `head_commit=null` (Pitfall 7 regression)
- `github-workflow-run-failure.json` — `conclusion=failure`, `workflow.name=CI` (Pitfall 6 regression — top-level workflow.name, not workflow_run.name)
- `github-workflow-run-success.json` — `conclusion=success`, filter rejection test
- `github-workflow-run-in-progress.json` — `action=in_progress`, wrong-action filter test
- `github-ping.json` — has `zen` and `hook_id`, no `action`, no `issue` (Pitfall 4 regression, D-04 unsupported_event test)
- `github-issues-opened-with-pipe.json` — title `fix(api): handle | in header`, body contains `|` and `\` (Pitfall 1 regression)

### Test harness
- `tests/test-phase15.sh` — 886 lines, 28 named test functions, inlines Phase 14 helpers, LISTENER_PORT=19015, uses `printf '%s'` for HMAC body
- `tests/test-map.json` — added webhook/templates/ mapping + test-phase15.sh entries

### 28 test functions present

**HOOK-03 (green via Plan 15-02):**
1. `test_issues_opened_routes` — asserts 202, event file, top-level `event_type=issues-opened`, stub `--event-file` invocation
2. `test_issues_labeled_routes` — same shape with labeled fixture, asserts `event_type=issues-labeled`
3. `test_issues_closed_filtered` — synthesizes closed via jq, asserts 202, no event file, log `reason=issue_action_not_matched`, no stub
4. `test_default_template_issues_opened_exists` — file + grep contract on `webhook/templates/issues-opened.md` for `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{REPO_NAME}}`

**HOOK-04 (green via Plan 15-02):**
5. `test_push_main_routes` — 202, event file, stub invoked
6. `test_push_feature_branch_filtered` — 202, no event file, log `branch_not_matched` + `feature/xyz`
7. `test_push_bot_loop_filtered` — mutates profile to add `webhook_bot_users=["claude-bot"]`, asserts log `loop_prevention`
8. `test_push_branch_delete_no_crash` — asserts 202 (not 500) + listener PID still alive (null head_commit safety)

**HOOK-05 (green via Plan 15-02):**
9. `test_workflow_run_failure_routes` — 202, event file has `event_type=workflow_run-completed`, stub invoked
10. `test_workflow_run_success_filtered` — log `workflow_conclusion_not_matched` + `success`
11. `test_workflow_run_in_progress_filtered` — log `workflow_action_not_completed` + `in_progress`
12. `test_workflow_template_dry_run` — **BRANCH fallback tripwire**: invokes real bin/claude-secure --dry-run, asserts stdout contains `CI` (Pitfall 6), `289782451`, AND literal `main` (BRANCH resolved from `.workflow_run.head_branch` since failure fixture has no `.ref`)

**HOOK-07 (green via Plan 15-03):**
13. `test_replay_finds_single_match` — seeds one event file, asserts exit 0 + stub invocation
14. `test_replay_ambiguous_errors` — seeds two files with substring `abcd1234`, asserts non-zero exit + both filenames in stderr
15. `test_replay_no_match_errors` — asserts stderr contains `no event file matching`
16. `test_replay_auto_profile` — asserts stub was invoked with `--profile test-profile` (auto-resolved)

**Locked decisions (green via Plans 15-02/15-03/15-04):**
17. `test_compute_event_type_cases` — python3 unit test on `webhook.listener.compute_event_type` for 4 cases
18. `test_ping_event_filtered` — Pitfall 4 regression, log `unsupported_event:ping`
19. `test_extract_field_truncates` — D-17, 9000-byte input, asserts ≤8300 bytes + `truncated` suffix
20. `test_extract_field_utf8_safe` — 8190 ASCII + 4x snowman, asserts UTF-8 decode succeeds
21. `test_render_handles_pipe_in_value` — Pitfall 1, asserts stdout contains literal `fix(api): handle | in header`
22. `test_render_handles_backslash_in_value` — asserts stdout contains literal `path\to\file`
23. `test_resolve_template_fallback_chain` — D-13, removes profile override, asserts repo default template renders
24. `test_explicit_template_no_default_fallback` — D-13 step 1, explicit `--prompt-template nonsense` must fail, no default fallback
25. `test_webhook_templates_dir_env_var` — D-15, custom WEBHOOK_TEMPLATES_DIR with unique marker
26. `test_install_copies_templates_dir` — grep contract against install.sh (`webhook/templates`, `mkdir -p /opt/claude-secure/webhook/templates`)
27. `test_event_file_has_top_level_event_type` — D-02, both `.event_type` and `._meta.event_type`
28. `test_spawn_event_type_priority` — D-03, self-contained setup: creates `prompts/priority-top.md` with `EVENT_TYPE={{EVENT_TYPE}}` anchor, synthesizes event file with conflicting `event_type`/`_meta.event_type`/`action`, asserts stdout contains `EVENT_TYPE=priority-top` (proving .event_type wins)

## Decisions Made

- **Inline (not source) Phase 14 helpers** — test-phase15.sh is standalone for isolation, matching Phase 14 Plan 01 precedent.
- **LISTENER_PORT=19015** — fixed per-phase to allow concurrent Phase 14/15 test runs on the same machine.
- **Stub exits 0 immediately** — no `sleep 1.0` like Phase 14's stub because Phase 15 does not re-test semaphore concurrency (owned by Phase 14).
- **setup_test_profile env-var parameters** — TEST_WEBHOOK_EVENT_FILTER, TEST_WEBHOOK_BOT_USERS, TEST_INSTALL_PROMPTS let individual tests override without duplicating the whole setup function.
- **Multi-mode PATH**: HOOK-03/04/05 routing tests keep the stub first on PATH so the listener spawns the stub; dry-run/replay/render tests prepend `$PROJECT_DIR/bin` so the real CLI runs directly. `test_replay_*` uses `PATH="$TEST_TMPDIR/bin:$PROJECT_DIR/bin:$PATH"` so replay itself invokes the stub for the downstream spawn.
- **Dispatcher forwards all args** — `"$@"` (not `"$1"`) so single-test invocation can take extra args.

## Deviations from Plan

None — plan executed exactly as written. All 3 tasks completed with their verify blocks passing on the first attempt.

## Issues Encountered

- **Phase 14 pre-existing failure**: `tests/test-phase14.sh test_unit_file_lint` FAILs on main because `webhook/claude-secure-webhook.service` does not exist. Confirmed pre-existing by stashing 15-01 changes and re-running — the failure is unchanged. Belongs to Phase 14 Plan 03 (not shipped), out of scope for 15-01. Logged to `.planning/phases/15-event-handlers/deferred-items.md`.

## Self-Healing Red→Green Contract

Running `bash tests/test-phase15.sh` now produces many FAIL lines. **That is the intended Wave 0 state.** Per the Nyquist sampling pattern:

- The 28 named test functions lock the test contract at Plan 15-01 time.
- Plan 15-02 (listener routing + filter + default templates) flips HOOK-03/04/05 routing tests and the locked-decision tests that depend on listener behavior.
- Plan 15-03 (spawn render_template + resolve_template fallback + extract_payload_field + replay subcommand) flips HOOK-07 tests + unit tests + dry-run tests.
- Plan 15-04 (installer copies webhook/templates/ to /opt/claude-secure) flips `test_install_copies_templates_dir`.

Plan 15-01's `<verify>` block intentionally only checks `bash -n`, executable bit, and `grep -q` — NOT `bash tests/test-phase15.sh`, which would fail red.

## Regression Suites

- **Phase 13:** `bash tests/test-phase13.sh` — 16/16 passed (green)
- **Phase 14:** `bash tests/test-phase14.sh` — 15/16 passed (1 pre-existing failure unrelated to 15-01)

## Next Phase Readiness

- Wave 0 complete. Plans 15-02 and 15-03 can execute in parallel under Wave 1 — both point their `<verify>` blocks at `bash tests/test-phase15.sh <test_name>` and transition assertions from RED to GREEN.
- All fixtures and named test functions exist and match the 15-VALIDATION.md 28-row map.
- No blockers.

## Self-Check: PASSED

Files verified on disk:
- FOUND: tests/test-phase15.sh (executable, parses clean)
- FOUND: tests/fixtures/github-issues-labeled.json
- FOUND: tests/fixtures/github-push-feature-branch.json
- FOUND: tests/fixtures/github-push-bot-loop.json
- FOUND: tests/fixtures/github-push-branch-delete.json
- FOUND: tests/fixtures/github-workflow-run-failure.json
- FOUND: tests/fixtures/github-workflow-run-success.json
- FOUND: tests/fixtures/github-workflow-run-in-progress.json
- FOUND: tests/fixtures/github-ping.json
- FOUND: tests/fixtures/github-issues-opened-with-pipe.json
- FOUND: tests/test-map.json (updated, valid JSON)

Commits verified in git log:
- FOUND: a518a5c test(15-01): add 9 Phase 15 webhook fixtures
- FOUND: 3e70c24 test(15-01): add test-phase15.sh with 28 named test functions
- FOUND: bd6abee test(15-01): add Phase 15 entries to test-map.json

---
*Phase: 15-event-handlers*
*Completed: 2026-04-12*
