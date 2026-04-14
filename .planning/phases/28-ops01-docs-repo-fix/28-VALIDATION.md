---
phase: 28
slug: ops01-docs-repo-fix
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-14
---

# Phase 28 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash shell scripts (custom harness) |
| **Config file** | `tests/test-map.json` (file→suite mapping); suite runner `run-tests.sh` |
| **Quick run command** | `./run-tests.sh tests/test-phase16.sh tests/test-phase23.sh` |
| **Full suite command** | `./run-tests.sh` |
| **Estimated runtime** | ~30 seconds (quick), ~2 minutes (full) |

---

## Sampling Rate

- **After every task commit:** Run `./run-tests.sh tests/test-phase16.sh tests/test-phase23.sh`
- **After every plan wave:** Run `./run-tests.sh`
- **Before `/gsd:verify-work`:** Full suite must be green, plus explicit re-run of `test-phase23.sh` and `test-phase16.sh`
- **Max feedback latency:** ~30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 28-01-01 | 01 | 0 | OPS-01 | integration | `./run-tests.sh tests/test-phase16.sh` (new: `test_docs_repo_field_alias_publishes`) | ❌ W0 | ⬜ pending |
| 28-01-02 | 01 | 1 | OPS-01 | integration | `./run-tests.sh tests/test-phase16.sh` (existing: legacy profile + no-repo skip) | ✅ exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase16.sh` — add `test_docs_repo_field_alias_publishes` (Phase 23-migrated profile regression test). Register in suite's `run_test` dispatch block.
- [ ] *(Optional)* `tests/test-phase23.sh` — add static grep assertion that `bin/claude-secure` does not contain bare `jq -r '\.report_repo // empty'` pattern (anti-regression lint guard).

*Existing infrastructure:* `setup_test_profile`, `setup_bare_repo`, `run_spawn_integration`, `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` helpers all exist in `tests/test-phase16.sh`. The `tests/fixtures/profile-23-docs/profile.json` canonical fixture exists from Phase 23 — no changes needed.

---

## Manual-Only Verifications

*All phase behaviors have automated verification.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
