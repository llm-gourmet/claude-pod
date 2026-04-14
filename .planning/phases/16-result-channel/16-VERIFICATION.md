---
phase: 16-result-channel
verified: 2026-04-14T00:00:00Z
status: passed
score: 2/2 must-haves verified (OPS-01, OPS-02)
verdict: PASS
---

# Phase 16: Result Channel Verification Report

**Phase Goal:** Deliver the result channel: after Claude exits, render a structured markdown report (OPS-01) and append a 13-key JSONL audit entry (OPS-02) — with secret redaction, push retry, and audit-always guarantees. All 31 integration tests pass.

**Verdict:** PASS

**Re-verification:** No — initial verification (backfilled via Phase 27 on 2026-04-14; Phase 16 executed 2026-04-12).

---

## Goal Achievement

### Observable Truths (from OPS-01/OPS-02 acceptance criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | After execution, a structured markdown report is written and pushed to a separate documentation repo (OPS-01) | VERIFIED | 16-03-SUMMARY `phase16_pass_after: 31`; 15/15 OPS-01 tests pass (test_report_push_success through test_clone_timeout_bounded); 7 functions wired into do_spawn via Pattern E: `render_report_template`, `redact_report_file`, `publish_report`, `push_with_retry`, `_extract_result_text_to_tempfile`, `resolve_report_template`, `_spawn_error_audit`. Key pitfall guards: RESULT_TEXT substituted last (Pitfall 2), GIT_ASKPASS helper for PAT (Pitfall 3), awk index+substr redaction (Pitfall 1), local file:// bare repo in tests. Commits `d48328a`, `8f7ceb6`, `50b3121`. |
| 2 | Each headless execution is logged to structured JSONL with event metadata (OPS-02) | VERIFIED | 16-03-SUMMARY `phase16_pass_after: 31`; 13/13 OPS-02 tests pass (test_audit_file_path through test_audit_webhook_id_null_when_absent); `write_audit_entry` function writes 13-key JSONL to `$LOG_DIR/${LOG_PREFIX}executions.jsonl` with `mkdir -p` guard (Pitfall 8), 4095-byte PIPE_BUF guard (Pitfall 7), `jq -cn --arg/--argjson` for safe quoting, O_APPEND atomicity via `>>`. Audit-always invariant (D-17): `write_audit_entry` called unconditionally after every spawn path. Commit `50b3121`. |

**Score:** 2/2 truths verified.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `bin/claude-secure` | 7 new production functions + do_spawn Pattern E integration | VERIFIED | Commits `d48328a`, `8f7ceb6`, `50b3121`. Functions: `render_report_template`, `redact_report_file`, `write_audit_entry`, `_extract_result_text_to_tempfile`, `push_with_retry`, `publish_report`, `_spawn_error_audit`. Pattern E wrapper with D-17 audit-always + D-18 exit-on-claude-failure-only. |
| `tests/test-phase16.sh` | 31 tests: 3 scaffold + 15 OPS-01 + 13 OPS-02 | VERIFIED | 31 tests at Wave 1b completion (16-03); expanded to 33 in Wave 2 (16-04). All tests sourced from Nyquist Wave 0 scaffold (16-01). Commit `50b3121`. |
| `tests/fixtures/envelope-success.json` | Claude envelope with cost_usd, duration_ms, session_id, result | VERIFIED | Created in Plan 16-01. Commit `feb2a50`. |
| `tests/fixtures/envelope-legacy-cost.json` | Legacy cost/duration field names for Pitfall 5 | VERIFIED | Created in Plan 16-01. Commit `feb2a50`. |
| `tests/fixtures/envelope-large-result.json` | 20KB result with CRLF + NUL | VERIFIED | 20017-byte result body. Created in Plan 16-01. Commit `feb2a50`. |
| `tests/fixtures/env-with-metacharacter-secrets` | .env with pipe, ampersand, slash, dollar, newline | VERIFIED | 8 metacharacter keys + EMPTY_VAL + QUOTED_VAL + REPORT_REPO_TOKEN. Created in Plan 16-01. Commit `feb2a50`. |
| `webhook/report-templates/` | issues-opened.md, issues-labeled.md, push.md, workflow_run-completed.md | VERIFIED | All 4 templates created in Plan 16-01. All contain `{{RESULT_TEXT}}` as last template token (Pitfall 2 invariant). Commit `ad1af91`. |
| `install.sh` | Step 5c copies report-templates to /opt/claude-secure/webhook/report-templates/ | VERIFIED | 15-line step 5c block added at lines 358-371 in Plan 16-04. D-12 always-refresh: individual file cp, never rm -rf. Commit `98e47a0`. |
| `tests/test-map.json` | Phase 16 mappings appended | VERIFIED | OPS-01 (16 tests) and OPS-02 (13 tests) top-level keys added alongside existing mappings array. Created in Plan 16-01. Commit `feb2a50`. |

---

## Key Link Verification (Wiring)

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `do_spawn` | `resolve_report_template` | selects template by event_type from D-08 fallback chain | WIRED | Plan 16-02. `_resolve_default_templates_dir(subdir)` parameterized to serve both prompt and report templates. Phase 15 call site unchanged (backward compat via default subdir='templates'). Commit `ba197ce`. |
| `do_spawn` | `render_report_template(template, event, envelope, status)` | `render_template` for Phase 15 vars → COST/DURATION/SESSION/STATUS → RESULT_TEXT/ERROR_MESSAGE LAST (Pattern B, Pitfall 2) | WIRED | Plan 16-03. Legacy `.cost_usd // .cost // 0` fallback (Pitfall 5). RESULT_TEXT/ERROR_MESSAGE substituted last so embedded `{{ISSUE_TITLE}}` in claude output survives as literal text. Commit `d48328a`. |
| `do_spawn` | `redact_report_file(report_file, env_file)` | awk index+substr literal replace, no sed (Pitfall 1) | WIRED | Plan 16-03. Iterates .env, strips `export` prefix + quotes, skips empty values (D-15). Metacharacters safe because awk reads value from file. Commit `d48328a`. |
| `do_spawn` | `publish_report(body, event_type, delivery_id, id8, repo)` | GIT_ASKPASS ephemeral helper → `git clone --depth 1` → `git commit` → `push_with_retry` | WIRED | Plan 16-03. PAT never in argv/URL/stderr. Ephemeral bash one-liner registered in `_CLEANUP_FILES`. `timeout 60` + `GIT_HTTP_LOW_SPEED_LIMIT=1` bounded clone. Commit `8f7ceb6`. |
| `push_with_retry` | `git pull --rebase` + 3-attempt loop | grep `remote rejected / failed to update ref / cannot lock ref` for non-fast-forward | WIRED | Plan 16-03 (initial 1-attempt retry); expanded to 3-attempt in Phase 17-03. Grep widened to catch file:// remote rejection strings. Commit `8f7ceb6`. |
| `do_spawn` | `write_audit_entry` | called ALWAYS after publish (D-17 audit-always, Pattern E ordering) | WIRED | Plan 16-03. `$LOG_DIR/${LOG_PREFIX}executions.jsonl` via O_APPEND `>>`. Commit `50b3121`. |

---

## Data-Flow Trace

| Step | Data Variable | Source | Produces Real Data | Status |
|------|---------------|--------|--------------------|--------|
| do_spawn envelope | `envelope_json` | `build_output_envelope` (success) or `build_error_envelope` (claude_error) | Yes — extracted from claude stdout | FLOWING |
| `_extract_result_text_to_tempfile` | result text | `.claude.result` from envelope JSON | Yes — python3 os.environb binary-safe UTF-8 truncation to 16384 bytes | FLOWING |
| `render_report_template` | rendered markdown | template file + event JSON + envelope JSON | Yes — RESULT_TEXT substituted last (Pitfall 2 guard) | FLOWING |
| `redact_report_file` | redacted report | rendered file + profile .env | Yes — awk literal replace per .env key (no regex metacharacter exposure) | FLOWING |
| `publish_report` | `report_url` | git clone + commit + push_with_retry | Yes — `${url_base%.git}/blob/${branch}/${rel_path}` on success, empty on skip/failure | FLOWING |
| `write_audit_entry` | JSONL line | all 14 positional args including final report_url | Yes — appended to `$LOG_DIR/${LOG_PREFIX}executions.jsonl` via O_APPEND | FLOWING |

---

## Behavioral Spot-Checks

| Behavior | Test | Status |
|----------|------|--------|
| Scaffold invariants (3/3) | test_fixtures_exist, test_templates_exist, test_no_force_push_grep | PASS |
| OPS-01 report push success | test_report_push_success | PASS |
| OPS-01 filename format | test_report_filename_format | PASS |
| OPS-01 commit message format | test_commit_message_format | PASS |
| OPS-01 no force-push | test_no_force_push_grep | PASS |
| OPS-01 rebase retry | test_rebase_retry | PASS |
| OPS-01 push failure handling | test_push_failure_audit_and_exit | PASS |
| OPS-01 secret redaction | test_secret_redaction_committed | PASS |
| OPS-01 empty value no-op | test_redaction_empty_value_noop | PASS |
| OPS-01 metacharacter redaction | test_redaction_metacharacters | PASS |
| OPS-01 PAT not leaked | test_pat_not_leaked_on_failure | PASS |
| OPS-01 template fallback (D-08) | test_report_template_fallback | PASS |
| OPS-01 skip when REPORT_REPO unset | test_no_report_repo_skips_push | PASS |
| OPS-01 result truncation | test_result_text_truncation | PASS |
| OPS-01 no recursive substitution | test_result_text_no_recursive_substitution | PASS |
| OPS-01 CRLF and NUL stripped | test_crlf_and_null_stripped | PASS |
| OPS-01 clone timeout bounded | test_clone_timeout_bounded | PASS |
| OPS-02 audit file path | test_audit_file_path | PASS |
| OPS-02 creates log dir | test_audit_creates_log_dir | PASS |
| OPS-02 JSONL parseable | test_audit_jsonl_parseable | PASS |
| OPS-02 mandatory keys | test_audit_has_mandatory_keys | PASS |
| OPS-02 status enum | test_audit_status_enum | PASS |
| OPS-02 spawn error path | test_audit_spawn_error | PASS |
| OPS-02 claude error path | test_audit_claude_error | PASS |
| OPS-02 cost fallback | test_audit_cost_fallback | PASS |
| OPS-02 PIPE_BUF bound | test_audit_line_under_pipe_buf | PASS |
| OPS-02 concurrent safe | test_audit_concurrent_safe | PASS |
| OPS-02 replay identical | test_audit_replay_identical | PASS |
| OPS-02 manual synthetic id | test_audit_manual_synthetic_id | PASS |
| OPS-02 webhook_id null when absent | test_audit_webhook_id_null_when_absent | PASS |

**Full suite result:** 31/31 PASS (per 16-03-SUMMARY `phase16_pass_after: 31`).

**Regression suites (from 16-03-SUMMARY):**

| Phase | Result | Notes |
|-------|--------|-------|
| 12 | 19/19 PASS | No regressions |
| 13 | 16/16 PASS | No regressions |
| 14 | 15/16 PASS | `test_unit_file_parses` fails on `systemd-analyze verify` — pre-existing sandbox RO-fs artifact (logged in deferred-items.md; reproduced against HEAD with no Phase 16 changes applied) |
| 15 | 28/28 PASS | No regressions |
| 16 | 31/31 PASS | Wave 1b complete |

---

## Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| OPS-01 | 16-01 (scaffold+templates) + 16-02 (resolver) + 16-03 (publish integration) + 16-04 (installer+docs) | After execution, a structured markdown report is rendered and pushed to a separate documentation repo | SATISFIED | 16-03-SUMMARY: `phase16_pass_after: 31`; 15/15 OPS-01 tests pass; `publish_report` + `render_report_template` + `redact_report_file` wired into do_spawn via Pattern E; `install.sh` step 5c ships report-templates on install. Note: do_spawn:2077 re-reads `.report_repo` only (bypasses `resolve_docs_alias` from Phase 23). This is a Phase 28 forward-compatibility fix for Phase 23+ migrated profiles — v2.0 profiles using `report_repo` are unaffected. |
| OPS-02 | 16-01 (scaffold) + 16-03 (audit integration) | Each headless execution is logged to structured JSONL with event metadata | SATISFIED | 16-03-SUMMARY: `phase16_pass_after: 31`; 13/13 OPS-02 tests pass; `write_audit_entry` writes 13-key JSONL unconditionally after every spawn path (D-17 audit-always invariant). |

**Coverage:** 2/2 requirements scoped to Phase 16 are satisfied.

---

## Key Design Decisions

**Pattern E ordering (audit AFTER publish):**
`write_audit_entry` runs after `publish_report` so `report_url` is known before the JSONL line is serialized. This avoids the need to re-open and rewrite JSONL lines for `report_url` backfill, which would break the O_APPEND atomicity invariant. The alternative (Pattern D: publish AFTER audit + reconcile) was rejected specifically because reconciliation logic requires random-write access to the append-only log file.

**D-18 exit semantics:**
Publish failures change `audit.status` to `push_error` but do NOT flip spawn exit. Only `claude_exit != 0` propagates nonzero. Rationale: callers (webhook listener, replay) use the exit code to decide whether to retry the *claude run*. A push failure does not justify re-running claude (same cost, same result). Push retry is a separate layer handled by `push_with_retry`.

**GIT_ASKPASS ephemeral helper:**
PAT is delivered to git via an ephemeral bash one-liner registered in `_CLEANUP_FILES`. The PAT is never in argv (visible to `ps`), never in the clone URL (visible in logs), and never in stderr (which is scrubbed by sed before surfacing). This is the only mechanism that satisfies all three leak vectors simultaneously.

**`delivery_id_short` = last 8 chars of stripped id:**
After removing `replay-`/`manual-` prefix, all three id types (webhook, replay, manual) produce the same 8-char hex slug format. This ensures `replay-a1b2c3d4...` and a webhook with the same underlying UUID produce the same filename slug, avoiding confusing `replay-*` prefixes in the report repo tree.

---

## Anti-Patterns Found

All 3 items were auto-fixed at commit `50b3121`:

| File | Pattern | Severity | Disposition |
|------|---------|----------|-------------|
| `bin/claude-secure` | `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` test escape hatch (Rule 3 deviation) | INFO | Production docker compose path unchanged; escape hatch only activates when env var is set AND file exists. Mirrors Phase 15 `CLAUDE_SECURE_EXEC` pattern. |
| `tests/test-phase16.sh` | `grep -q $'\x00'` NUL detection (always matched due to empty pattern behavior) | BUG (Rule 1 auto-fix) | Replaced with `perl -ne 'exit 0 if /\0/; END { exit 1 }'` for reliable binary-safe NUL detection. |
| `tests/test-phase16.sh` | `test_result_text_truncation` upper bound too tight (template baseline adds ~8 extra chars beyond 16384 truncation limit) | BUG (Rule 1 auto-fix) | Upper bound relaxed to 16400; positive assertion added for `... [truncated N more bytes]` suffix. |

No remaining issues.

---

## Gaps Summary

None. Both requirements (OPS-01, OPS-02) satisfied. 31/31 tests pass per SUMMARY evidence. The OPS-01 docs_repo integration concern (`do_spawn:2077`) is a Phase 28 forward-compatibility fix for Phase 23+ profiles — it does not affect v2.0 profiles. Verification was late (Phase 16 executed 2026-04-12, verification created 2026-04-14).

**Verdict: PASS — Phase 16 is verified complete. Both OPS-01 and OPS-02 are SATISFIED.**

---

*Verified: 2026-04-14*
*Verifier: Claude (gsd-verifier, backfill via Phase 27)*
