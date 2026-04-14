---
phase: 24-multi-file-publish-bundle
plan: "03"
subsystem: host-publish
tags: [docs-repo, bundle, atomic-commit, concurrency]
requires:
  - 24-01  # test-phase24.sh harness + fixtures + bundle.md template
  - 24-02  # verify_bundle_sections + sanitize_markdown_file helpers
provides:
  - publish_docs_bundle  # library function (bin/claude-secure:1646-1828)
affects:
  - bin/claude-secure
  - tests/test-phase24.sh  # Rule 3 test-harness fix, see Deviations
tech_stack:
  added: []
  patterns:
    - ephemeral-shallow-clone
    - redact-then-sanitize
    - clone-local-gitattributes-merge-union
    - single-atomic-commit
    - pat-scrub-on-stderr
key_files:
  created: []
  modified:
    - bin/claude-secure
    - tests/test-phase24.sh
decisions:
  - Redact BEFORE sanitize in loop body (order discipline per 24-RESEARCH.md Pitfall 1)
  - No `git diff --cached --quiet` gate (Phase 24 is non-idempotent by design)
  - Library-only, no CLI dispatch (per 24-RESEARCH.md Open Question 4)
  - INDEX.md uses clone-local `merge=union` gitattribute for concurrent-rebase auto-merge
  - Clone-local user.email/user.name required for rebase replay in push_with_retry
metrics:
  duration_min: 6
  tasks: 1
  files_modified: 2
  completed_date: 2026-04-14
---

# Phase 24 Plan 03: publish_docs_bundle Summary

**One-liner:** Adds the host-side `publish_docs_bundle()` library function (~183 LOC) that composes Plan 02 helpers, the Phase 16 secret redactor, and the Phase 17 retry-push into a single atomic report + INDEX.md commit, flipping Phase 24 from 4/13 to 13/13 passing.

## What Shipped

### bin/claude-secure (lines 1646-1828, 183 LOC including comments)

New function `publish_docs_bundle(body_path, session_id, summary_line, [delivery_id])`:

1. **Precondition guards** — body file exists, session_id non-empty, `verify_bundle_sections` passes, profile/docs config loaded, `.env` readable for redaction.
2. **Ephemeral shallow clone** of `$DOCS_REPO` with bounded HTTP flags, askpass helper (mode 700), PAT scrub on stderr, registered in `_CLEANUP_FILES`.
3. **Clone-local merge driver setup**: writes `projects/<slug>/reports/INDEX.md merge=union` to `.git/info/attributes` (not committed) so concurrent rebases auto-merge the append-only log.
4. **Clone-local identity**: `user.email` / `user.name` set so `push_with_retry`'s rebase replay does not die with "empty ident name not allowed".
5. **DOCS-02 path layout**: `projects/<slug>/reports/YYYY/MM/<date>-<session_id>.md` with **never-overwrite** guard (returns 1 if file already exists).
6. **DOCS-03 INDEX append**: 3-column `| timestamp | session_id | summary |` row, with pipes escaped and newlines collapsed in the summary.
7. **RPT-03 + RPT-04 pipeline**: `redact_report_file` THEN `sanitize_markdown_file` for each staged file (order matters — Pitfall 1).
8. **RPT-02 atomic commit**: single `git commit` staging both the report + the INDEX update, with PAT scrub on `commit_err`.
9. **RPT-05 push**: delegates to `push_with_retry` (Phase 17 3-attempt rebase loop), which picks up `REPORT_REPO_TOKEN` back-filled by Phase 23 `resolve_docs_alias`.
10. **stdout**: emits a `blob/<branch>/<path>` URL on success.

### tests/test-phase24.sh (Rule 3 test-harness fix)

The Wave 0 scaffold used `bare=$(_setup_bundle_profile NAME)` for 9 tests, but command substitution runs in a subshell — so the `source_cs` + `load_profile_config` side effects inside the helper never reached the test body. Fixed by:

- `_setup_bundle_profile` now returns via a `SETUP_BARE_REPO` global variable
- Helper explicitly exports `PROFILE="$profile_name"` (the real CLI flow sets this during arg parsing, not inside `load_profile_config`)
- All 9 test bodies updated to read `bare="$SETUP_BARE_REPO"`

## Test Delta

| Suite | Before | After | Delta |
| --- | --- | --- | --- |
| Phase 24 | 4/13 | **13/13** | +9 GREEN |
| Phase 16 regression | 33/33 | 33/33 | 0 |
| Phase 23 regression | 17/18 | 17/18 | 0 (pre-existing `docs_token_absent_from_container` failure) |

### Per-Requirement Traceability

| Req | Tests | Status |
| --- | --- | --- |
| DOCS-02 | `test_bundle_path_layout`, `test_bundle_never_overwrites` | 2/2 GREEN |
| DOCS-03 | `test_bundle_updates_index` | 1/1 GREEN |
| RPT-01 | `test_verify_bundle_sections`, `test_bundle_template_installed` | 2/2 GREEN (from Plan 02 + Plan 01) |
| RPT-02 | `test_bundle_single_commit`, `test_bundle_failure_clean_tree` | 2/2 GREEN |
| RPT-03 | `test_bundle_redacts_secrets` | 1/1 GREEN |
| RPT-04 | `test_sanitize_markdown_file` (Plan 02), `test_bundle_sanitizes_external_image` | 2/2 GREEN |
| RPT-05 | `test_bundle_push_rebase_retry`, `test_bundle_concurrent_race` | 2/2 GREEN |

## Deviations from Plan

### 1. [Rule 3 — Blocking test infrastructure] test-phase24.sh command-substitution subshell bug

**Found during:** Running `test_bundle_path_layout` — trace showed `declare -F publish_docs_bundle` returning 1 (function not defined) even though `_setup_bundle_profile` had sourced `bin/claude-secure`.

**Issue:** 9 of the 13 tests used `local bare; bare=$(_setup_bundle_profile NAME)` to capture the bare-repo path. Bash command substitution runs the helper in a subshell, so `source_cs`, `load_profile_config`, and the profile globals never reached the test body. Before this fix, none of the 9 Plan 03 tests could even see `publish_docs_bundle` as a defined function.

**Fix:** Rewrote `_setup_bundle_profile` to return the bare-repo path via a `SETUP_BARE_REPO` global, and updated all 9 call sites to read it. Also added `export PROFILE="$profile_name"` inside the helper (the real CLI flow sets PROFILE during arg parsing before `load_profile_config` is called — `load_profile_config` itself does not set PROFILE).

**Files modified:** tests/test-phase24.sh
**Commit:** 3a77641

### 2. [Rule 2 — Missing critical functionality] INDEX.md concurrent-rebase merge conflict

**Found during:** `test_bundle_concurrent_race` — publisher B failed with `CONFLICT (content): Merge conflict in projects/docs-bundle/reports/INDEX.md` during `pull --rebase` inside `push_with_retry`.

**Issue:** The plan's original function body had no concurrency handling for INDEX.md. Two parallel publishers both append a new row to the same "last line" context of INDEX.md, so git's default 3-way merge cannot auto-resolve the conflict.

**Fix:** Added a clone-local gitattributes entry (written to `.git/info/attributes`, NOT to a committed `.gitattributes`) that marks `projects/<slug>/reports/INDEX.md` with `merge=union`. Git's builtin union merge driver keeps every line from every side of the merge — exactly the right semantics for an append-only log.

**Files modified:** bin/claude-secure (publish_docs_bundle function body)
**Commit:** 3a77641

### 3. [Rule 1 — Bug] Missing clone-local user.email/user.name breaks rebase replay

**Found during:** Concurrency test after fixing the merge-union issue — publisher B then died with `fatal: empty ident name (for <igor9000@igorpc.localdomain>) not allowed` during the rebase replay step of `push_with_retry`.

**Issue:** The plan sets `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env vars only on the initial `git commit`. When `push_with_retry` does `pull --rebase`, git-rebase replays our commit as a NEW commit using the repository's configured identity, which was empty in the ephemeral clone.

**Fix:** Set `user.email` and `user.name` via `git config` on the clone immediately after cloning, so any rebase replay has a valid identity.

**Files modified:** bin/claude-secure (publish_docs_bundle function body)
**Commit:** 3a77641

---

None of these deviations required architectural changes or user input — all three are correctness/completeness fixes within the scope of the current task.

## Install.sh Impact

**No install.sh change needed.** Confirmed during Plan 01 research (24-RESEARCH.md Pitfall 6) that `install.sh` step 5c already uses `cp "$app_dir/webhook/report-templates/"*.md` (install.sh:477), so the bundle.md template added by Plan 01 will be auto-picked-up on a fresh install. Plan 03 adds no new files that need installer wiring.

## Regression Status

- **Phase 16** (result-channel): 33/33 — publish_report + redact_report_file unchanged, push_with_retry reused as-is.
- **Phase 23** (profile-doc-repo-binding): 17/18 — unchanged from baseline. The sole failing test (`docs_token_absent_from_container`) is pre-existing and predates this plan (verified by running the suite with my changes stashed).

## Known Stubs

None. The function is fully wired to real primitives and exercised end-to-end by all 9 Plan 03 tests.

## Self-Check: PASSED

- FOUND: bin/claude-secure (publish_docs_bundle at 1646-1828)
- FOUND: tests/test-phase24.sh (updated helper + 9 call sites)
- FOUND: commit 3a77641
