---
status: testing
phase: 29-prof02-repo-prompt
source: [29-01-SUMMARY.md, 29-02-SUMMARY.md]
started: 2026-04-14T12:25:00Z
updated: 2026-04-14T12:30:00Z
---

## Current Test
<!-- OVERWRITE each test - shows where we are -->

number: [testing complete]

## Tests

### 1. No `profile create` subcommand exists
expected: N/A — test used wrong invocation. create_profile is triggered via `--profile <newname> spawn`, not `profile create`. Actual tests use correct invocation.
result: skipped
reason: UAT used wrong command; create_profile is triggered by spawn with a new profile name

### 2. Repo prompt appears during first spawn
expected: Run `claude-secure --profile uat-test-29 spawn` (profile must not exist). After answering the workspace prompt, a second prompt appears: "GitHub repository for webhook routing (owner/repo) [skip]: " — before the auth-type selection.
result: issue
reported: "Prompt absent — output was: workspace → 'Copy auth credentials from default? [Y/n]:' with no repo prompt in between. Profile created without repo field."
severity: major

### 3. Empty input omits .repo key
expected: Press Enter (blank) at the repo prompt. After profile creation, `jq -r '.repo // "ABSENT"' ~/.claude-secure/profiles/<name>/profile.json` returns `ABSENT` — the key is not present at all, preserving backward-compat.
result: blocked
blocked_by: prior-phase
reason: "Repo prompt (test 2) not appearing — cannot test empty-skip path"

### 4. Invalid format warns but saves
expected: Enter `notavalidrepo` (no slash) at the repo prompt. A warning is printed to stderr: "Warning: 'notavalidrepo' does not look like owner/repo format — saved anyway." The profile is still created, and `jq -r '.repo'` returns `notavalidrepo` verbatim.
result: blocked
blocked_by: prior-phase
reason: "Repo prompt (test 2) not appearing — cannot test warn-don't-block path"

## Summary

total: 4
passed: 0
issues: 1
pending: 0
skipped: 1
blocked: 2

## Gaps

- truth: "Repo prompt 'GitHub repository for webhook routing (owner/repo) [skip]:' appears after workspace prompt during first spawn"
  status: failed
  reason: "User reported: Prompt absent — output was: workspace → 'Copy auth credentials from default? [Y/n]:' with no repo prompt in between. Profile created without repo field."
  severity: major
  test: 2
  root_cause: ""
  artifacts: []
  missing: []
  debug_session: ""
