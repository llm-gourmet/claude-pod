---
phase: 17
slug: operational-hardening
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-12
updated: "2026-04-14"
---

# Phase 17 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `17-RESEARCH.md` §Validation Architecture (fully elaborated there).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration test harness (same style as `tests/test-phase14.sh` / `15.sh` / `16.sh`) |
| **Config file** | None — inline harness in `tests/test-phase17.sh` (unit) and `tests/test-phase17-e2e.sh` (E2E) |
| **Quick run command** | `bash tests/test-phase17.sh` |
| **Full suite command** | `bash tests/test-phase17.sh && bash tests/test-phase17-e2e.sh` |
| **Estimated runtime** | ~10s unit + ≤90s E2E |

---

## Sampling Rate

- **After every task commit:** `bash tests/test-phase17.sh` (unit suite ~10s, all docker/find/flock mocked)
- **After every plan wave:** Phase 13/14/15/16/17 unit suites + E2E if Wave 1b artifacts present
- **Before `/gsd:verify-work`:** Full unit + E2E green; wall-clock <120s combined
- **Max feedback latency:** ~45s (cross-phase regression for unit)

---

## Per-Task Verification Map

Full mapping lives in `17-RESEARCH.md` §Validation Architecture (~36 named tests). Summary here; consult research for exact command strings.

### Reaper Core (D-01..D-10)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| test_reap_subcommand_exists | static | 17-02 | 1a | ❌ W0 |
| test_reaper_unit_files_exist | static | 17-02 | 1a | ❌ W0 |
| test_reaper_unit_files_lint | static (`systemd-analyze verify`) | 17-02 | 1a | ❌ W0 |
| test_reaper_service_directives | static (grep) | 17-02 | 1a | ❌ W0 |
| test_reaper_timer_directives | static (grep) | 17-02 | 1a | ❌ W0 |
| test_reaper_install_sections | static (grep) | 17-02 | 1a | ❌ W0 |
| test_reap_age_threshold_select | unit (mocked docker) | 17-02 | 1a | ❌ W0 |
| test_reap_age_threshold_skip | unit | 17-02 | 1a | ❌ W0 |
| test_reap_compose_down_invocation | unit (mocked) | 17-02 | 1a | ❌ W0 |
| test_reap_never_touches_images | static grep | 17-02 | 1a | ❌ W0 |
| test_reap_stale_event_files_deleted | integration | 17-02 | 1a | ❌ W0 |
| test_reap_fresh_event_files_preserved | integration | 17-02 | 1a | ❌ W0 |
| test_reap_event_age_secs_override | integration | 17-02 | 1a | ❌ W0 |
| test_reap_instance_prefix_scoping | unit (mocked) | 17-02 | 1a | ❌ W0 |
| test_reap_flock_single_flight | integration | 17-02 | 1a | ❌ W0 |
| test_reap_no_jsonl_output | static + integration | 17-02 | 1a | ❌ W0 |
| test_reap_log_format | integration | 17-02 | 1a | ❌ W0 |
| test_reap_per_project_failure_continues | unit (mocked) | 17-02 | 1a | ❌ W0 |
| test_reap_whole_cycle_failure_exits_nonzero | unit (mocked) | 17-02 | 1a | ❌ W0 |
| test_reap_dry_run | unit | 17-02 | 1a | ❌ W0 |
| test_reap_grep_guard | static | 17-02 | 1a | ❌ W0 |

### Hardening Directives (D-11..D-12)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| test_d11_directives_present | static grep | 17-02 | 1a | ❌ W0 |
| test_d11_forbidden_directives_absent | static grep | 17-02 | 1a | ❌ W0 |
| test_d11_comment_block_present | static grep | 17-02 | 1a | ❌ W0 |

### E2E Scenarios (D-13..D-16)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| scenario_hmac_rejection | E2E | 17-03 | 1b | ❌ W0 |
| scenario_concurrent_execution | E2E | 17-03 | 1b | ❌ W0 |
| scenario_orphan_cleanup | E2E | 17-03 | 1b | ❌ W0 |
| scenario_resource_limits | E2E | 17-03 | 1b | ❌ W0 |
| test_e2e_budget_under_90s | E2E gate | 17-03 | 1b | ❌ W0 |
| test_profile_e2e_fixture_shape | static | 17-01 | 0 | ❌ W0 |
| test_e2e_token_no_ghp_prefix | static | 17-01 | 0 | ❌ W0 |
| test_compose_has_mem_limit | static grep | 17-02 | 1a | ❌ W0 |

### Installer (D-17..D-18)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| test_installer_step_5d_present | static grep | 17-04 | 2 | ❌ W0 |
| test_installer_enables_timer | static grep | 17-04 | 2 | ❌ W0 |
| test_installer_post_install_hint | static grep | 17-04 | 2 | ❌ W0 |

### Regression

| Test | Command | File Exists |
|------|---------|-------------|
| Phase 13 regression | `bash tests/test-phase13.sh` | ✅ |
| Phase 14 regression | `bash tests/test-phase14.sh` | ✅ |
| Phase 15 regression | `bash tests/test-phase15.sh` | ✅ |
| Phase 16 regression | `bash tests/test-phase16.sh` | ✅ |

*Status legend: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

All Wave 0 artifacts create failing tests that later waves flip green (Nyquist self-healing).

- [ ] `tests/test-phase17.sh` — unit harness, ~24 named test functions, mocked docker/flock/find
- [ ] `tests/test-phase17-e2e.sh` — E2E four-scenario harness with 90s wall-clock guard
- [ ] `tests/fixtures/profile-e2e/profile.json` — `repo: "e2e/test"`, `webhook_secret: "e2e-test-secret"`, runtime-injected `report_repo` for bare-repo file:// URL
- [ ] `tests/fixtures/profile-e2e/.env` — `REPORT_REPO_TOKEN=fake-e2e-token` (NO `ghp_` prefix per Pitfall 13)
- [ ] `tests/fixtures/profile-e2e/prompts/issues-opened.md` — minimal `{{ISSUE_TITLE}}` template
- [ ] `tests/fixtures/profile-e2e/report-templates/issues-opened.md` — minimal `{{RESULT_TEXT}}` template
- [ ] `tests/fixtures/mock-docker-ps-fixture.txt` — fixture for unit-test docker ps mock (Pattern B / Pitfall 4)
- [ ] `webhook/claude-secure-reaper.service` — placeholder, populated in Wave 1a
- [ ] `webhook/claude-secure-reaper.timer` — placeholder, populated in Wave 1a
- [ ] `tests/test-map.json` — append Phase 17 mappings

*(Framework install: none — bash, jq, docker, systemd-analyze, flock, find, date already present and verified on host.)*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real systemd timer fires every 5 min on a live host | OPS-03 | Requires multi-cycle wall-clock observation against real systemd | After install, run `systemctl status claude-secure-reaper.timer` and `journalctl -u claude-secure-reaper -f` for ≥10 minutes; verify two cycle-start lines |
| Real GitHub PAT push under reaper-hardened listener | OPS-01 / D-12 | Validates D-11 hardening doesn't break the listener under real network | After install, send a real GitHub webhook to the listener with hardening enabled, verify successful push |

*All other Phase 17 behaviors have automated verification via mocked docker (unit) or local docker daemon + bare repo (E2E).*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (fixtures, mock data, harnesses, unit file placeholders)
- [ ] No watch-mode flags
- [ ] Feedback latency < 45s (Phase 17 unit alone ~10s)
- [ ] `nyquist_compliant: true` set in frontmatter (after Wave 0 lands)

**Approval:** pending
