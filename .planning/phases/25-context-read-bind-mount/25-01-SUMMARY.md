---
phase: 25-context-read-bind-mount
plan: 01
subsystem: test-harness
tags: [wave-0, nyquist, test-scaffold, bind-mount, docs-repo]
dependency_graph:
  requires:
    - Phase 23 (DOCS_REPO/DOCS_BRANCH/DOCS_PROJECT_DIR/DOCS_REPO_TOKEN resolution)
    - Phase 24 (bundle publish infra — unchanged, parallel reference point)
  provides:
    - tests/test-phase25.sh (15 named RED/GREEN tests for CTX-01..04)
    - tests/fixtures/profile-25-docs/ (profile.json, .env, whitelist.json)
    - docker-compose.yml claude.volumes entry for /agent-docs:ro
    - tests/test-map.json CTX-01..04 entries + path mappings
  affects:
    - Plan 25-02 (will implement fetch_docs_context, flip unit tests GREEN)
    - Plan 25-03 (will wire do_spawn call + integration tests GREEN under docker)
tech_stack:
  added: []
  patterns:
    - Wave 0 Nyquist scaffold mirrors Phase 23/24 harness style
    - Docker-gated skip-as-PASS prelude (`command -v docker && docker info`)
    - file:// bare-repo seeding via create_seeded_bare_repo helper
    - `__CLAUDE_SECURE_SOURCE_ONLY=1` library-mode sourcing for unit tests
key_files:
  created:
    - tests/test-phase25.sh
    - tests/fixtures/profile-25-docs/profile.json
    - tests/fixtures/profile-25-docs/.env
    - tests/fixtures/profile-25-docs/whitelist.json
  modified:
    - tests/test-map.json
    - docker-compose.yml
    - .planning/phases/25-context-read-bind-mount/25-VALIDATION.md
decisions:
  - Integration tests gated by `command -v docker && docker info`; on no-docker hosts they SKIP-as-PASS (never fail the suite)
  - Compose volume entry uses `${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro` so the compose file parses even when Plan 02 hasn't exported the var yet
  - Fake PAT uses literal `fake-phase25-docs-token` (no `ghp_` prefix) per Phase 17 Pitfall 13 — avoids installer secret-detection false positives
  - Added a `_spawn_ctx_background` helper with `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT=/dev/null` escape hatch so Plan 03 integration tests don't require real Anthropic credentials
metrics:
  duration: ~5min
  completed: 2026-04-14
---

# Phase 25 Plan 01: Wave 0 Test Harness Summary

Installed a 15-function test harness + fixtures + compose volume entry so Plans 02 and 03 execute with automated feedback (Nyquist compliance flipped to `true`).

## Test Function Status

| # | Test Function | CTX | Wave 0 Status | Flips GREEN In |
|---|---------------|-----|---------------|----------------|
| 1 | `test_fixtures_exist` | — | PASS (structural) | — |
| 2 | `test_compose_volume_entry` | CTX-01 | PASS (structural) | — |
| 3 | `test_test_map_registered` | — | PASS (structural) | — |
| 4 | `test_fetch_docs_context_function_exists` | CTX-01 | FAIL (RED) | Plan 02 |
| 5 | `test_fetch_docs_context_clone_flags` | CTX-01 | FAIL (RED) | Plan 02 |
| 6 | `test_fetch_docs_context_exports_path` | CTX-01 | FAIL (RED) | Plan 02 |
| 7 | `test_fetch_docs_context_skips_silently_when_no_docs_repo` | CTX-03 | FAIL (RED) | Plan 02 |
| 8 | `test_fetch_docs_context_emits_one_info_line_on_skip` | CTX-03 | FAIL (RED) | Plan 02 |
| 9 | `test_spawn_no_docs_does_not_invoke_git` | CTX-03 | FAIL (RED) | Plan 02 |
| 10 | `test_fetch_docs_context_mount_source_excludes_git` | CTX-04 | FAIL (RED) | Plan 02 |
| 11 | `test_fetch_docs_context_pat_scrub_on_clone_error` | CTX-04 | FAIL (RED) | Plan 02 |
| 12 | `test_agent_docs_read_works` | CTX-02 | SKIP-as-PASS (no docker on host) | Plan 03 |
| 13 | `test_agent_docs_write_attempt_fails_readonly` | CTX-02 | SKIP-as-PASS (no docker on host) | Plan 03 |
| 14 | `test_agent_docs_no_git_dir_in_container` | CTX-04 | SKIP-as-PASS (no docker on host) | Plan 03 |
| 15 | `test_do_spawn_calls_fetch_docs_context` | CTX-01 | FAIL (RED) | Plan 03 |

**Wave 0 summary:** `6 passed, 9 failed, 15 total` (exit code 1 — expected).
- 3 structural tests: PASS
- 3 docker-gated tests: SKIP-as-PASS (counted as PASS)
- 9 implementation tests: FAIL with clear NOT IMPLEMENTED errors until Plans 02/03 land

## Compose Volume Line Added

```yaml
      # Phase 25 CTX-01..CTX-04: read-only bind mount of the doc repo's
      # projects/<slug>/ subtree. fetch_docs_context (Plan 02) exports
      # AGENT_DOCS_HOST_PATH before `docker compose up`. Falls back to
      # /dev/null when no docs_repo is configured (CTX-03 silent skip).
      - ${AGENT_DOCS_HOST_PATH:-/dev/null}:/agent-docs:ro
```

Added to `claude.volumes` block, immediately after the existing `${LOG_DIR:-./logs}` entry. Additive only — no existing volume/service/env lines touched.

## Fixture Contents (for Plan 02 reference)

`tests/fixtures/profile-25-docs/profile.json`:
```json
{
  "workspace": "/tmp/claude-secure-test-ws-25-ctx",
  "repo": "owner/ctx-test",
  "docs_repo": "https://github.com/owner/ctx-test.git",
  "docs_branch": "main",
  "docs_project_dir": "projects/ctx-test",
  "docs_mode": "report_only"
}
```

`tests/fixtures/profile-25-docs/.env`:
```
CLAUDE_CODE_OAUTH_TOKEN=fake-phase25-oauth
DOCS_REPO_TOKEN=fake-phase25-docs-token
GITHUB_TOKEN=fake-phase25-github
```

**Fake PAT for Plan 02 reference:** `fake-phase25-docs-token` — tests assert this literal string is scrubbed from stderr on clone failure. Deliberately does NOT start with `ghp_` per Phase 17 Pitfall 13 (install.sh secret-detection heuristics).

`tests/fixtures/profile-25-docs/whitelist.json` is copied verbatim from `profile-23-docs/whitelist.json`.

## Test-Map Registration

Added to `tests/test-map.json`:
- `bin/claude-secure` path mapping: appended `test-phase25.sh` to tests array
- `docker-compose.yml` path mapping: appended `test-phase25.sh` to tests array
- New `tests/fixtures/profile-25-docs/**` → `test-phase25.sh` mapping block
- New `CTX-01`, `CTX-02`, `CTX-03`, `CTX-04` requirement entries mirroring the `BIND-01` shape (phase=25, test_file=tests/test-phase25.sh, tests=[...])

## Phase 23/24 Regression

- **Phase 23:** `17 passed, 1 failed, 18 total` — **unchanged from HEAD before Plan 25-01**. The one failing test (`test_docs_token_absent_from_container`) is a pre-existing stub that always returns 1 with a `INTEGRATION: requires docker compose; Plan 02 implements` message. Verified by `git stash && bash tests/test-phase23.sh` on parent commit. Not caused by Phase 25 changes.
- **Phase 24:** `13 passed, 0 failed, 13 total` — fully green.
- **docker compose config --quiet:** exits 0 with no errors (the unset `AGENT_DOCS_HOST_PATH` substitutes to `/dev/null`, a valid path Docker accepts).

## VALIDATION.md Frontmatter

- `nyquist_compliant: false` → `true`
- `wave_0_complete: false` → `true`
- `Wave 0 Requirements` checklist: both items checked
- `Validation Sign-Off` checklist: all six items checked
- `Approval:` line flipped from `pending` to `Wave 0 scaffold complete 2026-04-14`
- `Per-Task Verification Map` row for `25-01-01` flipped to `✅ green`; `25-02-01` and `25-03-01` remain `⬜ pending` for Plans 02/03.

## Deviations from Plan

None — plan executed exactly as written. The two tasks matched the plan's `<action>` blocks verbatim (fixture creation + test-map wiring + compose volume in Task 1; 15-function harness + VALIDATION.md updates in Task 2). No auto-fixes, no architectural decisions, no auth gates.

## Handoff Notes for Plan 25-02

- All CTX-01/CTX-03/CTX-04 unit tests are wired and RED. Plan 02's `fetch_docs_context()` implementation must:
  1. Be defined in `bin/claude-secure` (so `declare -F fetch_docs_context` passes post-source)
  2. Use `--depth=1 --filter=blob:none --sparse` + `git sparse-checkout set` (test 5 greps the function body for these literal flags)
  3. Export `AGENT_DOCS_HOST_PATH` pointing at a directory containing `todo.md`/`architecture.md`/`vision.md`/`ideas.md` (tests 6, 10)
  4. When `DOCS_REPO` is unset/empty: `return 0` silently, emit exactly one `fetch_docs_context: skipped` line to stderr, and NEVER invoke `git` (tests 7, 8, 9)
  5. On clone error: scrub `${DOCS_REPO_TOKEN}` from stderr (replace with `<REDACTED:DOCS_REPO_TOKEN>`) or at least never let the literal token appear (test 11)
  6. Mount source must contain NO `.git` directory at any depth — copy or sparse-checkout into a clean dir, not the raw clone (test 10)
- Unit tests use `file://` bare repos (Pitfall 3: file:// silently ignores `--depth`/`--filter`). Real partial-clone behavior only tested under a real HTTPS remote in manual QA.

## Handoff Notes for Plan 25-03

- `test_do_spawn_calls_fetch_docs_context` greps `declare -f do_spawn | grep fetch_docs_context` — Plan 03 must insert the call somewhere in the `do_spawn` body.
- Docker integration tests use a `_spawn_ctx_background` helper that background-spawns via `bin/claude-secure --profile ctx-* spawn --event '{...}' &`, then runs `docker compose -p $(spawn_project_name ...) exec -T claude ...`. Uses `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT=/dev/null` + `CLAUDE_SECURE_FAKE_CLAUDE_EXIT=0` to avoid needing real Anthropic creds.
- `_kill_spawn` cleanup: `kill $SPAWN_PID`, `wait`, `docker compose -p ... down --remove-orphans`.

## Self-Check: PASSED

File existence:
- FOUND: tests/test-phase25.sh
- FOUND: tests/fixtures/profile-25-docs/profile.json
- FOUND: tests/fixtures/profile-25-docs/.env
- FOUND: tests/fixtures/profile-25-docs/whitelist.json

Commit existence:
- FOUND: 53fb0b0 (Task 1: fixtures + test-map + compose volume)
- FOUND: 87fd2b7 (Task 2: test-phase25.sh harness + VALIDATION.md)
