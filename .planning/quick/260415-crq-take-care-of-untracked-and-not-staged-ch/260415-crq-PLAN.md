---
task_type: quick
task_id: 260415-crq
description: take care of untracked and not staged changes
autonomous: true
files_modified:
  - bin/claude-secure
  - tests/test-phase16.sh
  - tests/test-phase23.sh
  - tests/test-phase25.sh
  - err.txt
  - source
  - .planning/debug/
  - .planning/quick/260411-mre-add-run-tests-script-and-document-testin/
  - .planning/todos/done/2026-04-11-fix-permission-prompts-despite-skip-permissions.md
---

<objective>
Clean up the working tree by discarding temp debug artifacts and committing real work in two atomic, logically separated commits.

Purpose: Repo currently has 4 modified tracked files (real fixes) plus a mix of untracked items — some are temp debug junk, others are legitimate GSD planning artifacts. Leaving them in limbo makes subsequent `git status` noisy and blocks clean milestone verification.

Output:
- `err.txt` and `source` deleted (temp artifacts)
- One commit for the 4 tracked-file fixes (bin/claude-secure + 3 test fixes)
- One commit for the .planning/ artifacts (debug session, completed quick task, done todo)
- `.planning/quick/260415-crq-.../` left uncommitted (quick workflow handles it at finalize)
</objective>

<context>
@.planning/STATE.md
@./CLAUDE.md

# Git status context provided by orchestrator:
# Modified (tracked):
#   - bin/claude-secure       → Phase 28 fix: skip legacy profiles without docs_project_dir silently in fetch_docs_context
#   - tests/test-phase16.sh   → accept docs_repo OR report_repo naming (Phase 23 rename)
#   - tests/test-phase23.sh   → implement test_docs_token_absent_from_container (was stub returning 1)
#   - tests/test-phase25.sh   → add _claude_reachable_or_skip helper; extend skip-as-pass contract
#
# Untracked (KEEP — stage & commit):
#   - .planning/debug/
#   - .planning/quick/260411-mre-add-run-tests-script-and-document-testin/
#   - .planning/todos/done/2026-04-11-fix-permission-prompts-despite-skip-permissions.md
#
# Untracked (DELETE — temp artifacts):
#   - err.txt
#   - source
#
# Exclude from all commits (quick workflow owns it):
#   - .planning/quick/260415-crq-take-care-of-untracked-and-not-staged-ch/
</context>

<tasks>

<task type="auto">
  <name>Task 1: Delete temp debug artifacts</name>
  <files>err.txt, source</files>
  <action>
    Remove the two temp debug artifacts from the working tree:
    - `err.txt` — leftover clone auth failure output
    - `source` — single DBG line from a sourced script

    Use `rm /home/igor9000/claude-secure/err.txt /home/igor9000/claude-secure/source` (absolute paths). Do NOT use `git rm` — these files are untracked, so plain `rm` is correct.
  </action>
  <verify>
    <automated>test ! -e /home/igor9000/claude-secure/err.txt && test ! -e /home/igor9000/claude-secure/source && echo OK</automated>
  </verify>
  <done>Both files no longer exist on disk; `git status` no longer lists them as untracked.</done>
</task>

<task type="auto">
  <name>Task 2: Commit tracked-file fixes (bin + tests)</name>
  <files>bin/claude-secure, tests/test-phase16.sh, tests/test-phase23.sh, tests/test-phase25.sh</files>
  <action>
    Stage the 4 modified tracked files explicitly (never `git add -A`) and create ONE atomic commit grouping the Phase 28 legacy-profile fix with the three test-suite fixes (they all unblock the same milestone verification flow).

    Steps:
    1. Run `git status` first to confirm only these 4 files are staged after the add.
    2. `git add bin/claude-secure tests/test-phase16.sh tests/test-phase23.sh tests/test-phase25.sh`
    3. Use gsd-tools commit helper so hook-safety rules are honored:
       ```
       node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs" commit "fix: handle legacy profiles and stabilize phase 16/23/25 tests

       - bin/claude-secure: fetch_docs_context now skips legacy profiles
         without docs_project_dir silently instead of erroring (Phase 28)
       - tests/test-phase16.sh: accept docs_repo OR report_repo naming
         (Phase 23 rename compatibility)
       - tests/test-phase23.sh: implement test_docs_token_absent_from_container
         (was stub returning 1)
       - tests/test-phase25.sh: add _claude_reachable_or_skip helper,
         extend skip-as-pass contract" --files bin/claude-secure tests/test-phase16.sh tests/test-phase23.sh tests/test-phase25.sh
       ```
    4. Confirm commit landed with `git log -1 --stat`.

    DO NOT include any .planning/ paths in this commit — those belong to Task 3. DO NOT use `--no-verify`.
  </action>
  <verify>
    <automated>cd /home/igor9000/claude-secure && git log -1 --name-only --pretty=format:'%s' | grep -q 'stabilize phase 16/23/25' && git log -1 --name-only | grep -q '^bin/claude-secure$' && git log -1 --name-only | grep -q '^tests/test-phase23.sh$'</automated>
  </verify>
  <done>HEAD is a single commit touching exactly the 4 tracked files, subject line reflects the fix scope, and `git status` no longer lists those files as modified.</done>
</task>

<task type="auto">
  <name>Task 3: Commit .planning artifacts (debug, done todo, 260411-mre quick)</name>
  <files>.planning/debug/, .planning/quick/260411-mre-add-run-tests-script-and-document-testin/, .planning/todos/done/2026-04-11-fix-permission-prompts-despite-skip-permissions.md</files>
  <action>
    Stage the untracked .planning/ artifacts explicitly and commit as a separate chore commit. This is bookkeeping-only — no code changes — so keep it isolated from Task 2.

    CRITICAL: Do NOT stage `.planning/quick/260415-crq-take-care-of-untracked-and-not-staged-ch/` — that directory belongs to the current quick task and will be committed by the quick workflow's own finalize step.

    Steps:
    1. Stage each path explicitly:
       ```
       git add .planning/debug/ \
               .planning/quick/260411-mre-add-run-tests-script-and-document-testin/ \
               .planning/todos/done/2026-04-11-fix-permission-prompts-despite-skip-permissions.md
       ```
    2. Run `git status` and verify the 260415-crq directory is still listed as untracked (NOT staged).
    3. Create the commit via gsd-tools helper:
       ```
       node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs" commit "chore(planning): archive debug session, 260411-mre quick task, and completed todo

       - .planning/debug/: GSD debug session artifacts
       - .planning/quick/260411-mre-*: completed quick task (run-tests.sh docs)
       - .planning/todos/done/2026-04-11-fix-permission-prompts-*: resolved todo" --files .planning/debug/ .planning/quick/260411-mre-add-run-tests-script-and-document-testin/ .planning/todos/done/2026-04-11-fix-permission-prompts-despite-skip-permissions.md
       ```
    4. Confirm with `git log -1 --stat` and `git status`. Only `.planning/quick/260415-crq-.../` should remain untracked.
  </action>
  <verify>
    <automated>cd /home/igor9000/claude-secure && git log -1 --pretty=format:'%s' | grep -q 'archive debug session' && git status --porcelain | grep -v '^?? .planning/quick/260415-crq' | grep -v '^$' | { ! grep -q . ; }</automated>
  </verify>
  <done>HEAD is a chore commit containing only the planning artifacts; `git status` shows a clean tree except for `.planning/quick/260415-crq-.../` which the quick workflow will handle at finalize.</done>
</task>

</tasks>

<verification>
After all tasks complete, run:
```
cd /home/igor9000/claude-secure && git status && git log -2 --oneline
```

Expected state:
- Working tree clean except `.planning/quick/260415-crq-take-care-of-untracked-and-not-staged-ch/` (untracked, intentional).
- HEAD~0: `chore(planning): archive debug session, 260411-mre quick task, and completed todo`
- HEAD~1: `fix: handle legacy profiles and stabilize phase 16/23/25 tests`
- `err.txt` and `source` no longer exist.
</verification>

<success_criteria>
- [ ] `err.txt` and `source` deleted from disk
- [ ] Exactly 2 new commits on current branch (doc-repo)
- [ ] Commit 1 touches only `bin/claude-secure` + 3 `tests/test-phase*.sh` files
- [ ] Commit 2 touches only `.planning/debug/`, `.planning/quick/260411-mre-.../`, and the done todo
- [ ] `.planning/quick/260415-crq-.../` is NOT in either commit (still untracked)
- [ ] `git status` reports clean working tree (except the 260415-crq directory)
- [ ] No `--no-verify`, no `git add -A`, no `.env`/credentials accidentally staged
</success_criteria>

<output>
Quick task — no SUMMARY.md required from executor. The quick workflow finalize step will capture outcome and commit this plan directory.
</output>
