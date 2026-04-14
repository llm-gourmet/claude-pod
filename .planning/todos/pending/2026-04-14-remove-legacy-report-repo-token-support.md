---
created: 2026-04-14T07:06:18.563Z
title: Remove legacy REPORT_REPO_TOKEN support
area: tooling
files:
  - bin/claude-secure:88-165 (validate_docs_binding, resolve_docs_alias, emit_deprecation_warning, project_env_for_containers)
  - tests/test-phase23.sh (legacy alias tests: test_legacy_report_repo_alias, test_legacy_report_token_alias, test_deprecation_warning_rate_limit)
  - tests/fixtures/profile-23-legacy/ (entire fixture directory)
---

## Problem

Phase 23 added BIND-03 legacy alias support: `resolve_docs_alias()` maps old `report_repo` / `REPORT_REPO_TOKEN` fields to the new `docs_*` names, and `emit_deprecation_warning()` fires once per session. This back-compat was built for Phase 16 profiles still using the old schema.

Decision made during Phase 23 UAT: legacy support will be removed entirely. Only `DOCS_REPO_TOKEN` and `docs_*` profile fields going forward.

## Solution

Remove from `bin/claude-secure`:
- `resolve_docs_alias()` function (around line 199)
- `emit_deprecation_warning()` function (around line 174)
- REPORT_REPO / REPORT_BRANCH / REPORT_REPO_TOKEN back-fill exports in `load_profile_config`
- The `resolve_docs_alias` call in `load_profile_config` (around line 416)

Remove from `tests/test-phase23.sh`:
- `test_legacy_report_repo_alias`
- `test_legacy_report_token_alias`
- `test_deprecation_warning_rate_limit`

Remove `tests/fixtures/profile-23-legacy/` directory entirely.

Verify Phase 12 and Phase 16 tests still pass after removal (Phase 16 publish_report uses REPORT_REPO_TOKEN — check if it needs to be updated to read DOCS_REPO_TOKEN directly or if back-fill can simply be dropped).
