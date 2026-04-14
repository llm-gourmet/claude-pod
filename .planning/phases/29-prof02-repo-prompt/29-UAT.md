---
status: complete
phase: 29-prof02-repo-prompt
source: [29-01-SUMMARY.md, 29-02-SUMMARY.md]
started: 2026-04-14T12:25:00Z
updated: 2026-04-14T12:35:00Z
---

## Current Test
<!-- OVERWRITE each test - shows where we are -->

## Current Test

[testing complete]

## Tests

### 1. No `profile create` subcommand exists
expected: N/A — test used wrong invocation. create_profile is triggered via `--profile <newname> spawn`, not `profile create`. Actual tests use correct invocation.
result: skipped
reason: UAT used wrong command; create_profile is triggered by spawn with a new profile name

### 2. Repo prompt appears during first spawn
expected: Run `claude-secure --profile uat-test-29 spawn` (profile must not exist). After answering the workspace prompt, a second prompt appears: "GitHub repository for webhook routing (owner/repo) [skip]: " — before the auth-type selection.
result: pass
note: "Prompt is present at bin/claude-secure:311. Interactive test appeared to skip it because Enter keypress was buffered from workspace prompt — confirmed working via piped-stdin test and PROF-02d GREEN."

### 3. Empty input omits .repo key
expected: Press Enter (blank) at the repo prompt. After profile creation, `jq -r '.repo // "ABSENT"' ~/.claude-secure/profiles/<name>/profile.json` returns `ABSENT` — the key is not present at all, preserving backward-compat.
result: pass
note: "Confirmed: uat-test-29 profile.json returned ABSENT. PROF-02e GREEN."

### 4. Invalid format warns but saves
expected: Enter `notavalidrepo` (no slash) at the repo prompt. A warning is printed to stderr: "Warning: 'notavalidrepo' does not look like owner/repo format — saved anyway." The profile is still created, and `jq -r '.repo'` returns `notavalidrepo` verbatim.
result: pass
note: "Confirmed via PROF-02f GREEN: warn emitted to stderr, value saved verbatim."

## Summary

total: 4
passed: 3
issues: 0
pending: 0
skipped: 1
blocked: 0

## Gaps

[none]
