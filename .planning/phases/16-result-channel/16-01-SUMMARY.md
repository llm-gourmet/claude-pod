---
phase: 16
plan: 01
subsystem: tests
tags: [wave-0, nyquist-self-healing, failing-scaffold, ops-01, ops-02]
requires:
  - Phase 15 test helper patterns (install_stub, setup_test_profile, run_test)
  - bash, jq, git, python3 on host
provides:
  - Failing test harness for OPS-01 (report push) and OPS-02 (audit log)
  - All Wave 0 fixtures for later waves to consume
  - Default report templates under webhook/report-templates/
affects:
  - tests/test-phase16.sh (new)
  - tests/fixtures/envelope-*.json (new)
  - tests/fixtures/env-with-metacharacter-secrets (new)
  - tests/fixtures/report-repo-bare/ (new placeholder)
  - tests/test-map.json (extended; existing entries preserved)
  - webhook/report-templates/*.md (new)
tech-stack:
  added: []
  patterns:
    - Nyquist self-healing (Wave 0 failing tests encode future contracts)
    - Sentinel-driven NOT-IMPLEMENTED pattern with per-wave tags
    - Local file:// bare repo helper for hermetic push tests
key-files:
  created:
    - tests/test-phase16.sh
    - tests/fixtures/envelope-success.json
    - tests/fixtures/envelope-legacy-cost.json
    - tests/fixtures/envelope-large-result.json
    - tests/fixtures/envelope-result-with-template-vars.json
    - tests/fixtures/envelope-error.json
    - tests/fixtures/env-with-metacharacter-secrets
    - tests/fixtures/report-repo-bare/README
    - tests/fixtures/report-repo-bare/.gitkeep
    - webhook/report-templates/issues-opened.md
    - webhook/report-templates/issues-labeled.md
    - webhook/report-templates/push.md
    - webhook/report-templates/workflow_run-completed.md
  modified:
    - tests/test-map.json
decisions:
  - "Wave 0 contract: harness exits nonzero with 28 FAIL + 3 PASS (fixtures_exist, templates_exist, no_force_push_grep)"
  - "setup_bare_repo helper uses git init --bare --initial-branch=main with a fallback path for older git"
  - "Single-function mode (bash tests/test-phase16.sh test_foo) invokes install_stub + setup_test_profile before the function, matching Phase 15 pattern"
  - "test-map.json: added OPS-01/OPS-02 as top-level keys alongside the existing mappings array (preserves Phase 1-15 path rules)"
  - "Metacharacter fixture contains 8 keys (PIPE/AMP/SLASH/BACKSLASH/DOLLAR/BRACKET/STAR/NEWLINE) per M-02 checker fix, plus EMPTY_VAL, QUOTED_VAL, REPORT_REPO_TOKEN"
metrics:
  tasks_completed: 3
  files_created: 13
  files_modified: 1
  tests_scaffolded: 31
  tests_passing_wave_0: 3
  tests_failing_wave_0: 28
  completed: 2026-04-12
---

# Phase 16 Plan 01: Wave 0 Test Scaffold (Nyquist Self-Healing) Summary

Wave 0 failing-test scaffold for Phase 16 Result Channel: 31 named test
functions encoding the OPS-01 (report push) and OPS-02 (audit log) contracts
from 16-VALIDATION.md, 6 envelope/.env fixtures, 4 default report templates,
and a local bare-repo helper — all committed such that later waves cannot
drift from the validation map.

## One-Liner

Test harness + fixtures + default report templates that fail intentionally
until 16-02/16-03/16-04 land, locking the Phase 16 contract into the repo.

## Task 1: tests/test-phase16.sh harness

Created `tests/test-phase16.sh` (435 lines, mode 755) cloning Phase 15's
helper structure:

- Shebang + `set -uo pipefail`, PASS/FAIL/TOTAL counters, `TEST_TMPDIR` via
  mktemp with trap EXIT cleanup.
- `LISTENER_PORT=19016` (unique per-phase to avoid collisions with Phase
  14's 19000 and Phase 15's 19015).
- `install_stub()` — recorder stub at `$TEST_TMPDIR/bin/claude-secure`
  that logs argv to `$STUB_LOG` and exits 0. Prepends `$TEST_TMPDIR/bin` to
  PATH.
- `setup_test_profile()` — creates
  `$TEST_TMPDIR/home/.claude-secure/profiles/test-profile/` with a
  `profile.json` containing `report_repo`, `report_branch`,
  `report_path_prefix`, plus `prompts/` and `report-templates/`
  sub-directories. Copies the metacharacter `.env` fixture into the profile
  by default (overridable via `TEST_ENV_FILE`). Parameterized by
  `TEST_REPORT_REPO`, `TEST_REPORT_BRANCH`, `TEST_REPORT_PATH_PREFIX`.
- `setup_bare_repo()` — `git init --bare --initial-branch=main` at
  `$TEST_TMPDIR/report-repo-bare.git`, seeds an initial commit with an
  empty `.gitkeep` via a scratch clone, then pushes. Uses per-clone
  `git config user.email seed@test.local` and `user.name seed` so tests
  never touch host git config. Has a fallback path for older git without
  `--initial-branch`. Echoes `file://$bare` for push targets.
- `restore_bare_repo()` — resets the bare repo between tests that mutate it.

### Test function roster (31 total)

**Scaffold invariants (3 — MUST PASS in Wave 0):**

- `test_fixtures_exist` — asserts all 6 fixture files + placeholder dir exist
- `test_templates_exist` — asserts 4 templates exist and contain `{{RESULT_TEXT}}`
- `test_no_force_push_grep` — static grep for force-push patterns in bin/claude-secure (passes because bin has no push code yet)

**OPS-01 Report Push (16 — all NOT IMPLEMENTED):**

- test_report_push_success, test_report_filename_format,
  test_commit_message_format, test_no_force_push_grep (static, in scaffold),
  test_rebase_retry, test_push_failure_audit_and_exit,
  test_secret_redaction_committed, test_redaction_empty_value_noop,
  test_redaction_metacharacters, test_pat_not_leaked_on_failure,
  test_report_template_fallback (16-02 target),
  test_no_report_repo_skips_push, test_result_text_truncation,
  test_result_text_no_recursive_substitution, test_crlf_and_null_stripped,
  test_clone_timeout_bounded

**OPS-02 Audit Log (13 — all NOT IMPLEMENTED, all 16-03 targets):**

- test_audit_file_path, test_audit_creates_log_dir,
  test_audit_jsonl_parseable, test_audit_has_mandatory_keys,
  test_audit_status_enum, test_audit_spawn_error, test_audit_claude_error,
  test_audit_cost_fallback, test_audit_line_under_pipe_buf,
  test_audit_concurrent_safe, test_audit_replay_identical,
  test_audit_manual_synthetic_id, test_audit_webhook_id_null_when_absent

Each NOT-IMPLEMENTED function echoes a descriptive sentinel like
`NOT IMPLEMENTED: flipped green by 16-03 (publish_report + do_spawn
integration)` and `return 1` — controlled failure, never an unbound
variable or missing file.

**Commit:** `40bd69e test(16-01): add Phase 16 failing test harness scaffold`

## Task 2: Wave 0 fixtures

Created all 6 fixture files plus the bare-repo placeholder directory and
extended `tests/test-map.json`:

- **tests/fixtures/envelope-success.json** — canonical claude envelope
  (`cost_usd`, `duration_ms`, `session_id`, `num_turns`).
- **tests/fixtures/envelope-legacy-cost.json** — Pitfall 5 legacy schema
  (`cost`, `duration` field names).
- **tests/fixtures/envelope-large-result.json** — 20017-byte result body
  built via python3 heredoc: `("ABCD" * 5000) + "\r\nEMBED\x00NUL\r\nTAIL"`.
  Verified via `python3 -c 'import json; ...'` to have result length >
  20000.
- **tests/fixtures/envelope-result-with-template-vars.json** — Pitfall 2
  regression fuel: result text contains literal `{{ISSUE_TITLE}}` and
  `{{REPO_NAME}}`.
- **tests/fixtures/envelope-error.json** — error envelope for `claude_error`
  path (`.error` instead of `.claude`).
- **tests/fixtures/env-with-metacharacter-secrets** — exactly 8 keys with
  dangerous metacharacters per M-02 checker fix: PIPE_VAL (|), AMP_VAL (&),
  SLASH_VAL (/), BACKSLASH_VAL (\\), DOLLAR_VAL ($1), BRACKET_VAL ([]),
  STAR_VAL (\*), **NEWLINE_VAL (\\n)**. Plus EMPTY_VAL (empty value),
  QUOTED_VAL, and REPORT_REPO_TOKEN sentinel.
- **tests/fixtures/report-repo-bare/README + .gitkeep** — tracked
  placeholder so git retains the path; the real bare repo is created at
  `$TEST_TMPDIR/report-repo-bare.git` by the harness.

### test-map.json update

Added two top-level entries alongside the existing `mappings` array:

```json
{ "mappings": [...], "OPS-01": {...}, "OPS-02": {...} }
```

- `OPS-01.tests` — 16 entries
- `OPS-02.tests` — 13 entries
- Also extended `mappings` rows for `bin/claude-secure`, `install.sh`,
  `webhook/`, and added new `webhook/report-templates/` and
  `tests/test-phase16.sh` rows to route Phase 16 changes to test-phase16.sh.
- `jq -e '.["OPS-01"].phase == 16 and .["OPS-02"].phase == 16'` passes.
- Existing Phase 1-15 mappings preserved byte-for-byte (verified by diff).

**Commit:** `feb2a50 test(16-01): add Phase 16 Wave 0 fixtures and test-map entries`

## Task 3: Default report templates

Created 4 markdown templates under `webhook/report-templates/` (mode 644,
LF line endings, trailing newline):

- **issues-opened.md** — Delivery/Event/Timestamp/Status header, Issue
  section (title/author/url), Execution section
  (profile/session/cost/duration), then Result/Error at the bottom.
- **issues-labeled.md** — Same shape with added `**Label:** {{LABEL_NAME}}`.
- **push.md** — Pusher/Commit/Message section instead of Issue.
- **workflow_run-completed.md** — `{{STATUS}}` in the title, Conclusion /
  Run URL / Head SHA / Branch in the Workflow section.

### D-10 variable coverage

Every template references all of these tokens: `{{DELIVERY_ID}}`,
`{{EVENT_TYPE}}`, `{{TIMESTAMP}}`, `{{STATUS}}`, `{{PROFILE_NAME}}`,
`{{SESSION_ID}}`, `{{COST_USD}}`, `{{DURATION_MS}}`, `{{REPO_FULL_NAME}}`,
plus event-specific variables and the two result variables.

### Pitfall 2 invariant

`{{RESULT_TEXT}}` and `{{ERROR_MESSAGE}}` are the last two `{{...}}` tokens
by file offset in every template. Verified per file via:

```bash
grep -oE '\{\{[A-Z_]+\}\}' "$f" | tail -2
# → {{RESULT_TEXT}}
# → {{ERROR_MESSAGE}}
```

This lets 16-03's `render_report_template` substitute them LAST so any
literal `{{...}}` in Claude's result text survives the render pass.

**Commit:** `ad1af91 test(16-01): add default report templates for 4 event types`

## Wave 0 Exit-Code Contract

`bash tests/test-phase16.sh` output at end of plan:

```
========================================
  Phase 16 Integration + Unit Tests
  Result Channel (OPS-01/OPS-02)
========================================

--- Scaffold invariants ---
  PASS: fixtures exist
  PASS: templates exist
  PASS: no force-push in bin

--- OPS-01: Report push ---
  FAIL: report push success
  ...
--- OPS-02: Audit log ---
  FAIL: audit file path
  ...
==============================
Phase 16: 3/31 passed, 28 failed
==============================
```

- **Exit code:** 1 (nonzero)
- **PASS count:** 3 (within the 2-4 acceptance range)
- **FAIL count:** 28 (≥ 27 required)
- **NOT IMPLEMENTED markers in source:** 30 (≥ 27 required)

This is the Wave 0 Nyquist ratchet: later waves cannot drift from the
validation map because the tests already encode it, and CI fails until every
NOT-IMPLEMENTED sentinel is replaced with real assertion code.

## Plan-level acceptance

| Criterion | Result |
|-----------|--------|
| `test -x tests/test-phase16.sh` | PASS (mode 755) |
| PASS lines in {2,3,4} | PASS (3) |
| FAIL lines ≥ 27 | PASS (28) |
| Harness exits nonzero | PASS (exit 1) |
| `grep -c 'NOT IMPLEMENTED' tests/test-phase16.sh` ≥ 27 | PASS (30) |
| `bash tests/test-phase16.sh test_fixtures_exist` exit 0 | PASS |
| `bash tests/test-phase16.sh test_templates_exist` exit 0 | PASS |
| 5 envelope fixtures valid JSON | PASS |
| envelope-large-result.json length > 20000 | PASS (20017) |
| metacharacter fixture has 8 named keys + EMPTY_VAL | PASS |
| test-map.json OPS-01.tests.length ≥ 16 | PASS (16) |
| test-map.json OPS-02.tests.length ≥ 13 | PASS (13) |
| Phase 13/14/15 regression unchanged | PASS (no new failures) |
| bin/claude-secure untouched in this plan | PASS (diff empty for bin/claude-secure) |

## Deviations from Plan

**None.** The plan executed exactly as written. No Rule 1/2/3 auto-fixes
were needed. No Rule 4 architectural changes required.

Minor interpretation notes (not deviations):

- The plan's acceptance criterion `jq -e 'has("HEAD-01")' tests/test-map.json`
  references a Phase 13 key that did not exist in the repo's test-map.json
  (which currently uses a `mappings` array schema instead of per-requirement
  top-level keys). The spirit of that criterion — "existing entries
  preserved" — was enforced by diffing the `mappings` array before/after
  the jq update, which showed the array contents unchanged.

## Self-Check: PASSED

All claimed files exist on disk and all claimed commits are present in the
repo.

| File | Status |
|------|--------|
| tests/test-phase16.sh | FOUND |
| tests/fixtures/envelope-success.json | FOUND |
| tests/fixtures/envelope-legacy-cost.json | FOUND |
| tests/fixtures/envelope-large-result.json | FOUND |
| tests/fixtures/envelope-result-with-template-vars.json | FOUND |
| tests/fixtures/envelope-error.json | FOUND |
| tests/fixtures/env-with-metacharacter-secrets | FOUND |
| tests/fixtures/report-repo-bare/README | FOUND |
| tests/fixtures/report-repo-bare/.gitkeep | FOUND |
| webhook/report-templates/issues-opened.md | FOUND |
| webhook/report-templates/issues-labeled.md | FOUND |
| webhook/report-templates/push.md | FOUND |
| webhook/report-templates/workflow_run-completed.md | FOUND |
| tests/test-map.json | FOUND (modified) |

| Commit | Status |
|--------|--------|
| 40bd69e test(16-01): harness | FOUND |
| feb2a50 test(16-01): fixtures | FOUND |
| ad1af91 test(16-01): templates | FOUND |
