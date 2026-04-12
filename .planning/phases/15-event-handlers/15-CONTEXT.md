# Phase 15: Event Handlers - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Mode:** User-delegated auto-chain (like Phase 14) — Claude selected all gray areas with rationale.

<domain>
## Phase Boundary

Phase 15 turns the dumb webhook listener (Phase 14) into an event-aware dispatcher: it derives a composite event type from `X-GitHub-Event` + `payload.action`, applies per-profile filtering (only opened/labeled issues, only push-to-main, only failed workflow runs), enriches the persisted event file with a top-level `event_type` field, and selects an event-specific prompt template. Default templates ship in `webhook/templates/` and resolve as a fallback when a profile lacks an override.

This phase delivers HOOK-03 (Issue events), HOOK-04 (Push-to-Main events), HOOK-05 (CI Failure events), and the explicit packaging of HOOK-07 (CLI replay convenience) on top of Phase 13's existing `--event-file` machinery.

**Phase 15 does NOT implement SEC-02** (prompt injection sanitization) — that requirement lives in Future Requirements per `REQUIREMENTS.md` and is out of scope. Phase 15 ships only minimal hygiene (length truncation, control-character stripping, structural heredoc framing) as a side effect of safe template rendering, not as a security feature.

</domain>

<decisions>
## Implementation Decisions

### Event Type Derivation (D-01 through D-04)
- **D-01:** Composite event type is computed as `<X-GitHub-Event>` + optional `-<action>` suffix when the payload has an `action` field. Examples: `issues-opened`, `issues-labeled`, `push` (no action field), `workflow_run-completed`. Workflow runs are further qualified by conclusion when filtering (see D-12).
- **D-02:** The webhook listener (`webhook/listener.py`) computes the composite event type at request time and writes it to the event file at TOP LEVEL as `event_type` — alongside (not replacing) the existing `_meta.event_type` from Phase 14. The top-level field is the canonical contract spawn reads from.
- **D-03:** `bin/claude-secure spawn` is updated so its event-type extraction prefers `.event_type` (top-level) over `._meta.event_type` (Phase 14 fallback) over `.action` (older fallback). This keeps Phase 13's tests green while letting Phase 15's enriched events drive routing.
- **D-04:** Unknown composite types (no template, no filter rule) are logged but NOT spawned. Listener returns 202 to GitHub regardless (idempotent ack — GitHub never retries because we accepted the delivery).

### Per-Profile Event Filtering (D-05 through D-10)
- **D-05:** New optional field in `profile.json`: `webhook_event_filter`. Schema:
  ```json
  {
    "webhook_event_filter": {
      "issues": { "actions": ["opened", "labeled"], "labels": [] },
      "push": { "branches": ["main", "master"] },
      "workflow_run": { "conclusions": ["failure"], "workflows": [] }
    }
  }
  ```
- **D-06:** Filter omitted = sane defaults: issues opened+labeled, push to main+master, workflow_run failures (any workflow). Empty arrays for `labels` / `workflows` mean "match anything in that category" — explicit values narrow the filter.
- **D-07:** Filter evaluation happens AFTER HMAC verification but BEFORE persisting the event file or invoking spawn. Filtered events are logged to `webhook.jsonl` with `event=filtered` and `reason=<filter-name>`, return 202, do not persist, do not spawn. This keeps `~/.claude-secure/events/` free of payloads that will never produce a run.
- **D-08:** Push-to-main branch matching is exact-string match on `ref` minus `refs/heads/` prefix. No glob/regex in this phase — Phase 17 hardening can add if needed.
- **D-09:** Loop prevention for HOOK-04: profile may set `webhook_bot_users` (array of GitHub usernames). If `pusher.name` is in that list, the push is filtered with `reason=loop_prevention`. Default is empty (no loop protection). User documents this in README — it is the user's responsibility to add their bot account when wiring up auto-commit flows.
- **D-10:** Workflow run filter requires BOTH `action == completed` AND `workflow_run.conclusion in profile.workflow_run.conclusions`. The composite event type stays `workflow_run-completed` (action-based) so spawn template lookup is consistent — the conclusion is a filter input, not a type discriminator.

### Default Templates & Resolution (D-11 through D-15)
- **D-11:** Default templates ship in the source tree at `webhook/templates/`:
  - `webhook/templates/issues-opened.md`
  - `webhook/templates/issues-labeled.md`
  - `webhook/templates/push.md`
  - `webhook/templates/workflow_run-completed.md`
- **D-12:** `install.sh --with-webhook` copies `webhook/templates/` to `/opt/claude-secure/webhook/templates/` (always refresh — latest templates ship). Profile-level templates remain in `~/.claude-secure/profiles/<name>/prompts/` (Phase 13 convention) and take precedence.
- **D-13:** `bin/claude-secure resolve_template()` is extended with a fallback chain:
  1. Explicit `--prompt-template <name>` flag → `~/.claude-secure/profiles/<name>/prompts/<name>.md`
  2. Composite event type → `~/.claude-secure/profiles/<name>/prompts/<event-type>.md`
  3. Fallback to default → `/opt/claude-secure/webhook/templates/<event-type>.md` (or local repo `webhook/templates/<event-type>.md` for dev)
  4. Hard fail: log error, exit non-zero, no spawn.
- **D-14:** Default templates use only the variables defined per event type (D-16). They are deliberately minimal — a few sentences of context plus a clear instruction. Users override per-profile to customize tone/scope.
- **D-15:** Template lookup fallback path is resolved via a single `WEBHOOK_TEMPLATES_DIR` env var that defaults to `/opt/claude-secure/webhook/templates` when running under systemd, or `<repo>/webhook/templates` when running from a dev checkout (detected by presence of `.git` near the script).

### Variable Substitution per Event Type (D-16)
- **D-16:** `bin/claude-secure render_template()` is extended with the full per-event-type variable map:

  | Event Type | Variables Available |
  |------------|---------------------|
  | issues-opened, issues-labeled | `{{REPO_NAME}}`, `{{ISSUE_NUMBER}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{ISSUE_LABELS}}` (comma-joined), `{{ISSUE_AUTHOR}}`, `{{ISSUE_URL}}` |
  | push | `{{REPO_NAME}}`, `{{BRANCH}}`, `{{COMMIT_SHA}}`, `{{COMMIT_MESSAGE}}`, `{{COMMIT_AUTHOR}}`, `{{PUSHER}}`, `{{COMPARE_URL}}` |
  | workflow_run-completed | `{{REPO_NAME}}`, `{{WORKFLOW_NAME}}`, `{{WORKFLOW_RUN_ID}}`, `{{WORKFLOW_CONCLUSION}}`, `{{BRANCH}}`, `{{COMMIT_SHA}}`, `{{WORKFLOW_RUN_URL}}` |
  | (any) | `{{REPO_NAME}}`, `{{EVENT_TYPE}}` (always available) |

  Existing variables from Phase 13 (`{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{COMMIT_SHA}}`, `{{BRANCH}}`) remain compatible — Phase 15 only ADDS, never removes.

### Minimal Sanitization (D-17 through D-19)
- **D-17:** Every string variable extracted from the payload is truncated to 8192 bytes (UTF-8 safe — no mid-codepoint cuts). Truncated values get a `... [truncated N more bytes]` suffix so the model knows context was clipped.
- **D-18:** Null bytes (`\x00`) and ASCII control characters except `\n`, `\r`, `\t` are stripped from extracted variables before substitution. This is a hygiene step — not a security claim.
- **D-19:** Phase 15 explicitly does NOT implement: prompt-injection escaping, instruction-override detection, content-based sanitization, allow-list filtering of payload fields. Those belong to Future SEC-02. The phase ships templates with the assumption that Claude Code's `--dangerously-skip-permissions` runs inside the hardened Docker stack, which is the true security boundary.

### HOOK-07 Replay Convenience (D-20 through D-22)
- **D-20:** HOOK-07 is fundamentally already covered by Phase 13's `--event-file` flag combined with Phase 14's payload persistence. Phase 15 adds a thin convenience subcommand:
  - `claude-secure replay <delivery-id>` — finds the matching event file under `~/.claude-secure/events/` and calls `claude-secure spawn --profile <auto-resolved> --event-file <path>`.
- **D-21:** Profile auto-resolution for replay: parse the event file, extract `repository.full_name`, look up the matching profile (same logic as Phase 14 listener). User can override with `--profile` if needed.
- **D-22:** Replay finds the event by substring match on the filename (event files are named `<iso-ts>-<uuid8>.json`; the `<uuid8>` is the GitHub `X-GitHub-Delivery` first 8 chars). Multiple matches → error listing candidates. Zero matches → error.

### Listener Changes Summary (D-23)
- **D-23:** `webhook/listener.py` gains:
  - `compute_event_type(headers, payload)` helper returning composite type string
  - `apply_event_filter(profile, event_type, payload)` returning `(allowed: bool, reason: str)`
  - Filter check inserted between HMAC verification and event persistence
  - Top-level `event_type` field added to persisted event JSON
  - New log event types: `filtered` (filter rejection), `routed` (event accepted into spawn pipeline)

  No changes to: HMAC logic, semaphore, ThreadingHTTPServer setup, systemd unit, response codes, port/bind config.

### Spawn Changes Summary (D-24)
- **D-24:** `bin/claude-secure` gains:
  - Updated `event_type` extraction priority (D-03)
  - Extended `render_template()` with new variables per D-16
  - Extended `resolve_template()` with fallback to `WEBHOOK_TEMPLATES_DIR` per D-13
  - New `replay` subcommand per D-20–D-22
  - New helper `extract_payload_field(json, jq_path, default)` with the truncation+strip from D-17/D-18 baked in

### Claude's Discretion
- Exact wording of default templates in `webhook/templates/*.md` (planner picks tone — recommend brief, action-oriented, English)
- Whether to add `--dry-run` to `replay` subcommand (nice-to-have)
- Whether `extract_payload_field` becomes a sourceable bash function or a small Python helper invoked via subprocess (planner decides; bash + jq preferred for consistency)
- Test naming convention for the new event-type tests in `tests/test-phase15.sh`
- Whether to break out a `webhook/filter.py` module from `listener.py` or keep filtering inline (single-file precedent says inline; planner decides based on growing line count)
- Exact JSON schema validation for `webhook_event_filter` in profile.json — strict mode that rejects unknown keys vs. lenient pass-through

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — HOOK-03, HOOK-04, HOOK-05, HOOK-07 acceptance criteria
- `.planning/REQUIREMENTS.md` Future Requirements section — SEC-02 explicitly out of scope for v2.0

### Phase Dependencies
- `.planning/phases/12-profile-system/12-CONTEXT.md` — `profile.json` schema and the pattern for adding optional fields (`webhook_event_filter` follows this pattern)
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` — Spawn contract (D-01 through D-17), template resolution (D-13/D-16), variable substitution (D-17). Phase 15 extends rather than replaces this layer.
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — Listener architecture (D-01 through D-27), `_meta` envelope shape (D-18), event persistence path (D-17), webhook.jsonl logging (D-21), unknown-repo / invalid-signature handling (D-11/D-12) which Phase 15's filter logic must NOT regress.

### Existing Code
- `bin/claude-secure` lines 369–460: `resolve_template()` and `render_template()` — Phase 15 extends both. Line 502 is where event_type is extracted today (D-03 changes the priority).
- `webhook/listener.py` line ~315: where unknown-repo 404 fires; the new filter check goes immediately after HMAC verification at line ~341, before payload persistence at line ~380.
- `webhook/listener.py` line ~158: `_meta` envelope construction — Phase 15 ADDS top-level `event_type` next to it.
- `webhook/templates/` — does not exist yet; Phase 15 creates it.
- `tests/test-phase14.sh` — fixtures `tests/fixtures/github-issues-opened.json` and `tests/fixtures/github-push.json` exist and are reusable for Phase 15 routing tests. A new `tests/fixtures/github-workflow-run-failure.json` must be added.
- `install.sh` `install_webhook_service()` (line ~276) — extends to also copy `webhook/templates/` to `/opt/claude-secure/webhook/templates/`.

### Project Decisions
- `.planning/PROJECT.md` — "Agent SDK integration" Out of Scope reinforces the decision that template rendering happens host-side (in spawn) before the prompt is piped into `docker compose exec -T claude claude -p`.
- `CLAUDE.md` — Bash/jq stdlib preference for shell helpers; Python stdlib for listener changes.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Phase 13's `resolve_template()` and `render_template()` — Phase 15 EXTENDS these, never reimplements.
- Phase 14's listener structure (per-request profile lookup, HMAC raw-body verify, semaphore dispatch) — Phase 15 inserts a single filter step, otherwise untouched.
- Phase 14's event persistence path and `webhook.jsonl` schema — Phase 15 reuses, only adds new `event` field values (`filtered`, `routed`).
- Phase 14's stub `claude-secure` test harness — Phase 15's tests extend it with event-type assertions (the stub records what flags it was called with).
- jq + bash + sed pattern for variable extraction (already proven in Phase 13's `render_template`).

### Established Patterns
- Single-file Python services with stdlib only (validator, listener) — Phase 15 honors this.
- jq for JSON inspection in bash, never Python from inside the CLI script.
- JSONL structured logs at `~/.claude-secure/logs/<service>.jsonl`.
- Per-profile config via `profile.json`, never global shared state.
- Bash integration tests with stub binaries on `$PATH`.

### Integration Points
- **Reads from** `profile.json.webhook_event_filter` (new optional field) and `profile.json.webhook_bot_users` (new optional field).
- **Writes** new top-level `event_type` field to event files in `~/.claude-secure/events/`.
- **Reads** `~/.claude-secure/profiles/<name>/prompts/` first, falls back to `WEBHOOK_TEMPLATES_DIR` (default `/opt/claude-secure/webhook/templates`).
- **Modifies** `bin/claude-secure` (extends spawn template/variable handling, adds `replay` subcommand) — care must be taken not to regress Phase 13's HEAD-01 through HEAD-05 tests.
- **Modifies** `webhook/listener.py` — adds two helpers and reroutes the request handler, must not regress Phase 14's HOOK-01/02/06 tests.
- **Modifies** `install.sh` — extends `install_webhook_service()` to copy `webhook/templates/` directory.

### Constraints
- Listener must STILL return 202 within GitHub's 10-second window — filter check must be sub-millisecond (in-memory dict lookups, no I/O beyond profile.json read which is already cached per-request).
- Template rendering happens host-side, not inside the container — sanitization decisions live in `bin/claude-secure render_template()`.
- Phase 13 and Phase 14 test suites must remain green after Phase 15 changes — regression coverage is non-negotiable.

</code_context>

<specifics>
## Specific Ideas

- **Event type as composite key** is the linchpin decision. It lets template files have human-readable names (`issues-opened.md`, `workflow_run-completed.md`) AND lets one type cover multiple actions when desired (a profile can drop `issues-labeled.md` and only have `issues-opened.md` — labeled events would then hard-fail template resolution unless the filter excludes them, which is the user's contract).

- **Filter happens BEFORE persist** is a hostile-payload-hygiene continuation of Phase 14's "don't persist invalid signatures" stance. A push to `feature/foo` from a profile that only cares about `main` should not leave a payload sitting on disk forever.

- **Default templates ship in the repo** so a fresh install with no per-profile templates still produces meaningful spawns. Users can `cp /opt/claude-secure/webhook/templates/*.md ~/.claude-secure/profiles/<name>/prompts/` to start customizing.

- **Loop prevention is opt-in** because we cannot safely auto-detect "the bot's own commits" — the bot user is whatever git identity the user configured for the spawned Claude session. Documented in README, defaults to no loop protection (the user accepts responsibility).

- **Replay convenience is intentionally thin** — it's a one-line wrapper around `spawn --event-file` that exists so the user doesn't have to remember the events directory path. Phase 13's `--event-file` is the real machinery; Phase 15 just makes it discoverable from the CLI top level.

- **HOOK-07 is the lightest delivery in this phase** — most of the work is HOOK-03/04/05 routing. Mentioning HOOK-07 explicitly in CONTEXT prevents the planner from over-engineering it into a full replay UI.

- **SEC-02 is NOT in v2.0** — the Phase 14 CONTEXT incorrectly listed it as Phase 15 scope. REQUIREMENTS.md is the source of truth; SEC-02 lives in Future Requirements. Phase 15 ships only minimal hygiene (truncation + control char strip) which is necessary infrastructure, not the requirement.

</specifics>

<deferred>
## Deferred Ideas

- **SEC-02 prompt injection sanitization** — Future Requirements. Phase 15 ships only minimal length+control-char hygiene as a side effect of safe rendering, not as a security feature.
- **Branch glob/regex matching for push filter** — Phase 17 hardening if users complain. Phase 15 is exact-string match.
- **Auto-detection of bot loop commits** — Cannot safely infer; user opts in via `webhook_bot_users` array.
- **Per-event-type rate limiting** — Out of scope. Phase 14's bounded semaphore plus filter rejections are sufficient for v2.0.
- **Webhook payload diff against last event of same type** — Could enable smart deduplication but adds state. Defer to Phase 17 or skip entirely.
- **Replay UI with payload preview** — Phase 15's replay is CLI-only and thin. Web UI is permanently out of scope per PROJECT.md.
- **Template hot-reload without restart** — Templates are read on every spawn already (no caching); listener is already filter-stateless. Nothing to defer here.
- **Custom variable extraction via jq expressions in profile.json** — Power-user feature. Defer until requested.

### Reviewed Todos (not folded)
- **iptables packet-level logging** — Validator concern, not webhook event-handler concern. Stays as-is.

</deferred>

---

*Phase: 15-event-handlers*
*Context gathered: 2026-04-12*
*Auto-decided by Claude per user delegation, same pattern as Phase 14*
