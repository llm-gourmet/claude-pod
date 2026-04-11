# Phase 10: Automate Pre-Push Tests - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Harden the pre-push hook into a production-ready test gate: smart test selection based on changed files, dedicated test instance, clean-state guarantees between suites, and clear failure output. Local developer workflow only — CI is out of scope.

</domain>

<decisions>
## Implementation Decisions

### Test Selection Strategy
- **D-01:** Smart subset based on `git diff` — map changed files to relevant test suites (e.g., `proxy/` changes → `test-phase3.sh`, `claude/` changes → `test-phase1.sh`)
- **D-02:** Override with `RUN_ALL_TESTS=1` env var to force all tests regardless of changes
- **D-03:** When no files match any known test mapping (docs-only, `.planning/` only), skip tests and allow push

### Instance Awareness
- **D-04:** Dedicated `test` instance with its own compose project, isolated from user's running instances. Hook auto-starts the test instance if not already running.
- **D-05:** Teardown on success only — leave containers up on failure for debugging, `docker compose down` on success

### CI/Local Parity
- **D-06:** Pre-push hook is local-only. CI pipeline is a separate concern for a future phase. No shared test runner needed.

### Failure UX
- **D-07:** On failure, show a summary table of requirement IDs with PASS/FAIL status per suite, then block the push.

### Test Data & Container Lifecycle
- **D-08:** Each test suite starts with identical preconditions — full `docker compose down && up` between suites guarantees clean state
- **D-09:** Test instance uses its own `.env` with test-appropriate credentials (dummy keys, test secrets)

### Claude's Discretion
- File-to-test mapping design (static config file vs. convention-based detection)
- Summary table format and styling

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Test Infrastructure
- `tests/test-phase1.sh` — Phase 1 integration test pattern (reference for test structure)
- `tests/test-phase3.sh` — Phase 3 tests with compose override pattern (most complex test suite)
- `git-hooks/pre-push` — Current basic pre-push hook (to be replaced/hardened)

### Installation & CLI
- `install.sh` — Installer with `install_git_hooks()` function
- `bin/claude-secure` — CLI wrapper with multi-instance support (test instance creation pattern)

### Docker Infrastructure
- `docker-compose.yml` — Compose configuration (test instance will use same file with different project name)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `git-hooks/pre-push`: Basic hook already created — needs hardening, not building from scratch
- `install.sh:install_git_hooks()`: Hook installation function already exists
- `bin/claude-secure`: Multi-instance pattern (create_instance, COMPOSE_PROJECT_NAME) can be reused for test instance setup

### Established Patterns
- Test scripts follow `test-phase*.sh` naming convention, exit 0/1, use `report()` helper for PASS/FAIL per requirement ID
- Multi-instance uses `COMPOSE_PROJECT_NAME="claude-${INSTANCE}"` pattern
- Phase 3 tests use compose overrides (`docker compose -f docker-compose.yml -f override.yml`)

### Integration Points
- `git-hooks/pre-push` is the entry point — replace current naive implementation
- `install.sh` already copies hooks from `git-hooks/` directory
- Test instance needs a `.env` in `$CONFIG_DIR/instances/test/`

</code_context>

<specifics>
## Specific Ideas

- User emphasized that each test suite must start with identical preconditions — reliability over speed
- Full teardown+rebuild between suites is non-negotiable even though it's the slowest approach
- Containers left up on failure enables immediate debugging (`docker compose exec` into the test instance)

</specifics>

<deferred>
## Deferred Ideas

- CI pipeline integration (GitHub Actions) — separate future phase
- Parallel test execution with isolated compose projects — considered but rejected for simplicity
- Lightweight reset script between suites — rejected in favor of full teardown for reliability

</deferred>

---

*Phase: 10-automate-pre-push-tests*
*Context gathered: 2026-04-11*
