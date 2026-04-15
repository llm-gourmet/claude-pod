---
phase: quick-260415-dam
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - bin/claude-secure
  - tests/test-phase23.sh
  - tests/fixtures/profile-23-docs/profile.json
  - tests/fixtures/profile-24-bundle/profile.json
  - tests/fixtures/profile-25-docs/profile.json
  - tests/fixtures/profile-26-spool/profile.json
  - /home/igor9000/.claude-secure/profiles/default/profile.json
autonomous: true
requirements:
  - QUICK-260415-dam
must_haves:
  truths:
    - "DOCS_MODE is no longer read, exported, or referenced anywhere in the live codebase or test fixtures"
    - "tests/test-phase23.sh test_docs_vars_exported still passes (no DOCS_MODE assertion)"
    - "Profile loader does not warn or error when profile.json omits docs_mode"
    - "Live default profile at ~/.claude-secure/profiles/default/profile.json no longer contains docs_mode"
  artifacts:
    - path: "bin/claude-secure"
      provides: "Profile loader without DOCS_MODE read or export"
      contains: "export DOCS_REPO DOCS_BRANCH DOCS_PROJECT_DIR DOCS_REPO_TOKEN"
    - path: "tests/test-phase23.sh"
      provides: "Phase 23 test suite without DOCS_MODE assertion"
    - path: "tests/fixtures/profile-23-docs/profile.json"
      provides: "Phase 23 docs fixture sans docs_mode"
    - path: "tests/fixtures/profile-24-bundle/profile.json"
      provides: "Phase 24 bundle fixture sans docs_mode"
    - path: "tests/fixtures/profile-25-docs/profile.json"
      provides: "Phase 25 docs fixture sans docs_mode"
    - path: "tests/fixtures/profile-26-spool/profile.json"
      provides: "Phase 26 spool fixture sans docs_mode"
  key_links:
    - from: "bin/claude-secure load_profile_config()"
      to: "tests/test-phase23.sh test_docs_vars_exported"
      via: "exported env vars contract"
      pattern: "DOCS_REPO|DOCS_BRANCH|DOCS_PROJECT_DIR"
---

<objective>
Remove the unused `docs_mode` profile field from the live codebase. The field is read at bin/claude-secure:264 into $DOCS_MODE and exported, but no consumer reads it — it's pure dead code/state. Also remove the matching key from all test fixture profile.json files, the live default profile, and update the one phase-23 test assertion that still checks DOCS_MODE export.

Purpose: Eliminate dead state from the profile schema so future readers don't think docs_mode does something. Reduces cognitive load and prevents accidental "implementation" of behavior that was never intended.

Output: bin/claude-secure with no DOCS_MODE references, 4 test fixtures + 1 live profile with docs_mode key removed, and tests/test-phase23.sh passing without the DOCS_MODE assertion.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md
@bin/claude-secure
@tests/test-phase23.sh

<interfaces>
<!-- Current state of DOCS_MODE in the codebase, extracted via grep. -->
<!-- Executor uses these directly — no exploration needed. -->

bin/claude-secure (current):
```bash
# Line 263-264
DOCS_PROJECT_DIR=$(jq -r '.docs_project_dir // empty' "$pj" 2>/dev/null)
DOCS_MODE=$(jq -r '.docs_mode // "report_only"' "$pj" 2>/dev/null)

# Line 287
export DOCS_REPO DOCS_BRANCH DOCS_PROJECT_DIR DOCS_MODE DOCS_REPO_TOKEN
```

tests/test-phase23.sh test_docs_vars_exported() (lines 125-135):
```bash
test_docs_vars_exported() {
  install_fixture "profile-23-docs" "docs-vars"
  source_cs
  load_profile_config "docs-vars"
  [ "${DOCS_REPO:-}" = "https://github.com/owner/docs-test.git" ] || return 1
  [ "${DOCS_BRANCH:-}" = "main" ] || return 1
  [ "${DOCS_PROJECT_DIR:-}" = "projects/docs-test" ] || return 1
  [ "${DOCS_MODE:-}" = "report_only" ] || return 1   # <-- REMOVE
  return 0
}
```

Live default profile (~/.claude-secure/profiles/default/profile.json):
```json
{
  "workspace": "/home/igor9000/claude-workspace",
  "repo": "test/repo",
  "webhook_secret": "mysecret",
  "docs_repo": "https://github.com/llm-gourmet/obsidian.git",
  "docs_branch": "master",
  "docs_project_dir": "projects/default",
  "docs_mode": "report_only"
}
```

Verified-not-modified locations (planning artifacts — DO NOT touch):
- .planning/research/SUMMARY.md
- .planning/research/ARCHITECTURE.md
- .planning/phases/23-*/*
- .planning/phases/24-*/*
- .planning/phases/25-*/*
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Remove DOCS_MODE from bin/claude-secure and update phase-23 test</name>
  <files>bin/claude-secure, tests/test-phase23.sh</files>
  <action>
    1. In `bin/claude-secure`:
       - Delete line 264: `DOCS_MODE=$(jq -r '.docs_mode // "report_only"' "$pj" 2>/dev/null)`
       - On line 287, remove `DOCS_MODE` from the export list. The line should become:
         `export DOCS_REPO DOCS_BRANCH DOCS_PROJECT_DIR DOCS_REPO_TOKEN`
       - Do NOT touch the second export line for REPORT_REPO/REPORT_BRANCH/REPORT_REPO_TOKEN — those are unaffected.
       - Do NOT touch any of the back-fill blocks (REPORT_REPO_TOKEN, REPORT_REPO, REPORT_BRANCH) — they don't reference DOCS_MODE.

    2. In `tests/test-phase23.sh` `test_docs_vars_exported()` (around line 133):
       - Delete the line: `[ "${DOCS_MODE:-}" = "report_only" ] || return 1`
       - Update the comment on line 126 to drop "/MODE" — change `DOCS_REPO/BRANCH/PROJECT_DIR/MODE` to `DOCS_REPO/BRANCH/PROJECT_DIR`.
       - Leave the other three assertions (DOCS_REPO, DOCS_BRANCH, DOCS_PROJECT_DIR) unchanged.

    3. After edits, grep the codebase to confirm zero remaining DOCS_MODE/docs_mode references in non-planning files:
       ```
       grep -rn 'DOCS_MODE\|docs_mode' bin/ tests/ webhook/ proxy/ validator/ install.sh 2>/dev/null
       ```
       Expected: only matches inside test fixture profile.json files (which Task 2 handles). Zero matches in bin/claude-secure or tests/test-phase23.sh.
  </action>
  <verify>
    <automated>cd /home/igor9000/claude-secure && bash -n bin/claude-secure && bash -n tests/test-phase23.sh && ! grep -n 'DOCS_MODE\|docs_mode' bin/claude-secure tests/test-phase23.sh && bash tests/test-phase23.sh 2>&1 | tail -20</automated>
  </verify>
  <done>
    - `bin/claude-secure` contains zero matches for `DOCS_MODE` or `docs_mode`
    - `tests/test-phase23.sh` contains zero matches for `DOCS_MODE` or `docs_mode`
    - Both files pass `bash -n` syntax check
    - `tests/test-phase23.sh` runs and `test_docs_vars_exported` still passes (or is reported as passing; suite may have other unrelated tests — only this one matters here)
  </done>
</task>

<task type="auto">
  <name>Task 2: Strip docs_mode from all test fixture profiles and the live default profile</name>
  <files>tests/fixtures/profile-23-docs/profile.json, tests/fixtures/profile-24-bundle/profile.json, tests/fixtures/profile-25-docs/profile.json, tests/fixtures/profile-26-spool/profile.json, /home/igor9000/.claude-secure/profiles/default/profile.json</files>
  <action>
    For each of the 5 profile.json files, remove the `"docs_mode": "report_only"` key while preserving all other keys, indentation, and trailing newline.

    Use `jq` to do this safely (it preserves valid JSON and avoids whitespace/trailing-comma footguns). For each file:
    ```
    tmp=$(mktemp) && jq 'del(.docs_mode)' "$file" > "$tmp" && mv "$tmp" "$file"
    ```

    Files to process (in this order):
    1. `tests/fixtures/profile-23-docs/profile.json`
    2. `tests/fixtures/profile-24-bundle/profile.json`
    3. `tests/fixtures/profile-25-docs/profile.json`
    4. `tests/fixtures/profile-26-spool/profile.json`
    5. `/home/igor9000/.claude-secure/profiles/default/profile.json` (live profile outside repo — absolute path)

    After all 5 edits, validate each file is still valid JSON and confirm `docs_mode` is gone:
    ```
    for f in tests/fixtures/profile-23-docs/profile.json \
             tests/fixtures/profile-24-bundle/profile.json \
             tests/fixtures/profile-25-docs/profile.json \
             tests/fixtures/profile-26-spool/profile.json \
             /home/igor9000/.claude-secure/profiles/default/profile.json; do
      jq -e 'has("docs_mode") | not' "$f" > /dev/null && echo "OK: $f" || echo "FAIL: $f"
    done
    ```
    Expected: 5 OK lines.

    NOTE: Do NOT modify any planning artifacts (`.planning/**`) — those are historical and intentionally retain the legacy schema.
  </action>
  <verify>
    <automated>cd /home/igor9000/claude-secure && for f in tests/fixtures/profile-23-docs/profile.json tests/fixtures/profile-24-bundle/profile.json tests/fixtures/profile-25-docs/profile.json tests/fixtures/profile-26-spool/profile.json /home/igor9000/.claude-secure/profiles/default/profile.json; do jq -e 'has("docs_mode") | not' "$f" > /dev/null || { echo "FAIL: $f still has docs_mode"; exit 1; }; done && echo "all fixtures + live profile clean" && bash tests/test-phase23.sh 2>&1 | tail -10</automated>
  </verify>
  <done>
    - All 4 test fixture profile.json files still parse as valid JSON
    - All 4 test fixture profile.json files have no `docs_mode` key
    - Live default profile at `~/.claude-secure/profiles/default/profile.json` still parses and has no `docs_mode` key
    - Running `tests/test-phase23.sh` shows `test_docs_vars_exported` still passing (DOCS_PROJECT_DIR + DOCS_REPO + DOCS_BRANCH still resolve from the cleaned fixture)
    - No planning artifacts under `.planning/` were modified
  </done>
</task>

</tasks>

<verification>
After both tasks complete, run the consolidated grep to prove the field is fully purged from the live codebase:

```bash
grep -rn 'DOCS_MODE\|docs_mode' bin/ tests/ webhook/ proxy/ validator/ install.sh 2>/dev/null
```

Expected output: empty (zero matches).

Then run the phase-23 test suite end-to-end to confirm nothing regressed:

```bash
bash tests/test-phase23.sh
```

Expected: all tests pass, including `test_docs_vars_exported`.

Sanity-check the live profile loader doesn't blow up on the cleaned default profile:

```bash
bash -c 'source bin/claude-secure 2>/dev/null; PROFILE=default load_profile_config default 2>&1 | tail -5'
```

Expected: no errors, no warnings about missing docs_mode (the loader should never have cared).
</verification>

<success_criteria>
- [ ] `bin/claude-secure` has zero references to `DOCS_MODE` or `docs_mode`
- [ ] `tests/test-phase23.sh` has zero references to `DOCS_MODE` or `docs_mode`
- [ ] All 4 test fixture profile.json files have `docs_mode` removed and remain valid JSON
- [ ] Live default profile at `~/.claude-secure/profiles/default/profile.json` has `docs_mode` removed and remains valid JSON
- [ ] `tests/test-phase23.sh` passes with no regressions
- [ ] `grep -rn 'DOCS_MODE\|docs_mode' bin/ tests/ webhook/ proxy/ validator/ install.sh` returns empty
- [ ] No `.planning/**` files were modified
</success_criteria>

<output>
After completion, create `.planning/quick/260415-dam-remove-unused-docs-mode-field-from-profi/260415-dam-SUMMARY.md` with:
- Files modified (count + paths)
- Grep verification output (should be empty for live code)
- Phase-23 test suite result
- Confirmation that no planning artifacts were touched
</output>
