---
phase: 29-prof02-repo-prompt
plan: 01
subsystem: profile-system
tags: [tdd, red-state, wave-0, test-harness]
requires: []
provides:
  - "Failing PROF-02d/e/f tests that encode the create_profile repo-prompt contract"
  - "Regression guard for future refactors silently removing the .repo prompt"
affects:
  - tests/test-phase12.sh
tech-stack:
  added: []
  patterns:
    - "Piped stdin into sourced create_profile to exercise real prompt flow"
    - "Stderr capture INSIDE test function (run_test redirects stderr to /dev/null)"
key-files:
  created: []
  modified:
    - tests/test-phase12.sh
decisions:
  - "PROF-02e may transiently pass today (no .repo key anyway) but carries positive .env guard so it becomes a meaningful GREEN only after 29-02 wires the 4-prompt flow end-to-end"
  - "Stderr redirected per-test via `create_profile ... 2>\"$stderr_log\"` because global run_test swallows stderr"
  - "Tests pipe into sourced function, not subshell exec, so they exercise the actual bin/claude-secure definition — Nyquist guard against Pitfall 5 (helper-only fix)"
metrics:
  duration: "1min"
  completed: 2026-04-14T12:11:04Z
  tasks: 1
  files_modified: 1
---

# Phase 29 Plan 01: PROF-02 Wave 0 Failing Tests Summary

Added three failing tests (PROF-02d, PROF-02e, PROF-02f) to `tests/test-phase12.sh` that exercise the real `bin/claude-secure create_profile` function via piped stdin, establishing the RED state for the upcoming 29-02 prompt implementation.

## Tasks Completed

### Task 1: Add failing PROF-02d/e/f tests

**Commit:** `7bc88fb`

**Files modified:**
- `tests/test-phase12.sh` (+83 lines, 0 deletions — purely additive)

**Inserted line ranges:**
- Lines 220-249: `test_prof_02d_create_profile_prompts_for_repo` + run_test (happy path)
- Lines 251-276: `test_prof_02e_create_profile_skip_repo` + run_test (skip path)
- Lines 278-302: `test_prof_02f_create_profile_warns_on_bad_format` + run_test (warn path)

**Inserted after:** `run_test "PROF-02c: resolve_profile_by_repo returns exit 1 for unknown repo"` (line 218)
**Inserted before:** `# PROF-03a: validate_profile with missing profile directory` (now line 304)

## Test Behavior

Each new test sources `bin/claude-secure` via `_source_functions "$tmpdir"`, then pipes a 4-line stdin sequence into the real `create_profile` function:

| Test       | Stdin sequence                                              | Assertion                                                                                 |
| ---------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| PROF-02d   | `\nowner/my-repo\n1\noauth-token-xyz\n`                     | `jq -r '.repo'` == `owner/my-repo`                                                        |
| PROF-02e   | `\n\n1\noauth-token-xyz\n`                                  | `.workspace` present, `.repo` absent/empty, `.env` file present                           |
| PROF-02f   | `\nnot-a-valid-repo-format\n1\noauth-token-xyz\n`           | stderr contains `Warning`, `.repo` saved verbatim as `not-a-valid-repo-format`            |

## RED State Confirmation

Running `bash tests/test-phase12.sh` after this plan:

```
  PASS: PROF-02a: profile.json repo field readable via jq
  PASS: PROF-02b: resolve_profile_by_repo returns correct profile
  PASS: PROF-02c: resolve_profile_by_repo returns exit 1 for unknown repo
  FAIL: PROF-02d: create_profile prompts for and persists .repo field
  FAIL: PROF-02e: create_profile allows skipping .repo (empty input)
  FAIL: PROF-02f: create_profile warns on bad repo format but saves
  Results: 19 passed, 3 failed (of 22 total)
```

All three new PROF-02 tests FAIL as expected. No pre-existing tests regressed — counts before: 19/19 passing; counts after: 19/22 passing with exactly the 3 new tests red. PROF-02a/b/c (legacy profile-read tests using `create_test_profile` helper) still pass, proving additivity.

### Per-test RED rationale

- **PROF-02d FAIL:** current `create_profile` never reads a repo line; the first piped `\n` is consumed by the workspace prompt, `owner/my-repo` is consumed by `setup_profile_auth`'s "Choice [1]:" prompt, so `.repo` is never written. `jq -r '.repo // empty'` returns empty.
- **PROF-02e FAIL:** today the `.env` guard fails because the stdin sequence misaligns — `1` and `oauth-token-xyz` don't satisfy the auth flow correctly under the current 3-prompt sequence (workspace / choice / token). After 29-02 adds the repo prompt, the 4-line sequence will line up and the test goes green.
- **PROF-02f FAIL:** no warning is ever emitted by current `create_profile`, and `.repo` is never written. Both assertions fail.

## bin/claude-secure Diff Check

```
$ git diff --stat bin/claude-secure
(empty — file untouched)
```

Confirmed: this plan is tests-only. Plan 29-02 will patch `bin/claude-secure:296-343`.

## Deviations from Plan

None — plan executed exactly as written. No Rule 1/2/3 auto-fixes applied.

## Handoff Note

Plan 29-02 must patch `bin/claude-secure:296-343` `create_profile` per `29-RESEARCH.md` Code Example 1 to turn all three new tests GREEN. The patch should:

1. Add a `read -rp "GitHub repo (owner/repo, blank to skip): " repo_input` prompt between the workspace prompt and the `jq -n` profile.json build
2. When `repo_input` is non-empty, check it against the `^[^/]+/[^/]+$` regex; if it doesn't match, emit `Warning: ...` to stderr but still save the value
3. Build `profile.json` with either `{workspace: $ws}` (blank input) or `{workspace: $ws, repo: $repo}` (any non-empty input, valid or not)

## Self-Check: PASSED

**Files created/modified:**
- `tests/test-phase12.sh` — FOUND (modified, +83 lines)
- `.planning/phases/29-prof02-repo-prompt/29-01-SUMMARY.md` — FOUND (this file)

**Commits:**
- `7bc88fb` — FOUND: `test(29-01): add failing PROF-02d/e/f tests for create_profile repo prompt`

**Acceptance criteria verification:**
- `test_prof_02d_create_profile_prompts_for_repo` literal present: YES (line 225)
- `test_prof_02e_create_profile_skip_repo` literal present: YES (line 251)
- `test_prof_02f_create_profile_warns_on_bad_format` literal present: YES (line 281)
- 3 new run_test invocations present: YES (lines 244, 275, 301)
- Each printf stdin literal present: YES (lines 234, 261, 289)
- `grep -c "FAIL: PROF-02d"` == 1: YES
- `grep -c "FAIL: PROF-02e"` == 1: YES (acceptable — spec allows 0 or 1 in RED state)
- `grep -c "FAIL: PROF-02f"` == 1: YES
- `git diff --stat bin/claude-secure` empty: YES
- `git diff --numstat tests/test-phase12.sh` shows `83  0`: YES (additive only)
- PROF-02a/b/c still PASS: YES
