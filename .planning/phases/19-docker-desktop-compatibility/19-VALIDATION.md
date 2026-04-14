---
phase: 19
slug: docker-desktop-compatibility
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-13
---

# Phase 19 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash (shell integration tests) + pytest (Python validator unit tests) |
| **Config file** | tests/test_phase19_smoke.sh, tests/test_plat05_version_check.sh |
| **Quick run command** | `bash tests/test_plat05_version_check.sh` |
| **Full suite command** | `bash tests/test_phase19_smoke.sh && bash tests/test_plat05_version_check.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_plat05_version_check.sh`
- **After every plan wave:** Run `bash tests/test_phase19_smoke.sh && bash tests/test_plat05_version_check.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 19-01-01 | 01 | 1 | COMPAT-01 | file check | `grep -q "python:3.11-slim-bookworm" validator/Dockerfile` | ✅ | ⬜ pending |
| 19-01-02 | 01 | 1 | COMPAT-01 | file check | `grep -q "iptables_probe" validator/validator.py` | ❌ W0 | ⬜ pending |
| 19-02-01 | 02 | 1 | PLAT-05 | unit | `bash tests/test_plat05_version_check.sh` | ❌ W0 | ⬜ pending |
| 19-02-02 | 02 | 2 | PLAT-05 | integration | `bash tests/test_plat05_version_check.sh` | ❌ W0 | ⬜ pending |
| 19-03-01 | 03 | 1 | PLAT-05, COMPAT-01 | file check | `test -f tests/test_phase19_smoke.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test_plat05_version_check.sh` — unit tests for PLAT-05 version parsing (mock docker version output)
- [ ] `tests/test_phase19_smoke.sh` — smoke test fixture for end-to-end macOS path (no Docker Desktop needed; tests script structure and logic)

*Existing infrastructure: bash-based tests already used in Phases 16–18 (`tests/test_phase18_full_suite_under_macos_override.sh`). Same pattern.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| iptables probe passes on Docker Desktop Mac | COMPAT-01 | Requires macOS hardware with Docker Desktop | Boot stack on Mac, check validator logs for `iptables probe: OK` |
| Full smoke test execution | PLAT-05, COMPAT-01 | Requires macOS hardware | Run `bash tests/test_phase19_smoke.sh --live` on Mac, confirm exit 0 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
