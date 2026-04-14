---
phase: 16
slug: result-channel
status: complete
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-12
updated: "2026-04-14"
---

# Phase 16 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `16-RESEARCH.md` §Validation Architecture (fully elaborated there).

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration test harness (same style as `tests/test-phase14.sh` / `tests/test-phase15.sh`) |
| **Config file** | None — inline harness in `tests/test-phase16.sh` |
| **Quick run command** | `bash tests/test-phase16.sh` |
| **Full suite command** | `bash tests/test-phase16.sh` |
| **Estimated runtime** | ~15s (unit + local-bare-repo integration) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test-phase16.sh`
- **After every plan wave:** Run `bash tests/test-phase13.sh && bash tests/test-phase14.sh && bash tests/test-phase15.sh && bash tests/test-phase16.sh`
- **Before `/gsd:verify-work`:** Full Phase 13 + 14 + 15 + 16 suite must be green
- **Max feedback latency:** ~45s (cross-phase regression)

---

## Per-Task Verification Map

Full mapping lives in `16-RESEARCH.md` lines 793–824 (30 named tests spanning OPS-01 and OPS-02). Summary here; consult research for exact command strings.

### OPS-01 — Report Push (OPS-01 / D-01..D-03, D-08..D-16, Pitfalls 1/2/3/4/6/8/11)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| test_report_push_success | integration | 16-03 | 1b | ❌ W0 |
| test_report_filename_format | integration | 16-03 | 1b | ❌ W0 |
| test_commit_message_format | integration | 16-03 | 1b | ❌ W0 |
| test_no_force_push_grep | static | 16-03 | 1b | ❌ W0 |
| test_rebase_retry | integration | 16-03 | 1b | ❌ W0 |
| test_push_failure_audit_and_exit | integration | 16-03 | 1b | ❌ W0 |
| test_secret_redaction_committed | integration | 16-03 | 1b | ❌ W0 |
| test_redaction_empty_value_noop | unit | 16-03 | 1b | ❌ W0 |
| test_redaction_metacharacters | unit | 16-03 | 1b | ❌ W0 |
| test_pat_not_leaked_on_failure | integration | 16-03 | 1b | ❌ W0 |
| test_report_template_fallback | unit | 16-02 | 1a | ❌ W0 |
| test_no_report_repo_skips_push | integration | 16-03 | 1b | ❌ W0 |
| test_result_text_truncation | unit | 16-03 | 1b | ❌ W0 |
| test_result_text_no_recursive_substitution | unit | 16-03 | 1b | ❌ W0 |
| test_crlf_and_null_stripped | unit | 16-03 | 1b | ❌ W0 |
| test_clone_timeout_bounded | integration | 16-03 | 1b | ❌ W0 |

### OPS-02 — Audit Log (OPS-02 / D-04..D-07, D-17..D-18, Pitfalls 5/7/10/14)

| Test Function | Type | Plan | Wave | Scaffold |
|---------------|------|------|------|----------|
| test_audit_file_path | integration | 16-03 | 1b | ❌ W0 |
| test_audit_creates_log_dir | integration | 16-03 | 1b | ❌ W0 |
| test_audit_jsonl_parseable | integration | 16-03 | 1b | ❌ W0 |
| test_audit_has_mandatory_keys | integration | 16-03 | 1b | ❌ W0 |
| test_audit_status_enum | integration | 16-03 | 1b | ❌ W0 |
| test_audit_spawn_error | integration | 16-03 | 1b | ❌ W0 |
| test_audit_claude_error | integration | 16-03 | 1b | ❌ W0 |
| test_audit_cost_fallback | unit | 16-03 | 1b | ❌ W0 |
| test_audit_line_under_pipe_buf | unit | 16-03 | 1b | ❌ W0 |
| test_audit_concurrent_safe | integration | 16-03 | 1b | ❌ W0 |
| test_audit_replay_identical | integration | 16-03 | 1b | ❌ W0 |
| test_audit_manual_synthetic_id | integration | 16-03 | 1b | ❌ W0 |
| test_audit_webhook_id_null_when_absent | unit | 16-03 | 1b | ❌ W0 |

### Regression

| Test | Command | File Exists |
|------|---------|-------------|
| Phase 13 regression | `bash tests/test-phase13.sh` | ✅ |
| Phase 14 regression | `bash tests/test-phase14.sh` | ✅ |
| Phase 15 regression | `bash tests/test-phase15.sh` | ✅ |

*Status legend: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

All Wave 0 artifacts create failing tests that later waves flip green (Nyquist self-healing).

- [ ] `tests/test-phase16.sh` — top-level harness, ~30 named test functions, inlines Phase 14/15 helper patterns, stub claude-secure on PATH, local bare report repo setup, fixture builder for profile/envelope
- [ ] `tests/fixtures/envelope-success.json` — Claude envelope with `cost_usd`, `duration_ms`, `session_id`, `result` populated
- [ ] `tests/fixtures/envelope-legacy-cost.json` — envelope with legacy `cost` and `duration` field names (Pitfall 5)
- [ ] `tests/fixtures/envelope-large-result.json` — envelope with 20KB result text + embedded CRLF + NUL (Pitfall 4, D-16)
- [ ] `tests/fixtures/envelope-result-with-template-vars.json` — result contains literal `{{ISSUE_TITLE}}` to exercise Pitfall 2
- [ ] `tests/fixtures/envelope-error.json` — error envelope for `claude_error` path
- [ ] `tests/fixtures/env-with-metacharacter-secrets` — `.env` with `PIPE_VAL=foo|bar`, `AMP_VAL=x&y`, `SLASH_VAL=/etc/passwd`, `DOLLAR_VAL=$1abc`, `NEWLINE_VAL=line1\nline2`, `EMPTY_VAL=`
- [ ] `tests/fixtures/report-repo-bare/` — pre-seeded local bare git repo with `main` branch, restored fresh per test
- [ ] `webhook/report-templates/issues-opened.md` — default template (demonstrates all D-10 variables)
- [ ] `webhook/report-templates/issues-labeled.md` — default template
- [ ] `webhook/report-templates/push.md` — default template
- [ ] `webhook/report-templates/workflow_run-completed.md` — default template, {{STATUS}}-aware
- [ ] `tests/test-map.json` — append Phase 16 mappings

*(Framework install: none — bash, jq, git, python3 already present and verified on host.)*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real GitHub PAT push to live doc repo | OPS-01 | Needs real network + real PAT; CI uses local bare repo | After install, configure real `REPORT_REPO_TOKEN` in a test profile `.env`, run `claude-secure spawn --profile <name> --event-file <fixture>`, verify commit appears on GitHub |

*All other Phase 16 behaviors have automated verification via local bare repo + stubbed spawn.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (fixtures, bare repo, templates, harness)
- [ ] No watch-mode flags
- [ ] Feedback latency < 45s (Phase 16 alone ~15s)
- [ ] `nyquist_compliant: true` set in frontmatter (after Wave 0 lands)

**Approval:** pending
