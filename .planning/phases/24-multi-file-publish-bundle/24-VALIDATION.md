---
phase: 24
slug: multi-file-publish-bundle
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-14
---

# Phase 24 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash (bats-style shell tests, sourcing bin/claude-secure) |
| **Config file** | none — Wave 0 installs `tests/test-phase24.sh` |
| **Quick run command** | `bash tests/test-phase24.sh` |
| **Full suite command** | `bash tests/test-phase24.sh` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase24.sh`
- **After every plan wave:** Run `bash tests/test-phase24.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 24-01-01 | 01 | 0 | RPT-01 | stub | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-01-02 | 01 | 0 | RPT-01 | stub | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-02-01 | 02 | 1 | RPT-04 | unit | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-02-02 | 02 | 1 | RPT-03 | unit | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-03-01 | 03 | 1 | DOCS-02,RPT-02 | integration | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-03-02 | 03 | 1 | RPT-05 | integration | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |
| 24-03-03 | 03 | 1 | DOCS-03 | unit | `bash tests/test-phase24.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase24.sh` — 12 test stubs covering DOCS-02, DOCS-03, RPT-01 through RPT-05
- [ ] `tests/fixtures/phase24/` — fixture files: sample report with known secret, report with external image ref, report with HTML comments/raw HTML
- [ ] `webhook/report-templates/bundle.md` — mandatory 6-section report template

*Wave 0 installs harness and fixtures before any implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Concurrent publish race (two simultaneous publishes produce 2 commits, no lost updates) | RPT-05 | Requires real git remote with network timing | Run two `publish_docs_bundle` calls in parallel against a test remote; verify `git log --oneline` shows 2 commits |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
