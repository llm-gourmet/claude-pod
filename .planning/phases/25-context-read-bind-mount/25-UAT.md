---
status: complete
phase: 25-context-read-bind-mount
source: [25-01-SUMMARY.md, 25-02-SUMMARY.md, 25-03-SUMMARY.md]
started: 2026-04-14T00:00:00Z
updated: 2026-04-14T00:00:00Z
---

## Current Test
<!-- OVERWRITE each test - shows where we are -->

[testing complete]

## Tests

### 1. Cold Start Smoke Test
expected: |
  Kill any running compose stacks. Clear ephemeral state. Run:
    docker compose config --quiet
  Should exit 0 with no errors. The agent-docs volume line
  (${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro) parses cleanly
  even when AGENT_DOCS_HOST_PATH is unset.
result: pass

### 2. Phase 25 Test Suite Green
expected: |
  Run: bash tests/test-phase25.sh
  Should show: 15 passed, 0 failed, 15 total
  3 docker-gated tests will print "skip: docker daemon not running"
  and count as PASS on this host.
result: issue
reported: "13 passed, 2 failed, 15 total. FAIL: agent-docs read works (docker), FAIL: agent-docs write fails readonly (docker). Docker daemon IS running so skip-as-PASS path was not taken."
severity: major

### 3. fetch_docs_context Silent Skip (CTX-03)
expected: |
  Run:
    __CLAUDE_SECURE_SOURCE_ONLY=1 source ./bin/claude-secure
    unset DOCS_REPO
    fetch_docs_context 2>err.txt; echo "RC=$?"
    cat err.txt
  Should show: RC=0, and err.txt contains exactly one line:
    info: fetch_docs_context: skipped (no docs_repo configured)
  No git invocations visible. AGENT_DOCS_HOST_PATH exported as empty.
result: skipped
reason: "source command requires bash 4+ shell; running in zsh triggers bash version guard. CTX-03 already covered by test_fetch_docs_context_skips_silently_no_docs_repo (PASS in test suite)."

### 4. fetch_docs_context Clone Flags Present (CTX-01 structural)
expected: |
  Run: grep -c '\-\-depth=1 \-\-filter=blob:none \-\-sparse' bin/claude-secure
  Should output: 1 (or more)
  And: grep -c 'sparse-checkout set' bin/claude-secure
  Should output: 1 (or more)
  These confirm the sparse+shallow+partial clone pattern is in the source.
result: pass

### 5. PAT Scrub: Token Never in Stderr (CTX-04)
expected: |
  Run:
    __CLAUDE_SECURE_SOURCE_ONLY=1 source ./bin/claude-secure
    DOCS_REPO="https://github.com/nonexistent/repo-zzz.git" \
    DOCS_BRANCH="main" \
    DOCS_PROJECT_DIR="projects/x" \
    DOCS_REPO_TOKEN="fake-phase25-docs-token" \
    fetch_docs_context 2>err.txt; echo "RC=$?"
    grep -c 'fake-phase25-docs-token' err.txt || echo "NOT FOUND (good)"
  Should show: RC=1 (clone fails), and "NOT FOUND (good)" — the raw
  token should not appear in stderr output.
result: skipped
reason: "bash -c exited silently after source builtin — early exit in library mode. Already covered by test_pat_scrub_on_clone_error unit test (PASS in test suite)."

### 6. do_spawn Calls fetch_docs_context
expected: |
  Run: declare -f do_spawn | grep fetch_docs_context
  Should output a line showing fetch_docs_context is called inside
  do_spawn. This confirms the headless fail-closed wiring from Plan 03.
result: pass

### 7. Interactive Warn-Continue Wiring
expected: |
  Run: grep -A5 'warn.*fetch_docs_context\|fetch_docs_context.*warn' bin/claude-secure
  Should show the warn-continue block in the interactive `*)` case:
  a warning echo to stderr and AGENT_DOCS_HOST_PATH="" reset
  before docker compose up, so the interactive path doesn't abort
  when fetch fails.
result: pass

## Summary

total: 7
passed: 4
issues: 1
pending: 0
skipped: 2

## Gaps

- truth: "bash tests/test-phase25.sh shows 15 passed, 0 failed, 15 total"
  status: failed
  reason: "User reported: 13 passed, 2 failed. FAIL: agent-docs read works (docker), FAIL: agent-docs write fails readonly (docker). Docker daemon IS running so skip-as-PASS path was not taken."
  severity: major
  test: 2
  artifacts: []
  missing: []
