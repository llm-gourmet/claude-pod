---
status: complete
phase: 23-profile-doc-repo-binding
source: [23-01-SUMMARY.md, 23-02-SUMMARY.md, 23-03-SUMMARY.md]
started: 2026-04-14T00:00:00Z
updated: 2026-04-14T00:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. validate_docs_binding — field validation and fail-closed behavior
expected: A profile with docs_repo set to a malformed URL (e.g. "not-a-url" or "http://insecure") should fail at spawn with a clear actionable error. A profile with a valid https:// docs_repo, docs_branch, docs_project_dir and DOCS_REPO_TOKEN in .env should pass validation silently. A profile with NO docs_* fields at all should also pass (opt-out semantics).
result: pass

### 2. DOCS_REPO_TOKEN absent from container env
expected: Running a live stack with a profile containing DOCS_REPO_TOKEN in .env and dumping the container env (docker compose exec claude printenv | grep -i token) shows neither DOCS_REPO_TOKEN nor REPORT_REPO_TOKEN in container. Other vars (CLAUDE_CODE_OAUTH_TOKEN, GITHUB_TOKEN, etc.) remain present.
result: pass
notes: Verified via 23-HUMAN-UAT.md on 2026-04-13

### 3. Legacy alias resolution (resolve_docs_alias)
expected: A profile with legacy report_repo / REPORT_REPO_TOKEN fields (no docs_* fields) spawns successfully. The deprecation warning appears exactly once per shell session on stderr. A second spawn in the same session produces no second warning. DOCS_REPO, DOCS_BRANCH, DOCS_PROJECT_DIR, DOCS_REPO_TOKEN are all populated from the legacy fields.
result: skipped
reason: Legacy REPORT_REPO_TOKEN support will be removed entirely — only DOCS_REPO_TOKEN going forward

### 4. profile init-docs — bootstrap layout
expected: Running `claude-secure --profile <name> profile init-docs` on an empty doc repo creates exactly these paths under projects/<slug>/: todo.md, architecture.md, vision.md, ideas.md, specs/ (directory), reports/INDEX.md — all in a single atomic commit. `git log --oneline` on the doc repo shows exactly one new commit.
result: pass
notes: Fixed 2 bugs: (1) clone fallback for repos where docs_branch doesn't exist yet — now auto-detects actual default branch; (2) rm -f → rm -rf in cleanup() for temp directories

### 5. profile init-docs — idempotency
expected: Running `claude-secure --profile <name> profile init-docs` a second time on a repo where the layout already exists exits 0 with a message like "Doc layout already initialized" and creates NO additional git commit (commit count unchanged).
result: pass

### 6. profile init-docs — fails closed without docs_repo
expected: Running `claude-secure --profile <name> profile init-docs` on a profile that has no docs_repo configured exits with a non-zero status and an actionable error message (e.g. "docs_repo not configured"). Does not attempt any git operations.
result: pass

### 7. profile init-docs — PAT scrubbed from error output
expected: If init-docs fails (e.g. bad credentials), the error output does NOT contain the raw DOCS_REPO_TOKEN value. The token appears as <REDACTED:DOCS_REPO_TOKEN> or is completely absent from all stderr/stdout.
result: pass
notes: GitHub returns generic auth error with no token value in output

## Summary

total: 7
passed: 5
issues: 0
pending: 0
skipped: 1
blocked: 0

## Gaps

[none yet]
