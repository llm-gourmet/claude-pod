# Phase 26: Stop Hook & Mandatory Reporting — Research

**Researched:** 2026-04-14
**Domain:** Claude Code Stop hook API + host-side async shipper in bash
**Confidence:** HIGH (Stop hook API verified via official docs + corroborating GitHub source; existing code paths read directly)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01: Spool path — reuse existing log volume**
- Container: `/var/log/claude-secure/spool.md`
- Host: `$LOG_DIR/spool.md` (mounted via existing `docker-compose.yml:31`)
- Zero new volume entries; one spool per profile (fixed filename is safe — one session per profile at a time)
- Shipper deletes after successful push

**D-02: Stop hook script — new `claude/hooks/stop-hook.sh`**
- Installed to `/etc/claude-secure/hooks/stop-hook.sh` by `claude/Dockerfile` (reuses the existing `COPY hooks/` line at Dockerfile:20)
- Registered in `claude/settings.json` under `hooks.Stop` alongside existing `hooks.PreToolUse`
- Reads JSON from stdin (same pattern as `pre-tool-use.sh`)
- Logic:
  1. Parse stdin JSON
  2. If `stop_hook_active == true` → yield (allow exit)
  3. If `/var/log/claude-secure/spool.md` exists → yield
  4. Else → block with re-prompt reason

**D-03: Re-prompt message — hardcoded in `stop-hook.sh`**
- No template infrastructure; literal string embedded in the script body:
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

**D-04: Spool format — `bundle.md` (6-section) directly**
- Spool IS the final report body; no intermediate conversion
- Shipper calls `publish_docs_bundle "$LOG_DIR/spool.md" "$session_id" ...`
- `verify_bundle_sections` runs, but broken reports publish anyway (Phase 16 D-17 best-effort philosophy)
- No re-prompt on shipper side — `stop_hook_active` guard already limits to one attempt

**D-05: Shipper — `run_spool_shipper()` forked from both spawn paths**
- Called after `docker compose exec ... claude ...` returns in BOTH paths:
  - Headless: `do_spawn`, after line 2159
  - Interactive: `*)` dispatch case, after line 2850
- Execution model: fork `( _spool_shipper_loop "$spool_file" "$session_id" ) & disown`
- 3 attempts with jittered delay; on success `rm "$spool_file"`; on failure append to audit JSONL
- SPOOL-03: background fork + disown ⇒ spawn return is never blocked
- Session IDs:
  - Headless: `$delivery_id` (in do_spawn scope)
  - Interactive: `$(uuidgen | tr '[:upper:]' '[:lower:]')` generated at call site

**D-06: Coverage — headless AND interactive**
- Stop hook fires from `claude/settings.json` regardless of invocation mode (no code change needed for the hook itself)
- `run_spool_shipper` must be added to BOTH spawn paths

**D-07: Spool cleanup guard**
- At spawn preamble (before containers start): if `$LOG_DIR/spool.md` exists → run shipper inline (blocking, non-forked) to drain prior session's stale spool
- Prevents accumulation from crashed sessions

### Claude's Discretion

- Exact bash structure of `_spool_shipper_loop` 3-attempt jitter implementation
- Whether `spool-audit.jsonl` shares schema with Phase 16 `executions.jsonl` (recommended: yes, subset)
- Test escape hatch env var name (recommended: `CLAUDE_SECURE_SKIP_SPOOL_SHIPPER`)
- Wave structure: Wave 0 failing tests → Wave 1 stop-hook + settings → Wave 2 shipper + spawn integration → Wave 3 installer + README

### Deferred Ideas (OUT OF SCOPE)

- Operator-customizable re-prompt template (Phase 27+ / backlog)
- Multi-spool queue with session-id suffixes (not needed; one session per profile)
- Spool encryption (revisit in SEC-03)
- `CLAUDE_SECURE_SKIP_REPORT=1` opt-out env var for interactive "quick query" sessions (backlog)
- Cross-session dedup detection (out of scope)
- iptables packet-level logging (unrelated pending todo)

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SPOOL-01 | Stop hook verifies local report spool file was written before Claude exits — if missing, re-prompts Claude once to produce it | Stop hook API (below) confirms `decision: "block"` + `reason` output re-injects reason as context; `stop_hook_active` field prevents recursion. Hardcoded re-prompt in `stop-hook.sh` (D-03). |
| SPOOL-02 | Stop hook makes no network calls — only checks local spool file (doc repo outage cannot block Claude exit) | Hook script is pure bash + stat + jq + printf. No curl, no DNS. 5-second exit budget verified by DNS-failure integration test (success criterion 2). |
| SPOOL-03 | Host-side async shipper reads spool after Claude exits and pushes to doc repo with jittered backoff — failure logged to audit JSONL, never blocks next spawn | `run_spool_shipper` forks to background with `disown`; spawn path returns immediately. Stale-spool drain at next spawn preamble handles crashed-shipper leftover. |

</phase_requirements>

## Summary

Phase 26 closes the v4.0 loop: Phase 23 bound profiles to doc repos, Phase 24 built the atomic publish bundle, Phase 25 bind-mounted docs read-only for context. Phase 26 enforces that **every** Claude session produces a report — via a Stop hook that blocks exit when the local spool is missing, and a host-side async shipper that publishes after Claude exits without blocking new spawns on failure.

The research flag from the roadmap — "Stop hook API field names must be re-verified" — is now resolved with HIGH confidence from the official docs at `code.claude.com/docs/en/hooks`. All field names, input/output schemas, and settings.json structure are documented below.

**Primary recommendation:** Implement `claude/hooks/stop-hook.sh` as a ~30-line bash script using the same stdin-JSON pattern as `pre-tool-use.sh`; register it in `claude/settings.json` using the SAME nested `{"matcher": "...", "hooks": [...]}` structure as PreToolUse (matcher is ignored for Stop but the schema is accepted); implement `run_spool_shipper()` in `bin/claude-secure` as a fork-and-disown background loop mirroring the existing `push_with_retry` 3-attempt rebase idiom.

## Stop Hook API (Context7/Official Doc Verified)

**Source:** https://code.claude.com/docs/en/hooks (official Claude Code docs, HIGH confidence)
**Corroborating source:** https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/hook-development/SKILL.md (HIGH confidence)

### When it fires
The `Stop` event fires when Claude finishes responding and is about to exit the current turn. The hook can block exit and inject additional context before the turn completes.

### Input JSON Schema (stdin to hook script)

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
  "cwd": "/workspace",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "I've completed the implementation..."
}
```

| Field | Type | Meaning |
|-------|------|---------|
| `session_id` | string | Claude session UUID |
| `transcript_path` | string | Path to the JSONL transcript of this session |
| `cwd` | string | Working directory when the hook fires |
| `permission_mode` | string | `"default"` / `"acceptEdits"` / etc. |
| `hook_event_name` | string | Always `"Stop"` for this event |
| **`stop_hook_active`** | **boolean** | **`true` when this hook is itself running inside a prior Stop-hook-triggered continuation. Use this to prevent infinite loops.** |
| `last_assistant_message` | string | Text of Claude's final response in this turn (useful for inspection but not required here) |

### Output Format (hook stdout)

Stop hooks have TWO valid output paths: **exit codes** or **JSON decision output**. Either works; Phase 26 should use JSON for explicitness.

**Allow exit** (spool exists OR stop_hook_active is true):
```bash
exit 0   # silent approve
```
Or equivalently (explicit JSON):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "Report spool present"
  }
}
```

**Block exit with re-prompt** (spool is missing on first attempt):
```json
{
  "decision": "block",
  "reason": "Write your session report to /var/log/claude-secure/spool.md before exiting. Use these exact section headings (H2 markdown):\n## Goal\n## Where Worked\n## What Changed\n## What Failed\n## How to Test\n## Future Findings"
}
```

When `decision=block`, Claude receives the `reason` text as feedback and continues the turn. When that next turn ends, the Stop hook fires AGAIN — this time with `stop_hook_active=true` — and the hook MUST yield (exit 0) to prevent an infinite loop.

**Alternative exit-code-based block:** `exit 2` with the re-prompt message on stderr is also valid per the docs. JSON is preferred here because the message is multi-line and the semantics are clearer to future readers.

### Recursion Guard — the `stop_hook_active` Pattern

Per the official docs:
> The `stop_hook_active` field tells your hook whether a Stop hook is currently being evaluated. When `true`, your hook is running in response to a prior Stop hook's decision, so take care not to create an infinite loop.

**Canonical bash pattern:**
```bash
INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0   # yield — never re-block a re-prompted turn
fi
```

This directly satisfies SPOOL-04's "re-prompt exactly once" success criterion (listed as #4 in the phase description; note: phase numbered it as "stop_hook_active guard prevents recursive re-prompting").

### Matcher Field Semantics

**Stop hooks do NOT support matchers** (per docs: "Stop... no matcher support... always fires on every occurrence").

However, the settings.json **structure** is the same nested form used by PreToolUse — the `matcher` field is accepted but ignored. This matches the existing `claude/settings.json` format so we don't need a different nesting level.

### settings.json Registration — Exact Format

Existing `claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/etc/claude-secure/hooks/pre-tool-use.sh"
          }
        ]
      }
    ]
  }
}
```

After Phase 26:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/etc/claude-secure/hooks/pre-tool-use.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/etc/claude-secure/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

Note: omit `matcher` from the Stop entry — it would be silently ignored. The nested `hooks` array is retained because that's the documented structure for all hook events.

## Existing Code Analysis

### CONTEXT.md Line-Number Verification

| Reference | Expected | Verified | Notes |
|-----------|----------|----------|-------|
| `verify_bundle_sections` | 1060 | **line 1060** ✓ | Validates 6 H2 sections; returns 0/1 |
| `publish_docs_bundle` | 1658 | **line 1658** ✓ | `body_path`, `session_id`, `summary_line`, `delivery_id` |
| `push_with_retry` | — | **line 1290** | 3-attempt rebase loop; model for shipper retry. **Caveat:** it reads `$REPORT_REPO_TOKEN` directly from env — shipper must ensure DOCS_REPO_TOKEN is projected to REPORT_REPO_TOKEN (already handled by Phase 23 `resolve_docs_alias`) |
| `do_spawn` entry | 1975 | **line 1975** ✓ | |
| `docker compose exec -T claude claude -p` | 2159 | **line 2159** ✓ | Headless Claude call. Shipper call goes AFTER `publish_report` (~line 2234) — see integration note below |
| Interactive `exec -it claude claude` | 2850 | **line 2850** ✓ | Interactive path in top-level `*)` dispatch case |
| `docker-compose.yml` log volume | — | **line 31** | `${LOG_DIR:-./logs}:/var/log/claude-secure` — writable on both ends |
| `claude/Dockerfile` COPY hooks | — | **line 20** | `COPY hooks/ /etc/claude-secure/hooks/` — already globs the directory |
| `_CLEANUP_FILES` array / `spawn_cleanup` | — | **lines 48 / 574** | Use for any ephemeral files the shipper creates |
| `_spawn_error_audit` | — | **line 1845** | Pattern for best-effort audit writes on error paths |

### Reusable Helpers (Drop-In)

1. **`verify_bundle_sections "$body_path"`** (line 1060) — already called inside `publish_docs_bundle` (line 1673), so the shipper does NOT need to call it separately. Broken reports publish anyway.

2. **`publish_docs_bundle "$body_path" "$session_id" "$summary_line" "$delivery_id"`** (line 1658) — the shipper's single entry point for actually pushing. Requires these globals to be set:
   - `PROFILE`, `DOCS_REPO`, `DOCS_REPO_TOKEN`, `DOCS_PROJECT_DIR`, `DOCS_BRANCH`, `CONFIG_DIR`, `LOG_DIR`
   - All are already loaded by `load_profile_config` which runs on both spawn paths before the shipper is invoked.

3. **`push_with_retry` pattern** (line 1290) — already embedded INSIDE `publish_docs_bundle`, so the shipper's retry loop wraps `publish_docs_bundle` as a unit, not around individual push calls.

4. **`write_audit_entry` pattern** (line 1209) — 14-argument canonical audit writer. The spool shipper should write to a **separate file** (`spool-audit.jsonl`) to avoid O_APPEND PIPE_BUF collision with `do_spawn`'s `executions.jsonl` writes (Phase 16 D-06 discipline).

5. **Background fork pattern:** the existing codebase does NOT use `disown` anywhere (grep confirms zero hits). CONTEXT.md notes "used in reaper" but reaper runs as a systemd-managed process, not a forked subshell. Phase 26 introduces the `( ... ) & disown` pattern — document it in the wave's code comments.

### `pre-tool-use.sh` Pattern (for `stop-hook.sh` reuse)

Key structural elements from `claude/hooks/pre-tool-use.sh`:

```bash
#!/bin/bash
set -euo pipefail

INPUT=$(cat)    # single-read stream, must be the first operational line

# Optional logging via LOG_HOOK env var
LOG_FILE="/var/log/claude-secure/${LOG_PREFIX:-}hook.log"
log() { [ "${LOG_HOOK:-0}" = "1" ] && echo "[$(date -Iseconds)] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# Decision helpers
deny() { jq -n --arg reason "$1" '{hookSpecificOutput: {...}}'; exit 0; }
allow() { exit 0; }
```

**Reuse for `stop-hook.sh`:**
- Same `INPUT=$(cat)` first-line pattern
- Same `LOG_HOOK` env var for structured logging (write to `${LOG_PREFIX:-}hook.log` + `hook.jsonl`)
- Same jq-based JSON construction for the block/approve output

### Integration Points in `do_spawn` (line 2159+)

Looking at the post-Claude-exit flow (lines 2159–2258), the existing order is:
1. `claude_stdout=$(docker compose exec -T ...)` (line 2159)
2. Validate `result` field (lines 2165–2172)
3. Build envelope (2191–2200)
4. Extract audit fields (2203–2205)
5. `publish_report` — the Phase 16 legacy report path (2224)
6. `write_audit_entry` — executions.jsonl (2238–2252)
7. Emit envelope to stdout (2255)
8. Return claude_exit (2258)

**Where to add `run_spool_shipper`:** Between step 1 and step 3, or after step 6 — both are defensible. **Recommendation:** after step 6 (line 2253 area), so that:
- `executions.jsonl` gets its line first (single atomic O_APPEND, no interleaving)
- The background fork happens AFTER all foreground audit writes finish
- The shipper's own audit writes go to a separate `spool-audit.jsonl` file

**Interactive path (line 2850):**
```bash
docker compose exec -it claude claude --dangerously-skip-permissions
# ↓ ADD HERE
run_spool_shipper "$(uuidgen | tr '[:upper:]' '[:lower:]')"
```
The interactive path has no `delivery_id` in scope, so the call site must generate one.

### Stale Spool Drain Integration Point (D-07)

**Headless:** the logical place is before `fetch_docs_context` (line 2109) — after `load_profile_config` has set `LOG_DIR` but before any container work starts. Running the shipper inline here ensures any prior stale spool is drained before the new session begins writing to the same path.

**Interactive:** in the `*)` case, after `mkdir -p "$LOG_DIR"` (line 2836) and before `cleanup_containers` (line 2839).

### PAT / Env Variable Caveat for Shipper

`publish_docs_bundle` requires:
- `DOCS_REPO_TOKEN` in the environment (line 1687 check)
- But `push_with_retry` internally reads `$REPORT_REPO_TOKEN` (line 1298)

Phase 23's `resolve_docs_alias` already back-fills `REPORT_REPO_TOKEN=DOCS_REPO_TOKEN` when the new-style field is used. The shipper function runs in the SAME process (before fork) and thus inherits both vars via the already-loaded profile config. **After fork into background**, the child subshell inherits via Unix process semantics — no re-loading needed.

**Pitfall to avoid:** Do NOT `unset` any *_TOKEN vars in the main process before spawning the shipper subshell. The subshell's env is snapshotted at fork time.

## Implementation Approach

### 1. `claude/hooks/stop-hook.sh` (D-02, D-03)

Target size: ~40 lines. Structure:

```bash
#!/bin/bash
# stop-hook.sh — Stop hook for claude-secure mandatory reporting (SPOOL-01, SPOOL-02).
# Zero network calls (SPOOL-02). Re-prompts once if spool is missing; yields on
# stop_hook_active=true to prevent infinite loops (success criterion 4).
set -euo pipefail

SPOOL_FILE="/var/log/claude-secure/spool.md"
LOG_FILE="/var/log/claude-secure/${LOG_PREFIX:-}hook.log"

INPUT=$(cat)

log() {
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    echo "[$(date -Iseconds)] stop-hook: $*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# Recursion guard: if we are running as a re-prompt continuation, yield.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  log "yielding (stop_hook_active=true)"
  exit 0
fi

# Spool present? yield.
if [ -f "$SPOOL_FILE" ]; then
  log "yielding (spool exists: $SPOOL_FILE)"
  exit 0
fi

# Spool missing — block exit with re-prompt (JSON decision).
log "blocking (spool missing); re-prompting"
REPROMPT=$(cat <<'EOF'
Write your session report to /var/log/claude-secure/spool.md before exiting.
Use these exact section headings (H2 markdown):
## Goal
## Where Worked
## What Changed
## What Failed
## How to Test
## Future Findings
EOF
)
jq -n --arg reason "$REPROMPT" '{decision: "block", reason: $reason}'
exit 0
```

**Security properties:**
- Zero curl/wget/nslookup calls → SPOOL-02 ✓
- No whitelisted domains needed → not a validator path
- stdin-only input → no env var injection surface
- `set -euo pipefail` + input sanity ensures failure modes are loud

**File permissions:** Mirror `pre-tool-use.sh` — chmod 555 in Dockerfile line 23 (already globs `*.sh`, so adding `stop-hook.sh` to the same directory handles perms automatically).

### 2. `claude/settings.json` (D-02)

Add the `Stop` key alongside `PreToolUse`. See "Stop Hook API" → settings.json Registration above for the exact JSON.

**Test hook for settings.json:** JSON-schema validity via `jq . claude/settings.json`. Structural test in Wave 0 asserts `.hooks.Stop[0].hooks[0].command == "/etc/claude-secure/hooks/stop-hook.sh"`.

### 3. `run_spool_shipper()` + `_spool_shipper_loop()` (D-05)

```bash
# Add near publish_docs_bundle (line ~1658) in bin/claude-secure.

# Phase 26 SPOOL-03: fork-and-disown async shipper. Never blocks the spawn
# return. Called from do_spawn (~line 2253) and interactive *) (~line 2850).
run_spool_shipper() {
  local session_id="$1"
  local spool_file="${LOG_DIR}/spool.md"

  # Test escape hatch (Rule 3 deviation pattern — see Phase 16 D-23):
  if [ "${CLAUDE_SECURE_SKIP_SPOOL_SHIPPER:-0}" = "1" ]; then
    return 0
  fi

  # No spool = no report (D-07 silent skip; operator didn't wire reporting).
  [ -f "$spool_file" ] || return 0

  # Fork to background. disown detaches the child PID from the parent shell
  # so spawn return is never gated on shipper completion (SPOOL-03).
  ( _spool_shipper_loop "$spool_file" "$session_id" ) &
  disown
}

# Inline blocking variant (D-07): drains a stale spool BEFORE new session
# starts. Same loop body, no background fork.
run_spool_shipper_inline() {
  local session_id="$1"
  local spool_file="${LOG_DIR}/spool.md"
  [ -f "$spool_file" ] || return 0
  _spool_shipper_loop "$spool_file" "$session_id"
}

# Shared retry body. Writes outcome to $LOG_DIR/${LOG_PREFIX}spool-audit.jsonl.
_spool_shipper_loop() {
  local spool_file="$1" session_id="$2"
  local attempt=0 max_attempts=3
  local summary="Phase 26 spool: ${session_id}"  # fallback; real headline can come from first H2
  local delivery_id="${session_id}"              # publish_docs_bundle accepts either
  local rc report_url=""

  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt+1))
    if report_url=$(publish_docs_bundle "$spool_file" "$session_id" "$summary" "$delivery_id" 2>&1 | tail -1); then
      _spool_audit_write "pushed" "$attempt" "$report_url" ""
      rm -f "$spool_file"
      return 0
    fi
    rc=$?
    # Jittered backoff: 0s, 5±2s, 10±2s
    if [ "$attempt" -lt "$max_attempts" ]; then
      local base=$((attempt * 5))
      local jitter=$(( (RANDOM % 5) - 2 ))   # -2..+2
      local delay=$(( base + jitter ))
      [ "$delay" -lt 0 ] && delay=0
      sleep "$delay"
    fi
  done

  _spool_audit_write "push_failed" "$attempt" "" "publish_docs_bundle rc=$rc"
  # Leave spool.md in place for the next spawn's inline drain (D-07).
  return 1
}

_spool_audit_write() {
  local status="$1" attempt="$2" report_url="$3" error="$4"
  mkdir -p "$LOG_DIR"
  local audit_file="$LOG_DIR/${LOG_PREFIX:-}spool-audit.jsonl"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -cn \
    --arg ts "$ts" \
    --arg profile "${PROFILE:-}" \
    --arg status "$status" \
    --arg report_url "$report_url" \
    --arg error "${error:0:200}" \
    --argjson attempt "$attempt" \
    '{ts:$ts, profile:$profile, spool_status:$status, attempt:$attempt, report_url:($report_url|select(length>0)), error:($error|select(length>0))}' \
    >> "$audit_file" 2>/dev/null || true
}
```

**Jitter rationale:** Matches CONTEXT.md D-05 spec ("delays 0s, 5s, 10s (jittered +/- 2s)"). The `RANDOM % 5 - 2` is `$bash`-native and avoids `awk` dependencies in the shipper tight loop.

**Why `publish_docs_bundle` output is captured via `tail -1`:** The function's contract (header comment at line 1657) says "stdout last line = report URL". Everything else is diagnostic output.

### 4. Integration Call Sites

**Headless** (`do_spawn`, after line 2253 `write_audit_entry`):
```bash
# Phase 26 SPOOL-03: fork-and-disown spool shipper after audit write.
run_spool_shipper "$_audit_session"   # use claude session_id, not delivery_id
```

Rationale for using `$_audit_session` instead of `$delivery_id`: the session_id is what `publish_docs_bundle` expects and is extracted from Claude's output at line 2205. `delivery_id` is webhook-scoped.

**Interactive** (after line 2850):
```bash
docker compose exec -it claude claude --dangerously-skip-permissions
run_spool_shipper "$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d - || echo "manual-$$")"
```

**Stale drain** (headless, before line 2109 `fetch_docs_context`; interactive, after line 2836 `mkdir -p "$LOG_DIR"`):
```bash
# Phase 26 D-07: drain any leftover spool from a prior crashed session.
run_spool_shipper_inline "$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d - || echo "drain-$$")"
```

### 5. Dockerfile + install.sh

**`claude/Dockerfile`:** NO CHANGE NEEDED. Line 20 already does `COPY hooks/ /etc/claude-secure/hooks/` which copies the entire directory. Adding `claude/hooks/stop-hook.sh` to the repo makes it land automatically on the next image rebuild. Lines 22–23 already `chmod 555` all `*.sh` files in that directory.

**`install.sh`:** NO CHANGE NEEDED for the shipper (pure `bin/claude-secure` addition). The installer may need a note in the README pointing operators to rebuild the claude image if they have a pre-Phase-26 cache, but the `docker compose up -d --build` invocation at spawn time rebuilds automatically when files change.

## Runtime State Inventory

Phase 26 is additive (new hook script + new bash functions). Nothing is renamed or migrated.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — `spool.md` is a NEW file created fresh per session and deleted on successful push | None |
| Live service config | `claude/settings.json` needs a new `.hooks.Stop[]` entry (add-only; existing PreToolUse preserved verbatim) | Edit settings.json in-place (single file in git) |
| OS-registered state | None — Stop hook fires from settings.json at runtime, not from a persistent OS registration | None |
| Secrets/env vars | `DOCS_REPO_TOKEN` must be in scope when shipper subshell forks. Already loaded by `load_profile_config` before spawn. No new secret names. | None — verified by reading `publish_docs_bundle:1686` precondition check |
| Build artifacts | None — no compiled deliverables; bash scripts + JSON configs only | None — `docker compose up --build` will rebuild claude image if Dockerfile touches new file |

## Common Pitfalls

### Pitfall 1: `stop_hook_active` defaulted to false is wrong (HIGH severity)

**What goes wrong:** A bash script reading `jq -r '.stop_hook_active'` returns the literal string `"null"` or `"false"` depending on whether the field is present. A naive comparison `if [ "$var" = "true" ]` works, but `if [ "$var" != "false" ]` breaks (null != false).

**How to avoid:** Use `jq -r '.stop_hook_active // false'` (the `//` operator coerces missing/null to false) and compare strictly with `= "true"`.

**Warning sign:** A re-prompted session that still doesn't write the spool triggers an infinite Stop→continue→Stop loop, eventually hitting Claude's built-in loop cap. **Test for this** with a deliberately broken template (success criterion 4).

### Pitfall 2: Foregrounded shipper blocks spawn exit (HIGH severity, blocks SPOOL-03)

**What goes wrong:** Forgetting `disown` after `&` means the backgrounded child is still in the parent shell's job table. When the parent function returns, bash's cleanup may wait for jobs depending on shell options (`wait`, `SIGCHLD` trap from `spawn_cleanup`). The shipper's publish attempt with network retries could block spawn return by up to 30+ seconds.

**How to avoid:** Always `( _spool_shipper_loop ... ) & disown` — the subshell + disown combo fully detaches. Verify with a test that measures wall-clock time between `run_spool_shipper` call and function return (< 100ms).

**Warning sign:** Integration test reporting "DNS failure integration test: spawn returned after 28s" (should be <5s per success criterion 2).

### Pitfall 3: Shipper subshell inherits an unset-before-fork env var (MEDIUM severity)

**What goes wrong:** If any code path between `load_profile_config` and `run_spool_shipper` calls `unset DOCS_REPO_TOKEN` (for example, a defensive cleanup step), the backgrounded subshell inherits the unset state and `publish_docs_bundle` bails at line 1687.

**How to avoid:** Do NOT unset credential vars between profile load and shipper fork. Add a shipper-side sanity check (fail fast with clear message) to catch this early.

**Warning sign:** `spool-audit.jsonl` shows repeated `push_failed` with error `"DOCS_REPO_TOKEN missing from profile env"`.

### Pitfall 4: Audit JSONL line-locking collision (MEDIUM severity)

**What goes wrong:** If `spool-audit.jsonl` and `executions.jsonl` are the SAME file, concurrent appends from multiple spawns of the same profile can interleave inside a single 4096-byte O_APPEND write. Phase 16 enforces a < 4095-byte line cap to preserve atomicity, but that's per-line, not per-file.

**How to avoid:** CONTEXT.md D-05 already mandates a separate file (`spool-audit.jsonl`). **Do not try to be clever and merge them.**

**Warning sign:** Malformed JSONL lines in executions.jsonl under high-concurrency load tests.

### Pitfall 5: `publish_docs_bundle` requires `CONFIG_DIR/profiles/$PROFILE/.env` to be readable (MEDIUM severity)

**What goes wrong:** The backgrounded shipper inherits `PROFILE` and `CONFIG_DIR` but the `.env` file on disk is unchanged. `publish_docs_bundle` calls `redact_report_file` which reads the .env (line 1697). If the shipper runs long enough for the main process to exit and a *different* profile to start, the .env could be in flux.

**How to avoid:** The shipper is short-lived (max ~15s of retries) and profiles have their own $LOG_DIR so cross-contamination is unlikely. Still, document that `spool.md` MUST be pushed for profile P BEFORE spawning a different profile — or accept that stale-drain happens on the next P spawn.

**Warning sign:** Shipper audit shows PAT errors immediately after multi-profile test runs.

### Pitfall 6: Hook stdin JSON not actually JSON (LOW severity)

**What goes wrong:** Claude Code 2.x passes a stringified JSON object via stdin; Claude Code 3.x may evolve this. A `jq` parse failure in the hook should fail-safe toward "allow exit" (don't trap the user) or fail-loud.

**How to avoid:** Wrap the `jq` call in a fallback: `STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")`. If JSON is malformed, default to `false` (process normally, so spool check still runs) rather than locking the user out.

## Code Examples

### Example 1: Idiomatic stdin-JSON hook with fallback

```bash
# Source: claude/hooks/pre-tool-use.sh (pattern confirmed in repo)
INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
```

### Example 2: JSON decision output for block-with-reason

```bash
# Source: https://code.claude.com/docs/en/hooks (official)
jq -n --arg reason "$REPROMPT" '{decision: "block", reason: $reason}'
```

### Example 3: Fork-and-disown background pattern

```bash
# Standard bash idiom; confirmed absent from existing codebase so Phase 26
# introduces it.
( _spool_shipper_loop "$spool_file" "$session_id" ) &
disown
```

### Example 4: Reusing publish_docs_bundle with last-line URL extraction

```bash
# Source: bin/claude-secure:1657 — function contract comment says
# "stdout last line = report URL for HTTPS, or rel path for file://"
report_url=$(publish_docs_bundle "$spool_file" "$session_id" "$summary" "$delivery_id" 2>&1 | tail -1)
```

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash 5+ | stop-hook.sh, shipper | ✓ | via Dockerfile node:22-slim + host brew bash on macOS | — |
| jq | stop-hook.sh stdin parse + shipper audit writes | ✓ | installed in both container (Dockerfile line 6) and host (install.sh requirement) | — |
| uuidgen | interactive session_id generation | ✓ | `uuid-runtime` in Dockerfile line 6 | `$$`-based fallback in shipper sketch |
| git (host) | `publish_docs_bundle` clone + push | ✓ | pre-existing from Phase 16 | — |
| curl/wget | NONE for stop hook (SPOOL-02 forbids) | n/a | hook has zero network | — |
| docker compose | unchanged | ✓ | already required by all spawn paths | — |

**Missing dependencies with no fallback:** None. All tools are already in both host and container environments.

**Missing dependencies with fallback:** `uuidgen` fallback to `$$` is already used elsewhere in the codebase (line 1849 `_spawn_error_audit`), so the shipper can reuse the pattern.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash unit test harness (`run_test` / `PASS=0` / `FAIL=0` pattern; no external framework) |
| Config file | `tests/test-map.json` (requirement → test mapping) |
| Quick run command | `bash tests/test-phase26.sh <single_test_name>` |
| Full suite command | `bash tests/test-phase26.sh` |
| Framework install | None needed (bash + jq + git are baseline) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SPOOL-01 | Missing spool triggers re-prompt once | unit | `bash tests/test-phase26.sh test_stop_hook_reprompts_when_spool_missing` | ❌ Wave 0 |
| SPOOL-01 | Present spool yields cleanly | unit | `bash tests/test-phase26.sh test_stop_hook_yields_when_spool_present` | ❌ Wave 0 |
| SPOOL-01 | settings.json Stop entry registered | structural | `bash tests/test-phase26.sh test_settings_json_has_stop_hook` | ❌ Wave 0 |
| SPOOL-01 | stop_hook_active=true yields (recursion guard / sc #4) | unit | `bash tests/test-phase26.sh test_stop_hook_yields_on_stop_hook_active_true` | ❌ Wave 0 |
| SPOOL-02 | Zero network calls (grep for curl/wget/nslookup in script) | static | `bash tests/test-phase26.sh test_stop_hook_no_network_calls` | ❌ Wave 0 |
| SPOOL-02 | DNS failure does not block exit (5s budget) | integration | `bash tests/test-phase26.sh test_stop_hook_dns_failure_exits_fast` | ❌ Wave 0 |
| SPOOL-03 | Shipper forks and returns immediately (< 100ms) | unit | `bash tests/test-phase26.sh test_run_spool_shipper_returns_immediately` | ❌ Wave 0 |
| SPOOL-03 | Successful push deletes spool | unit | `bash tests/test-phase26.sh test_shipper_deletes_spool_on_success` | ❌ Wave 0 |
| SPOOL-03 | Failed push logs to spool-audit.jsonl with retry counter | unit | `bash tests/test-phase26.sh test_shipper_logs_push_failed_with_attempt` | ❌ Wave 0 |
| SPOOL-03 | Failing shipper run never blocks new spawn | integration | `bash tests/test-phase26.sh test_stale_spool_drain_before_new_session` | ❌ Wave 0 |
| SPOOL-03 | Jittered retry delays (0s, 5s±2, 10s±2) | unit | `bash tests/test-phase26.sh test_shipper_retry_delays_in_expected_range` | ❌ Wave 0 |
| SPOOL-03 | Audit JSONL schema validates | unit | `bash tests/test-phase26.sh test_spool_audit_jsonl_parseable` | ❌ Wave 0 |
| (D-04) | Broken-sections report publishes anyway (best-effort) | unit | `bash tests/test-phase26.sh test_shipper_publishes_malformed_best_effort` | ❌ Wave 0 |
| (D-07) | Stale spool drains inline at spawn start | integration | `bash tests/test-phase26.sh test_stale_spool_drained_at_spawn_preamble` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase26.sh` (phase-only; ~15s if mocked, longer with docker)
- **Per wave merge:** `bash tests/test-phase26.sh && bash tests/test-phase24.sh && bash tests/test-phase25.sh` (verify upstream contracts still hold)
- **Phase gate:** Full `bash tests/test-phase1.sh ... test-phase26.sh` green; docker smoke of test #6 (DNS failure exit budget) on real `docker compose` before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test-phase26.sh` — harness + all 14 test stubs (failing by default per Nyquist RED-before-GREEN)
- [ ] `tests/fixtures/profile-26-spool/` — minimal fixture profile with file:// bare docs_repo (mirror Phase 24/25 fixture shape)
- [ ] `tests/fixtures/spools/valid-bundle.md` — 6-section valid spool
- [ ] `tests/fixtures/spools/broken-missing-section.md` — 5-section malformed spool for SPOOL-04 test
- [ ] `tests/fixtures/stop-hook-inputs/*.json` — stdin fixtures: {stop_hook_active:false}, {stop_hook_active:true}, malformed-json
- [ ] `tests/test-map.json` — add SPOOL-01/02/03 keys + `paths: ["claude/hooks/stop-hook.sh", "tests/test-phase26.sh", "tests/fixtures/profile-26-spool/**"] → ["test-phase26.sh"]`
- [ ] CLAUDE_SECURE_SKIP_SPOOL_SHIPPER hook-out in shipper for determinism
- [ ] DNS-failure simulation technique: run stop-hook.sh inside an offline network namespace OR use a `getent`-busting `PATH` shim (similar to Phase 17 mock docker pattern)

## Project Constraints (from CLAUDE.md)

The project-level CLAUDE.md imposes these directives relevant to Phase 26:

1. **Bash 5.x + jq + curl + uuidgen toolchain only** (CLAUDE.md "Supporting Libraries: Bash hooks" row). Python for hook logic is explicitly called out as not-yet-justified. Phase 26 stays within this constraint.

2. **Hook scripts must be root-owned and immutable by the Claude process** (CLAUDE.md "Constraints" section). Verified: `claude/Dockerfile:21-23` does `chown -R root:root /etc/claude-secure/hooks/ && chmod 555`. The new `stop-hook.sh` inherits this automatically because the `COPY hooks/` glob picks it up and the chmod glob `*.sh` applies to the whole directory.

3. **Buffered, no streaming** (CLAUDE.md "Architecture: Proxy"). Irrelevant to Phase 26 — proxy untouched.

4. **No NFQUEUE / no kernel module dependency** (CLAUDE.md "Constraints"). Irrelevant to Phase 26 — no kernel-level work.

5. **Minimize supply-chain surface — prefer stdlib** (CLAUDE.md "What NOT to Use" table, "Avoid http-proxy / axios / got" row). Phase 26 uses only baseline CLI tools (bash/jq/curl/git); no new npm or pip packages.

6. **Linux + WSL2 native, no macOS Docker Desktop fragility** (CLAUDE.md "Constraints"). Phase 26 integration points use `LOG_DIR` which is already path-normalized in Phase 25 (realpath on WSL2); new code follows the same pattern.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Phase 16 `publish_report` — legacy path, single-file report | Phase 24 `publish_docs_bundle` — 6-section atomic bundle with INDEX.md | Phase 24 (2026-04-14) | Phase 26 shipper MUST call `publish_docs_bundle`, not `publish_report` |
| Stop hook not yet wired | Stop hook enforces local spool check | Phase 26 (this phase) | No back-compat issue — Stop hook is additive |

**Deprecated/outdated:**
- Claude Code Stop hook API docs at `docs.claude.com/en/docs/claude-code/hooks` redirect to `code.claude.com/docs/en/hooks`. Always use the new URL for citations. (Verified 2026-04-14.)

## Open Questions

1. **Does `publish_docs_bundle` emit its `report_url` on the LAST line of stdout even when internal diagnostics also print to stdout?**
   - What we know: Function header comment at line 1657 says "stdout last line = report URL". Function body at 1760+ uses many `echo "ERROR: ..."` calls but those go to **stderr** (`>&2`).
   - What's unclear: Whether any info-level logs go to stdout without `>&2`. A quick scan didn't find any, but comprehensive audit is advisable before trusting `tail -1`.
   - Recommendation: Wave 1 test the last-line contract with a captured-stdout unit test that publishes a known fixture bundle to a file:// repo and asserts the last line matches the expected relative path pattern.

2. **Does `disown` inside a function work the same way as at the top level in bash 5.x?**
   - What we know: `disown` operates on the CURRENT shell's job table. Inside a function, the job added by `&` belongs to the function's shell (same as the caller's shell — bash functions share the parent shell's state).
   - What's unclear: If `spawn_cleanup` trap runs on SIGCHLD, does it reap disowned children? Test should verify that a forked shipper survives `spawn_cleanup` being called (triggered by `docker compose down`).
   - Recommendation: Wave 2 integration test spawns a 10-second sleep-based mock shipper, calls `spawn_cleanup`, and verifies the mock shipper is still alive after the cleanup returns.

3. **Should the inline stale-drain run BEFORE or AFTER `fetch_docs_context`?**
   - What we know: Both are network operations in principle (drain may push; fetch always clones). If drain fails, do we still want to proceed with the spawn?
   - What's unclear: CONTEXT.md says "run shipper first (inline, not forked), then proceed with spawn" but doesn't specify behavior when the drain itself fails.
   - Recommendation: Drain failures should NOT abort the new spawn (otherwise a single bad prior spool permanently bricks the profile). Log the failure, leave the spool in place, continue. Next spawn retries again.

4. **Where does `run_spool_shipper` live in `do_spawn` — before or after the envelope is emitted to stdout?**
   - What we know: Line 2255 emits envelope to stdout, line 2258 returns exit code. The shipper should fork BEFORE line 2258 so that the webhook listener gets the envelope before the shipper potentially delays (even by 100ms of fork overhead).
   - What's unclear: If the shipper fork races with the emit, is there any stdout interleaving risk? (Shouldn't be, because disowned subshell has its own stdout handles.)
   - Recommendation: Place `run_spool_shipper` BETWEEN the audit write (line 2253) and the envelope emit (line 2255). Belt-and-suspenders: the shipper's stdout is redirected to `/dev/null` inside the subshell to guarantee no interleave.

## Sources

### Primary (HIGH confidence)
- [Claude Code Hooks Official Docs](https://code.claude.com/docs/en/hooks) — Stop hook input schema, output format, `stop_hook_active` semantics, matcher non-support, settings.json structure. Verified 2026-04-14.
- [anthropics/claude-code SKILL.md (GitHub main)](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/hook-development/SKILL.md) — Stop hook settings.json example + decision field schema. Corroborates primary source.
- `bin/claude-secure` (in-repo read) — line 1060 `verify_bundle_sections`, line 1290 `push_with_retry`, line 1658 `publish_docs_bundle`, line 1845 `_spawn_error_audit`, line 1975 `do_spawn`, line 2159 headless exec, line 2850 interactive exec. Verified via direct Read tool 2026-04-14.
- `claude/hooks/pre-tool-use.sh` (in-repo read) — canonical stdin-JSON hook pattern. Verified 2026-04-14.
- `claude/settings.json` (in-repo read) — existing PreToolUse structure. Verified 2026-04-14.
- `docker-compose.yml:31` (in-repo read) — log volume mount confirmed. Verified 2026-04-14.
- `.planning/config.json` — nyquist_validation: true confirmed. Verified 2026-04-14.

### Secondary (MEDIUM confidence)
- WebSearch results mentioning Stop hook flat/nested structure — cross-referenced with primary docs and corrected. The nested `{"matcher": "...", "hooks": [...]}` form is correct.

### Tertiary (LOW confidence)
- None. All Phase 26 claims are backed by primary sources or direct code reads.

## Metadata

**Confidence breakdown:**
- Stop hook API: **HIGH** — official docs + GitHub source + existing PreToolUse analogue all agree
- Existing code integration points: **HIGH** — all line numbers verified by direct Read
- Shipper retry loop design: **HIGH** — mirrors established `push_with_retry` pattern (line 1290)
- Background fork pattern (`disown`): **MEDIUM** — new to this codebase; Open Question 2 flags the SIGCHLD/spawn_cleanup interaction for Wave 2 test verification
- Test strategy: **HIGH** — mirrors Phase 24/25 Wave 0 scaffolding pattern

**Research date:** 2026-04-14
**Valid until:** 2026-05-14 (30 days; Stop hook API is stable but this phase's research flag noted "version-sensitive" — re-verify at plan time if Claude Code releases a major version)

## RESEARCH COMPLETE
