---
phase: 12
slug: profile-system
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + bats-core (shell testing) |
| **Config file** | tests/test-phase12.sh |
| **Quick run command** | `bash tests/test-phase12.sh --quick` |
| **Full suite command** | `bash tests/test-phase12.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase12.sh --quick`
- **After every plan wave:** Run `bash tests/test-phase12.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 12-01-01 | 01 | 1 | PROF-01 | integration | `bash tests/test-phase12.sh profile_create` | ❌ W0 | ⬜ pending |
| 12-01-02 | 01 | 1 | PROF-01 | integration | `bash tests/test-phase12.sh profile_spawn` | ❌ W0 | ⬜ pending |
| 12-02-01 | 02 | 1 | PROF-02 | integration | `bash tests/test-phase12.sh repo_mapping` | ❌ W0 | ⬜ pending |
| 12-02-02 | 02 | 1 | PROF-02 | integration | `bash tests/test-phase12.sh repo_resolve` | ❌ W0 | ⬜ pending |
| 12-03-01 | 01 | 1 | PROF-03 | integration | `bash tests/test-phase12.sh validation_fail_closed` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase12.sh` — test harness with all PROF-01/02/03 test cases
- [ ] Test fixtures — sample profile directories with valid/invalid configs

*Existing test infrastructure (test-phase9.sh) provides patterns but will be replaced.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Docker container uses profile's .env | PROF-01 | Requires running Docker | Start instance with --profile, verify env vars inside container |
| Superuser mode merges all profiles | PROF-01 | Requires multiple profiles + Docker | Create 2+ profiles, run without --profile, verify merged whitelist |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
