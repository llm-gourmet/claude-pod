---
phase: 9
slug: multi-instance-support-for-claude-secure
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-10
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + curl + jq (integration tests) |
| **Config file** | `tests/test-phase9.sh` |
| **Quick run command** | `bash tests/test-phase9.sh` |
| **Full suite command** | `for f in tests/test-phase*.sh; do bash "$f"; done` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase9.sh`
- **After every plan wave:** Run `for f in tests/test-phase*.sh; do bash "$f"; done`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 09-01-01 | 01 | 1 | INST-flag-parse | unit (bash) | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-02 | 01 | 1 | INST-auto-create | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-03 | 01 | 1 | INST-multi-run | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-04 | 01 | 1 | INST-migration | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-05 | 01 | 1 | INST-list | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-06 | 01 | 1 | INST-isolation | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |
| 09-01-07 | 01 | 1 | INST-log-prefix | integration | `bash tests/test-phase9.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase9.sh` — multi-instance integration tests (stubs for all behaviors above)
- [ ] Test infrastructure for temp config dirs (reuse pattern from `tests/test-phase4.sh`)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Two instances visible in `docker ps` simultaneously | INST-multi-run | Requires Docker daemon running | Start two instances, verify `docker ps` shows containers for both project names |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
