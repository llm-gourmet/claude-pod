# Deferred Items — Phase 18 Platform Abstraction

Out-of-scope issues discovered during plan execution but not fixed because
they are unrelated to the current plan's surface area.

## From Plan 04

### tests/test-phase17.sh :: test_reap_dry_run (FAIL) — pre-existing

**Symptom:** `dry-run marker missing from output` — the test asserts that
`do_reap --dry-run` emits a line containing `[dry-run]` but the current
reap pipeline does not emit this marker. The failure is present BEFORE
Plan 04's changes (verified by `git stash` / re-run experiment).

**Scope:** Unrelated to PORT-03 (lock primitive swap). The mkdir-lock
rewrite does not touch the dry-run code path. `reap_stale_event_files`
already honors `REAPER_DRY_RUN=1` with a `[dry-run]` marker, but
`reap_orphan_projects` does not emit one in its code path, and the test
fixture uses `MOCK_DOCKER_PS_OUTPUT` that exercises the project-reap
branch — not the event-file branch.

**Owner:** Pre-existing Phase 17 issue. Should be handled in a quick-fix
or a dedicated follow-up plan. Leaving untouched to respect the
SCOPE BOUNDARY rule for parallel executors.

### Plan 05 re-investigation (2026-04-13)

Further debugging during Plan 05 execution revealed the actual root cause:
`do_reap` uses `trap ... EXIT` for lock cleanup, which fires only on shell
exit — NOT when the function returns. test-phase17.sh's `run_test` wrapper
invokes tests in the current shell (no subshell), so when
`test_reap_whole_cycle_failure_exits_nonzero` calls `do_reap`, it leaves the
lockdir + pidfile (containing the current shell PID) in place. The
subsequent `test_reap_dry_run` then hits the lock, sees its own PID still
alive, and early-returns with "another instance is running" — never
emitting the `[dry-run]` marker the test asserts. The `[dry-run]` code path
in `reap_orphan_projects` is fine; the test harness simply never reaches it.

**Fix options** (for a future follow-up plan):
1. Convert `trap EXIT` to explicit cleanup at every `return` path in do_reap.
2. Add lockdir cleanup to the end of each reaper test (test-side fix).
3. Wrap `run_test` calls for reaper tests in a subshell so EXIT traps fire.

Plan 05 does NOT touch this — Plan 05's surface area is install.sh and
tests/test-phase18.sh. The test-phase18.sh suite is green end-to-end. The
cross-suite check `run-tests.sh test-phase17.sh test-phase18.sh` continues
to fail on this pre-existing Phase 17 issue.
