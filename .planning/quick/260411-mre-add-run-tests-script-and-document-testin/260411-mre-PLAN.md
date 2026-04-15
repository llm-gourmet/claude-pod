---
phase: quick
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - run-tests.sh
  - README.md
autonomous: true
requirements: []
must_haves:
  truths:
    - "Developer can run all tests with ./run-tests.sh"
    - "Developer can run specific test suites with ./run-tests.sh test-phase1.sh test-phase3.sh"
    - "README documents testing workflow, smart selection, and test-map structure"
  artifacts:
    - path: "run-tests.sh"
      provides: "Convenience wrapper for pre-push hook"
    - path: "README.md"
      provides: "Testing section before Architecture Details"
  key_links: []
---

<objective>
Create a run-tests.sh convenience script and add a Testing section to README.md.

Purpose: Make it easy to run the integration test suite manually without needing to know the pre-push hook internals or fake git ref stdin format.
Output: run-tests.sh at repo root, updated README.md with Testing section.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@git-hooks/pre-push
@tests/test-map.json
@README.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create run-tests.sh convenience script</name>
  <files>run-tests.sh</files>
  <action>
Create run-tests.sh at the repo root. The script should:

1. Print a header: "claude-secure test runner"
2. Accept optional positional args as specific test script names (e.g., `./run-tests.sh test-phase1.sh test-phase3.sh`)
3. If args provided: set those as the test scripts to run by passing them through to the pre-push hook logic
4. If no args: run all tests

The core mechanism: pipe fake git refs into the pre-push hook with RUN_ALL_TESTS=1:
```bash
echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main 0000000000000000000000000000000000000000" | RUN_ALL_TESTS=1 bash git-hooks/pre-push
```

For specific tests, instead of using the pre-push hook (which doesn't support selecting individual scripts), directly replicate the test execution pattern from the pre-push hook sections 4-8:
- Set the same env vars (COMPOSE_PROJECT_NAME=claude-test, COMPOSE_FILE, SECRETS_FILE, WHITELIST_PATH, WORKSPACE_PATH, LOG_DIR)
- For each requested test script: docker compose down, docker compose up -d --wait, run the test, track results
- Print a summary table at the end
- Teardown on success, leave running on failure (same as pre-push hook behavior)

Keep the script around 50-80 lines. Include `set -uo pipefail`. Add `chmod +x` note in a comment. The script must:
- cd to repo root via `git rev-parse --show-toplevel`
- Validate that requested test scripts exist before running
- Exit with appropriate codes (0 for pass, 1 for fail)
  </action>
  <verify>
    <automated>bash -n run-tests.sh && echo "Syntax OK"</automated>
  </verify>
  <done>run-tests.sh exists at repo root, is executable, syntax-checks clean, supports both all-tests and specific-test modes</done>
</task>

<task type="auto">
  <name>Task 2: Add Testing section to README.md</name>
  <files>README.md</files>
  <action>
Read README.md fully first. Insert a new `## Testing` section immediately BEFORE the `## Architecture Details` line (currently at line 235).

The Testing section should contain:

### Quick Start subsection
- Show `./run-tests.sh` to run all tests
- Show `./run-tests.sh test-phase1.sh test-phase3.sh` to run specific suites
- Note: requires Docker running

### Available Test Suites subsection
Table listing each test script and what it covers:
| Script | Covers |
|--------|--------|
| test-phase1.sh | Container infrastructure, networking, health checks |
| test-phase2.sh | Call validation, hook enforcement, iptables rules |
| test-phase3.sh | Secret redaction in proxy |
| test-phase4.sh | Installer script |
| test-phase6.sh | Phase 6 features |
| test-phase7.sh | Environment file and secret loading |
| test-phase9.sh | CLI wrapper (bin/claude-secure) |

### Smart Pre-Push Hook subsection
Explain how the pre-push hook (`git-hooks/pre-push`) works:
- Automatically selects relevant tests based on changed files using `tests/test-map.json`
- Skips tests for doc-only changes (*.md, .planning/, .claude/)
- Falls back to running all tests if no mapping found
- Uses an isolated `claude-test` Docker Compose instance
- Skip with `git push --no-verify`
- Override to run all: `RUN_ALL_TESTS=1 git push`

### test-map.json Structure subsection
Brief explanation of the test-map.json format:
- `mappings`: array of `{paths: [...], tests: [...]}` — maps file path prefixes to test suites
- `always_skip`: array of patterns that never trigger tests (globs like `*.md`, directory prefixes like `.planning/`)
- Show a small example snippet from the actual file

Keep the entire section concise — aim for 60-80 lines of markdown.
  </action>
  <verify>
    <automated>grep -n "## Testing" README.md && grep -n "## Architecture Details" README.md</automated>
  </verify>
  <done>README.md has a Testing section appearing before Architecture Details, documenting run-tests.sh, test suites, smart pre-push hook, and test-map.json</done>
</task>

</tasks>

<verification>
- `bash -n run-tests.sh` passes (valid syntax)
- `grep "## Testing" README.md` finds the section
- Testing section appears before Architecture Details in README.md
- run-tests.sh references the pre-push hook correctly
</verification>

<success_criteria>
- run-tests.sh exists, is executable, and wraps the pre-push hook for easy manual test execution
- README.md documents the full testing workflow including smart selection and test-map structure
</success_criteria>

<output>
After completion, create `.planning/quick/260411-mre-add-run-tests-script-and-document-testin/260411-mre-SUMMARY.md`
</output>
