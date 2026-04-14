---
phase: 29
slug: prof02-repo-prompt
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-14
---

# Phase 29 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash test harness (`run_test` helper in tests/test-phase12.sh) |
| **Config file** | None — scripts self-contained, invoked via `tests/run-tests.sh` |
| **Quick run command** | `bash tests/test-phase12.sh` |
| **Full suite command** | `bash tests/run-tests.sh` |
| **Estimated runtime** | ~1 second (quick), ~2 minutes (full) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase12.sh`
- **After every plan wave:** Run `bash tests/test-phase12.sh && bash tests/run-tests.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~1 second

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 29-01-01 | 01 | 0 | PROF-02 | unit | `bash tests/test-phase12.sh` (new: `test_prof_02d`, `test_prof_02e`) | ❌ W0 | ⬜ pending |
| 29-01-02 | 01 | 1 | PROF-02 | unit | `bash tests/test-phase12.sh` (all `test_prof_02*` pass) | ✅ exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase12.sh` — add `test_prof_02d` (happy path: prompt, provide `owner/repo`, persist as `.repo`)
- [ ] `tests/test-phase12.sh` — add `test_prof_02e` (skip path: empty input → no `.repo` key in profile.json)
- [ ] *(Optional)* `tests/test-phase12.sh` — add `test_prof_02f` (invalid format emits stderr warning but saves value anyway)

*Existing infrastructure:* `create_test_profile` helper (lines 60-97) provides the exact two-branch `jq -n` pattern to mirror in production. No new test file needed — extending the existing Phase 12 test file is correct (PROF-02 is a Phase 12 requirement).*

---

## Manual-Only Verifications

*All phase behaviors have automated verification.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
