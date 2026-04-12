---
phase: 16
plan: 02
subsystem: bin/claude-secure
tags: [wave-1a, ops-01, resolver, template-fallback, tdd]
requires:
  - Phase 15 _resolve_default_templates_dir / resolve_template pattern (D-13)
  - Phase 16 Wave 0 test scaffold (16-01) with test_report_template_fallback sentinel
  - bash on host
provides:
  - resolve_report_template() — D-08 report template fallback chain
  - _resolve_default_templates_dir(subdir) — parameterized generalization
  - Documented profile.json report_repo/report_branch/report_path_prefix fields
affects:
  - bin/claude-secure (2 functions modified/added)
  - webhook/config.example.json (schema doc key)
  - tests/test-phase16.sh (test_report_template_fallback implemented)
tech-stack:
  added: []
  patterns:
    - Parameterized template resolver (single function, subdir-keyed routing)
    - TDD RED -> GREEN for a small surface change
    - Subshell-scoped source of bin/claude-secure via __CLAUDE_SECURE_SOURCE_ONLY
key-files:
  created:
    - .planning/phases/16-result-channel/deferred-items.md
    - .planning/phases/16-result-channel/16-02-SUMMARY.md
  modified:
    - bin/claude-secure
    - webhook/config.example.json
    - tests/test-phase16.sh
decisions:
  - "Parameterized _resolve_default_templates_dir with subdir arg (Pattern F from 16-RESEARCH.md) instead of duplicating the function — keeps test surface small and avoids drift"
  - "resolve_report_template placed immediately after resolve_template and before render_template for logical grouping"
  - "Phase 15 call site `default_dir=\$(_resolve_default_templates_dir)` left untouched — backward compat via default subdir='templates'"
  - "Test sourced bin/claude-secure inside a subshell to avoid polluting harness PROFILE/CONFIG_DIR between tests"
  - "Pre-existing Phase 14 test_unit_file_parses failure logged to deferred-items.md (reproduced against HEAD, not a regression)"
metrics:
  tasks_completed: 2
  files_created: 2
  files_modified: 3
  tests_flipped_green: 1
  phase16_pass_before: 3
  phase16_pass_after: 4
  phase13_regressions: 0
  phase15_regressions: 0
  completed: 2026-04-12
---

# Phase 16 Plan 02: Wave 1a — Report Template Resolver Summary

Generalized the Phase 15 template resolver so a single function serves both
prompt templates and report templates, added `resolve_report_template()`
following the D-08 fallback chain, and documented the three new
report-publishing fields in `webhook/config.example.json`. Flipped
`test_report_template_fallback` from NOT-IMPLEMENTED sentinel to GREEN
without touching any Phase 15 call sites.

## One-Liner

Parameterized `_resolve_default_templates_dir(subdir)` + new
`resolve_report_template(event_type)` cloned from the Phase 15 D-13 chain,
flipping one Phase 16 test green with zero regressions in Phase 13/15.

## Task 1: Generalize `_resolve_default_templates_dir` and add `resolve_report_template`

### TDD flow

**RED** — `tests/test-phase16.sh::test_report_template_fallback` replaced its
NOT-IMPLEMENTED sentinel with a real assertion exercising all four tiers of
the D-08 fallback chain:

1. `(a) profile override` — `$CONFIG_DIR/profiles/test-profile/report-templates/issues-opened.md` wins
2. `(b) env var override` — `WEBHOOK_REPORT_TEMPLATES_DIR=$env_dir` wins when no profile override
3. `(c) dev checkout` — `$APP_DIR/webhook/report-templates/push.md` wins when env + profile unset
4. `(d) unresolvable` — `resolve_report_template does-not-exist-event` returns 1

The test body runs inside a subshell so the harness's `PROFILE`/`CONFIG_DIR`
are never polluted between tests. Before implementation, the test failed
with `resolve_report_template: command not found` (commit `09c832a`).

**GREEN** — Implemented in `bin/claude-secure` (commit `ba197ce`):

- `_resolve_default_templates_dir()` now accepts `subdir` arg (`${1:-templates}`):
  - `subdir="templates"` + `$WEBHOOK_TEMPLATES_DIR` → env var wins
  - `subdir="report-templates"` + `$WEBHOOK_REPORT_TEMPLATES_DIR` → env var wins
  - Dev checkout: `$APP_DIR/webhook/$subdir` when `$APP_DIR/.git` present
  - Prod fallback: `/opt/claude-secure/webhook/$subdir`
- `resolve_report_template()` placed between `resolve_template()` and
  `render_template()`. Signature: takes `event_type`, echoes path on stdout,
  returns 1 on hard fail with every checked path listed to stderr.

### Function signatures added / changed

```bash
# bin/claude-secure lines 389-413 (modified)
_resolve_default_templates_dir() {
  local subdir="${1:-templates}"
  # ... routes WEBHOOK_{,REPORT_}TEMPLATES_DIR by subdir
}

# bin/claude-secure lines 568-603 (new)
resolve_report_template() {
  local event_type="$1"
  # profile override -> default fallback -> hard fail
}
```

### Phase 15 call site untouched

Line 551 (`default_dir=$(_resolve_default_templates_dir)`) — no argument
means `subdir` defaults to `"templates"`, which preserves Phase 15's behavior
verbatim. Verified by running `bash tests/test-phase15.sh` → 28/28 passed.

### Static + runtime acceptance criteria

| Criterion | Expected | Actual |
|-----------|----------|--------|
| `grep -c 'resolve_report_template()' bin/claude-secure` | 1 | 1 |
| `grep -c '_resolve_default_templates_dir()' bin/claude-secure` | 1 | 1 |
| `grep -E 'local subdir=.*templates' bin/claude-secure` | present | `local subdir="${1:-templates}"` |
| `grep -c 'WEBHOOK_REPORT_TEMPLATES_DIR' bin/claude-secure` | ≥ 2 | 3 |
| `resolve_report_template` between `resolve_template` and `render_template` | yes | line 585 (between 532 and 619) |
| `bash tests/test-phase16.sh test_report_template_fallback; echo $?` | 0 | 0 |
| `bash tests/test-phase15.sh` | N/N, 0 failed | 28/28, 0 failed |
| `bash tests/test-phase13.sh` | 0 failures | 16/16, 0 failed |
| `bash tests/test-phase16.sh 2>&1 | grep -c '^  PASS: '` | ≥ 3 | 4 |

**Commits:**
- `09c832a test(16-02): add failing test for resolve_report_template D-08 fallback chain`
- `ba197ce feat(16-02): generalize _resolve_default_templates_dir and add resolve_report_template`

## Task 2: Document profile.json report fields in `webhook/config.example.json`

`webhook/config.example.json` is strict JSON, so added a
`_phase16_profile_schema` string-array sibling key at the bottom of the
existing object. It documents the three new OPTIONAL profile.json fields
(`report_repo`, `report_branch`, `report_path_prefix`), plus the
`REPORT_REPO_TOKEN` convention for the profile `.env`, and points at
decisions D-01, D-02, D-08, D-14.

The listener's Config loader (`webhook/listener.py:141`) reads keys via
`.get()` / typed lookups, so it silently ignores the new informational key —
no runtime impact on webhook-listener behavior.

| Criterion | Expected | Actual |
|-----------|----------|--------|
| `jq -e '._phase16_profile_schema' …` non-null array | yes | 7-element array |
| contains `report_repo`, `report_branch`, `report_path_prefix`, `REPORT_REPO_TOKEN` | ≥ 4 matches | 4 |
| `jq -e 'has("bind") and has("port")'` | true | true |
| `jq . webhook/config.example.json` | valid JSON | valid |
| `python3 -c 'import json; json.load(...)'` | exits 0 | exits 0 |

**Commit:** `1056d53 docs(16-02): document Phase 16 profile.json report fields in config.example.json`

## Phase 16 Test Status (after plan)

```
Phase 16: 4/31 passed, 27 failed
```

| Test | Status | Owner |
|------|--------|-------|
| test_fixtures_exist | PASS | 16-01 scaffold |
| test_templates_exist | PASS | 16-01 scaffold |
| test_no_force_push_grep | PASS | 16-01 static (still trivially passes, bin/claude-secure has no push yet) |
| **test_report_template_fallback** | **PASS** (NEW) | **16-02 (this plan)** |
| All 27 remaining OPS-01 + OPS-02 tests | FAIL (NOT IMPLEMENTED) | 16-03 / 16-04 |

The 27 failing tests all still emit their 16-03 / 16-04 sentinel strings.
Exactly one test flipped, as the plan requires.

## Regression sweep

| Suite | Before | After | Delta |
|-------|--------|-------|-------|
| Phase 13 | 16/16 | 16/16 | 0 |
| Phase 14 | 15/16 (pre-existing `test_unit_file_parses` fail) | 15/16 (unchanged) | 0 — logged to deferred-items.md |
| Phase 15 | 28/28 | 28/28 | 0 |
| Phase 16 | 3/31 | 4/31 | **+1 (test_report_template_fallback)** |

The Phase 14 failure was reproduced with `bin/claude-secure` stashed back to
HEAD — it is pre-existing and unrelated to 16-02. Logged under
`.planning/phases/16-result-channel/deferred-items.md` for follow-up.

## Deviations from Plan

**None.** The plan executed exactly as written:

- `_resolve_default_templates_dir` generalized per Pattern F (16-RESEARCH.md)
- `resolve_report_template` inserted in the exact location specified
- Phase 15 call site untouched (regression clean)
- Test body taken from the plan's `<action>` section (adapted to a subshell
  for harness hygiene — a cosmetic refinement within Claude's discretion
  from 16-CONTEXT.md "Claude's Discretion" section)
- `webhook/config.example.json` received the `_phase16_profile_schema` key
  verbatim from the plan's example

No Rule 1/2/3 auto-fixes were needed. No Rule 4 architectural changes.

**Scope boundary note:** Phase 14's pre-existing `test_unit_file_parses`
failure was reproduced, confirmed pre-existing, and logged as a deferred
item rather than fixed. Out of scope for 16-02.

## Self-Check: PASSED

All claimed files exist and all claimed commits are in the repo.

| File | Status |
|------|--------|
| bin/claude-secure | FOUND (modified) |
| webhook/config.example.json | FOUND (modified) |
| tests/test-phase16.sh | FOUND (modified) |
| .planning/phases/16-result-channel/deferred-items.md | FOUND |
| .planning/phases/16-result-channel/16-02-SUMMARY.md | FOUND (this file) |

| Commit | Status |
|--------|--------|
| 09c832a test(16-02): failing test for resolve_report_template | FOUND |
| ba197ce feat(16-02): resolve_report_template + generalized resolver | FOUND |
| 1056d53 docs(16-02): profile.json report fields in config.example.json | FOUND |
