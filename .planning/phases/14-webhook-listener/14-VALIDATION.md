---
phase: 14
slug: webhook-listener
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-12
updated: "2026-04-14"
---

# Phase 14 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution. Derived from `14-RESEARCH.md` Validation Architecture section.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration tests (project convention; matches `tests/test-phase13.sh`) |
| **Config file** | `tests/test-map.json` (add `webhook/` path and `tests/test-phase14.sh` entry) |
| **Quick run command** | `bash tests/test-phase14.sh` |
| **Full suite command** | `bash run-tests.sh` (runs all `tests/test-phase*.sh`) |
| **Estimated runtime** | ~45 seconds (stubbed `claude-secure`, no real Docker) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase14.sh`
- **After every plan wave:** Run `bash run-tests.sh`
- **Before `/gsd:verify-work`:** Full suite green + manual `systemctl status claude-secure-webhook` on a real systemd host
- **Max feedback latency:** ~45 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 14-XX-XX | TBD | 0 | Infra | harness | `test -x tests/test-phase14.sh` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 1 | HOOK-01 | unit | `systemd-analyze verify webhook/claude-secure-webhook.service` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 1 | HOOK-01 | integration | `bash tests/test-phase14.sh test_install_webhook` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-01 | integration (gated) | `CLAUDE_SECURE_TEST_SYSTEMD=1 bash tests/test-phase14.sh test_systemd_start` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-02 | integration | `bash tests/test-phase14.sh test_hmac_valid` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-02 | integration | `bash tests/test-phase14.sh test_hmac_invalid` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-02 | integration | `bash tests/test-phase14.sh test_hmac_missing_header` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-02 | integration | `bash tests/test-phase14.sh test_hmac_newline_sensitivity` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 2 | HOOK-02 | integration | `bash tests/test-phase14.sh test_unknown_repo_404` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | HOOK-06 | integration | `bash tests/test-phase14.sh test_concurrent_5` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | HOOK-06 | integration | `bash tests/test-phase14.sh test_semaphore_queue` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | HOOK-06 | integration | `bash tests/test-phase14.sh test_health_active_spawns` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | Cross | integration | `bash tests/test-phase14.sh test_wrong_path_404` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | Cross | integration | `bash tests/test-phase14.sh test_wrong_method_405` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | Cross | integration | `bash tests/test-phase14.sh test_invalid_json_400` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | Cross | integration | `bash tests/test-phase14.sh test_sigterm_shutdown` | ❌ W0 | ⬜ pending |
| 14-XX-XX | TBD | 3 | Cross | unit | `bash tests/test-phase14.sh test_missing_config` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*
*Task IDs filled in by planner.*

---

## Wave 0 Requirements

- [ ] `tests/test-phase14.sh` — HOOK-01 (unit-file lint + install), HOOK-02 (HMAC pass/fail/missing/newline), HOOK-06 (concurrency, semaphore, health), cross-cutting (404/405/400/sigterm/missing config). Must stub `claude-secure` binary so no real Docker is invoked during the fast path.
- [ ] `tests/fixtures/github-issues-opened.json` — sample GitHub Issues payload for HMAC + routing tests
- [ ] `tests/fixtures/github-push.json` — sample GitHub push payload
- [ ] `tests/test-map.json` update — add `{"paths": ["webhook/"], "tests": ["test-phase14.sh"]}` and `{"paths": ["install.sh"], "tests": ["test-phase14.sh", ...]}`
- [ ] Stub harness function (in `test-phase14.sh` or shared helper) that replaces `bin/claude-secure spawn` with a fast mock writing a marker file for assertion

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Service survives host reboot | HOOK-01 | Requires real systemd + reboot; cannot simulate cleanly in CI | After install: `sudo systemctl enable --now claude-secure-webhook` → `sudo reboot` → `sudo systemctl status claude-secure-webhook` — must show `active (running)` |
| WSL2 systemd warning prints when `/etc/wsl.conf` missing `[boot] systemd=true` | HOOK-01 | Requires WSL2 host with mutated `wsl.conf` | On WSL2 without systemd enabled: run `sudo bash install.sh --with-webhook` — must print warning with copy-pastable snippet; install still succeeds |
| GitHub → real webhook → spawn completes end-to-end | HOOK-01, HOOK-02, HOOK-06 | Requires public endpoint (tunnel) and real GitHub webhook configuration | Document in README: configure tunnel, set webhook in GitHub, trigger a real event, check `~/.claude-secure/events/` and spawn log |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (`tests/test-phase14.sh`, fixtures, test-map updates)
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
</content>
</invoke>
