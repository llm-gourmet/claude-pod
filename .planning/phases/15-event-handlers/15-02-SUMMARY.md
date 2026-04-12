---
phase: 15-event-handlers
plan: "02"
subsystem: webhook-listener
tags:
  - event-routing
  - filter
  - templates
  - HOOK-03
  - HOOK-04
  - HOOK-05
dependency_graph:
  requires:
    - phase: 14-webhook-listener
      plans: ["02"]
    - phase: 15-event-handlers
      plans: ["01"]
  provides:
    - composite event type derivation (compute_event_type)
    - per-profile event filter (apply_event_filter) with sane defaults
    - top-level event_type field on persisted payload JSON
    - filtered/routed JSONL log events
    - four default prompt templates consumed by Plan 15-03 spawn renderer
  affects:
    - bin/claude-secure (consumed indirectly via event_type + templates dir)
tech_stack:
  added: []
  patterns:
    - dispatch-table filter keyed on X-GitHub-Event base
    - zero-I/O filter evaluation (profile dict loaded upstream)
    - additive backward-compat logging (routed + received both emitted)
key_files:
  created:
    - webhook/templates/issues-opened.md
    - webhook/templates/issues-labeled.md
    - webhook/templates/push.md
    - webhook/templates/workflow_run-completed.md
  modified:
    - webhook/listener.py
    - .gitignore
decisions:
  - Expand resolve_profile_by_repo to carry webhook_event_filter and webhook_bot_users so apply_event_filter runs with zero I/O (Pitfall 3)
  - Emit BOTH event=routed (new, D-23) and event=received (Phase 14 compat) for accepted events
metrics:
  duration: "~7min"
  completed_date: 2026-04-12
  tasks_completed: 2
  files_touched: 6
requirements:
  - HOOK-03
  - HOOK-04
  - HOOK-05
---

# Phase 15 Plan 02: Event Filtering, Routing, and Default Templates Summary

Added composite event type derivation and a per-profile event filter between HMAC verification and event persistence in the webhook listener, plus the four default prompt templates that the Plan 15-03 spawn renderer will consume.

## What Changed

### webhook/listener.py (604 lines, +142 net)

Three new module-level symbols introduced above the existing `Config` class:

- `DEFAULT_FILTER` — module constant mapping base event type to default filter config (D-06). Values:
  - `issues` → `{actions: [opened, labeled], labels: []}`
  - `push` → `{branches: [main, master]}`
  - `workflow_run` → `{conclusions: [failure], workflows: []}`
- `compute_event_type(headers, payload) -> str` — collapses `(X-GitHub-Event, payload.action)` into a composite string per D-01. Header arg may be a dict or `http.client.HTTPMessage`. Examples:
  - `('issues', 'opened')` → `issues-opened`
  - `('push', None)` → `push`
  - `('ping', None)` → `ping`
  - `('workflow_run', 'completed')` → `workflow_run-completed`
- `apply_event_filter(profile, event_type, payload) -> (allowed, reason)` — D-05..D-10. Re-derives `base = event_type.split("-", 1)[0]` and dispatches to issues/push/workflow_run branches. Unknown bases return `(False, "unsupported_event:<base>")`, which is how the latent Phase 14 `ping` bug (Pitfall 4) is closed. Push branch enforces loop prevention (`webhook_bot_users`) before branch matching (D-09).

Three existing functions modified:

- `resolve_profile_by_repo()` — extended return dict with `webhook_event_filter` and `webhook_bot_users` fields (loaded from the same single disk read). This keeps the filter zero-I/O (Pitfall 3). Previously-returned fields (`name`, `repo`, `webhook_secret`) are unchanged so Phase 14 callers still work.
- `persist_event()` — injects `payload["event_type"] = event_type` at the top level before the existing `_meta` block (D-02). `_meta.event_type` is deliberately retained for backward compatibility with pre-Phase-15 event files.
- `WebhookHandler.do_POST()` — between the HMAC `compare_digest` branch (line ~347) and the `persist_event` call, the handler now:
  1. Resolves `event_type = compute_event_type(self.headers, payload)`
  2. Runs `allowed, reason = apply_event_filter(profile, event_type, payload)`
  3. If `not allowed`: logs `event=filtered` with `reason`, returns `202 {"status":"filtered","reason":...}` without persisting or spawning
  4. Otherwise persists, logs `event=routed` (new, D-23) AND `event=received` (Phase 14 compat), spawns, and returns `202 {"status":"accepted",...}`

### webhook/templates/ (new directory, 4 files)

Copied verbatim from `.planning/phases/15-event-handlers/15-RESEARCH.md` lines 847-937:

| File | Variables used (D-16) |
|------|----------------------|
| `issues-opened.md` | REPO_NAME, ISSUE_NUMBER, ISSUE_TITLE, ISSUE_AUTHOR, ISSUE_URL, ISSUE_LABELS, ISSUE_BODY |
| `issues-labeled.md` | same as issues-opened |
| `push.md` | REPO_NAME, BRANCH, COMMIT_SHA, COMMIT_AUTHOR, PUSHER, COMPARE_URL, COMMIT_MESSAGE |
| `workflow_run-completed.md` | REPO_NAME, WORKFLOW_NAME, WORKFLOW_RUN_ID, BRANCH, COMMIT_SHA, WORKFLOW_CONCLUSION, WORKFLOW_RUN_URL |

Cross-contamination grep checks confirmed: `push.md` has no `ISSUE_TITLE` or `WORKFLOW_NAME`; `issues-opened.md` has no `COMMIT_SHA`.

### .gitignore

Added `__pycache__/` and `*.pyc` — Python compiled-artifact output generated by running tests against `webhook/listener.py`.

## Test Results

### Phase 15 listener-side tests (all green)

```
PASS: test_compute_event_type_cases
PASS: test_issues_opened_routes
PASS: test_issues_labeled_routes
PASS: test_issues_closed_filtered
PASS: test_push_main_routes
PASS: test_push_feature_branch_filtered
PASS: test_push_bot_loop_filtered
PASS: test_push_branch_delete_no_crash
PASS: test_workflow_run_failure_routes
PASS: test_workflow_run_success_filtered
PASS: test_workflow_run_in_progress_filtered
PASS: test_ping_event_filtered
PASS: test_event_file_has_top_level_event_type
PASS: test_default_template_issues_opened_exists
```

### Phase 14 regression (no new failures)

```
Results: 15/16 passed, 1 failed
```

The single failing test is `test_unit_file_lint`, a pre-existing sandbox limitation documented in the plan prompt ("not your concern"). It is unrelated to any Phase 15 change.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Expand resolve_profile_by_repo return fields**
- **Found during:** Task 1 verification (`test_push_bot_loop_filtered` failure)
- **Issue:** The plan calls `apply_event_filter(profile, ...)` expecting `profile["webhook_bot_users"]` and `profile["webhook_event_filter"]`, but Phase 14's `resolve_profile_by_repo` only returned `{name, repo, webhook_secret}`. Without expanding the return dict, the filter has no way to see the per-profile fields the test harness writes into `profile.json`.
- **Fix:** Added `webhook_event_filter` (default `{}`) and `webhook_bot_users` (default `[]`) to the returned dict. Loads happen from the same single `json.loads(profile_json.read_text())` already running in the resolver — zero new I/O, Pitfall 3 still honored.
- **Files modified:** `webhook/listener.py` (resolve_profile_by_repo)
- **Commit:** 0bbb6fd (rolled into Task 1 commit)

## Authentication Gates

None encountered.

## Explicit Scope Boundary

`bin/claude-secure` is **not** modified by this plan. Plan 15-03 handles all spawn-side work (render_template, extract_payload_field, resolve_template fallback chain, replay subcommand). Plan 15-03 committed in parallel while this plan was executing (commit `4eb6dd1`); no file overlap — 15-03 touches only `bin/claude-secure`, 15-02 touches `webhook/listener.py` + `webhook/templates/`.

`install.sh` is also not modified — Plan 15-04 handles installer integration of the new templates directory.

## Self-Check: PASSED

- FOUND: webhook/templates/issues-opened.md
- FOUND: webhook/templates/issues-labeled.md
- FOUND: webhook/templates/push.md
- FOUND: webhook/templates/workflow_run-completed.md
- FOUND: webhook/listener.py (compute_event_type, apply_event_filter, DEFAULT_FILTER)
- FOUND: commit 0bbb6fd (listener filter)
- FOUND: commit 47117a8 (templates)
