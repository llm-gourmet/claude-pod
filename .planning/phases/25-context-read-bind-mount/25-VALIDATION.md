---
phase: 25
slug: context-read-bind-mount
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-14
---

# Phase 25 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash (shell tests sourcing bin/claude-secure in library mode) |
| **Config file** | none — Wave 0 installs `tests/test-phase25.sh` |
| **Quick run command** | `bash tests/test-phase25.sh` |
| **Full suite command** | `bash tests/test-phase25.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase25.sh`
- **After every plan wave:** Run `bash tests/test-phase25.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 20 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 25-01-01 | 01 | 0 | CTX-01..04 | stub | `bash tests/test-phase25.sh` | ✅ | ✅ green |
| 25-02-01 | 02 | 1 | CTX-01,CTX-03,CTX-04 | unit | `bash tests/test-phase25.sh` | ❌ W0 | ⬜ pending |
| 25-03-01 | 03 | 2 | CTX-01,CTX-02 | integration | `bash tests/test-phase25.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `tests/test-phase25.sh` — stubs covering CTX-01..04 + defensive cases (no-docs-repo skip, .git/ absent, read-only rejection, cleanup on exit)
- [x] `tests/fixtures/profile-25-docs/` — profile.json, .env, whitelist.json for sparse-clone tests

*Wave 0 installs harness and fixtures before any implementation.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Write attempt inside container fails with EROFS | CTX-02 | Requires real `docker run` with bind mount | `docker run --rm -v /tmp/agent-docs:/agent-docs:ro alpine sh -c "echo test > /agent-docs/x"` → must exit non-zero with `Read-only file system` |
| `/agent-docs/.git/` absent inside container | CTX-04 | Requires real `docker run` | Spawn with profile + docs_repo; `docker exec ... ls /agent-docs/.git` must fail |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 20s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** Wave 0 scaffold complete 2026-04-14
