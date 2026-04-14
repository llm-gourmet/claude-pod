---
phase: 23
slug: profile-doc-repo-binding
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-13
---

# Phase 23 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash + bats-style shell assertions (same as test-phase16.sh precedent) |
| **Config file** | `tests/test-phase23.sh` — Wave 0 installs |
| **Quick run command** | `bash tests/test-phase23.sh` |
| **Full suite command** | `bash tests/test-phase23.sh && bash tests/test-phase16.sh && bash tests/test-phase12.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase23.sh`
- **After every plan wave:** Run `bash tests/test-phase23.sh && bash tests/test-phase16.sh && bash tests/test-phase12.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 23-01-01 | 01 | 0 | BIND-01 | unit | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |
| 23-01-02 | 01 | 1 | BIND-01 | integration | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |
| 23-01-03 | 01 | 1 | BIND-02 | integration | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |
| 23-02-01 | 02 | 1 | BIND-03 | integration | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |
| 23-02-02 | 02 | 2 | BIND-03 | regression | `bash tests/test-phase16.sh && bash tests/test-phase12.sh` | ✅ | ⬜ pending |
| 23-03-01 | 03 | 1 | DOCS-01 | integration | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |
| 23-03-02 | 03 | 2 | DOCS-01 | idempotency | `bash tests/test-phase23.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase23.sh` — stubs for BIND-01, BIND-02, BIND-03, DOCS-01
- [ ] `tests/fixtures/profile-legacy/profile.json` — legacy profile with `report_repo`/`REPORT_REPO_TOKEN` for back-compat tests
- [ ] `tests/fixtures/profile-new/profile.json` — new profile with `docs_repo`, `docs_branch`, `docs_project_dir`, `DOCS_REPO_TOKEN`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Container `env` dump shows no DOCS_REPO_TOKEN | BIND-02 | Requires live container inspection | Run `docker exec <claude-container> env \| grep -i token` and verify absence |
| Deprecation warning fires exactly once per shell session | BIND-03 | Stateful shell session behavior | Source profile twice in same shell, confirm warning appears only on first invocation |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
