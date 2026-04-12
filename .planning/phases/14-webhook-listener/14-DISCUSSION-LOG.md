# Phase 14: Webhook Listener - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 14-webhook-listener
**Areas discussed:** Language/runtime, Endpoint routing & HMAC secret, Concurrency, Payload persistence, systemd install & user, Unknown-repo handling
**Mode:** User-delegated ("entscheide du bitte") — Claude selected all gray areas and chose recommended options with rationale.

---

## Language / Runtime

| Option | Description | Selected |
|--------|-------------|----------|
| Python stdlib (http.server + hmac + subprocess) | Matches validator precedent. Zero pip deps. Built-in HMAC, threading, JSON. | ✓ |
| Bash + socat/ncat + openssl | Minimum host deps. Fragile for JSON/HTTP body handling, harder to test. | |
| Node.js stdlib | Matches proxy. But validator is already Python — adding a second Python service is more consistent than a second Node service. | |

**User's choice:** Delegated to Claude → Python stdlib.
**Notes:** Python chosen because (1) validator already uses this exact stack, (2) `hmac.compare_digest` is a one-liner, (3) no host-side pip install step needed, (4) test harness can reuse validator's patterns.

---

## Endpoint Routing & HMAC Secret Location

| Option | Description | Selected |
|--------|-------------|----------|
| Single `/webhook` + global secret | Simplest config. One secret leak compromises all profiles. | |
| Path-based `/webhook/<profile>` + per-profile secret | Explicit profile in URL. User must configure URL per profile in GitHub. | |
| Single `/webhook` + per-profile secret via repo lookup | One endpoint URL for all profiles, but each profile has own secret resolved via `repository.full_name`. Best of both. | ✓ |

**User's choice:** Delegated → Option 3.
**Notes:** Profile resolution order: parse repo → lookup profile by `profile.json.repo` field → load that profile's `webhook_secret` → verify HMAC. Unknown repos rejected 404 before HMAC check.

---

## Concurrency Model

| Option | Description | Selected |
|--------|-------------|----------|
| Unbounded spawn-and-forget | Simplest. Risks OOM under bursty load since `docker compose up` is heavy. | |
| Bounded semaphore (default 3) | Capped concurrent spawns. Excess requests queue on semaphore; listener still returns 202 immediately. | ✓ |
| Serial queue (1 at a time) | Safest but slow. Defeats HOOK-06 concurrent-safety intent. | |

**User's choice:** Delegated → Bounded semaphore.
**Notes:** Default `max_concurrent_spawns = 3` configurable in `webhook/config.json`. GitHub 10s delivery timeout requires immediate 202 Accepted; semaphore wait happens in daemon thread after response is sent.

---

## Payload Persistence

| Option | Description | Selected |
|--------|-------------|----------|
| Always persist before spawn | Enables HOOK-07 replay, Phase 16 audit, debugging. Costs disk. | ✓ |
| Only persist failed events | Saves disk but loses replay/audit for success path. | |
| Don't persist (systemd journal only) | Loses structured payload for replay. Phase 13 `--event-file` becomes useless for real events. | |

**User's choice:** Delegated → Always persist.
**Notes:** `~/.claude-secure/events/<ISO-ts>-<uuid8>.json` written before spawn invocation. Matches Phase 13 `--event-file` contract. Retention/cleanup deferred to Phase 17. Unknown-repo and invalid-signature payloads are NOT persisted (hostile payload hygiene).

---

## systemd Install & Run-as User

| Option | Description | Selected |
|--------|-------------|----------|
| Root `/etc/systemd/system/` unit | Simple Docker socket access. Minimal installer complexity. | ✓ |
| Dedicated `claude-secure` system user | Principle of least privilege. Requires `usermod -aG docker`, more install steps. Security gain is marginal since listener delegates to hardened stack. | |
| User-level `~/.config/systemd/user/` | No root needed. Breaks "service survives restart" if user not logged in. | |

**User's choice:** Delegated → Root system unit.
**Notes:** Root justified because the listener is a thin transport layer delegating to `bin/claude-secure spawn`, which itself runs the hardened container stack. Adding a system user adds installer complexity without meaningful security gain. `install.sh` gains `--with-webhook` (or interactive prompt) + WSL2 systemd detection.

---

## Unknown-Repo Handling

| Option | Description | Selected |
|--------|-------------|----------|
| Reject 404 before HMAC | Correct because without profile lookup there's no secret to verify against. Clean rejection. | ✓ |
| Accept, log as orphan, don't spawn | Allows HMAC-valid payloads to be recorded for debugging unknown repos — but you can't verify HMAC without knowing the secret, so "valid" is meaningless here. | |

**User's choice:** Delegated → 404 reject.
**Notes:** Order: parse repo → lookup profile → (if none) 404 → else verify HMAC → spawn. Rejected payloads are NOT persisted to events dir, only logged in `webhook.jsonl` with repo, source IP, timestamp.

---

## Claude's Discretion

Areas where Claude has implementation flexibility:
- Exact `webhook/config.json` schema beyond required fields
- `--dry-run` flag for listener testing (nice-to-have)
- Python module layout inside `webhook/` (single file vs split)
- Test harness: shell-based integration tests (project convention) vs pytest for unit tests
- Whether `X-GitHub-Event` header is persisted inside the event envelope or derived in Phase 15

## Deferred Ideas

- Rate limiting on `/webhook` — assumes reverse proxy handles
- Event-type routing → Phase 15
- Payload sanitization before prompt injection → Phase 15 (SEC-02)
- Event file retention cleanup → Phase 17
- Webhook secret rotation CLI
- Health monitoring integration (Prometheus, Slack) → HEALTH-01, HEALTH-02 future
- `claude-secure headless status/logs` commands → CLI-01, CLI-02 future
- Dedicated system user for listener → possible Phase 17 revisit
</content>
</invoke>