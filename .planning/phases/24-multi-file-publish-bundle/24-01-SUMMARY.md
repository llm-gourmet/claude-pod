---
phase: 24-multi-file-publish-bundle
plan: 01
subsystem: testing
tags: [bash, jq, git-bare-repo, nyquist-self-healing, wave-0-scaffold, publish-docs-bundle, sanitize-markdown, test-fixtures]

# Dependency graph
requires:
  - phase: 23-profile-doc-repo-binding
    provides: profile-23-docs fixture pattern, _setup_bare_repo helper, do_profile_init_docs seeding INDEX.md, load_profile_config, redact_report_file, push_with_retry
  - phase: 16-result-channel
    provides: webhook/report-templates/ directory, redact_report_file, push_with_retry base
provides:
  - Wave 0 RED test harness for Phase 24 (tests/test-phase24.sh, 13 tests, 12 named functions)
  - Canonical 6-section bundle.md template at webhook/report-templates/bundle.md
  - profile-24-bundle fixture with DOCS_REPO_TOKEN + SEEDED_SECRET for redaction tests
  - 4 bundle body fixtures (valid, missing-section, exfil, secret) covering RPT-01, RPT-03, RPT-04 attack vectors
  - test-map.json registration of RPT-01..05 + DOCS-02 + DOCS-03 requirement entries
  - _setup_bundle_profile test helper (installs fixture, seeds bare repo via init-docs)
affects: [24-02-verify-sanitize, 24-03-publish-docs-bundle]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Wave 0 Nyquist self-healing scaffold (fixtures + test harness + RED sentinels before any implementation)"
    - "Fixture profile with file:// bare repo pattern rewired by _patch_docs_repo (reused from Phase 23)"
    - "_setup_bundle_profile wrapper that composes install_fixture + _setup_bare_repo + _patch_docs_repo + load_profile_config + do_profile_init_docs"
    - "Template file under webhook/report-templates/ mirrors Phase 16 convention"

key-files:
  created:
    - tests/test-phase24.sh
    - tests/fixtures/profile-24-bundle/profile.json
    - tests/fixtures/profile-24-bundle/.env
    - tests/fixtures/profile-24-bundle/whitelist.json
    - tests/fixtures/bundles/valid-body.md
    - tests/fixtures/bundles/missing-section-body.md
    - tests/fixtures/bundles/exfil-body.md
    - tests/fixtures/bundles/secret-body.md
    - webhook/report-templates/bundle.md
  modified:
    - tests/test-map.json

key-decisions:
  - "Wave 0 scaffold ships 2 GREEN + 11 RED sentinels (test_fixtures_exist + test_bundle_template_installed PASS; remaining 11 fail because verify_bundle_sections, sanitize_markdown_file, publish_docs_bundle do not yet exist)"
  - "fixture .env force-added via git add -f (follows Phase 23 precedent; contains only fake tokens)"
  - "RPT-01 NOT marked complete in REQUIREMENTS.md -- Plan 01 ships only the template + fixture half; Plan 02 adds verify_bundle_sections (RPT-01 logic half) and Plan 03 ties it together"
  - "_setup_bundle_profile helper seeds INDEX.md via do_profile_init_docs so publish_docs_bundle tests start against a non-empty bare repo with the Phase 23 directory layout already in place"
  - "Test harness mirrors tests/test-phase23.sh verbatim (SCRIPT_DIR/PROJECT_DIR, TEST_TMPDIR, CONFIG_DIR, HOME export, cleanup trap, run_test/install_fixture/source_cs/_setup_bare_repo/_patch_docs_repo/_count_commits) to keep the Phase 23/24 test scaffolds structurally identical"

patterns-established:
  - "Phase 24 fixture + template scaffolding matches Phase 23 structure -- future phases extending docs-repo publishing should clone Phase 24 Plan 01 shape"
  - "Force-add of fake-token .env fixtures is the project's standard workaround for the gitignored .env pattern"

requirements-completed: []  # RPT-01 listed in plan frontmatter but deliberately NOT marked complete -- Plan 01 is the Wave 0 scaffold only; RPT-01 becomes verifiable after Plans 02 + 03 implement verify_bundle_sections and publish_docs_bundle

# Metrics
duration: ~15min
completed: 2026-04-14
---

# Phase 24 Plan 01: Wave 0 Test Scaffold + Fixtures + Bundle Template Summary

**Wave 0 Nyquist self-healing scaffold for Phase 24 publishing: 13-test harness (2 GREEN + 11 RED sentinels), 4 attack-vector bundle fixtures, profile-24-bundle .env with DOCS_REPO_TOKEN and SEEDED_SECRET, canonical 6-section bundle.md template, and 7 new RPT/DOCS requirement entries in test-map.json.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-04-14T10:00:00Z (approximate)
- **Completed:** 2026-04-14T10:15:00Z (approximate)
- **Tasks:** 3
- **Files modified:** 10 (9 created, 1 edited)

## Accomplishments

- Wave 0 RED test harness ships with precise 2/11/13 pass/fail/total sentinel state
- All 6 mandatory H2 sections (Goal, Where Worked, What Changed, What Failed, How to Test, Future Findings) present in webhook/report-templates/bundle.md
- 4 attack-vector bundle bodies encode RPT-04 (attacker.tld images, HTML comments, raw HTML `<img>`, reference-style image defs) and RPT-03 (literal TEST_SECRET_VALUE_ABC)
- test-map.json registers 7 new top-level requirement entries: RPT-01..05, DOCS-02, DOCS-03
- _setup_bundle_profile helper composes Phase 23 primitives to deliver a ready-to-publish bare repo with INDEX.md seeded by init-docs
- Phase 16 and Phase 23 regressions confirmed unchanged (same pre-existing failures, no new ones)

## Task Commits

Each task was committed atomically (parallel executor uses --no-verify):

1. **Task 1: Create fixtures and canonical bundle.md template** — `40358ed` (test)
2. **Task 2: Create tests/test-phase24.sh harness with 12 named test functions (RED scaffold)** — `ddac14f` (test)
3. **Task 3: Register test-phase24.sh and per-requirement entries in tests/test-map.json** — `f226990` (chore)

## Files Created/Modified

- `tests/test-phase24.sh` — Wave 0 test harness, 12 named functions, 13 run_test dispatch calls, sources bin/claude-secure in library mode (created, chmod +x)
- `tests/fixtures/profile-24-bundle/profile.json` — profile with docs_repo=https://github.com/owner/docs-bundle.git, docs_branch=main, docs_project_dir=projects/docs-bundle, docs_mode=report_only (created)
- `tests/fixtures/profile-24-bundle/.env` — fake CLAUDE_CODE_OAUTH_TOKEN, DOCS_REPO_TOKEN, and SEEDED_SECRET=TEST_SECRET_VALUE_ABC for RPT-03 redaction assertion (created, force-added)
- `tests/fixtures/profile-24-bundle/whitelist.json` — empty secrets + readonly_domains (created)
- `tests/fixtures/bundles/valid-body.md` — fully-formed body with all 6 mandatory H2 sections (created)
- `tests/fixtures/bundles/missing-section-body.md` — intentionally missing `## Future Findings` for verify_bundle_sections negative test (created)
- `tests/fixtures/bundles/exfil-body.md` — embeds `![alt](https://attacker.tld/...)`, `<!-- DOCS_REPO_TOKEN=... -->`, `<img src="https://attacker.tld/...">`, and `[exfil]: https://attacker.tld/refdef` reference-style image def (created)
- `tests/fixtures/bundles/secret-body.md` — contains literal `TEST_SECRET_VALUE_ABC` for RPT-03 redaction leak detection (created)
- `webhook/report-templates/bundle.md` — canonical 6-section template with `{{REPO_FULL_NAME}}`, `{{SESSION_ID}}`, `{{DELIVERY_ID}}`, `{{EVENT_TYPE}}`, `{{TIMESTAMP}}`, `{{STATUS}}`, `{{PROFILE_NAME}}`, `{{COST_USD}}`, `{{DURATION_MS}}`, `{{GOAL}}`, `{{WHERE_WORKED}}`, `{{WHAT_CHANGED}}`, `{{WHAT_FAILED}}`, `{{HOW_TO_TEST}}`, `{{FUTURE_FINDINGS}}`, `{{ERROR_MESSAGE}}` variables (created)
- `tests/test-map.json` — extended bin/claude-secure + webhook/report-templates/ mappings, added 2 new mapping entries (test-phase24.sh itself + fixtures/profile-24-bundle/** + fixtures/bundles/**), added 7 top-level requirement entries RPT-01..05 + DOCS-02 + DOCS-03 (modified)

## Decisions Made

- **Followed Phase 23 force-add precedent for .env**: `tests/fixtures/profile-24-bundle/.env` is gitignored by the top-level `.env` rule but contains only fake tokens; `git add -f` is the project's standard pattern (Phase 23 Plan 02 used this approach verbatim).
- **Did NOT mark RPT-01 complete**: Plan 01 frontmatter lists `requirements: [RPT-01]`, but Plan 01 is the Wave 0 scaffold — only the template + fixture half exists. verify_bundle_sections (Plan 02) and publish_docs_bundle (Plan 03) must land before RPT-01 is actually verifiable. This mirrors Phase 23 Plan 01's pattern, which listed BIND-01/02/03 + DOCS-01 in its frontmatter but did not flip any requirement boxes — DOCS-01 was only marked complete by Plan 23-03.
- **Scaffolding mirrors test-phase23.sh verbatim**: The per-test helpers (source_cs, install_fixture, _setup_bare_repo, _patch_docs_repo, _count_commits) are byte-for-byte copies from tests/test-phase23.sh with "profile-23-docs" replaced by "profile-24-bundle". This keeps the Phase 23 and Phase 24 test scaffolds structurally identical so the failure model and maintenance story are the same.
- **_setup_bundle_profile composes init-docs seeding**: Rather than re-implementing INDEX.md creation in the test harness, the helper calls `do_profile_init_docs` to seed `projects/<slug>/reports/INDEX.md` so publish_docs_bundle tests start against a realistic post-init state.

## Deviations from Plan

None - plan executed exactly as written. All 3 tasks, all 10 files, all verification checks and acceptance criteria matched the plan contents verbatim.

## Issues Encountered

- **Worktree started from stale commit**: The executor's git worktree branch `worktree-agent-a62e21f3` was spawned from commit `4a066d0`, which predated the Phase 24 plan files (`d62ad9e docs(24): create multi-file publish bundle phase plan`). Resolved by running `git merge doc-repo --no-edit` to fast-forward the worktree branch to include the plan files and Phase 23 reference artifacts. No conflicts.
- **Zsh `!` history expansion in bash-style verification one-liners**: Initial verification attempt mixed zsh interactive features with bash test semantics. Re-ran the negative-grep check inside an explicit `bash -c` subshell to confirm `missing-section-body.md` correctly omits `## Future Findings`.

## User Setup Required

None — no external service configuration required.

## Wave 0 Sentinel State (Verified)

```
$ bash tests/test-phase24.sh
Phase 24: Multi-File Publish Bundle tests
=========================================
  PASS: fixtures_exist
  PASS: bundle_template_installed
  FAIL: verify_bundle_sections
  FAIL: sanitize_markdown_file
  FAIL: bundle_path_layout
  FAIL: bundle_never_overwrites
  FAIL: bundle_updates_index
  FAIL: bundle_single_commit
  FAIL: bundle_failure_clean_tree
  FAIL: bundle_redacts_secrets
  FAIL: bundle_sanitizes_external_image
  FAIL: bundle_push_rebase_retry
  FAIL: bundle_concurrent_race

Results: 2 passed, 11 failed, 13 total
Exit: 1
```

Matches the success criteria exactly: `Results: 2 passed, 11 failed, 13 total` with non-zero exit.

## Regression Checks

- **Phase 16 (`tests/test-phase16.sh`)**: 32/33 passed, 1 failed — pre-existing failure (`test_report_template_fallback`) unchanged; confirmed baseline by checking out doc-repo snapshot of the phase-16 inputs and observing the same failure. Phase 24 did not touch any Phase 16 file.
- **Phase 23 (`tests/test-phase23.sh`)**: 17/18 passed, 1 failed — pre-existing failure (`test_docs_token_absent_from_container`) is a known integration stub in test-phase23.sh that returns 1 unconditionally ("INTEGRATION: requires docker compose; Plan 02 implements"). Unchanged baseline.

No new regressions introduced.

## Next Phase Readiness

- **Plan 24-02 unblocked**: `verify_bundle_sections` and `sanitize_markdown_file` helpers can now be added to `bin/claude-secure` and will flip `test_verify_bundle_sections` + `test_sanitize_markdown_file` to GREEN. The 6-section allowlist is fixed by `webhook/report-templates/bundle.md` and the Plan 01 fixtures encode every attack vector the sanitizer must strip.
- **Plan 24-03 unblocked**: `publish_docs_bundle` can be implemented and will flip the remaining 9 Wave 0 RED sentinels to GREEN. `_setup_bundle_profile` already seeds a realistic bare repo + INDEX.md, so Plan 03 has a ready-to-use integration harness.
- **Feedback latency under 15s**: `bash tests/test-phase24.sh test_bundle_single_commit` completes in well under 15 seconds, satisfying the Nyquist self-healing target for Plan 02 and 03 development cycles.

---
*Phase: 24-multi-file-publish-bundle*
*Completed: 2026-04-14*

## Self-Check: PASSED

All 11 files and 3 task commits verified present after writing SUMMARY.md.
