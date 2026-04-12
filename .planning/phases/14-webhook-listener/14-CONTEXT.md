# Phase 14: Webhook Listener - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning

<domain>
## Phase Boundary

A persistent host-side Python systemd service receives GitHub webhook POSTs, verifies HMAC-SHA256 signatures against per-profile secrets, persists raw payloads to disk, and invokes `claude-secure spawn` with bounded concurrency. Each spawn runs in its own Docker Compose project for isolation.

This phase delivers HOOK-01 (systemd service), HOOK-02 (HMAC verification), and HOOK-06 (concurrent-safe dispatch with unique compose project names).

Event-type routing, prompt template selection per event type, and payload sanitization belong to **Phase 15** — not here. This phase treats the spawn call as an opaque handoff: any valid webhook for a known repo triggers one spawn.

HOOK-07 (CLI replay) is **already covered** by Phase 13's `claude-secure spawn --event-file <path>` flag combined with this phase's payload persistence — no additional CLI work.

</domain>

<decisions>
## Implementation Decisions

### Language & Runtime (D-01 through D-03)
- **D-01:** Listener is written in Python 3.11+ using only stdlib (`http.server`, `hmac`, `subprocess`, `threading`, `json`, `pathlib`, `uuid`). Matches the validator service pattern (`validator/`). Zero host-side pip dependencies.
- **D-02:** Listener runs on the **host**, not inside a container. It needs to invoke `docker compose` commands via the existing `bin/claude-secure spawn` subcommand, which requires host-side Docker socket access.
- **D-03:** Single-file service at `webhook/listener.py` (new top-level dir mirroring `proxy/` and `validator/`). Config file at `webhook/config.example.json` shipped as template.

### HTTP Endpoint & Routing (D-04 through D-07)
- **D-04:** Single endpoint: `POST /webhook`. One GitHub webhook URL per host — user configures one webhook per repo in GitHub settings, all point to the same host endpoint. Simpler reverse-proxy / tunnel setup (nginx, cloudflared, tailscale funnel).
- **D-05:** `GET /health` returns `{"status":"ok","active_spawns":<int>}` for monitoring integration. No auth on health endpoint.
- **D-06:** Binds to `127.0.0.1:9000` by default. User fronts with reverse proxy or tunnel for GitHub reachability. Port and bind address configurable via `webhook/config.json`.
- **D-07:** Any other path or method returns `404` (or `405` for wrong method on `/webhook`). No directory listing, no verbose error bodies.

### Profile Resolution & HMAC Secret (D-08 through D-12)
- **D-08:** Profile resolution order: (1) parse raw body as JSON, (2) extract `repository.full_name`, (3) scan `~/.claude-secure/profiles/*/profile.json` for matching `repo` field, (4) load that profile's `webhook_secret`, (5) verify HMAC signature from `X-Hub-Signature-256` header using `hmac.compare_digest`.
- **D-09:** HMAC secret is stored in each profile's `profile.json` as a new `webhook_secret` field. Per-profile secret, not global. Adds isolation: compromising one profile's secret does not affect others.
- **D-10:** Profile cache: profile→secret map is rebuilt on-demand per request (no caching). Handles profile add/remove without service restart. Performance is adequate — webhook rate is single-digit per minute at most.
- **D-11:** On unknown repo (no profile matches `repository.full_name`), return `404 {"error":"unknown_repo"}` **before** HMAC verification. Log with `repo`, source IP, timestamp. Unknown repos never trigger spawn.
- **D-12:** On HMAC mismatch for known repo, return `401 {"error":"invalid_signature"}`. Log with profile name, source IP, timestamp. Rate limiting out of scope.

### Concurrency Model (D-13 through D-16)
- **D-13:** Bounded concurrency via `threading.Semaphore`. Default `max_concurrent_spawns = 3`. Configurable in `webhook/config.json`. `docker compose up` is heavy (network creation, container pulls, health checks) — unbounded concurrency risks host OOM.
- **D-14:** Listener responds to GitHub with `202 Accepted` **immediately** after persisting the payload and acquiring a semaphore slot (or being queued). GitHub's webhook delivery timeout is 10 seconds — a full spawn cycle exceeds that.
- **D-15:** When semaphore is saturated, listener still returns `202 Accepted` and queues the spawn (thread waits on semaphore). GitHub does not know the difference. No explicit queue length limit in this phase — if it becomes a problem, Phase 17 can add backpressure.
- **D-16:** Spawn subprocess is invoked via `subprocess.Popen` in a daemon thread: `bin/claude-secure spawn --profile <name> --event-file <persisted-path>`. Parent listener does not block on subprocess exit. Output is captured to a log file per invocation (see D-21).

### Payload Persistence (D-17 through D-20)
- **D-17:** Every validated payload is written to `~/.claude-secure/events/<ISO-timestamp>-<uuid8>.json` **before** spawn is invoked. Filename format: `20260412T143052Z-a1b2c3d4.json`. Enables HOOK-07 replay, Phase 16 audit, and post-mortem debugging.
- **D-18:** Payload file contains the full raw request body (the JSON GitHub sent) plus a small sidecar envelope with `received_at`, `profile`, `event_type` (derived from `X-GitHub-Event` header), `delivery_id` (from `X-GitHub-Delivery` header). Matches the shape Phase 13 `do_spawn` already accepts as `--event-file`.
- **D-19:** Unknown-repo and invalid-signature payloads are **not** persisted to the events directory. They are logged to the structured log (D-21) with enough info for debugging but without storing potentially hostile payload bodies.
- **D-20:** Retention/cleanup of `events/` is out of scope for Phase 14. Phase 17 (container reaper) may extend to event file reaping. For now, accumulation is acceptable.

### Logging (D-21 through D-22)
- **D-21:** Structured JSONL log at `~/.claude-secure/logs/webhook.jsonl`. One line per request with fields: `ts`, `event` (received/spawned/rejected/health), `profile`, `repo`, `delivery_id`, `status_code`, `reason`, `spawn_pid`. Matches existing `logs/` patterns from v1.0.
- **D-22:** Each spawned subprocess redirects stdout+stderr to `~/.claude-secure/logs/spawns/<delivery_id>.log`. systemd journal still captures the listener's own lifecycle messages.

### systemd Service (D-23 through D-26)
- **D-23:** Unit file: `webhook/claude-secure-webhook.service`, installed to `/etc/systemd/system/claude-secure-webhook.service` by `install.sh` (new optional step, gated by `--with-webhook` flag or interactive prompt).
- **D-24:** Service runs as `root`. Justification: service shells out to `docker compose`, which requires Docker socket access. Adding a dedicated `claude-secure` system user and `usermod -aG docker` adds installer complexity without a meaningful security gain — the listener already delegates all real work to `bin/claude-secure spawn`, which itself invokes the hardened container stack. Root on the listener is a minimal trusted envelope.
- **D-25:** Service has `Restart=always`, `RestartSec=5s`, `StandardOutput=journal`, `StandardError=journal`, `ExecStart=/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json`. The `install.sh` step copies `webhook/listener.py` to `/opt/claude-secure/webhook/` and `webhook/config.example.json` to `/etc/claude-secure/webhook.json` (only if not already present — no overwrites).
- **D-26:** `install.sh` detects WSL2 (via `/proc/version` grep for `microsoft`) and, if found, checks `/etc/wsl.conf` for `[boot] systemd=true`. If missing, prints a warning with the exact snippet to add plus `wsl.exe --shutdown` instructions. Install still proceeds — warning, not hard failure.

### Response Codes & Error Format (D-27)
- **D-27:** All responses are JSON with `Content-Type: application/json`.
  - `202 Accepted` → `{"status":"accepted","delivery_id":"..."}`
  - `200 OK` → `{"status":"ok","active_spawns":N}` (health only)
  - `400 Bad Request` → `{"error":"invalid_json"}` or `{"error":"missing_header","header":"X-Hub-Signature-256"}`
  - `401 Unauthorized` → `{"error":"invalid_signature"}`
  - `404 Not Found` → `{"error":"unknown_repo"}` or `{"error":"not_found"}`
  - `405 Method Not Allowed` → `{"error":"method_not_allowed"}`
  - `500 Internal Server Error` → `{"error":"spawn_failed","detail":"..."}`

### Claude's Discretion
- Exact `webhook/config.json` schema fields beyond `port`, `bind`, `max_concurrent_spawns`, `events_dir`, `logs_dir` — add as implementation surfaces needs.
- Whether to include a `--dry-run` flag on the listener (parse payload, skip spawn) for local testing. Nice-to-have if trivial.
- Exact Python module layout inside `webhook/` (single file vs `listener.py` + `profiles.py` + `spawner.py`). Planner decides based on testability.
- Test harness approach for HMAC verification, concurrency semaphore, and persistence — shell-based integration tests per project convention, but pytest acceptable for listener unit tests if planner prefers.
- Whether `X-GitHub-Event` header is persisted inside the event file envelope or derived from payload during Phase 15 consumption. Either works; pick whichever simplifies Phase 15.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` — HOOK-01, HOOK-02, HOOK-06 acceptance criteria (Webhooks section)

### Phase Dependencies
- `.planning/phases/12-profile-system/12-CONTEXT.md` — Profile directory layout (D-07, D-08), `profile.json` schema, `repo` field matching GitHub `repository.full_name` (D-04, D-05), validation pattern (D-14)
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` — `do_spawn` contract: `--profile`, `--event`, `--event-file`, `--prompt-template`, `--dry-run` flags. Ephemeral compose project name pattern (D-05). Metadata envelope (D-11). HOOK-07 already covered by `--event-file`.
- `.planning/phases/13-headless-cli-path/13-RESEARCH.md` — Headless execution research: `docker compose exec -T`, exit code propagation, bug #7263.

### Existing Code
- `bin/claude-secure` — `do_spawn()` at line 447: the subprocess this listener invokes. Parses `--profile`, `--event-file`, generates ephemeral `COMPOSE_PROJECT_NAME`, handles lifecycle.
- `validator/` — Python stdlib http.server pattern (threading, sqlite, iptables). Best reference for listener structure, error handling, graceful shutdown.
- `proxy/` — Node stdlib http server pattern (secondary reference — different language but similar "single-file service" philosophy).
- `install.sh` — Installer patterns for host-side setup, dependency checks, file permissions. Phase 14 adds a new optional step for systemd unit installation.
- `config/whitelist.json` — JSON config file shipped as template, copied on install if absent. Same pattern applies to `webhook/config.example.json`.

### Project Decisions
- `.planning/PROJECT.md` — Core value, four-layer architecture, v2.0 milestone goal, "One profile = one repo" out-of-scope note (reinforces per-profile webhook routing).
- `CLAUDE.md` — Technology stack section: Python 3.11+ for services, stdlib-only preference, no streaming, zero pip deps.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `bin/claude-secure spawn` (line 447) — The exact subprocess the listener invokes. Already handles `--event-file`, profile validation, ephemeral compose project names, and cleanup traps. Zero new CLI work needed.
- `validator/` module (Python stdlib http.server, threading, sqlite, subprocess for iptables) — Structural template for `webhook/listener.py`. Same error handling, logging, graceful shutdown patterns apply.
- `install.sh` existing patterns — Host-side setup, file copy to `/opt` and `/etc`, dependency checks. Add new optional block for systemd unit.
- `config/whitelist.json` template → installed to `/etc/claude-secure/whitelist.json` pattern — apply to `webhook/config.example.json` → `/etc/claude-secure/webhook.json`.

### Established Patterns
- Python stdlib-only for host services (validator precedent).
- JSONL structured logs to `~/.claude-secure/logs/<service>.jsonl` — same for `webhook.jsonl`.
- JSON config files with example templates in the source tree — same for `webhook/config.example.json`.
- Profile directory scan via glob `~/.claude-secure/profiles/*/profile.json` and `jq`-parse (bash) or `json.load` (Python).
- Per-profile isolation via config files, never global shared state.

### Integration Points
- **Invokes** `bin/claude-secure spawn` via subprocess — no modifications to `bin/claude-secure` required for Phase 14.
- **Reads** `~/.claude-secure/profiles/*/profile.json` — adds one new field (`webhook_secret`). Profile creation helper in `bin/claude-secure` may prompt for secret during `create_profile()` in a follow-up, but not required for Phase 14 (user can edit profile.json manually).
- **Writes** to `~/.claude-secure/events/` (new) and `~/.claude-secure/logs/webhook.jsonl` + `~/.claude-secure/logs/spawns/<id>.log` (new log files, existing dir).
- **Installed by** `install.sh` with new optional `--with-webhook` flag (or interactive prompt), gated on systemd availability.

### Constraints
- WSL2: systemd requires `[boot] systemd=true` in `/etc/wsl.conf` — installer warns but does not block.
- Host must have Python 3.11+ — already a dependency for other project tools; checked in `install.sh`.
- Listener runs as root to access Docker socket — justified trade-off (D-24).

</code_context>

<specifics>
## Specific Ideas

- The listener is deliberately **dumb about event semantics**. It does not inspect `X-GitHub-Event` to pick prompt templates or decide what to do. That is Phase 15's job. Phase 14's only job: authenticate + persist + hand off.
- Per-profile `webhook_secret` + repo-based routing means a single host endpoint (simple tunnel setup) while preserving secret isolation between profiles. GitHub's one-secret-per-webhook constraint is fine because each profile has one webhook, pointed at the shared endpoint.
- Writing payloads to disk **before** spawn is critical for Phase 15 (replay), Phase 16 (audit log), and debugging. Phase 13's `--event-file` already consumes this shape, so the contract is locked.
- `202 Accepted` immediately after persistence is the trick that lets heavy `docker compose up` cycles coexist with GitHub's 10-second delivery timeout. The semaphore + daemon thread handle the async work without blocking the HTTP response.
- Listener never calls Docker directly. It always goes through `bin/claude-secure spawn`, which means the security layers (PreToolUse hooks, proxy, validator) remain the single enforcement point. Phase 14 adds a transport layer, not a new security boundary.
- `install.sh` WSL2 systemd check is a **warn, don't block** decision because many users run `install.sh` before configuring `wsl.conf`, and a hard failure would be frustrating. A clear warning with copy-pastable config is more helpful.

</specifics>

<deferred>
## Deferred Ideas

- **Rate limiting / abuse protection on /webhook** — Out of scope for Phase 14. Assumes reverse proxy / tunnel provides IP filtering if needed. Could be a Phase 17 hardening item.
- **Dynamic event-to-prompt-template routing** — Phase 15 (HOOK-03, HOOK-04, HOOK-05). Phase 14 always invokes spawn with default template resolution from Phase 13.
- **Payload sanitization before prompt injection** — Phase 15 scope (SEC-02 in future requirements). Phase 14 persists raw payloads; Phase 15 sanitizes during event handling.
- **Event file retention / cleanup** — Phase 17 container reaper could extend to this. For now, accumulation is acceptable.
- **Webhook secret rotation via CLI** — Nice-to-have. For now, edit `profile.json` manually and restart the listener (or not — `webhook_secret` is re-read per request).
- **Health monitoring integration (Prometheus metrics, Slack alerts)** — Future requirement HEALTH-01, HEALTH-02. Not in v2.0 scope.
- **`claude-secure headless status` and `claude-secure headless logs` commands** — Future requirements CLI-01, CLI-02. Not in v2.0 scope.
- **Dedicated system user instead of root** — Rejected for Phase 14 (D-24). Could be revisited in Phase 17 hardening if compelling reason emerges.

### Reviewed Todos (not folded)
- **iptables packet-level logging** (from STATE.md pending todos) — Belongs to validator service hardening, not webhook listener. Not applicable to Phase 14.

</deferred>

---

*Phase: 14-webhook-listener*
*Context gathered: 2026-04-12*
</content>
</invoke>