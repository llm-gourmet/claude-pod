# Phase 15: Event Handlers - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 15-event-handlers
**Mode:** User-delegated auto-chain — user said "1" (continue auto-chain) so Claude selected all gray areas and chose recommended options with rationale, same pattern as Phase 14's "entscheide du bitte".

---

## Event Type Composition

| Option | Description | Selected |
|--------|-------------|----------|
| Use raw `X-GitHub-Event` header only (e.g. `issues`) | Simplest. Action filtering happens elsewhere. | |
| Composite `<event>-<action>` (e.g. `issues-opened`) | Lets template files distinguish opened vs. labeled. Slightly more files but maps cleanly to user intent. | ✓ |
| Use payload-content discriminator (e.g. `issue.state.opened`) | Brittle, depends on payload schema variation. | |

**Rationale:** Composite key creates a clean 1:1 mapping between event semantics and template files. Profile owners drop the templates they care about; missing templates hard-fail (per D-13) unless filtered out (per D-05).

---

## Filter Rule Location

| Option | Description | Selected |
|--------|-------------|----------|
| Inside listener.py before persistence | Single enforcement point. Filtered events never touch disk. | ✓ |
| Inside `bin/claude-secure spawn` | Reuses existing profile-loading logic. But events would persist before filter, polluting events dir. | |
| Inside template (filter expressed as template metadata) | Clever but couples filter logic to templates. Hard to reason about. | |

**Rationale:** Hostile-payload hygiene continuation of Phase 14's invalid-signature handling. Filter rejections must not persist.

---

## Default Templates Location

| Option | Description | Selected |
|--------|-------------|----------|
| Ship in `webhook/templates/`, install to `/opt/claude-secure/webhook/templates/` | Mirrors Phase 14's `webhook/` source-tree convention. install.sh already touches `/opt/claude-secure/webhook/`. | ✓ |
| Ship inside each new profile (copy on profile create) | Tight coupling to profile lifecycle. Adds work to PROF-01. | |
| Ship as embedded heredocs inside `bin/claude-secure` | Avoids file paths but bloats the script. Hard to customize without editing the binary. | |

**Rationale:** Source-tree directory + installer copy is the existing pattern (whitelist.json, config.example.json). Profile prompts/ takes precedence; default fallback fills the gap.

---

## Loop Prevention for HOOK-04

| Option | Description | Selected |
|--------|-------------|----------|
| Auto-detect bot commits (heuristic on author name / commit message) | Cannot safely infer the user's bot identity. False positives. | |
| Opt-in `webhook_bot_users` array in profile.json | User accepts responsibility, lists known bot accounts. Default empty = no protection. | ✓ |
| Skip all push events from same minute as a recent spawn | State-dependent. Race conditions. | |

**Rationale:** User knows their git identity; we don't. Document the pitfall in README, give them a clean knob.

---

## SEC-02 Sanitization Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Implement full prompt-injection sanitization in Phase 15 | Big surface area. SEC-02 is in Future Requirements, not v2.0. | |
| Minimal hygiene only (truncate + strip control chars) as a side effect of safe rendering | Necessary infrastructure for any extraction. Not a security claim. | ✓ |
| Skip even minimal hygiene | Risks sed/jq corruption on unicode edge cases. | |

**Rationale:** Phase 14's CONTEXT mentioned SEC-02 as Phase 15 scope, but REQUIREMENTS.md puts it in Future. The phase ships only the hygiene that makes rendering safe, nothing more. SEC-02 stays Future.

---

## HOOK-07 Replay Surface

| Option | Description | Selected |
|--------|-------------|----------|
| Already done by Phase 13 + Phase 14, no Phase 15 work | Strict reading of REQUIREMENTS — `--event-file` covers replay. | |
| Add thin `claude-secure replay <delivery-id>` convenience subcommand | Discoverable, low cost, satisfies the "via CLI command" wording in HOOK-07. | ✓ |
| Build full replay UI (list, search, preview, replay) | Massive scope creep. | |

**Rationale:** HOOK-07 wording says "via CLI command" — a `replay` subcommand is the most direct interpretation. Implementation is a one-line wrapper around existing spawn.

---

## Workflow Run Filter Discriminator

| Option | Description | Selected |
|--------|-------------|----------|
| Composite type encodes conclusion (`workflow_run-failure` vs `workflow_run-success`) | Templates can be totally different per outcome. | |
| Composite type encodes only action (`workflow_run-completed`); conclusion is a filter input | Uniform template lookup, conclusion-as-filter is consistent with branch-as-filter for push. | ✓ |
| Discriminator at template level (template inspects payload itself) | Pushes logic into template machinery. Out of scope. | |

**Rationale:** Consistency with how push uses branch as a filter input rather than a type discriminator.

---

## Claude's Discretion

Areas where Claude has implementation flexibility:
- Exact wording of default templates in `webhook/templates/*.md`
- Whether `replay` gets a `--dry-run` flag
- Bash function vs Python helper for `extract_payload_field`
- Test naming for `tests/test-phase15.sh`
- Whether to split `webhook/filter.py` from `listener.py`
- Strict vs lenient JSON validation for `webhook_event_filter`

## Deferred Ideas

- SEC-02 prompt injection sanitization (Future Requirements)
- Branch glob/regex matching (Phase 17 hardening if needed)
- Auto bot-loop detection (cannot safely infer)
- Per-event-type rate limiting (semaphore + filter is enough)
- Webhook payload deduplication (defer or skip)
- Replay UI with payload preview (web UI is permanent out-of-scope)
- Template hot-reload (already stateless)
- Custom variable extraction via jq expressions in profile.json (power user)
