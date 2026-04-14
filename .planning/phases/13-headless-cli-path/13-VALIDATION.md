---
phase: 13
slug: headless-cli-path
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-11
updated: "2026-04-14"
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + docker compose (shell integration tests) |
| **Config file** | tests/test-phase13.sh |
| **Quick run command** | `bash tests/test-phase13.sh` |
| **Full suite command** | `bash tests/test-phase13.sh` |
| **Estimated runtime** | ~30 seconds (container startup dominates) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase13.sh`
- **After every plan wave:** Run `bash tests/test-phase13.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 13-01-01 | 01 | 1 | HEAD-01 | integration | `bash tests/test-phase13.sh` | ❌ W0 | ⬜ pending |
| 13-01-02 | 01 | 1 | HEAD-02 | integration | `bash tests/test-phase13.sh` | ❌ W0 | ⬜ pending |
| 13-01-03 | 01 | 1 | HEAD-03 | integration | `bash tests/test-phase13.sh` | ❌ W0 | ⬜ pending |
| 13-01-04 | 01 | 1 | HEAD-04 | integration | `bash tests/test-phase13.sh` | ❌ W0 | ⬜ pending |
| 13-02-01 | 02 | 2 | HEAD-05 | integration | `bash tests/test-phase13.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase13.sh` — test scaffold with stubs for HEAD-01 through HEAD-05
- [ ] Test helper functions for spawn lifecycle (start/verify/cleanup)

*Existing test infrastructure (test-map.json routing, shell test patterns) covers framework needs.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Concurrent spawn isolation | HEAD-04 | Requires two parallel spawns with timing | Run two `claude-secure spawn` simultaneously, verify no cross-contamination |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
