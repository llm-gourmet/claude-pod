---
phase: 16
plan: 03
subsystem: bin/claude-secure
tags: [wave-1b, ops-01, ops-02, publish, render, redact, audit, integration]
requires:
  - Phase 16 Plan 02 resolve_report_template (D-08 fallback chain)
  - Phase 15 _substitute_token_from_file / _substitute_multiline_token_from_file (Pitfall 1 awk-from-file pattern)
  - Phase 15 extract_payload_field python3 env-var transport (Pitfall 4 UTF-8 safe truncation)
  - Phase 13 do_spawn lifecycle (trap spawn_cleanup, _CLEANUP_FILES registration)
  - jq 1.7, python3.11+, git 2.x, bash 5.x, uuidgen
provides:
  - render_report_template(template, event, envelope, status) — full report body renderer with Pitfall 2 RESULT_TEXT-LAST ordering
  - redact_report_file(report_file, env_file) — D-15 literal-replace secret redaction (awk index+substr)
  - write_audit_entry(...14 args) — D-06 13-key JSONL audit writer with Pitfall 7 4095-byte guard
  - _extract_result_text_to_tempfile(envelope) — 16384-byte UTF-8-safe truncator for result text (D-16)
  - push_with_retry(clone_dir, branch) — D-14 non-fast-forward pull-rebase-retry-once, PAT-scrubbed stderr
  - publish_report(body, event_type, delivery_id, id8, repo) — GIT_ASKPASS-helper publish pipeline (D-12, D-13, Pitfall 3, Pitfall 9)
  - _spawn_error_audit(err_msg) — best-effort audit writer for early-return spawn_error paths
  - do_spawn integration: Pattern E render->redact->publish->audit wrapper with D-17 audit-always + D-18 exit-on-claude-failure-only
  - --skip-report flag + CLAUDE_SECURE_SKIP_REPORT=1 env var
  - CLAUDE_SECURE_FAKE_CLAUDE_STDOUT test escape hatch
affects:
  - bin/claude-secure (7 new functions, do_spawn rewritten tail)
  - tests/test-phase16.sh (28 sentinels replaced with real assertions + run_spawn_integration helper)
tech-stack:
  added: []
  patterns:
    - Pattern E: audit AFTER publish so report_url populates in the same line
    - Pattern B: awk-from-file LITERAL substring replace (index + substr) for redaction — zero regex metacharacter hazards
    - GIT_ASKPASS ephemeral helper script for PAT delivery (never argv, never URL, never stderr)
    - python3 os.environb env-var transport for binary-safe UTF-8 truncation
    - POSIX O_APPEND atomicity invariant (bash `>>` + PIPE_BUF=4096 line guard)
    - Subshell-scoped test integration harness with CLAUDE_SECURE_FAKE_CLAUDE_STDOUT injection
    - Local bare file:// report repo for end-to-end push testing
key-files:
  created:
    - .planning/phases/16-result-channel/16-03-SUMMARY.md
  modified:
    - bin/claude-secure
    - tests/test-phase16.sh
decisions:
  - "do_spawn Pattern E wrapper writes audit AFTER publish so report_url is populated in the same JSONL line (eliminates reconciliation)"
  - "D-18 exit rule: publish failures set audit.status=push_error but do NOT flip spawn exit — only Claude-itself failures (claude_exit != 0) propagate nonzero"
  - "publish_report return codes: 0=success, 1=real failure, 2=skip (REPORT_REPO/TOKEN unset) — the wrapper distinguishes skip-vs-failure so audit status stays success on skip"
  - "delivery_id_short = last 8 chars of the STRIPPED id (after removing replay-/manual- prefix), per Open Question 2 — ensures replay/manual/webhook ids share the same 8-char slug format"
  - "webhook_id is the raw _meta.delivery_id when present, empty string for replay-/manual- synthetic ids (not null) so JSONL stays stable)"
  - "RESULT_TEXT and ERROR_MESSAGE substituted LAST in render_report_template (Pitfall 2) so embedded {{ISSUE_TITLE}} in claude output survives as literal text"
  - "write_audit_entry 4095-byte guard retries without error_short when oversized (audit-always invariant preserved)"
  - "CLAUDE_SECURE_FAKE_CLAUDE_STDOUT test escape hatch mirrors Phase 15 CLAUDE_SECURE_EXEC pattern — production docker compose exec path unchanged"
  - "Test harness uses run_spawn_integration helper with subshell-scoped source-only mode to avoid env pollution between tests"
  - "Local file:// bare repo (setup_bare_repo) instead of committed fixture so tests can rewrite history for rebase-retry assertion"
  - "grep -q $'\\x00' treats NUL as empty pattern (always matches); test_crlf_and_null_stripped uses perl -ne /\\0/ for reliable NUL detection"
metrics:
  tasks_completed: 3
  files_created: 1
  files_modified: 2
  functions_added: 7
  tests_flipped_green: 28
  phase16_pass_before: 4
  phase16_pass_after: 31
  phase13_regressions: 0
  phase15_regressions: 0
  phase12_regressions: 0
  lines_added: ~1050
  duration_min: 180
  completed: 2026-04-12
---

# Phase 16 Plan 03: Wave 1b — Render + Redact + Publish + Audit Wired into do_spawn

Wiring plan that flipped the Phase 16 test suite from 4/31 to 31/31 by adding
seven production functions and integrating them into `do_spawn` via a
Pattern E render -> redact -> publish -> audit wrapper that honors D-17
(audit-always) and D-18 (exit on claude failure only).

## One-liner

Completes the headless result channel: claude-secure spawn now renders an
event-typed markdown report, redacts profile secrets, pushes to a remote docs
repo via GIT_ASKPASS, and appends a 13-key JSONL audit line — with every
pitfall guarded.

## What was built

### Functions added (bin/claude-secure)

1. **`_extract_result_text_to_tempfile(envelope)`** — 16384-byte UTF-8 safe
   truncation of `.claude.result`. Uses python3 `os.environb` env-var
   transport so binary payloads pass losslessly. Strips control chars except
   tab/LF/CR. Appends `... [truncated N more bytes]` suffix on overflow.
   Registered in `_CLEANUP_FILES`. (D-16, Pitfall 4)

2. **`render_report_template(template, event_json, envelope_json, status)`**
   — full report body renderer. Calls `render_template` first for Phase 15
   event-scoped variables, then substitutes COST_USD, DURATION_MS, SESSION_ID,
   TIMESTAMP, STATUS from the envelope, then RESULT_TEXT and ERROR_MESSAGE
   LAST (Pitfall 2) so any embedded `{{ISSUE_TITLE}}` in claude output
   survives as literal text. Uses `.claude.cost_usd // .claude.cost // 0`
   legacy fallback (Pitfall 5).

3. **`redact_report_file(report_file, env_file)`** — D-15 in-place literal
   substring replace. Iterates .env, strips `export` prefix + quotes, SKIPS
   empty values (D-15), and uses awk `index()` + `substr()` to replace every
   occurrence with `<REDACTED:KEY>`. Metacharacters `| & / \ $ [ ] * .` are
   all safe because awk reads the value from a file, not from argv.
   (Pitfall 1 fix — NO sed with interpolation.)

4. **`write_audit_entry`** (14 positional args) — appends a single JSONL
   line to `$LOG_DIR/${LOG_PREFIX}executions.jsonl`. `mkdir -p "$LOG_DIR"`
   before append (Pitfall 8). Uses `jq -cn --arg/--argjson` for safe
   quoting. 4095-byte guard (Pitfall 7) retries without `error_short` if
   oversized — audit-always invariant preserved.

5. **`push_with_retry(clone_dir, branch)`** — LC_ALL=C + GIT_ASKPASS env +
   GIT_ASKPASS_PAT + GIT_TERMINAL_PROMPT=0. Doubly overrides
   `credential.helper` on the push command. On non-fast-forward rejection:
   runs `git pull --rebase` and retries push exactly ONCE (D-14). Always
   sed-scrubs the PAT from the error log before surfacing (Pitfall 3). Never
   uses `--force`, `--force-with-lease`, `-f`, or `+refs` (Pitfall 9 — static
   `test_no_force_push_grep` invariant remains green).

6. **`publish_report(body, event_type, delivery_id, id8, repo)`** —
   orchestrates the full publish flow:
   - Returns 2 when `REPORT_REPO` or `REPORT_REPO_TOKEN` is empty (skip).
   - `mktemp` clone_dir registered in `_CLEANUP_FILES`.
   - Ephemeral GIT_ASKPASS helper script (executable bash one-liner).
   - `timeout 60` + `--depth 1` + `GIT_HTTP_LOW_SPEED_LIMIT=1` +
     `GIT_HTTP_LOW_SPEED_TIME=30` bounded clone.
   - D-12 path: `${prefix}/${year}/${month}/${event_type}-${id8}.md`.
   - D-13 commit message: `report(${event_type}): ${repo} ${id8}`.
   - `GIT_AUTHOR_NAME/EMAIL=claude-secure`, no host git config touched.
   - On `git commit` "nothing to commit" (Pitfall 6, identical replay):
     treated as success — emit the expected URL so audit records the known
     location.
   - Calls `push_with_retry`.
   - Returns `${url_base%.git}/blob/${branch}/${rel_path}` on success.

7. **`_spawn_error_audit(err_msg)`** — best-effort audit writer for
   early-return spawn_error paths. Called from the four precondition checks
   in `do_spawn` (missing --profile, missing --event-file file, missing
   --event, invalid JSON). Uses synthetic `manual-<uuid32>` delivery_id and
   `"unknown"` event_type; `2>/dev/null || true` so audit failure never
   blocks the error exit.

### do_spawn integration (Pattern E)

Replaced the `build_output_envelope` / `build_error_envelope` tail with a
wrapper that:

1. Derives `delivery_id` via the priority `._meta.delivery_id` (webhook) >
   `replay-<uuid>` (CLAUDE_SECURE_EXEC set) > `manual-<uuid>` (direct spawn).
2. Computes `delivery_id_short` = last 8 hex chars of the STRIPPED id.
3. Derives `webhook_id` = raw `_meta.delivery_id` or empty string for
   synthetic ids.
4. Extracts `audit_repo/audit_commit/audit_branch` from event JSON using
   `.repository.full_name`, `.pull_request.head.sha // .after //
   .head_commit.id`, `.pull_request.head.ref // .ref` with `refs/heads/`
   strip.
5. Reads `report_repo`, `report_branch`, `report_path_prefix` from
   `profile.json` and exports them as `REPORT_REPO`, `REPORT_BRANCH`,
   `REPORT_PATH_PREFIX` so `publish_report` picks them up.
6. Runs claude (or the `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` escape hatch in
   tests).
7. Builds `envelope_json` via `build_output_envelope` (success) or
   `build_error_envelope` (claude_error), setting initial `audit_status`.
8. Extracts `_audit_cost/_audit_duration_total/_audit_session` from the
   envelope using the legacy `.cost // .duration` fallback (Pitfall 5).
9. If `--skip-report` not set AND `resolve_report_template` finds a template:
   renders it via `render_report_template`, redacts via `redact_report_file`,
   then calls `publish_report`. A real publish failure (rc != 0, rc != 2)
   changes `audit_status` from `success` to `push_error` and clears
   `report_url`.
10. `write_audit_entry` runs ALWAYS with the final `report_url`
    (D-17 audit-always, Pattern E).
11. `echo "$envelope_json"` emits the envelope to stdout.
12. `return "$claude_exit"` — D-18: only Claude failures flip the exit code.

### Added flags / env vars

- `--skip-report` — skip publish, still audit (testing / dry-runs).
- `CLAUDE_SECURE_SKIP_REPORT=1` — env var equivalent.
- `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT=<file>` + `CLAUDE_SECURE_FAKE_CLAUDE_EXIT=<rc>`
  — test escape hatch that bypasses `docker compose up/exec` and uses file
  contents as claude stdout. Mirrors Phase 15 `CLAUDE_SECURE_EXEC` pattern.

### Tests added (tests/test-phase16.sh)

- **`run_spawn_integration`** helper — subshell-scoped source-only mode,
  injects `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT`, builds per-test profile,
  writes REPORT_REPO_TOKEN to .env, calls `do_spawn`. Captures stdout,
  stderr, and spawn rc into `$TEST_TMPDIR/<tid>/`.
- **`audit_log_path`** helper — returns per-test JSONL path.
- **28 sentinels replaced** with real end-to-end assertions using local
  file:// bare repo (`setup_bare_repo`). Coverage:
  - OPS-01: push success, filename format (id8 hex), commit message format,
    rebase-retry, push failure audit + exit 0, redaction committed, empty
    value no-op, metacharacter redaction, PAT no-leak, skip when REPORT_REPO
    empty, result truncation, embedded template var survives, CRLF/NUL,
    clone timeout bounded.
  - OPS-02: audit file path, mkdir lazy, JSONL parseable, 13 mandatory keys,
    status enum, spawn_error path, claude_error path, cost fallback,
    PIPE_BUF bound, concurrent 10-way write, replay delivery_id format,
    manual delivery_id format, webhook_id null when absent.

## Test gate

```text
========================================
  Phase 16 Integration + Unit Tests
  Result Channel (OPS-01/OPS-02)
========================================
--- Scaffold invariants ---     3/3   PASS
--- OPS-01: Report push ---    15/15  PASS
--- OPS-02: Audit log ---      13/13  PASS
==============================
Phase 16: 31/31 passed, 0 failed
==============================
```

Regression suites:

| Phase | Result     | Notes                                                                     |
| ----- | ---------- | ------------------------------------------------------------------------- |
| 12    | 19/19 PASS | no regressions                                                            |
| 13    | 16/16 PASS | no regressions                                                            |
| 14    | 15/16 PASS | `test_unit_file_parses` fails on `systemd-analyze verify` — sandbox RO-fs artifact pre-existing (see `deferred-items.md`) |
| 15    | 28/28 PASS | no regressions                                                            |
| 16    | 31/31 PASS | Wave 1b complete                                                          |

## Pitfalls covered

| Pitfall                                      | Guard                                                                     |
| -------------------------------------------- | ------------------------------------------------------------------------- |
| 1: sed with interpolated user data           | `redact_report_file` uses awk index+substr, not sed                       |
| 2: recursive template substitution           | RESULT_TEXT/ERROR_MESSAGE substituted LAST in `render_report_template`    |
| 3: PAT leak in URL/argv/stderr               | GIT_ASKPASS helper + sed-scrub of clone_err + commit URL strips .git     |
| 4: UTF-8 truncation breaking multi-byte      | python3 os.environb transport in `_extract_result_text_to_tempfile`       |
| 5: legacy cost/duration field names          | `.cost_usd // .cost // 0` fallback in render + audit extract              |
| 6: nothing-to-commit on identical replay     | `git commit` failure treated as success in `publish_report`               |
| 7: audit line > PIPE_BUF (4096)              | `write_audit_entry` guard retries without error_short                     |
| 8: LOG_DIR missing on first spawn            | `mkdir -p "$LOG_DIR"` inside `write_audit_entry`                          |
| 9: accidental force-push                     | Never uses --force/-f/+refs; static grep test stays green                 |
| 14: PER-LOG_PREFIX audit file collision      | Each profile's `${LOG_PREFIX}executions.jsonl` is its own O_APPEND target |

## Design decisions

See `decisions:` in frontmatter. Most notable:

- **Pattern E ordering** (audit AFTER publish) — chosen over Pattern D
  (publish AFTER audit + reconcile) because reconciliation logic would need
  to re-open and rewrite JSONL lines, breaking the O_APPEND atomicity
  invariant. Pattern E does publish -> write_audit_entry in a single flow
  so `report_url` is known before the audit line is serialized.

- **D-18 exit semantics** — publish failures audit-log only, do not flip
  spawn exit code. Rationale: callers (webhook listener, replay) use the
  exit code to decide whether to retry the *claude run*. A publish failure
  does not justify re-running claude (same cost, same result). Push retry
  is a separate layer handled by `push_with_retry`.

- **delivery_id_short = last 8 of stripped id** — Open Question 2 resolved
  in favor of stripping prefix first so `replay-a1b2c3d4...` and
  `manual-a1b2c3d4...` both produce the SAME slug format (`<event>-d4e5f6g7.md`)
  when replayed with the same underlying uuid. Avoids confusing
  `replay-a1b2c3d4-*` filename prefixes in the report repo tree.

- **webhook_id empty string vs null** — chose empty string for synthetic
  ids so the JSONL `webhook_id` key is always a string. Downstream queries
  like `jq 'select(.webhook_id == "")'` work uniformly.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 - Blocking] Added `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` escape
    hatch**
- **Found during:** Task 3 integration test design
- **Issue:** Plan specified test assertions hitting full `do_spawn` but
  production path runs `docker compose exec -T claude claude -p ...` which
  cannot run inside the test sandbox.
- **Fix:** Added env-var escape hatch mirroring Phase 15 `CLAUDE_SECURE_EXEC`:
  if `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` is set to a readable file, skip
  `docker compose up --wait` + `exec`, use file contents as `claude_stdout`,
  use `CLAUDE_SECURE_FAKE_CLAUDE_EXIT` as the exit code. Production path
  unchanged (escape hatch only activates when env var is set AND file exists).
- **Files modified:** bin/claude-secure (3-line `if/else` around the
  `docker compose` block)
- **Commit:** 50b3121

**2. [Rule 1 - Bug] `test_crlf_and_null_stripped` NUL detection via perl**
- **Found during:** Running Phase 16 suite
- **Issue:** `grep -q $'\x00' "$f"` returned 0 (match) even when file had no
  NUL bytes. Bash `$'\x00'` produces an empty string, and grep treats empty
  pattern as "match every line".
- **Fix:** Replaced with `perl -ne 'exit 0 if /\0/; END { exit 1 }' "$f"`
  which uses Perl's binary-safe NUL regex.
- **Files modified:** tests/test-phase16.sh
- **Commit:** 50b3121

**3. [Rule 1 - Bug] `test_result_text_truncation` upper bound relaxed**
- **Found during:** Running Phase 16 suite (16387 A's > 16384 limit)
- **Issue:** Test counted all A's in the rendered file, but the template
  baseline (`**Author:**`, etc.) contributes ~8 extra A's beyond the
  truncated-to-16384 result body.
- **Fix:** Relaxed upper bound to 16400 and added positive assertion that
  the `... [truncated N more bytes]` suffix appears.
- **Files modified:** tests/test-phase16.sh
- **Commit:** 50b3121

### Pre-existing issues NOT fixed (out of scope per sandbox boundary)

- **Phase 14 `test_unit_file_parses`** — `systemd-analyze verify` fails with
  "Failed to setup working directory: Read-only file system" inside the
  Claude sandbox. Reproducible against HEAD with no Phase 16 changes applied.
  Logged in `.planning/phases/16-result-channel/deferred-items.md` by 16-02.

## Known Stubs

None. Every function is fully wired into `do_spawn` with real side effects
(audit JSONL written, report committed + pushed, envelope emitted).

## Commits

| Task | Description                                                                                                 | Commit    |
| ---- | ----------------------------------------------------------------------------------------------------------- | --------- |
| 1    | Add render_report_template, redact_report_file, write_audit_entry, _extract_result_text_to_tempfile         | d48328a   |
| 2    | Add publish_report + push_with_retry with GIT_ASKPASS helper                                                | 8f7ceb6   |
| 3    | Wire publish + render + redact + audit into do_spawn (Pattern E) + 28 tests flipped green                   | 50b3121   |

## Self-Check: PASSED

- bin/claude-secure: FOUND
- tests/test-phase16.sh: FOUND
- .planning/phases/16-result-channel/16-03-SUMMARY.md: FOUND
- Commit d48328a: FOUND
- Commit 8f7ceb6: FOUND
- Commit 50b3121: FOUND
- Phase 16 suite: 31/31 PASS
- Phase 12/13/15 regressions: 63/63 PASS
- Phase 14 regression: 15/16 (1 pre-existing sandbox artifact)
