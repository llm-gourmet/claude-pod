---
phase: 15-event-handlers
verified: 2026-04-12T00:00:00Z
status: passed
score: 4/4 must-haves verified
verdict: PASS
requirements_delivered:
  - HOOK-03
  - HOOK-04
  - HOOK-05
  - HOOK-07
tests:
  phase_15: "28/28 passed"
  phase_14_regression: "15/16 passed (1 pre-existing sandbox-only failure: test_unit_file_lint — documented in deferred-items.md)"
  phase_13_regression: "16/16 passed"
pitfalls_verified:
  - "Pitfall 1 (sed-escape): no `sed s|{{...}}|...` patterns in bin/claude-secure — uses awk-from-file substitution"
  - "Pitfall 4 (UTF-8 truncation): no `head -c` or `cut -b` in bin/claude-secure — uses python3 with env-var payload"
  - "Pitfall 6 (workflow_run.name empty): `.workflow.name // .workflow_run.name` present at line 642"
  - "Pitfall 7 (null head_commit): `.head_commit.message // empty` and `.issue.body // empty` null-safe jq patterns present"
---

# Phase 15: Event Handlers Verification Report

**Phase Goal:** Incoming GitHub events are routed to the correct profile and dispatched with appropriate prompts.
**Verified:** 2026-04-12
**Status:** PASS
**Re-verification:** No — initial verification.

## Goal Achievement

### Observable Truths (from ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Issue event (opened/labeled) routes to profile and spawns headless session with issue context | VERIFIED | `tests/test-phase15.sh` HOOK-03 block: 4/4 PASS — issues opened routes, issues labeled routes, issues closed filtered, default template issues-opened dry-run renders `{{ISSUE_TITLE}}`, `{{ISSUE_NUMBER}}` |
| 2 | Push-to-main event routes to profile and spawns headless session with commit context | VERIFIED | `tests/test-phase15.sh` HOOK-04 block: 4/4 PASS — push main routes, push feature branch filtered, push bot-loop filtered, push branch-delete no-crash |
| 3 | CI failure (workflow_run completed with failure) routes to profile and spawns with failure context | VERIFIED | `tests/test-phase15.sh` HOOK-05 block: 4/4 PASS — workflow_run failure routes, success filtered, in_progress filtered, workflow dry-run renders `{{WORKFLOW_NAME}}`, `{{WORKFLOW_CONCLUSION}}` |
| 4 | User can replay a stored webhook payload via CLI command | VERIFIED | `tests/test-phase15.sh` HOOK-07 block: 4/4 PASS — replay finds single match, replay ambiguous errors, replay no-match errors, replay auto-profile resolution |

**Score:** 4/4 success criteria verified.

### Required Artifacts (Level 1–3)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `webhook/templates/issues-opened.md` | Default Issue-opened template | VERIFIED | Exists, 20 lines, references `{{REPO_NAME}}`, `{{ISSUE_NUMBER}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{ISSUE_AUTHOR}}`, `{{ISSUE_URL}}`, `{{ISSUE_LABELS}}` — all in D-16 table |
| `webhook/templates/issues-labeled.md` | Default Issue-labeled template | VERIFIED | Exists, 19 lines, references `{{ISSUE_LABELS}}`, `{{ISSUE_NUMBER}}`, `{{REPO_NAME}}`, etc. — all in D-16 |
| `webhook/templates/push.md` | Default push template | VERIFIED | Exists, 21 lines, references `{{BRANCH}}`, `{{REPO_NAME}}`, `{{COMMIT_SHA}}`, `{{COMMIT_AUTHOR}}`, `{{PUSHER}}`, `{{COMPARE_URL}}`, `{{COMMIT_MESSAGE}}` — all in D-16 |
| `webhook/templates/workflow_run-completed.md` | Default CI failure template | VERIFIED | Exists, 20 lines, references `{{REPO_NAME}}`, `{{WORKFLOW_NAME}}`, `{{WORKFLOW_RUN_ID}}`, `{{WORKFLOW_CONCLUSION}}`, `{{BRANCH}}`, `{{COMMIT_SHA}}`, `{{WORKFLOW_RUN_URL}}` — all in D-16 |
| `webhook/listener.py` | Event-aware dispatcher | VERIFIED | Contains `compute_event_type` (line 44), `apply_event_filter` (line 66), top-level `event_type` injection (line 269), filtered/routed logging (lines 480, 514), ping → `unsupported_event:ping` via DEFAULT_FILTER fallthrough (line 79) |
| `bin/claude-secure` | Extended spawn + replay | VERIFIED | Contains `_resolve_default_templates_dir` (389), `extract_payload_field` (417), generalized `_substitute_token_from_file`/`_substitute_multiline_token_from_file` awk-from-file (475/506), extended `resolve_template` fallback (520), extended `render_template` per D-16 (568), `do_replay` using `exec` recursion (797/882), event_type priority `.event_type // ._meta.event_type // .action` (722, 582) |
| `install.sh` | Copies webhook/templates/ | VERIFIED | Lines 348–356 `mkdir -p /opt/claude-secure/webhook/templates` + `cp "$app_dir/webhook/templates/"*.md ...` |
| `tests/test-phase15.sh` | 28 named tests | VERIFIED | 28/28 PASS in a single run |
| `tests/fixtures/github-*.json` | 9 new fixtures | VERIFIED | 11 total present (9 net-new vs. Phase 14 baseline): github-issues-labeled, github-issues-opened-with-pipe, github-ping, github-push-bot-loop, github-push-branch-delete, github-push-feature-branch, github-workflow-run-failure, github-workflow-run-in-progress, github-workflow-run-success |
| `tests/test-map.json` | Phase 15 mappings | VERIFIED | Lines 8–11, 22 map `install.sh`, `bin/claude-secure`, `webhook/`, `webhook/templates/`, `tests/test-phase15.sh` → `test-phase15.sh` |

### Key Link Verification (Wiring)

| From | To | Via | Status | Evidence |
|------|----|----|--------|----------|
| `listener.py do_POST` | `compute_event_type(headers, payload)` | post-HMAC, pre-persist call | WIRED | Line 473 calls `compute_event_type(self.headers, payload)` after HMAC compare at 457 and before `persist_event` at 493 |
| `listener.py do_POST` | `apply_event_filter(profile, event_type, payload)` | filter check returning (allowed, reason) | WIRED | Line 477 calls `apply_event_filter`; on `not allowed` returns 202 with `status: filtered` (line 488) without persisting or spawning |
| `listener.py persist_event` | top-level `event_type` field | `payload["event_type"] = event_type` | WIRED | Line 269 injects the canonical field BEFORE the `_meta` dict on line 270 (kept for backward compat per D-02) |
| `listener.py filtered path` | `webhook.jsonl event=filtered` | `log_event(event='filtered', reason=...)` | WIRED | Line 480 emits `event="filtered"` with `reason=...`, `status_code=202` |
| `listener.py accepted path` | `webhook.jsonl event=routed` | `log_event(event='routed', ...)` | WIRED | Line 514 emits `event="routed"` immediately before `spawn_async` at line 532; Phase 14's `event="received"` is retained at line 524 for back-compat |
| `bin/claude-secure do_spawn` | event_type priority extraction | `.event_type // ._meta.event_type // .action // "unknown"` | WIRED | Line 722 (do_spawn) and line 582 (render_template) both use this jq priority |
| `bin/claude-secure resolve_template` | WEBHOOK_TEMPLATES_DIR fallback | `_resolve_default_templates_dir` | WIRED | `resolve_template` (520) falls through profile dir → `_resolve_default_templates_dir` (389) which honors env var → dev checkout → `/opt/claude-secure/webhook/templates` |
| `bin/claude-secure do_replay` | reuses do_spawn via exec | `exec "$CLAUDE_SECURE_EXEC:-$0"` with `spawn --event-file` | WIRED | Line 882: `exec "$exec_target" --profile "$explicit_profile" spawn --event-file "$event_file"` — no duplication of spawn lifecycle |
| `install.sh install_webhook_service` | `/opt/claude-secure/webhook/templates/` | `cp "$app_dir/webhook/templates/"*.md` | WIRED | Lines 349–356 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|---------------------|--------|
| `listener.py` persisted event JSON | `payload["event_type"]` | `compute_event_type(self.headers, payload)` at line 473 | Yes — composite string from live GitHub headers + payload action | FLOWING |
| `bin/claude-secure` rendered prompt | `$rendered_prompt` | `render_template` extracts via jq from event JSON → `extract_payload_field` (D-17/D-18 hygiene) → awk substitution | Yes — every token in each default template has a corresponding `_extract_to_tempfile` + `_substitute_*` pair | FLOWING |
| `bin/claude-secure` event_type variable | `$event_type` | `jq -r '.event_type // ._meta.event_type // .action // "unknown"'` (line 722) | Yes — reads the top-level field persisted by listener | FLOWING |
| Replay flow | `$event_file` → spawn `--event-file` | Filename substring match on `~/.claude-secure/events/*.json` (line 837) + `resolve_profile_by_repo` (line 867) | Yes — end-to-end tested by `replay auto profile` and `replay finds single match` | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `compute_event_type` returns composite strings | `python3 -c "from webhook.listener import compute_event_type; ..."` | All cases return expected: `issues-opened`, `push`, `ping`, `workflow_run-completed` | PASS |
| `apply_event_filter` rejects ping | Python import + call on `{}, 'ping', {}` | Returns `(False, 'unsupported_event:ping')` | PASS |
| `apply_event_filter` default push filter rejects feature branches | Python import + call | Returns `(False, 'branch_not_matched:feature')` | PASS |
| `apply_event_filter` default workflow_run filter rejects success | Python import + call | Returns `(False, ...)` (only `failure` passes) | PASS |
| Pitfall 1 absent | `grep -E 'sed .s\|\{\{[A-Z_]+\}\}' bin/claude-secure` | No matches | PASS |
| Pitfall 4 absent | `grep -E 'head -c\|cut -b' bin/claude-secure` | No matches | PASS |
| Pitfall 6 present | `grep '.workflow.name // .workflow_run.name' bin/claude-secure` | Line 642 | PASS |
| Pitfall 7 present | `grep 'head_commit.message // empty' bin/claude-secure` | Line 659 | PASS |
| Phase 15 test suite | `bash tests/test-phase15.sh` | 28/28 passed, 0 failed | PASS |
| Phase 14 regression | `bash tests/test-phase14.sh` | 15/16 passed (1 pre-existing `test_unit_file_lint` sandbox-only failure — deferred item) | PASS |
| Phase 13 regression | `bash tests/test-phase13.sh` | 16/16 passed | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| HOOK-03 | 15-02 | Listener handles Issue events (opened, labeled) and dispatches to correct profile | SATISFIED | 4/4 HOOK-03 tests pass; `DEFAULT_FILTER` honors `actions=[opened, labeled]`; `issues-opened.md`, `issues-labeled.md` templates resolve via fallback chain |
| HOOK-04 | 15-02 | Listener handles Push-to-Main events and dispatches to correct profile | SATISFIED | 4/4 HOOK-04 tests pass; `DEFAULT_FILTER` honors `branches=[main, master]`; loop prevention via `webhook_bot_users` runs before branch match (D-09); branch-delete edge case covered |
| HOOK-05 | 15-02 | Listener handles CI Failure events (workflow_run completed with failure) and dispatches to correct profile | SATISFIED | 4/4 HOOK-05 tests pass; `DEFAULT_FILTER` requires `action=completed` AND `conclusion=failure`; `workflow_run-completed.md` template extracts `.workflow.name // .workflow_run.name` for Pitfall 6 safety |
| HOOK-07 | 15-03 | User can replay a stored webhook payload for debugging via CLI command | SATISFIED | 4/4 HOOK-07 tests pass; `replay <delivery-id>` subcommand uses `exec` recursion into `spawn --event-file`, auto-resolves profile from `.repository.full_name`, supports `--profile` override and `--dry-run`, errors on ambiguous/no match |

No orphaned requirements — REQUIREMENTS.md maps exactly HOOK-03/04/05/07 to Phase 15, and all four are covered by declared plans.

### Anti-Patterns Found

None.

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | No TODO/FIXME/XXX/HACK/PLACEHOLDER in `bin/claude-secure` or `webhook/` | — | — |
| — | — | No `head -c` / `cut -b` byte-unsafe truncation | — | — |
| — | — | No `sed s\|{{TOKEN}}\|$VALUE\|` escape-bug pattern | — | — |
| — | — | No `injection`, `sanitize`, `SEC-02`, or `instruction.override` code (D-19 honored — SEC-02 is Future Requirement) | — | — |

### Cross-Phase Integration

| Flow | Status | Evidence |
|------|--------|----------|
| Listener writes top-level `event_type` → spawn reads it | VERIFIED | `listener.py:269` writes `payload["event_type"] = event_type`; `claude-secure:722` reads `.event_type // ._meta.event_type // .action // "unknown"`; test `event file has top level type` and `spawn event_type priority` both PASS |
| Profile-level templates take precedence over defaults | VERIFIED | `resolve_template` (520) checks `$profile_dir/prompts/${event_type}.md` before `_resolve_default_templates_dir` fallback; test `resolve_template fallback chain` PASS |
| `WEBHOOK_TEMPLATES_DIR` env var overrides production path | VERIFIED | `_resolve_default_templates_dir` (389) honors env var first; test `WEBHOOK_TEMPLATES_DIR env var` PASS |
| Dev checkout auto-detection | VERIFIED | `_resolve_default_templates_dir` detects `$APP_DIR/.git` and uses `$APP_DIR/webhook/templates` (line 394) |
| Phase 14 `_meta.event_type` back-compat retained | VERIFIED | `persist_event` (270–275) still writes `_meta` sidecar alongside new top-level field; `render_template` and `do_spawn` include `._meta.event_type` as second-priority fallback |
| Phase 13 test suite unchanged | VERIFIED | 16/16 passing — spawn/template/envelope contracts unaffected by Phase 15 extensions |
| Filter runs AFTER HMAC, BEFORE persist | VERIFIED | Listener do_POST order: signature check (457) → compute_event_type (473) → apply_event_filter (477) → persist_event (493) — test `push feature branch filtered` confirms filtered events do not land in events dir |

### Human Verification Required

None. Automated test suite + code-level spot-checks cover all four success criteria end-to-end with stub binaries. No UI, no real-time behavior, no external services to test by hand.

### Gaps Summary

No gaps. Phase 15 delivers HOOK-03/04/05/07 end-to-end with full test coverage (28/28), zero regressions in Phases 13 (16/16) and 14 (15/16 — the 16th is the pre-existing documented `test_unit_file_lint` sandbox-only failure, unchanged by Phase 15). All four named pitfalls (1, 4, 6, 7) are defended in the actual code, not just in test assertions. D-19 (NO SEC-02) is honored — only D-17/D-18 hygiene is present, no prompt-injection code. Default templates exist, reference only D-16 variables, and are copied by `install.sh`. Cross-phase integration (listener → persist → spawn → render_template → resolve_template fallback chain) is wired and tested.

---

*Verified: 2026-04-12*
*Verifier: Claude (gsd-verifier)*
