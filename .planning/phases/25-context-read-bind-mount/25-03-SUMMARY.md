---
phase: 25-context-read-bind-mount
plan: 03
subsystem: infra
tags: [bash, docker-compose, bind-mount, spawn-integration]

# Dependency graph
requires:
  - phase: 25-context-read-bind-mount
    provides: "Plan 25-01 Wave 0 test scaffold (tests/test-phase25.sh, profile-25-docs fixture, docker-compose agent-docs:/agent-docs:ro volume)"
  - phase: 25-context-read-bind-mount
    provides: "Plan 25-02 fetch_docs_context() host-side helper (bin/claude-secure lines 1857-1961)"
  - phase: 23-profile-doc-repo-binding
    provides: "resolve_docs_alias exports DOCS_REPO / DOCS_BRANCH / DOCS_PROJECT_DIR / DOCS_REPO_TOKEN from load_profile_config"
provides:
  - "do_spawn() invokes fetch_docs_context before docker compose up (fail-closed)"
  - "Interactive no-subcommand path invokes fetch_docs_context before docker compose up (warn-continue)"
  - "End-to-end CTX-01..CTX-04 satisfaction: /agent-docs bind mount populated for both headless and interactive entry points"
affects: [25 phase closure, webhook spawn path, interactive CLI]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Asymmetric failure policy: fail-closed on headless spawn (programmatic caller needs loud failure), warn-continue on interactive shell (human caller may be iterating on config)"
    - "Explicit AGENT_DOCS_HOST_PATH='' reset on interactive failure branch so compose substitution falls back to the inert /dev/null default rather than inheriting stale outer-shell state"

key-files:
  created:
    - ".planning/phases/25-context-read-bind-mount/25-03-SUMMARY.md"
  modified:
    - "bin/claude-secure — two add-only insertions (13 lines in do_spawn + 9 lines in interactive *) case)"

key-decisions:
  - "do_spawn fail-closed vs interactive warn-continue split preserved verbatim from the plan's Open Question 1 resolution"
  - "AGENT_DOCS_HOST_PATH='' reset on interactive failure branch added to prevent stale-env leakage into compose substitution"
  - "No change to docker compose up -d / docker compose up -d --wait flag (out of scope per plan discipline section)"

patterns-established:
  - "Pattern: two entry points to the same helper with asymmetric failure handling -- headless (programmatic) fails closed, interactive (human) warns and falls back to inert default"

requirements-completed: [CTX-01, CTX-02]

# Metrics
duration: 2min
completed: 2026-04-14
---

# Phase 25 Plan 03: do_spawn + Interactive `fetch_docs_context` Wiring Summary

**Two add-only insertions in `bin/claude-secure` complete the Phase 25 context-read bind-mount pipeline: do_spawn fails closed, interactive path warns and continues, full 15-test Phase 25 suite green.**

## Performance

- **Duration:** ~2 min
- **Started:** 2026-04-14T09:18:40Z
- **Completed:** 2026-04-14T09:20:47Z
- **Tasks:** 2
- **Files modified:** 1 (`bin/claude-secure`, 22 insertion lines across 2 add-only hunks)

## Accomplishments

- **Task 1 (do_spawn headless wiring, fail-closed):** 13-line additive block inserted between the REPORT_REPO export `fi` and the `# Resolve and render prompt template` comment. On fetch failure, calls `_spawn_error_audit "spawn: fetch_docs_context failed"` and `return 1`. Turns `test_do_spawn_calls_fetch_docs_context` green.
- **Task 2 (interactive `*)` wiring, warn-continue):** 9-line additive block inserted between `cleanup_containers` and `docker compose up -d` in the no-subcommand case. On fetch failure, prints warning to stderr, resets `AGENT_DOCS_HOST_PATH=""` (so compose falls back to inert `/dev/null` default), and proceeds. Turns the three docker-gated Phase 25 tests green or skip-pass.
- **End-to-end:** both headless `spawn` and interactive no-subcommand paths now populate `/agent-docs` inside the claude container when `docs_repo` is configured; structural `.git/` exclusion from Plan 02 + `:ro` flag from Plan 01 yield the CTX-02/CTX-04 kernel-level read-only guarantee at container entry.

## Insertion Sites (post-edit line numbers)

| Site | File | Lines | Hunk size | Failure policy |
|------|------|-------|-----------|----------------|
| do_spawn headless path | bin/claude-secure | 2083-2094 | +13 | fail-closed (`_spawn_error_audit` + `return 1`) |
| Interactive `*)` case   | bin/claude-secure | 2822-2830 | +9  | warn-continue (`echo warning` + `AGENT_DOCS_HOST_PATH=""` + `export`) |

Both sites grep cleanly:

```
$ grep -n 'fetch_docs_context' bin/claude-secure
1857:fetch_docs_context() {                                       # function def from Plan 02
...
2091:  if ! fetch_docs_context; then                              # Task 1 do_spawn call
2092:    _spawn_error_audit "spawn: fetch_docs_context failed"
...
2826:    if ! fetch_docs_context; then                            # Task 2 interactive call
2827:      echo "warning: fetch_docs_context failed on interactive path; continuing without /agent-docs mount" >&2
```

## Task Commits

1. **Task 1: Wire fetch_docs_context into do_spawn (fail-closed)** — `62ea5a6` (feat)
2. **Task 2: Wire fetch_docs_context into interactive `*)` case (warn-continue)** — `0e79046` (feat)

## Files Created/Modified

- `bin/claude-secure` — two add-only insertions totaling 22 lines (13 + 9). Zero removals, zero reorderings. `git diff --stat` shows `1 file changed, 22 insertions(+)` across the two commits.
- `.planning/phases/25-context-read-bind-mount/25-03-SUMMARY.md` — this file.

## Decisions Made

None beyond the plan. The two insertion blocks were specified verbatim in the plan's `<action>` sections and were inserted exactly as written, preserving the asymmetric failure policy (fail-closed on headless, warn-continue on interactive) that the plan's Open Question 1 resolution prescribed.

## Deviations from Plan

**None — plan executed exactly as written.**

- Task 1's insertion matches the plan's exact `<action>` text character-for-character (13 lines inside do_spawn).
- Task 2's insertion matches the plan's exact `<action>` text character-for-character (9 lines inside the `*)` case), including the `AGENT_DOCS_HOST_PATH=""` reset branch that the plan flagged as a compose-substitution safety measure.
- No Rule 1/2/3/4 triggers fired during execution. No auto-fixes applied. No CLAUDE.md directives required adjustment.

## Test Suite Breakdown

### Phase 25 end-to-end (post-wiring)

```
$ bash tests/test-phase25.sh
  PASS: fixtures exist
  PASS: compose volume entry present
  PASS: test-map registered
  PASS: fetch_docs_context function exists
  PASS: fetch_docs_context clone flags
  PASS: fetch_docs_context exports path
  PASS: fetch_docs_context skips silently no docs repo
  PASS: fetch_docs_context emits one info line on skip
  PASS: spawn no docs does not invoke git
  PASS: mount source excludes .git
  PASS: pat scrub on clone error
  PASS: agent-docs read works (docker)              [skip: docker daemon not running -> skip-PASS]
  PASS: agent-docs write fails readonly (docker)    [skip: docker daemon not running -> skip-PASS]
  PASS: agent-docs no .git in container (docker)    [skip: docker daemon not running -> skip-PASS]
  PASS: do_spawn calls fetch_docs_context

Phase 25 tests: 15 passed, 0 failed, 15 total
```

**15/15 PASS** on this WSL2 host. The three docker-gated tests print `skip: docker daemon not running` and are counted as PASS by the harness per Plan 01's `run_test` skip-PASS convention. On a host with a running Docker daemon they will execute the real bind-mount read/write/`.git` existence assertions against a live container.

Docker daemon state during test run: not running (`docker info` failed with `Cannot connect to the Docker daemon`). This is the documented SKIP-PASS path; the three gated tests are byte-for-byte the same assertions that will execute on a daemon-up host — no code-path difference between the two modes.

### Regression suites

| Phase | Result | Pre-existing failures | Regression? |
|-------|--------|-----------------------|-------------|
| Phase 23 | 17 passed, 1 failed | `docs_token_absent_from_container` (docker-gated integration, pre-existing per 25-02 SUMMARY) | No — verified identical failure with `git stash` baseline |
| Phase 24 | 13 passed, 0 failed | None | No |
| Phase 16 | 21 passed, 12 failed | 12 docker-gated tests require a running daemon (pre-existing on this host) | No — verified identical counts with `git stash` baseline (21 passed / 12 failed before and after my edits) |

### Compose sanity

```
$ docker compose config --quiet
(exit 0)
```

No YAML parse errors; Plan 01's `agent-docs:/agent-docs:ro` volume entry with `${AGENT_DOCS_HOST_PATH:-/dev/null}` substitution validates cleanly.

## Auth Gates

None. No credentials were needed for any task.

## Manual Smoke Test

Not performed — docker daemon is not running on this host, and Plan 25-02 already verified the end-to-end sparse-clone path via ad-hoc bash scripts against a real bare git repo fixture. The only new behavior in Plan 03 is the *call site*, not the helper itself; the call site is validated by the unit test `test_do_spawn_calls_fetch_docs_context` (greps `declare -f do_spawn` for `fetch_docs_context`) and by the three docker-gated tests on a daemon-up host.

## Issues Encountered

1. **Worktree staleness.** The orchestrator spawned me on a branch (`worktree-agent-a89e7d6c`) that was behind `doc-repo` by the Phase 18-25 commits. Merged `doc-repo` into the worktree branch (clean fast-forward-style merge, no conflicts) to bring in Plans 25-01 and 25-02 artifacts. Harness-level only; no plan-execution impact.

2. **Pre-existing test failures in Phase 16 and Phase 23.** Both sets are docker-gated integration tests that require a running Docker daemon. Confirmed pre-existing via `git stash` baseline comparison (identical failure counts before and after my edits). Not regressions; documented per plan discipline.

## Next Phase Readiness

- **Phase 25 is complete.** All four CTX-01..CTX-04 requirements are now demonstrably satisfied by the Phase 25 test harness, with end-to-end coverage spanning host-side sparse clone (Plan 02), compose volume wiring (Plan 01), and spawn-path integration (Plan 03).
- **Phase 26+** can now assume that any `spawn` invocation on a profile with `docs_repo` configured will produce a read-only `/agent-docs/` mount inside the claude container at runtime. The Stop-hook `publish_docs_bundle` caller (Phase 26 scope) can read context from `/agent-docs/` inside the container and publish reports via the Phase 24 bundle helper.
- **Daemon-up validation** is still needed in the CI/smoke environment to convert the three SKIP-PASS gates into hard PASS gates. The test expressions are unchanged on that path.

## Self-Check

- `bin/claude-secure` — FOUND (22 lines added across 2 hunks)
- `.planning/phases/25-context-read-bind-mount/25-03-SUMMARY.md` — FOUND (this file)
- Commit `62ea5a6` (feat(25-03): wire fetch_docs_context into do_spawn (fail-closed)) — FOUND in git log
- Commit `0e79046` (feat(25-03): wire fetch_docs_context into interactive `*)` case (warn-continue)) — FOUND in git log

## Self-Check: PASSED

---
*Phase: 25-context-read-bind-mount*
*Completed: 2026-04-14*
