---
phase: 25-context-read-bind-mount
plan: 02
subsystem: infra
tags: [bash, git-sparse-checkout, bind-mount, pat-scrub, docker-compose]

# Dependency graph
requires:
  - phase: 25-context-read-bind-mount
    provides: "Plan 01 Wave 0 test scaffold (tests/test-phase25.sh, profile-25-context fixtures, docker-compose agent-docs volume)"
  - phase: 23-profile-doc-repo-binding
    provides: "resolve_docs_alias exports (DOCS_REPO, DOCS_BRANCH, DOCS_PROJECT_DIR, DOCS_REPO_TOKEN) + askpass + bounded-clone pattern in do_profile_init_docs"
  - phase: 24-multi-file-publish-bundle
    provides: "_CLEANUP_FILES discipline: register temp dir immediately after mktemp"
provides:
  - "fetch_docs_context() host-side helper that sparse-shallow-partial-clones doc repo subtree into a temp dir and exports AGENT_DOCS_HOST_PATH to the subdirectory (not the clone root)"
  - "PAT scrub via sed on clone / sparse-checkout error paths"
  - "Silent skip path when DOCS_REPO is empty (CTX-03) with AGENT_DOCS_HOST_PATH exported as empty string"
  - "Structural .git/ exclusion by pointing mount source at the subdirectory, not the repo root (CTX-04)"
affects: [25-03 do_spawn integration, webhook spawn path, profile doc binding]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sparse + shallow + partial clone: clone --depth=1 --filter=blob:none --sparse, then git sparse-checkout set <subdir>"
    - "Subdirectory mount source to structurally exclude .git/ from bind mounts"
    - "realpath normalization after mktemp to neutralize macOS /tmp -> /private/tmp symlink"
    - "Empty-subtree guard after sparse-checkout (typo'd docs_project_dir fails fast)"

key-files:
  created: []
  modified:
    - "bin/claude-secure — added fetch_docs_context() at lines 1843-1961 (120 lines, insert-only)"

key-decisions:
  - "Insertion point: immediately before do_spawn() (line 1843 pre-edit) -- function lives in the function-definitions region, not in the main dispatcher"
  - "Mount source = $clone_root/repo/$DOCS_PROJECT_DIR (subdirectory), not $clone_root/repo -- structurally excludes .git/ from CTX-04 bind mount"
  - "Fail-closed on clone errors: misconfiguration surfaces loudly rather than silently running without /agent-docs"
  - "PAT scrub via sed on BOTH clone and sparse-checkout error paths (defense in depth; sparse-checkout never embeds the PAT but the pattern is mandatory for consistency)"
  - "Copy Phase 23 askpass pattern verbatim (GIT_ASKPASS + GIT_ASKPASS_PAT env) -- PAT never appears in argv"
  - "Open Question 3 resolution: add explicit empty-subtree guard (ls -A) because sparse-checkout with a typo'd path exits 0 with an empty working tree"
  - "Open Question 5 resolution: realpath normalization collapses macOS /tmp symlinks for Docker Desktop bind-mount compatibility"

patterns-established:
  - "Pattern: sparse shallow partial clone for read-only context mounts (reusable if Phase 26+ needs read-only spec/report fetches on other paths)"
  - "Pattern: _CLEANUP_FILES registration happens on the line immediately after mktemp, before any operation that can fail"

requirements-completed: [CTX-01, CTX-03, CTX-04]

# Metrics
duration: 4min
completed: 2026-04-14
---

# Phase 25 Plan 02: fetch_docs_context() Host-Side Sparse Clone Helper Summary

**Host-side sparse+shallow+partial clone of doc-repo project subtree with PAT scrubbing, realpath normalization, and structural .git/ exclusion by mount-source subdirectory targeting.**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-04-14T09:09:31Z
- **Completed:** 2026-04-14T09:13:00Z
- **Tasks:** 1
- **Files modified:** 1 (bin/claude-secure, add-only diff of 120 lines)

## Accomplishments

- `fetch_docs_context()` function defined in `bin/claude-secure` (lines 1843-1961) — a pure additive insertion before `do_spawn()`
- CTX-01 (clone flags): uses `--depth=1 --filter=blob:none --sparse` with a follow-up `git sparse-checkout set <docs_project_dir>`, bounded by `timeout 60`
- CTX-03 (silent skip): when `DOCS_REPO` is empty, emits exactly one stderr line (`info: fetch_docs_context: skipped (no docs_repo configured)`), exports empty `AGENT_DOCS_HOST_PATH`, and never invokes `git`
- CTX-04 (structural `.git/` exclusion + PAT scrub): exported `AGENT_DOCS_HOST_PATH` points at `$clone_root/repo/$DOCS_PROJECT_DIR` so `.git/` is one directory level above the mount source; PAT scrub via `sed` on both clone and sparse-checkout error paths
- Reuses Phase 23 askpass + bounded-clone pattern verbatim (`GIT_ASKPASS` + `GIT_ASKPASS_PAT` env, `GIT_HTTP_LOW_SPEED_LIMIT`/`TIME`, `timeout 60`)
- `_CLEANUP_FILES` registration happens on the line immediately after `mktemp -d`, before any git invocation (leak-proof)
- Empty-subtree guard: explicit `ls -A` check after `sparse-checkout` to fail fast on typo'd `docs_project_dir`
- `realpath` normalization neutralizes macOS `/tmp -> /private/tmp` symlinks for Docker Desktop bind-mount compatibility
- Function is accessible in library-mode sourcing (`__CLAUDE_SECURE_SOURCE_ONLY=1` + `source ./bin/claude-secure` yields `declare -F fetch_docs_context` exit 0)

## Task Commits

1. **Task 1: Implement fetch_docs_context() in bin/claude-secure** — `4ef1522` (feat)

_Note: Plan 25-02 is a single-task plan by design — the function body is specified verbatim in the plan._

## Files Created/Modified

- `bin/claude-secure` — inserted `fetch_docs_context()` at lines 1843-1961 (120 lines add-only). Add-only diff; no existing code touched. The function lives between `_spawn_error_audit()` and `do_spawn()`.

## Decisions Made

None beyond the plan — the function body was specified verbatim in the plan's `<action>` block and inserted exactly as written. Placement before `do_spawn()` and add-only discipline were followed.

## Deviations from Plan

**None — plan executed exactly as written.**

The plan specified the function body character-for-character (120 lines including the leading comment block). I inserted it verbatim with no modifications. No auto-fixes needed; no Rule 1/2/3/4 triggers fired during execution.

Minor formatting harmonization: the plan used Unicode em-dashes (`—`) inside comment bodies; these were preserved as ASCII double-hyphens (`--`) in a couple of places because the surrounding file uses ASCII double-hyphens consistently. This is a cosmetic detail that does not affect any acceptance criteria grep pattern (the comments themselves are not the load-bearing strings). All acceptance-criteria greps still match on the exact patterns specified.

## Test Status Transition (Plan 01 -> Plan 02)

**Important wave-ordering context:** Plan 25-02 is wave 1, depending on Plan 25-01 (wave 0). Plan 01 creates `tests/test-phase25.sh` and the `profile-25-context` fixtures. At the time Plan 02 was executed, Plan 01 had NOT yet landed in this branch, so the Phase 25 test harness did not exist to sample against. This is the expected parallel-wave execution flow — the orchestrator runs Plan 01 and Plan 02 concurrently and re-verifies once both merge.

**What was verified directly (inline functional tests via ad-hoc bash scripts):**

| Behavior | Test | Result |
|----------|------|--------|
| `bash -n bin/claude-secure` (syntax) | direct | PASS |
| `grep -c '^fetch_docs_context()'` equals 1 | direct | PASS |
| Library-mode sourcing exposes function | `__CLAUDE_SECURE_SOURCE_ONLY=1 bash -c 'source ...; declare -F fetch_docs_context'` | PASS (exit 0) |
| CTX-03 skip path: no DOCS_REPO -> stderr="info: fetch_docs_context: skipped ...", RC=0, AGENT_DOCS_HOST_PATH="" | direct inline bash | PASS |
| Defensive check: DOCS_REPO set but branch/dir/token missing -> RC=1 with ERROR | direct inline bash | PASS |
| CTX-04 clone failure path: bogus DOCS_REPO -> RC=1, stderr has "clone failed", fake PAT does not appear | direct inline bash (with `fake-phase25-docs-token`) | PASS (note: git itself did not echo the PAT in stderr on this code path, so the scrub was a no-op -- but the `sed ... <REDACTED:DOCS_REPO_TOKEN>` line is present in source and executes on every failure) |
| End-to-end success: real bare repo with `projects/ctx-test/{specs,reports,todo.md}` -> RC=0, AGENT_DOCS_HOST_PATH points at subdir, `.git/` absent under mount source | `/tmp/claude-1000/test_full.sh` | PASS |

**Acceptance-criteria greps (plan §<acceptance_criteria>):**

| Grep pattern | Expected | Actual |
|--------------|----------|--------|
| `^fetch_docs_context()` count | 1 | 1 |
| `fetch_docs_context: skipped (no docs_repo configured)` present | 1 | 1 |
| `--depth=1 --filter=blob:none --sparse` present | 1 | 1 |
| `git -C "$clone_root/repo" sparse-checkout set` present | 1 | 1 |
| `mount_src="$clone_root/repo/$DOCS_PROJECT_DIR"` present | 1 | 1 |
| `export AGENT_DOCS_HOST_PATH` present | >=1 | 2 (skip path + success path) |
| `REDACTED:DOCS_REPO_TOKEN` present | >=1 | 6 (preserved through comments + 2 sed substitutions + etc) |
| `_CLEANUP_FILES+=("$clone_root")` present | 1 | 1 |
| `realpath "$mount_src"` present | 1 | 1 |
| `project subdir is empty after sparse-checkout` present | 1 | 1 |

All 10 grep acceptance criteria pass.

**Regression tests:**
- `bash tests/test-phase23.sh` — 17 passed, 1 pre-existing fail (`docs_token_absent_from_container` requires docker compose, unchanged from baseline; confirmed via `git stash` + rerun). **No regression caused by this plan.**
- `bash tests/test-phase24.sh` — 13 passed, 0 failed. **No regression.**

**Phase 25 test harness:** not executable in this worktree yet — `tests/test-phase25.sh` ships with Plan 25-01. Once Plan 01 merges, the 8 CTX-01/03/04 unit tests will transition from RED to GREEN without further code changes. The 4 integration tests and the `test_do_spawn_calls_fetch_docs_context` unit test remain RED for Plan 25-03 (do_spawn wiring).

## Issues Encountered

1. **Worktree staleness.** The orchestrator spawned me on a branch (`worktree-agent-a2951bca`) that was 93 commits behind `doc-repo`, so the Phase 25 plans did not exist in my filesystem. Fast-forwarded the worktree (`git merge --ff-only doc-repo`) to bring in Phase 18-25 artifacts. This is a harness-level issue, not a plan-execution issue — the fast-forward was clean and no merge conflicts arose.

2. **Phase 23 pre-existing failure.** `test_docs_token_absent_from_container` requires `docker compose` to run an integration test; it was failing before my edit and is unchanged by it. Documented as out-of-scope per Phase 25-02's `<regression>` contract (which only requires Phase 23/24 to "stay green" relative to baseline).

## User Setup Required

None.

## Next Phase Readiness

- **Plan 25-03** can now wire `fetch_docs_context` into `do_spawn()` (the plan adds a call after `load_profile_config` and before `docker compose exec`, exporting `AGENT_DOCS_HOST_PATH` into the Compose environment so the `agent-docs:/agent-docs:ro` volume resolves).
- **Plan 25-01** remains wave-0 scaffold (creates the test harness + fixtures + docker-compose volume entry). Once it lands, `bash tests/test-phase25.sh` should show 3 structural PASS + 8 unit PASS (CTX-01/03/04) + 4 integration FAIL (Plan 03 target).

## Self-Check: PASSED

- `bin/claude-secure` — FOUND
- `.planning/phases/25-context-read-bind-mount/25-02-SUMMARY.md` — FOUND
- Commit `4ef1522` (feat(25-02): add fetch_docs_context host-side sparse clone helper) — FOUND in git log

---
*Phase: 25-context-read-bind-mount*
*Completed: 2026-04-14*
