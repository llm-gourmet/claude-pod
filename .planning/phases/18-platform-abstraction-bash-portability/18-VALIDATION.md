---
phase: 18
slug: platform-abstraction-bash-portability
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-13
---

# Phase 18 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration tests (existing pattern) |
| **Config file** | none — Wave 0 installs `tests/test-phase18.sh` |
| **Quick run command** | `bash tests/test-phase18.sh` |
| **Full suite command** | `bash tests/run-tests.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase18.sh`
- **After every plan wave:** Run `bash tests/run-tests.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 18-01-01 | 01 | 0 | PLAT-02 | unit | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-01-02 | 01 | 0 | TEST-01 | unit | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-02-01 | 02 | 1 | PLAT-03 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-02-02 | 02 | 1 | PLAT-04 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-03-01 | 03 | 1 | PORT-01 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-03-02 | 03 | 1 | PORT-02 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-04-01 | 04 | 1 | PORT-03 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-04-02 | 04 | 1 | PORT-04 | integration | `bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |
| 18-05-01 | 05 | 2 | TEST-01 | integration | `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos bash tests/test-phase18.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase18.sh` — stubs for all PLAT-*/PORT-*/TEST-01 requirement tests
- [ ] Entry added to `tests/run-tests.sh` for phase 18 test file
- [ ] Fixture brew prefix directory `tests/fixtures/brew/` with stub `bin/bash` and `gnubin/date`

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Homebrew bootstrap on real macOS | PLAT-03 | No macOS runner in CI | On a Mac: run `bash install.sh`, verify GNU tools installed via brew |
| Re-exec into brew bash 5 on macOS | PORT-02 | Requires real bash 3.2 | On a Mac: run a script with `declare -A`, verify re-exec fires |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
