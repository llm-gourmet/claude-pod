---
phase: 15
slug: event-handlers
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-12
updated: "2026-04-14"
---

# Phase 15 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution. Derived verbatim from `15-RESEARCH.md` Validation Architecture section (28-row test map), with task IDs filled in by the planner.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration tests with stub `claude-secure` on `$PATH` (inherits the Phase 14 harness pattern — `install_stub`, `setup_test_profile`, `start_listener`, `gen_sig`) |
| **Config file** | `tests/test-map.json` — add `webhook/templates/` path mapping and ensure `bin/claude-secure` + `webhook/` + `install.sh` include `test-phase15.sh` |
| **Quick run command** | `bash tests/test-phase15.sh <test_name>` (single-test invocation) |
| **Full suite command** | `bash tests/test-phase15.sh` |
| **Regression commands** | `bash tests/test-phase13.sh && bash tests/test-phase14.sh` (must stay green) |
| **Estimated runtime** | ~30 seconds (stubbed `claude-secure`, no real Docker) |

---

## Sampling Rate

- **Per task commit:** `bash tests/test-phase15.sh <single_test_name>` (fast, ~2s per test case)
- **Per plan wave:** `bash tests/test-phase15.sh` (full Phase 15 suite, ~30s with listener startup)
- **Phase gate (before `/gsd:verify-work`):** All three suites green in sequence:
  ```
  bash tests/test-phase13.sh && \
  bash tests/test-phase14.sh && \
  bash tests/test-phase15.sh
  ```
- **Max feedback latency:** ~35 seconds (single suite), ~2 minutes (all three)

---

## Per-Task Verification Map

> 28 rows lifted from `15-RESEARCH.md` "Phase Requirements → Test Map" plus two regression suites. Task IDs reference the plan numbering below. Plan 15-01 creates every `tests/test-phase15.sh` entry in its Wave 0 stub form; later plans transition them from red to green.

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 15-01-T1 | 15-01 | 0 | Infra | harness | `test -x tests/test-phase15.sh` | ❌ W0 | ⬜ pending |
| 15-01-T2 | 15-01 | 0 | Infra | fixture gate | `jq -e . tests/fixtures/github-issues-labeled.json` | ❌ W0 | ⬜ pending |
| 15-01-T3 | 15-01 | 0 | Infra | fixture gate | `jq -e . tests/fixtures/github-ping.json` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-03 | integration | `bash tests/test-phase15.sh test_issues_opened_routes` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-03 | integration | `bash tests/test-phase15.sh test_issues_labeled_routes` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-03 | integration | `bash tests/test-phase15.sh test_issues_closed_filtered` | ❌ W0 | ⬜ pending |
| 15-02-T2 | 15-02 | 1 | HOOK-03 | file | `bash tests/test-phase15.sh test_default_template_issues_opened_exists` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-04 | integration | `bash tests/test-phase15.sh test_push_main_routes` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-04 | integration | `bash tests/test-phase15.sh test_push_feature_branch_filtered` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-04 | integration | `bash tests/test-phase15.sh test_push_bot_loop_filtered` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-04 | integration | `bash tests/test-phase15.sh test_push_branch_delete_no_crash` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-05 | integration | `bash tests/test-phase15.sh test_workflow_run_failure_routes` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-05 | integration | `bash tests/test-phase15.sh test_workflow_run_success_filtered` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | HOOK-05 | integration | `bash tests/test-phase15.sh test_workflow_run_in_progress_filtered` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | HOOK-05 | unit (dry-run) | `bash tests/test-phase15.sh test_workflow_template_dry_run` | ❌ W0 | ⬜ pending |
| 15-03-T3 | 15-03 | 1 | HOOK-07 | integration | `bash tests/test-phase15.sh test_replay_finds_single_match` | ❌ W0 | ⬜ pending |
| 15-03-T3 | 15-03 | 1 | HOOK-07 | integration | `bash tests/test-phase15.sh test_replay_ambiguous_errors` | ❌ W0 | ⬜ pending |
| 15-03-T3 | 15-03 | 1 | HOOK-07 | integration | `bash tests/test-phase15.sh test_replay_no_match_errors` | ❌ W0 | ⬜ pending |
| 15-03-T3 | 15-03 | 1 | HOOK-07 | integration | `bash tests/test-phase15.sh test_replay_auto_profile` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | D-01/D-02 | unit | `bash tests/test-phase15.sh test_compute_event_type_cases` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | D-04 | integration | `bash tests/test-phase15.sh test_ping_event_filtered` | ❌ W0 | ⬜ pending |
| 15-03-T1 | 15-03 | 1 | D-17/D-18 | unit | `bash tests/test-phase15.sh test_extract_field_truncates` | ❌ W0 | ⬜ pending |
| 15-03-T1 | 15-03 | 1 | D-17 | unit | `bash tests/test-phase15.sh test_extract_field_utf8_safe` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | Pitfall 1 | unit | `bash tests/test-phase15.sh test_render_handles_pipe_in_value` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | Pitfall 1 | unit | `bash tests/test-phase15.sh test_render_handles_backslash_in_value` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | D-13 | unit | `bash tests/test-phase15.sh test_resolve_template_fallback_chain` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | D-13 | unit | `bash tests/test-phase15.sh test_explicit_template_no_default_fallback` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | D-15 | unit | `bash tests/test-phase15.sh test_webhook_templates_dir_env_var` | ❌ W0 | ⬜ pending |
| 15-04-T1 | 15-04 | 2 | D-12 | grep contract | `bash tests/test-phase15.sh test_install_copies_templates_dir` | ❌ W0 | ⬜ pending |
| 15-02-T1 | 15-02 | 1 | D-02 | integration | `bash tests/test-phase15.sh test_event_file_has_top_level_event_type` | ❌ W0 | ⬜ pending |
| 15-03-T2 | 15-03 | 1 | D-03 | unit | `bash tests/test-phase15.sh test_spawn_event_type_priority` | ❌ W0 | ⬜ pending |
| 15-02-T1, 15-03-T* | all | 1 | Regression | integration | `bash tests/test-phase13.sh` | ✅ | ⬜ pending |
| 15-02-T1, 15-03-T* | all | 1 | Regression | integration | `bash tests/test-phase14.sh` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements (Plan 15-01)

- [ ] `tests/test-phase15.sh` — created, executable, stubs `claude-secure` on PATH, sources or inlines the Phase 14 harness helpers (`install_stub`, `setup_test_profile`, `start_listener`, `gen_sig`). All 28 test functions present as named shell functions (many FAIL until Wave 1/2 land — self-healing red→green per Phase 14 precedent).
- [ ] `tests/fixtures/github-issues-labeled.json` — `action=labeled`, `issue.labels=[{name:"bug"}]`, top-level `label.name=bug`
- [ ] `tests/fixtures/github-push-feature-branch.json` — `ref=refs/heads/feature/xyz`
- [ ] `tests/fixtures/github-push-bot-loop.json` — `ref=refs/heads/main`, `pusher.name=claude-bot`
- [ ] `tests/fixtures/github-push-branch-delete.json` — `ref=refs/heads/old`, `deleted=true`, `head_commit=null`
- [ ] `tests/fixtures/github-workflow-run-failure.json` — `action=completed`, `workflow_run.conclusion=failure`, `workflow.name=CI`
- [ ] `tests/fixtures/github-workflow-run-success.json` — `action=completed`, `workflow_run.conclusion=success`
- [ ] `tests/fixtures/github-workflow-run-in-progress.json` — `action=in_progress`, `workflow_run.conclusion=null`
- [ ] `tests/fixtures/github-ping.json` — `zen="..."`, `hook_id=123`, `repository.full_name=test-org/test-repo`, NO `action`, NO `issue`
- [ ] `tests/fixtures/github-issues-opened-with-pipe.json` — `issue.title` containing `|`, `issue.body` containing `|` AND `\` (Pitfall 1 regression)
- [ ] `tests/test-map.json` — add `{"paths": ["webhook/templates/"], "tests": ["test-phase15.sh"]}`, ensure `bin/claude-secure`, `webhook/`, `install.sh`, and `tests/test-phase15.sh` entries include `test-phase15.sh`
- [ ] `.planning/phases/15-event-handlers/15-VALIDATION.md` — this file

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real GitHub → live webhook → Issue event (opened) produces a spawn | HOOK-03 | Requires a public endpoint, GitHub webhook config, and a real issue creation | Configure webhook in GitHub repo settings; open a new issue; confirm `~/.claude-secure/events/` shows a file with top-level `event_type=issues-opened`; confirm `~/.claude-secure/logs/spawns/<delivery>.log` exists |
| Real GitHub → live webhook → push to `main` produces a spawn | HOOK-04 | Same reason | Push a commit to `main`; confirm spawn log exists and templates render `{{BRANCH}}=main`, `{{COMMIT_SHA}}`, `{{COMMIT_MESSAGE}}` |
| Real GitHub → live webhook → failed workflow_run produces a spawn | HOOK-05 | Requires a broken Actions workflow that actually fails | Push a commit that fails CI; confirm the `workflow_run-completed` payload lands, filter allows it (conclusion=failure), spawn log contains `WORKFLOW_NAME` from top-level `workflow.name` (not empty from `workflow_run.name`) |
| Filter rejections are observable | HOOK-03/04/05 | Requires inspecting `webhook.jsonl` | `tail -f ~/.claude-secure/logs/webhook.jsonl` while sending rejected events (push to `feature/*`, `workflow_run` with conclusion=success, `issues` closed) — confirm `event=filtered` lines with `reason=<filter-name>` |
| `claude-secure replay <delivery-id>` UX | HOOK-07 | Requires real event files on disk and terminal interaction for ambiguous/no-match error messaging | After any real event lands: `claude-secure replay <first-8-chars-of-delivery>` must invoke `spawn --event-file` via `exec`; ambiguous substring prints candidate list and errors; zero matches prints clear error |
| `ping` event from GitHub "Test" button produces no spawn | Pitfall 4 | Requires clicking the Test delivery button in GitHub webhook settings | Send the test ping from GitHub UI; confirm `webhook.jsonl` shows a single `event=filtered reason=unsupported_event:ping` entry and zero spawn logs |
| Install smoke test: `/opt/claude-secure` has no `.git` leak | Pitfall 9 | Requires running the real installer | After `sudo bash install.sh --with-webhook`: `find /opt/claude-secure -name .git` must be empty so the dev-checkout fallback in `_resolve_default_templates_dir` does not false-positive |

---

## Validation Sign-Off

- [ ] All Wave 1/2 tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 (Plan 15-01) covers all MISSING references (`tests/test-phase15.sh`, 9 fixtures, test-map update, this validation file)
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s for single-suite runs
- [ ] `nyquist_compliant: true` set in frontmatter (flipped by plan-checker once Wave 0 ships)
- [ ] Phase 13 + Phase 14 regression suites listed as required gates on every plan that touches `bin/claude-secure` or `webhook/listener.py`

**Approval:** pending
