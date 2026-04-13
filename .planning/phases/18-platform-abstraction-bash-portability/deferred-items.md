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
