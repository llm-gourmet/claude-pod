---
phase: 7
slug: env-file-strategy-and-secret-loading-for-claude-secure
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-10
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + curl + jq (integration tests in Docker) |
| **Config file** | `tests/test-phase3.sh` (existing secret redaction tests) |
| **Quick run command** | `bash tests/test-phase7.sh` |
| **Full suite command** | `bash tests/test-phase3.sh && bash tests/test-phase4.sh && bash tests/test-phase7.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase7.sh`
- **After every plan wave:** Run `bash tests/test-phase3.sh && bash tests/test-phase4.sh && bash tests/test-phase7.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 07-01-01 | 01 | 1 | ENV-01 | integration | `docker compose exec proxy printenv GITHUB_TOKEN` | ❌ W0 | ⬜ pending |
| 07-01-02 | 01 | 1 | ENV-02 | integration | Add test secret, verify redaction without docker-compose.yml edit | ❌ W0 | ⬜ pending |
| 07-01-03 | 01 | 1 | ENV-03 | integration | `docker compose exec claude env \| grep -v ANTHROPIC \| grep -v CLAUDE` | ❌ W0 | ⬜ pending |
| 07-01-04 | 01 | 1 | ENV-04 | integration | Existing test-phase3.sh tests | ✅ | ⬜ pending |
| 07-01-05 | 01 | 1 | ENV-05 | integration | Start with minimal .env (auth only) | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase7.sh` — integration tests for ENV-01 through ENV-05
- [ ] Existing `tests/test-phase3.sh` may need updates if docker-compose structure changes

*Existing infrastructure partially covers phase requirements (ENV-04 via test-phase3.sh).*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Repo .env deletion doesn't break workflow | ENV-02 | Requires user workflow verification | 1. Delete repo .env 2. Run claude-secure 3. Verify secrets still redacted |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
