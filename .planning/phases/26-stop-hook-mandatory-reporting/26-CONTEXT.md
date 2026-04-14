# Phase 26: Stop Hook & Mandatory Reporting — Context

**Gathered:** 2026-04-14
**Status:** Ready for research and planning
**Mode:** User-delegated auto-chain (user said "you decide" — Claude selected all gray areas and recommended options)

<domain>
## Phase Boundary

Every Claude session (headless AND interactive) produces a spool file before exit. A local-only Stop hook enforces the write — re-prompting Claude exactly once if the file is absent, then yielding regardless. A host-side async shipper calls `publish_docs_bundle` after Claude exits with jittered retry and audit logging on failure.

**Scope anchor:** Write-enforce (Stop hook) + push (shipper). No dashboard, no cross-session dedup, no report UI.

**The two mechanisms:**
1. **Stop hook** — runs INSIDE the container via `claude/settings.json`. Checks for spool file. Re-prompts once if missing. Zero network calls (SPOOL-02).
2. **Host-side shipper** — runs on the host as a forked background function after `docker compose exec` returns. Calls `publish_docs_bundle`. Retries with jitter. Never blocks next spawn (SPOOL-03).

</domain>

<decisions>
## Implementation Decisions

### D-01: Spool path — reuse existing log volume

- **Location inside container:** `/var/log/claude-secure/spool.md`
- **Location on host:** `$LOG_DIR/spool.md` (already mounted as `${LOG_DIR:-./logs}:/var/log/claude-secure` in docker-compose.yml)
- **Zero new docker-compose.yml entries** — the log volume is already writable on both ends
- **One spool per profile:** The log volume is per-profile (via `$LOG_PREFIX`). Since only one Claude session runs per profile at a time, a fixed `spool.md` filename is safe. The shipper deletes it after a successful push so a fresh session starts clean.

### D-02: Stop hook script — new `stop-hook.sh` in claude/hooks/

- **File:** `claude/hooks/stop-hook.sh` (installed to `/etc/claude-secure/hooks/stop-hook.sh` by Dockerfile.claude)
- **Registered in:** `claude/settings.json` under `hooks.Stop` (alongside existing `hooks.PreToolUse`)
- **Input:** JSON from stdin (same pattern as pre-tool-use.sh) — researcher must verify exact schema via Context7

**Script logic:**
```
1. Parse input JSON from stdin
2. Check `stop_hook_active` field — if true (Claude is re-prompting attempt #2), yield immediately:
   output: {"decision": "approve"} (or equivalent — verify with Context7)
3. Check for /var/log/claude-secure/spool.md existence
4. If present → yield (report already written): output approve
5. If absent → block with re-prompt message (verify exact output format with Context7):
   output: {"decision": "block", "reason": "<re-prompt message>"}
```

**⚠️ RESEARCH FLAG:** The researcher MUST verify with Context7 before planning:
- Exact JSON field name for "this is already a re-prompt" guard (tentatively `stop_hook_active`)
- Exact output format for block-with-reason vs approve from a Stop hook
- Whether Stop hooks receive stdin JSON (like PreToolUse) or something different
- Whether `matcher` applies to Stop hooks or if they always fire

### D-03: Re-prompt message — hardcoded in stop-hook.sh

No template infrastructure needed. The re-prompt message is hardcoded in the Stop hook script:

```
Write your session report to /var/log/claude-secure/spool.md before exiting.
Use these exact section headings (H2 markdown):
## Goal
## Where Worked
## What Changed
## What Failed
## How to Test
## Future Findings
```

Rationale: the Stop hook is a small bash script running in the container where template resolution would require mounting additional files. Hardcoded is simpler and sufficient for this use case. If operators need custom messages, that's a future phase.

### D-04: Spool file format — bundle.md (6-section) directly

The spool file IS the final report body. Claude writes the 6-section markdown directly to `/var/log/claude-secure/spool.md`. No intermediate conversion. The shipper passes it to `publish_docs_bundle($LOG_DIR/spool.md, ...)` after Claude exits.

- `verify_bundle_sections` runs in the shipper before publishing — if sections are missing, log the error but still publish best-effort (broken report > no report, per Phase 16 D-17 philosophy)
- No re-prompt on the shipper side — the `stop_hook_active` guard already limited re-prompts to one attempt

### D-05: Shipper execution model — fork-to-background from spawn paths

New function: `run_spool_shipper()` in `bin/claude-secure`.

**Called from:**
1. `do_spawn` — after `docker compose exec -T claude claude` returns (headless path, line ~2159)
2. Interactive spawn `exec -it` path — after `docker compose exec -it claude claude` returns (line ~2850)

**Execution model:**
```bash
run_spool_shipper() {
  local spool_file="$LOG_DIR/spool.md"
  [ -f "$spool_file" ] || return 0  # no spool = no report configured, silent skip

  # Fork to background: publish_docs_bundle call with jittered retry
  # 3 attempts: delays 0s, 5s, 10s (jittered +/- 2s)
  # On success: rm "$spool_file"
  # On failure after 3 attempts: append to audit JSONL (spool_status: "push_failed"),
  #   leave spool.md for next run's shipper to retry
  # disown: never blocks return
  ( _spool_shipper_loop "$spool_file" ) &
  disown
}
```

**Session ID for publish_docs_bundle:**
- Headless path: `$delivery_id` (already in do_spawn scope) passed to shipper
- Interactive path: `$(uuidgen | tr '[:upper:]' '[:lower:]')` — generate at call site

**SPOOL-03 compliance:** Background fork + disown means the spawn function returns immediately after forking. Failure audit goes to `$LOG_DIR/${LOG_PREFIX}spool-audit.jsonl` (new file, separate from executions.jsonl to avoid line-locking with do_spawn's write).

### D-06: Interactive session coverage — both headless AND interactive

The Stop hook fires from `claude/settings.json` which applies to all Claude Code sessions regardless of how they're invoked. No code change needed for the hook itself.

The `run_spool_shipper` call must be added to BOTH spawn paths:
1. Headless: `do_spawn` after claude exits (~line 2159)
2. Interactive: the `exec -it` path at line ~2850 (after `docker compose exec -it claude claude --dangerously-skip-permissions` returns)

### D-07: Spool cleanup guard

If a previous session left a stale `spool.md` (shipper failed 3 times), the next session's Stop hook will see it as "already written" and not re-prompt — this is acceptable. The shipper at next spawn start should attempt a push of the stale file before the new session begins.

Add to spawn preamble: if `$LOG_DIR/spool.md` exists at spawn start → run shipper first (inline, not forked), then proceed with spawn. This handles leftover spools from crashed sessions.

### Claude's Discretion
- Exact bash structure of `_spool_shipper_loop` retry function (3-attempt jitter implementation)
- Whether `spool-audit.jsonl` entries share schema with Phase 16 `executions.jsonl` (recommended: yes, subset)
- Test escape hatch var name for spool tests (recommend: `CLAUDE_SECURE_SKIP_SPOOL_SHIPPER`)
- Wave structure for plans (recommend: Wave 0 failing tests, Wave 1 stop-hook.sh + settings.json, Wave 2 run_spool_shipper + spawn integration, Wave 3 installer + README)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Prior Phase Contracts (required reading)
- `.planning/phases/16-result-channel/16-CONTEXT.md` — D-17/D-18 audit-always/push-best-effort philosophy; report push failure handling pattern
- `.planning/phases/24-multi-file-publish-bundle/24-RESEARCH.md` — `publish_docs_bundle` signature, spool format, `verify_bundle_sections` contract
- `.planning/phases/25-context-read-bind-mount/25-RESEARCH.md` — `/agent-docs:ro` bind mount pattern (model for spool writable mount)

### Project-level
- `.planning/REQUIREMENTS.md` — SPOOL-01, SPOOL-02, SPOOL-03 definitions
- `.planning/PROJECT.md` — Core value, v4.0 milestone goal
- `CLAUDE.md` — Tech stack constraints

### Implementation References (verify line numbers before planning)
- `claude/settings.json` — existing `hooks.PreToolUse` entry; add `hooks.Stop` here
- `claude/Dockerfile` — COPY hooks pattern at line 20; `stop-hook.sh` goes alongside `pre-tool-use.sh`
- `docker-compose.yml:31` — log volume mount `${LOG_DIR:-./logs}:/var/log/claude-secure` — the spool path rides this
- `bin/claude-secure:2159` — `docker compose exec -T claude claude` call in do_spawn — shipper call goes after this
- `bin/claude-secure:2850` — interactive `exec -it claude` path — second shipper call site
- `bin/claude-secure:1658` — `publish_docs_bundle()` function signature
- `bin/claude-secure:1060` — `verify_bundle_sections()` function
- `claude/hooks/pre-tool-use.sh` — existing hook script pattern for stdin JSON reading
- `tests/test-phase24.sh` — existing bundle test scaffold to extend for spool integration tests
- `tests/test-phase25.sh` — existing Phase 25 test pattern (docker-gated tests)

### Must-Verify at Plan Time (Context7)
- **Stop hook API:** Input JSON schema, `stop_hook_active` field name, output format for block/approve
- **settings.json Stop hook registration:** Whether `matcher` field applies, exact key structure

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `publish_docs_bundle()` at `bin/claude-secure:1658` — ready to call; takes `body_path` + `session_id` + env (PROFILE, DOCS_REPO_TOKEN etc.)
- `verify_bundle_sections()` at `bin/claude-secure:1060` — validates 6 mandatory H2 sections; returns 0/1
- Log volume mount in `docker-compose.yml:31` — already writable at `$LOG_DIR/` on host, `/var/log/claude-secure/` in container
- `claude/hooks/pre-tool-use.sh` — existing pattern for stdin-driven hook scripts: `INPUT=$(cat)` → parse with jq → output JSON decision
- `claude/settings.json` — existing hooks registration; Stop hook goes in the same `hooks` object
- `spawn_cleanup` trap + `_CLEANUP_FILES` array — for spool.md cleanup registration (add after successful push)
- `push_with_retry()` — already has 3-attempt rebase loop (from Phase 17); `run_spool_shipper` loop can reference same pattern

### Integration Points
- **`do_spawn` line ~2159** — After `claude_stdout=$(docker compose exec -T ...)`, add `run_spool_shipper "$delivery_id"`
- **Interactive spawn line ~2850** — After `docker compose exec -it claude claude --dangerously-skip-permissions`, add `run_spool_shipper "$(uuidgen | tr '[:upper:]' '[:lower:]')"`
- **Spawn preamble (stale spool guard)** — Near top of do_spawn / interactive path, before containers start: if `$LOG_DIR/spool.md` exists, run shipper inline (blocking, no retry limit) to drain prior session's spool before new session begins
- **`claude/Dockerfile`** — Add `COPY hooks/stop-hook.sh /etc/claude-secure/hooks/` + chmod line (mirrors existing pre-tool-use.sh treatment)
- **`install.sh`** — No change needed for shipper (pure bin/claude-secure addition); may need `chmod 555` on `stop-hook.sh` if installer rebuilds the claude image
- **`tests/run-tests.sh`** — Register new `tests/test-phase26.sh` file

### Patterns Established
- **PreToolUse hook stdin pattern:** `INPUT=$(cat)` → `echo "$INPUT" | jq -r '.field'` → output JSON — use same in stop-hook.sh
- **Background fork pattern:** `( long_running_function ) & disown` — used in reaper; same here for shipper
- **Wave 0 failing tests:** Phase 12/13/14/15/16/17/24/25 all started with RED Wave 0 tests. Phase 26 follows.
- **Test escape hatch vars:** `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` (Phase 16), `CLAUDE_SECURE_EXEC` (Phase 15) — add `CLAUDE_SECURE_SKIP_SPOOL_SHIPPER` for unit tests

</code_context>

<specifics>
## Specific Ideas

- **One spool per profile at a time:** Fixed filename `spool.md` is safe because one profile = one active session. Session IDs are for the shipper's `publish_docs_bundle` call, not for the filename.
- **Stale spool drain:** Before each spawn, if `$LOG_DIR/spool.md` exists, drain it inline first. Prevents accumulation from crashes while ensuring leftover reports eventually reach the doc repo.
- **stop_hook_active guard:** This is the key invariant for SPOOL-04 — WITHOUT it, the hook would re-prompt infinitely. The researcher MUST lock this field name down via Context7 before planning starts.
- **verify_bundle_sections best-effort:** If Claude's re-prompted report is still malformed (SPOOL-04 "second attempt still fails"), publish it anyway. Broken report is better than no report. The function's non-zero return is logged to audit but doesn't prevent the push.
- **Spool audit JSONL schema (suggested):**
  ```json
  {"ts": "...", "profile": "...", "session_id": "...", "spool_status": "pushed|push_failed|stale_drained", "attempt": 1, "report_url": "...", "error": ""}
  ```
</specifics>

<deferred>
## Deferred Ideas

- **Operator-customizable re-prompt template** — If the hardcoded message proves insufficient. Phase 27 or backlog.
- **Multi-spool queue** (if concurrent sessions per profile ever needed) — Session-ID-suffixed filenames e.g. `spool-${SESSION_ID}.md`. Not needed now (one session per profile).
- **Spool encryption** — For sensitive reports. Revisit in SEC-03.
- **Stop hook for non-report tasks** — Some interactive sessions may genuinely not need a report (e.g., quick queries). A `CLAUDE_SECURE_SKIP_REPORT=1` env var that the user sets before spawn would suppress the Stop hook's re-prompt. Backlog.
- **Cross-session spool dedup** — Detecting duplicate reports (same session re-spawned). Out of scope.

### Reviewed Todos (not folded)
- **iptables packet-level logging** — Unrelated to Stop Hook; stays in pending todos.

</deferred>

---

*Phase: 26-stop-hook-mandatory-reporting*
*Context gathered: 2026-04-14*
