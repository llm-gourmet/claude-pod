---
phase: 26
slug: stop-hook-mandatory-reporting
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-14
---

# Phase 26 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash test harness (`run_test` helper in tests/test-phase26.sh) |
| **Config file** | None — Wave 0 installs tests/test-phase26.sh + test-map.json entry |
| **Quick run command** | `bash tests/test-phase26.sh` |
| **Full suite command** | `bash tests/run-tests.sh` |
| **Estimated runtime** | ~5 seconds (quick), ~2 minutes (full) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase26.sh`
- **After every plan wave:** Run `bash tests/test-phase26.sh && bash tests/run-tests.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 26-01-01 | 01 | 0 | SPOOL-01 | unit | `bash tests/test-phase26.sh` (new: stop_hook_blocks_on_missing_spool) | ❌ W0 | ⬜ pending |
| 26-01-02 | 01 | 0 | SPOOL-02 | unit | `bash tests/test-phase26.sh` (new: stop_hook_zero_network_calls) | ❌ W0 | ⬜ pending |
| 26-01-03 | 01 | 0 | SPOOL-01 | unit | `bash tests/test-phase26.sh` (new: stop_hook_active_guard_prevents_loop) | ❌ W0 | ⬜ pending |
| 26-01-04 | 01 | 0 | SPOOL-03 | unit | `bash tests/test-phase26.sh` (new: shipper_publishes_and_deletes_spool) | ❌ W0 | ⬜ pending |
| 26-01-05 | 01 | 0 | SPOOL-03 | unit | `bash tests/test-phase26.sh` (new: shipper_retries_on_failure_max_3) | ❌ W0 | ⬜ pending |
| 26-02-01 | 02 | 1 | SPOOL-01/02 | unit | `bash tests/test-phase26.sh` (flip stop_hook tests GREEN) | ✅ exists | ⬜ pending |
| 26-03-01 | 03 | 2 | SPOOL-03 | unit | `bash tests/test-phase26.sh` (flip shipper tests GREEN) | ✅ exists | ⬜ pending |
| 26-04-01 | 04 | 3 | SPOOL-01/03 | integration | `bash tests/test-phase26.sh` (stale drain + README) | ✅ exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test-phase26.sh` — failing test stubs for SPOOL-01/02/03:
  - `test_stop_hook_blocks_on_missing_spool` — hook receives no spool → returns block decision
  - `test_stop_hook_yields_on_existing_spool` — spool present → returns approve decision
  - `test_stop_hook_active_guard_prevents_loop` — stop_hook_active=true → always yields
  - `test_stop_hook_zero_network_calls` — no outbound calls during hook execution (SPOOL-02)
  - `test_shipper_publishes_and_deletes_spool` — successful publish_docs_bundle → spool deleted
  - `test_shipper_retries_on_failure_max_3` — 3 failures → audit logged, spool retained
  - `test_shipper_never_blocks_spawn` — shipper fork returns immediately (disown pattern)
- [ ] `tests/test-map.json` — register test-phase26.sh in the test map

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Stop hook fires inside live container and re-prompts Claude | SPOOL-01 | Requires full docker compose stack + live Claude Code session | Run `claude-secure --profile test spawn`, exit without writing report, verify re-prompt appears once then exits |
| Fork-and-disown shipper survives docker compose down | SPOOL-03 | Requires docker lifecycle manipulation | Run `docker compose down` during an in-flight shipper; verify spool.md survives and audit JSONL logged |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
