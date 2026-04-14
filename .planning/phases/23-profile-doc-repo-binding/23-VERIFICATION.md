---
phase: 23-profile-doc-repo-binding
verified: 2026-04-13T21:15:00Z
status: human_needed
score: 4/4 must-haves verified (17/18 tests pass; 1 deferred to human)
human_verification:
  - test: "Run a live claude-secure spawn with a profile that has DOCS_REPO_TOKEN in .env. After the container starts, exec into the claude container and run: printenv | grep -i docs_repo_token. Verify the variable is absent from container environment."
    expected: "No output from printenv grep — DOCS_REPO_TOKEN must not appear in the container environment."
    why_human: "test_docs_token_absent_from_container requires a live docker compose stack. The test is explicitly stubbed (returns 1) and deferred to Phase 24 which tests against a real container stack. Programmatic verification would require docker compose up which the sandbox cannot do."
---

# Phase 23: Profile Doc-Repo Binding Verification Report

**Phase Goal:** Profile <-> Doc Repo Binding — every claude-secure profile can declare a doc-repo binding (BIND-01), host-only token projection keeps DOCS_REPO_TOKEN out of containers (BIND-02), legacy report_repo aliases resolve without breakage (BIND-03), and `profile init-docs` clones + initializes the bound repo (DOCS-01).
**Verified:** 2026-04-13T21:15:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|---------|
| 1 | A profile with docs_repo/docs_branch/docs_project_dir/docs_mode + DOCS_REPO_TOKEN validates and exports DOCS_REPO/DOCS_BRANCH/DOCS_PROJECT_DIR/DOCS_MODE/DOCS_REPO_TOKEN into host shell | VERIFIED | `validate_docs_binding` (line 121), `resolve_docs_alias` (line 232), `load_profile_config` calls both; `test_valid_docs_binding` and `test_docs_vars_exported` PASS |
| 2 | A profile with malformed docs_repo fails validate_profile with non-zero exit and actionable stderr | VERIFIED | `validate_docs_binding` checks `^https://[^[:space:]]+\.git$`; `test_docs_repo_url_validation` PASS |
| 3 | SECRETS_FILE path passed to docker-compose env_file does NOT contain DOCS_REPO_TOKEN or REPORT_REPO_TOKEN lines | VERIFIED (programmatic) / HUMAN NEEDED (container layer) | `project_env_for_containers` (line 175) uses `LC_ALL=C grep -Ev` with anchored ERE; `test_projected_env_omits_docs_token` and `test_projected_env_omits_legacy_token` PASS; live container verification deferred |
| 4 | Legacy report_repo / REPORT_REPO_TOKEN profiles load without errors, DOCS_REPO is populated, deprecation warning fires exactly once | VERIFIED | `resolve_docs_alias` back-fills DOCS_REPO from report_repo; `emit_deprecation_warning` uses per-profile sentinel in $TMPDIR; `test_legacy_report_repo_alias`, `test_legacy_report_token_alias`, `test_deprecation_warning_rate_limit` all PASS |
| 5 | `profile init-docs` creates 6-file layout in one atomic commit, is idempotent, fails closed without docs_repo, scrubs PAT from error output | VERIFIED | `do_profile_init_docs` (line 1348) implements all behaviors; `test_init_docs_creates_layout`, `test_init_docs_single_commit`, `test_init_docs_idempotent`, `test_init_docs_requires_docs_repo`, `test_init_docs_pat_scrub_on_error` all PASS |

**Score:** 5/5 truths verified (one truth has a deferred container-layer component requiring human check)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `bin/claude-secure` | validate_docs_binding function | VERIFIED | Line 121, 1 definition, called from validate_profile line 112 |
| `bin/claude-secure` | project_env_for_containers function | VERIFIED | Line 175, _HOST_ONLY_VARS=("DOCS_REPO_TOKEN" "REPORT_REPO_TOKEN"), called from load_profile_config line 430 |
| `bin/claude-secure` | emit_deprecation_warning function | VERIFIED | Line 207, sentinel at ${TMPDIR}/cs-deprecation-warned-${profile}, rate-limited, tty-aware |
| `bin/claude-secure` | resolve_docs_alias function | VERIFIED | Line 232, exports DOCS_REPO/BRANCH/PROJECT_DIR/MODE/REPO_TOKEN + back-fills REPORT_REPO/BRANCH/REPORT_REPO_TOKEN, called from load_profile_config line 449 |
| `bin/claude-secure` | do_profile_init_docs function | VERIFIED | Line 1348, 6-file layout, idempotency gate via git diff --cached --quiet, PAT scrub on clone and commit error paths |
| `bin/claude-secure` | profile) dispatch case | VERIFIED | Line 2304, routes init-docs to do_profile_init_docs |
| `tests/test-phase23.sh` | 18-test harness | VERIFIED | 17/18 PASS; 1 FAIL (test_docs_token_absent_from_container — explicit deferral) |
| `tests/fixtures/profile-23-docs/` | New-schema fixture (docs_repo, DOCS_REPO_TOKEN) | VERIFIED | profile.json, .env (DOCS_REPO_TOKEN present, fake token), whitelist.json all present |
| `tests/fixtures/profile-23-legacy/` | Legacy-schema fixture (report_repo, REPORT_REPO_TOKEN) | VERIFIED | profile.json, .env (REPORT_REPO_TOKEN present, no DOCS_REPO_TOKEN), whitelist.json all present |
| `tests/test-map.json` | Phase 23 test suite registered | VERIFIED | test-phase23.sh string found, valid JSON |
| `README.md` | docs_repo, DOCS_REPO_TOKEN, legacy, profile init-docs docs | VERIFIED | Lines 236-283: Doc Repo Binding section, DOCS_REPO_TOKEN host-only note, Legacy Field Names, profile init-docs subcommand |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| validate_profile | validate_docs_binding | `if ! validate_docs_binding "$name"` at line 112 | WIRED | grep count=1 |
| load_profile_config | project_env_for_containers | `SECRETS_FILE=$(project_env_for_containers "$pdir/.env")` at line 430 | WIRED | grep count=1 |
| load_profile_config | resolve_docs_alias | `resolve_docs_alias "$name"` at line 449 | WIRED | grep count=1 |
| profile) dispatch | do_profile_init_docs | `do_profile_init_docs "$PROFILE"` at line 2314 | WIRED | grep count=1 |
| do_profile_init_docs | push_with_retry | `push_with_retry "$clone_dir" "$DOCS_BRANCH"` at line 1473 | WIRED | push_with_retry appears 8 times total; called directly from do_profile_init_docs |
| docker-compose env_file | SECRETS_FILE | `${SECRETS_FILE:-/dev/null}` at lines 13 and 45 | WIRED | Both claude and proxy services reference SECRETS_FILE |

### Data-Flow Trace (Level 4)

Not applicable — this phase implements bash functions and CLI tooling, not components rendering dynamic data from a data store. The data flow is: profile.json fields -> resolve_docs_alias -> DOCS_* env vars -> do_profile_init_docs -> git clone/commit/push. This is verified end-to-end by the test suite.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| test suite passes 17/18 | `bash tests/test-phase23.sh` | 17 passed, 1 failed, 18 total | PASS |
| bin/claude-secure syntax valid | `bash -n bin/claude-secure` | exits 0 | PASS |
| Phase 12 regression | `bash tests/test-phase12.sh` | 19/19 pass | PASS |
| Phase 16 regression | `bash tests/test-phase16.sh` | 33/33 pass | PASS |
| validate_docs_binding wired | `grep -c 'validate_docs_binding "\$name"' bin/claude-secure` | 1 | PASS |
| project_env_for_containers wired | `grep -c 'SECRETS_FILE=\$(project_env_for_containers' bin/claude-secure` | 1 | PASS |
| resolve_docs_alias wired | `grep -c 'resolve_docs_alias "\$name"' bin/claude-secure` | 1 | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| BIND-01 | 23-02-PLAN | User can configure docs_repo, docs_branch, docs_project_dir, DOCS_REPO_TOKEN per profile | SATISFIED | validate_docs_binding + resolve_docs_alias implemented; 4 BIND-01 tests PASS |
| BIND-02 | 23-02-PLAN | DOCS_REPO_TOKEN never mounted into Claude container | SATISFIED (programmatic) / HUMAN NEEDED (container) | project_env_for_containers filters token from SECRETS_FILE; test_projected_env_omits_docs_token PASS; live container check deferred |
| BIND-03 | 23-02-PLAN | Legacy report_repo/REPORT_REPO_TOKEN profiles continue working | SATISFIED | resolve_docs_alias back-fills from legacy fields; back-fills REPORT_REPO/REPORT_REPO_TOKEN for Phase 16; 3 BIND-03 tests PASS; Phase 16 33/33 pass |
| DOCS-01 | 23-03-PLAN | profile init-docs creates projects/<slug>/todo.md + architecture.md + vision.md + ideas.md + specs/ | SATISFIED | do_profile_init_docs creates all 6 files; 5 DOCS-01 tests PASS |

**Note:** `REQUIREMENTS.md` tracking table shows BIND-01, BIND-02, BIND-03 as "Pending" while DOCS-01 shows "Complete". This is a tracking document discrepancy — the implementations are fully present and tested. The REQUIREMENTS.md should be updated to mark BIND-01/02/03 as "Complete".

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| tests/test-phase23.sh | test_docs_token_absent_from_container | `return 1` with "INTEGRATION: requires docker compose" | INFO | Explicit documented deferral; not a code stub — this is a live-container integration test that cannot run without docker compose |

No blockers, no implementation stubs found. The one failing test is an intentional integration test deferral with explicit documentation.

### Human Verification Required

#### 1. BIND-02 Container Isolation Check

**Test:** Start a session with a profile that has `DOCS_REPO_TOKEN` in `.env`. Run `docker compose exec claude printenv | grep -i token` (or equivalent). Verify `DOCS_REPO_TOKEN` and `REPORT_REPO_TOKEN` do not appear in container environment.
**Expected:** Neither `DOCS_REPO_TOKEN` nor `REPORT_REPO_TOKEN` appears in the container's environment. `CLAUDE_CODE_OAUTH_TOKEN` and `GITHUB_TOKEN` should still be present.
**Why human:** Requires a live `docker compose` stack with a real profile. The sandbox environment does not have Docker available. The programmatic verification (projected .env file content) is complete, but the end-to-end container isolation can only be confirmed by running the actual stack.

### Gaps Summary

No gaps. All four requirements have verified implementations:

- **BIND-01:** `validate_docs_binding` correctly validates the 4 profile fields with opt-out semantics, fail-closed on malformed HTTPS URL, and back-compat with no-docs-fields profiles.
- **BIND-02:** `project_env_for_containers` filters `DOCS_REPO_TOKEN` and `REPORT_REPO_TOKEN` from the file passed to docker-compose `env_file`. Verified programmatically; live container verification deferred.
- **BIND-03:** `resolve_docs_alias` populates `DOCS_REPO`/`DOCS_REPO_TOKEN` from legacy `report_repo`/`REPORT_REPO_TOKEN` with back-fill in reverse direction for Phase 16 compatibility. `emit_deprecation_warning` fires exactly once per profile per shell session. Phase 16 regression 33/33 green.
- **DOCS-01:** `do_profile_init_docs` bootstraps the 6-file layout in one atomic commit, is idempotent on second run, fails closed without docs_repo, and scrubs the PAT from all error output.

The sole failing test (`test_docs_token_absent_from_container`) is an intentional live-docker integration test explicitly deferred to Phase 24.

---

_Verified: 2026-04-13T21:15:00Z_
_Verifier: Claude (gsd-verifier)_
