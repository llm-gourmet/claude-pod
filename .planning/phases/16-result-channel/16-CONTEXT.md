# Phase 16: Result Channel - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Mode:** User-delegated auto-chain (pattern: user said "1" → Claude selected all gray areas and picked recommended options with rationale, same pattern as Phases 14/15)

<domain>
## Phase Boundary

Every completed headless execution (success OR failure) produces two durable artifacts:

1. **Structured markdown report** pushed to a separate documentation repository (per profile) — OPS-01
2. **Structured JSONL audit log entry** on the host — OPS-02

The phase wires this into the existing `do_spawn` lifecycle in `bin/claude-secure` so that both webhook-triggered spawns AND `replay` spawns produce identical output. Listener-side logging (webhook.jsonl) already exists from Phase 14 and is NOT duplicated here — this phase is about execution-level reporting, not webhook-delivery logging.

**Scope anchor:** Write/push during spawn lifecycle. No report-UI, no dashboards, no cross-repo mirroring, no webhook notifications on failures.

</domain>

<decisions>
## Implementation Decisions

### Transport & Configuration

- **D-01:** Report push transport is **HTTPS + GitHub Personal Access Token** via `git push`. PAT lives in profile `.env` as `REPORT_REPO_TOKEN` (redacted by proxy like any other secret). Reuses the existing profile `.env` loading pattern from Phase 12. No SSH key management.
- **D-02:** Report repository is configured **per-profile** via new fields in `profile.json`:
  - `report_repo` — full HTTPS URL (e.g. `https://github.com/user/docs.git`)
  - `report_branch` — target branch (default `"main"`)
  - `report_path_prefix` — optional directory inside the repo (default `"reports"`)
  - When `report_repo` is unset or empty, report push is **skipped silently** (audit still written). This lets profiles opt into reporting.
- **D-03:** Clone strategy: **fresh shallow clone (`git clone --depth 1 --branch <report_branch>`)** into a per-spawn `$TMPDIR` subdirectory. Cloned directory registered with `_CLEANUP_FILES` (or sibling cleanup list) and removed by `spawn_cleanup` trap. No cached bare repos, no worktrees. Matches ephemeral spawn lifecycle.

### Audit Log

- **D-04:** Audit log file path: **`$LOG_DIR/${LOG_PREFIX}executions.jsonl`** — per-profile, per-instance, honoring existing multi-instance LOG_PREFIX convention from v1.0. Example: `~/.claude-secure/logs/executions.jsonl` for default instance; `~/.claude-secure/logs/test-executions.jsonl` for test instance.
- **D-05:** Audit is written from **`bin/claude-secure` inside `do_spawn`** (not from `listener.py`). Rationale: envelope, cost, duration, session_id, and exit code all live in `do_spawn`'s scope; and this single writer covers both webhook-triggered and `replay` spawns without duplication.
- **D-06:** JSONL schema — mandatory keys in every audit entry:
  - `ts` — ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`)
  - `delivery_id` — GitHub X-GitHub-Delivery header (or `"replay-<uuid>"` for replay, `"manual-<uuid>"` for direct spawn with no webhook context)
  - `webhook_id` — GitHub hook ID if present in `_meta`, else null
  - `event_type` — composite event type (Phase 15 D-03)
  - `profile` — profile name
  - `repo` — full repo name (`owner/name`) or null
  - `commit_sha` — `head_commit.id` or `workflow_run.head_sha` or null
  - `branch` — branch name or null (same gated-fallback pattern as Phase 15)
  - `cost_usd` — number (from claude envelope), null if missing
  - `duration_ms` — number, null if missing
  - `session_id` — claude session_id string, null if missing
  - `status` — `"success"` | `"spawn_error"` | `"claude_error"` | `"report_push_failed"`
  - `report_url` — full URL to the committed report file on GitHub, null if push skipped/failed
- **D-07:** JSONL writes are **append-only with `O_APPEND` + `fsync`** — concurrent spawns (different LOG_PREFIXes) write to different files, so no cross-instance locking needed. Within one instance, POSIX `O_APPEND` guarantees atomic line appends for writes ≤ PIPE_BUF (4KB). Each JSON line stays under 4KB by design (8KB payload fields from Phase 15 are NOT in audit — only the cost/duration metadata).

### Report Format & Rendering

- **D-08:** Report templates follow the **same fallback chain as Phase 13/15 prompt templates**:
  1. `$CONFIG_DIR/profiles/<profile>/report-templates/<event_type>.md` — profile override
  2. `$WEBHOOK_REPORT_TEMPLATES_DIR/<event_type>.md` — env var override (parallel to `WEBHOOK_TEMPLATES_DIR`)
  3. `$APP_DIR/webhook/report-templates/<event_type>.md` — dev-checkout fallback (when `.git` present)
  4. `/opt/claude-secure/webhook/report-templates/<event_type>.md` — production fallback
  5. Hard fail if none resolves (consistent with Phase 15 D-13)
- **D-09:** Default templates ship for the same 4 event types as prompt templates: `issues-opened`, `issues-labeled`, `push`, `workflow_run-completed`. Installer copies `webhook/report-templates/*.md` into `/opt/claude-secure/webhook/report-templates/` (D-12 always-refresh pattern from Phase 15).
- **D-10:** Report variables extend Phase 15's D-16 variable set with **result-specific** additions:
  - All D-16 variables (DELIVERY_ID, EVENT_TYPE, REPO_FULL_NAME, ISSUE_NUMBER, etc.)
  - `{{RESULT_TEXT}}` — Claude's final message body (from envelope `.claude.result`)
  - `{{COST_USD}}`, `{{DURATION_MS}}`, `{{SESSION_ID}}` — metadata from envelope
  - `{{TIMESTAMP}}` — ISO-8601 UTC timestamp
  - `{{STATUS}}` — one of the D-06 status values
  - `{{ERROR_MESSAGE}}` — populated on failures, empty on success
- **D-11:** Rendering reuses the **`_substitute_token_from_file` awk-from-file helper from Phase 15** (D-17 / Pitfall 1 fix). No new sed code. Same UTF-8-safe `extract_payload_field` for long fields (result text may exceed 8KB — see D-15 for truncation).

### File Placement & Commit

- **D-12:** Report filename inside the doc repo: **`<report_path_prefix>/<YYYY>/<MM>/<event_type>-<delivery_id_short>.md`**, where `delivery_id_short` is the first 8 chars of the delivery id (matches Phase 14 event file pattern). Example: `reports/2026/04/issues-opened-9c1a7e44.md`.
- **D-13:** Commit message: `"report(<event_type>): <repo> <delivery_id_short>"` — single-line, conventional, no body. Authored with `GIT_AUTHOR_NAME="claude-secure"` and `GIT_AUTHOR_EMAIL="claude-secure@localhost"` via env vars to avoid touching host git config.
- **D-14:** Push strategy: **`git push origin <report_branch>`** (non-forced) from the shallow clone. On rejection (remote drifted), retry exactly once with `git pull --rebase && git push`. Second failure → audit with `status: "report_push_failed"` and surface warning to stderr. Never force-push.

### Secret Hygiene

- **D-15:** Before commit, the rendered report body passes through a **secret-redaction pass**: iterate over `/.env` key-value pairs for the active profile and replace every occurrence of the secret value with `<REDACTED:$KEY>`. Empty values are skipped (no accidental global `""` replacement). Done in-place on the staged file before `git add`. This mirrors the Anthropic proxy redaction philosophy but runs in bash via `sed -i` with properly escaped delimiters — using the same awk-from-file substitution pattern as D-11 to avoid the Pitfall 1 sed-escape bug.
- **D-16:** Result text over 16KB is truncated with a `... [truncated N more bytes]` suffix (double the Phase 15 payload limit since full Claude output can be long). UTF-8-safe via the Phase 15 python3 helper.

### Failure Modes

- **D-17:** **Audit-always, push best-effort:**
  - Spawn fails before Claude runs → audit entry with `status: "spawn_error"`, no report push attempted.
  - Claude runs and fails (nonzero exit) → audit entry with `status: "claude_error"`, error report pushed if template exists (uses same fallback chain as success report), otherwise skip push.
  - Claude succeeds but push fails → audit entry with `status: "report_push_failed"`, exit code 0 (success from spawn's perspective, report is degraded not broken). Warning to stderr.
  - Success path → `status: "success"`.
- **D-18:** Spawn exits **nonzero only when Claude itself fails**. Report-push failure is surfaced via stderr + audit `status` but does NOT flip spawn's exit code. Rationale: audit is the source of truth; push is observability. A webhook retriggering spawn because push failed would multiply cost with no security benefit.

### Claude's Discretion
- Exact prose of default report templates
- Whether report push runs inline in `do_spawn` or in a separate `spawn_publish_report` helper (clarity call)
- Whether to add a `--skip-report` flag for testing (recommended: yes, mirrors `--dry-run`)
- Whether the audit entry is written before or after the report push (recommended: after push, so `report_url` is populated in the same line)
- JSON key ordering within audit entries (all mandatory keys must appear; order is cosmetic)
- Test fixture reuse from Phase 15 (recommended: reuse `github-*.json` and add golden-output assertions)

### Folded Todos
None. (No pending backlog items match Phase 16 scope.)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Prior Phase Contracts
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` — Envelope shape (`build_output_envelope` at `bin/claude-secure:343`), template resolution chain, do_spawn lifecycle
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — Delivery ID plumbing, event file persistence layout under `$CONFIG_DIR/events/`, JsonlHandler pattern at `webhook/listener.py:170`
- `.planning/phases/15-event-handlers/15-CONTEXT.md` — D-13 template fallback chain, D-16 variable set, D-17 awk-from-file substitution, Pitfall 1 (sed-escape) and Pitfall 4 (UTF-8 truncation)

### Project-level
- `.planning/REQUIREMENTS.md` — OPS-01, OPS-02 definitions
- `.planning/PROJECT.md` — Core value ("no secret leaves uncontrolled"), redaction mandate
- `CLAUDE.md` — Tech stack constraints, bash/python/jq toolchain

### Implementation References
- `bin/claude-secure:343-378` — Existing `build_output_envelope` and `build_error_envelope` functions (audit integration point)
- `bin/claude-secure:475+` — `_substitute_token_from_file` awk helper (reuse for report rendering + redaction)
- `bin/claude-secure:438+` — `extract_payload_field` python3 helper (reuse for UTF-8-safe result truncation)
- `bin/claude-secure:700-786` — `do_spawn` function (audit + report push insertion point)
- `webhook/listener.py:170-206` — JsonlHandler pattern (reference only; phase 16 audit is written from bash, not reused)
- `install.sh:348-356` — Phase 15 template installer step 5b (pattern to extend for report-templates)
- `.planning/phases/15-event-handlers/tests/test-phase15.sh` — Phase 15 test scaffold pattern (Nyquist self-healing, Wave 0 failing tests → Wave 1 fixes)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`build_output_envelope()` / `build_error_envelope()`** at `bin/claude-secure:343,361` — Already emits the structured JSON that the audit log needs. Phase 16 feeds this envelope into the JSONL writer.
- **`_substitute_token_from_file()`** at `bin/claude-secure:475` — Phase 15's Pitfall 1 fix. Reused verbatim for report template rendering. No new substitution code.
- **`extract_payload_field()`** at `bin/claude-secure:438` — UTF-8-safe payload extraction via python3. Reused for long result text truncation.
- **`resolve_template()`** at `bin/claude-secure:~380` — Template fallback chain. Clone-and-adapt for `resolve_report_template()`.
- **`spawn_cleanup()` + `_CLEANUP_FILES`** at `bin/claude-secure:336` — Existing trap handles ephemeral file cleanup. Extend with report clone directory.
- **`JsonlHandler`** at `webhook/listener.py:170` — Proven JSONL append pattern. Phase 16 uses same `O_APPEND` semantics but in bash (`>>`).
- **Profile `.env` loader** (Phase 12) — Already loaded by `load_profile_config`. Reused for both the PAT and the secret-redaction key list.

### Established Patterns
- **Template fallback chain:** profile override → env var → dev checkout → production → hard fail. Used in Phases 13, 15; same in Phase 16.
- **Awk-from-file substitution** (Phase 15 D-17): never use sed with user-controlled strings. Report rendering + redaction both use this.
- **Gated fallback for optional fields:** `[ -s "$v_file" ] && fallback...` — Phase 15 Note 4. Applied to branch/commit_sha in audit.
- **LOG_PREFIX multi-instance:** v1.0 convention. Audit log respects it.
- **Install step pattern:** `mkdir -p /opt/.../X && cp webhook/X/*.md /opt/.../X/ && chmod 644` — Phase 15 step 5b. Clone for report-templates.
- **D-12 always-refresh:** installer always overwrites defaults, never `rm -rf`. Same for report-templates.

### Integration Points
- **`do_spawn` success branch** (`bin/claude-secure:785`) — After `build_output_envelope`, call `publish_report` and `write_audit_entry`.
- **`do_spawn` error branch** (`bin/claude-secure:780`) — After `build_error_envelope`, call `publish_report` (error template) and `write_audit_entry`.
- **`spawn_cleanup` trap** — Extend with clone directory removal.
- **Profile schema** — Add `report_repo`, `report_branch`, `report_path_prefix` to profile.json. Profile validator needs matching keys.
- **Installer `install_webhook_service`** — Add step for copying `webhook/report-templates/` (mirrors 15-04 step).

</code_context>

<specifics>
## Specific Ideas

- **Nyquist self-healing test pattern:** Phase 15 established that Wave 0 writes failing tests that later waves flip green. Phase 16 follows this — test scaffold first, implementation second. Test fixtures from Phase 15 can be reused with new assertion helpers for report content + audit lines.
- **Mirror Phase 15 structure:** Plans should follow the 4-plan pattern — Wave 0 test scaffold, Wave 1a config+templates, Wave 1b bin/claude-secure integration, Wave 2 installer extension.
- **Audit entries MUST be JSONL-parseable with `jq -c`:** Tests should validate via `jq -c '.' < executions.jsonl`. A single unparseable line fails the test.
- **Report redaction MUST strip `.env` values, not keys:** `KEY=secretvalue` → `<REDACTED:KEY>` in the report. Empty values skipped (prevents corrupting whitespace).
- **No --force in git push:** Audit the code for any force flag. Never force push to the doc repo.

</specifics>

<deferred>
## Deferred Ideas

- **SSH deploy key support for report repo** — Alternative transport. Phase 17 hardening candidate.
- **Health webhook on report-push failure** — HEALTH-02 (Future Requirements).
- **Cost tracking dashboards / per-period aggregation** — COST-01 (Future Requirements).
- **Report content-addressable caching / dedup** — Not needed at current volume (tens of events per day).
- **Cross-repo report mirroring** (push to multiple doc repos) — Out of scope; add when a second profile wants it.
- **In-repo audit mirror** (push audit JSONL to doc repo) — Could be useful but complicates rebase-on-conflict. Revisit if operators request it.
- **Report template hot-reload** — Templates are already stateless; no hot-reload needed.
- **Report diffing / PR creation** (instead of direct commit) — Adds GitHub API dependency. Direct commit is simpler.
- **Encrypted reports (age/gpg)** — If the doc repo is private, TLS + repo-level ACLs are sufficient. Revisit for SEC-03 if added.

### Reviewed Todos (not folded)
- **iptables packet-level logging** (from STATE.md Pending Todos) — Unrelated to Result Channel; stays in backlog for Phase 17.

</deferred>

---

*Phase: 16-result-channel*
*Context gathered: 2026-04-12*
