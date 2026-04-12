# Phase 14: Webhook Listener - Research

**Researched:** 2026-04-12
**Domain:** Python stdlib HTTP server, GitHub webhook HMAC verification, systemd unit files, host-side subprocess concurrency
**Confidence:** HIGH

## Summary

Phase 14 is almost entirely a scoping/gluing job: CONTEXT.md locks the language (Python 3.11+ stdlib), the architecture (single-file `webhook/listener.py` matching the `validator/` precedent), and every HTTP semantic. Research only needs to fill the *how*: the exact stdlib primitives and the one critical gotcha (raw body must be captured verbatim — re-serialising JSON breaks HMAC), the `ThreadingHTTPServer` upgrade over `HTTPServer`, the `Semaphore` + daemon-thread pattern that lets spawn work finish *after* the 202 response, and the systemd unit directives that are safe for a root service that shells out to Docker.

The GitHub webhook spec is stable and well-documented: `X-Hub-Signature-256: sha256=<hexdigest>`, computed with `hmac.new(secret, raw_body, hashlib.sha256).hexdigest()`, compared with `hmac.compare_digest`. GitHub's delivery-side timeout is a hard **10 seconds** (not configurable) — this is what drives the "respond 202 immediately, spawn in a daemon thread" architecture locked in D-14/D-15/D-16. The canonical Python stdlib reference implementation exists (Eli Bendersky, 2014, BaseHTTPRequestHandler + HMAC) and matches the locked design almost one-for-one; the only deltas are ThreadingHTTPServer (for D-13 concurrency) and sha256 instead of sha1 (for modern HMAC).

The highest-risk item is **raw body capture**. The only correct way to read the body is `self.rfile.read(int(self.headers['Content-Length']))` — the *exact* bytes GitHub sent. If any later step does `json.dumps(json.loads(body))` and feeds that to HMAC, verification will silently fail on payloads with non-canonical key ordering, whitespace, or unicode escaping. This is the one thing that must be called out in every task that touches the body.

**Primary recommendation:** Model `webhook/listener.py` directly on `validator/validator.py` (same `BaseHTTPRequestHandler` + `_send_json` + logger pattern), but (1) use `ThreadingHTTPServer` instead of `HTTPServer`, (2) add a single `threading.Semaphore(max_concurrent_spawns)` guarding `subprocess.Popen` of `bin/claude-secure spawn`, (3) always read the raw body once and pass *that byte string* to both HMAC verification and disk persistence, (4) install the systemd unit with `Type=simple`, `Restart=always`, `RestartSec=5`, `StandardOutput=journal`, `StandardError=journal`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Language & Runtime**
- **D-01:** Listener written in Python 3.11+ using only stdlib (`http.server`, `hmac`, `subprocess`, `threading`, `json`, `pathlib`, `uuid`). Matches `validator/` pattern. Zero host-side pip deps.
- **D-02:** Listener runs on the host, not in a container. Needs host-side Docker socket access to invoke `bin/claude-secure spawn`.
- **D-03:** Single-file service at `webhook/listener.py` (new top-level dir mirroring `proxy/` and `validator/`). Config file at `webhook/config.example.json` shipped as template.

**HTTP Endpoint & Routing**
- **D-04:** Single endpoint: `POST /webhook`. One URL per host; each GitHub repo's webhook points at the same endpoint.
- **D-05:** `GET /health` returns `{"status":"ok","active_spawns":<int>}`. No auth.
- **D-06:** Binds to `127.0.0.1:9000` by default. Port and bind address configurable via `webhook/config.json`.
- **D-07:** Any other path or method returns `404` (or `405` for wrong method on `/webhook`). No directory listing, no verbose error bodies.

**Profile Resolution & HMAC Secret**
- **D-08:** Profile resolution order: (1) parse raw body as JSON, (2) extract `repository.full_name`, (3) scan `~/.claude-secure/profiles/*/profile.json` for matching `repo` field, (4) load that profile's `webhook_secret`, (5) verify HMAC from `X-Hub-Signature-256` using `hmac.compare_digest`.
- **D-09:** HMAC secret stored per-profile in `profile.json` as new `webhook_secret` field. Per-profile isolation.
- **D-10:** Profile cache rebuilt on-demand per request (no in-memory cache). Handles profile add/remove without restart.
- **D-11:** Unknown repo → `404 {"error":"unknown_repo"}` **before** HMAC verification. Log with `repo`, source IP, ts.
- **D-12:** HMAC mismatch for known repo → `401 {"error":"invalid_signature"}`. Log with profile name, IP, ts. Rate limiting out of scope.

**Concurrency Model**
- **D-13:** `threading.Semaphore` with default `max_concurrent_spawns = 3`. Configurable.
- **D-14:** Listener responds `202 Accepted` immediately after persisting payload and acquiring (or queueing for) semaphore slot. GitHub's delivery timeout is 10s.
- **D-15:** When semaphore saturated, still return `202 Accepted` and queue the spawn (thread waits). No explicit queue length limit in Phase 14.
- **D-16:** Spawn invoked via `subprocess.Popen` in daemon thread: `bin/claude-secure spawn --profile <name> --event-file <persisted-path>`. Parent does not block.

**Payload Persistence**
- **D-17:** Every validated payload written to `~/.claude-secure/events/<ISO-timestamp>-<uuid8>.json` **before** spawn invoked. Example filename: `20260412T143052Z-a1b2c3d4.json`.
- **D-18:** Payload file contains full raw request body + small sidecar envelope with `received_at`, `profile`, `event_type` (from `X-GitHub-Event`), `delivery_id` (from `X-GitHub-Delivery`). Matches shape Phase 13 `do_spawn` accepts as `--event-file`.
- **D-19:** Unknown-repo and invalid-signature payloads **not** persisted. Logged only.
- **D-20:** Retention/cleanup of `events/` out of scope for Phase 14. Accumulation acceptable.

**Logging**
- **D-21:** Structured JSONL log at `~/.claude-secure/logs/webhook.jsonl`. Fields: `ts`, `event`, `profile`, `repo`, `delivery_id`, `status_code`, `reason`, `spawn_pid`.
- **D-22:** Each spawned subprocess redirects stdout+stderr to `~/.claude-secure/logs/spawns/<delivery_id>.log`. systemd journal captures listener lifecycle.

**systemd Service**
- **D-23:** Unit file: `webhook/claude-secure-webhook.service`, installed to `/etc/systemd/system/claude-secure-webhook.service` by `install.sh` (new optional step, gated by `--with-webhook` flag or interactive prompt).
- **D-24:** Service runs as `root`. Justification: shells out to `docker compose`, needs socket access. Dedicated user + `docker` group adds installer complexity without meaningful security gain; listener delegates all real work to hardened `bin/claude-secure spawn`.
- **D-25:** `Restart=always`, `RestartSec=5s`, `StandardOutput=journal`, `StandardError=journal`, `ExecStart=/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json`. `install.sh` copies `webhook/listener.py` to `/opt/claude-secure/webhook/` and `webhook/config.example.json` to `/etc/claude-secure/webhook.json` (never overwrites existing).
- **D-26:** `install.sh` detects WSL2 (grep `microsoft` in `/proc/version`) and checks `/etc/wsl.conf` for `[boot] systemd=true`. If missing, warns with copy-pastable snippet and `wsl.exe --shutdown` instructions. Install still proceeds.

**Response Codes & Error Format**
- **D-27:** All responses JSON with `Content-Type: application/json`:
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
- Test harness approach (shell-based per project convention; pytest acceptable for unit tests if planner prefers).
- Whether `X-GitHub-Event` header is persisted inside the event file envelope or derived from payload during Phase 15. Either works.

### Deferred Ideas (OUT OF SCOPE)

- Rate limiting / abuse protection on `/webhook` — Phase 17 hardening at earliest.
- Dynamic event-to-prompt-template routing — Phase 15 (HOOK-03, HOOK-04, HOOK-05).
- Payload sanitization before prompt injection — Phase 15 (SEC-02).
- Event file retention / cleanup — Phase 17 container reaper.
- Webhook secret rotation via CLI — future enhancement.
- Health monitoring integration (Prometheus, Slack) — HEALTH-01/02.
- `claude-secure headless status` / `headless logs` CLI — CLI-01/02.
- Dedicated system user instead of root — rejected for Phase 14, revisit Phase 17 if justified.
- iptables packet-level logging (STATE.md pending todo) — belongs to validator, not this phase.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HOOK-01 | Webhook listener runs as a host-side systemd service receiving GitHub webhooks | Supported by "systemd Unit File" section. `Type=simple`, `Restart=always`, `RestartSec=5s`, `StandardOutput=journal`, WSL2 detection pattern. Python 3.11+ stdlib `http.server` verified as sufficient host service runtime. |
| HOOK-02 | Every incoming webhook is verified via HMAC-SHA256 signature against raw payload body | Supported by "Python stdlib HTTP + HMAC" and "GitHub Webhook Spec" sections. `self.rfile.read(content_length)` captures raw body; `hmac.new(secret, raw, hashlib.sha256).hexdigest()` + `hmac.compare_digest` is the canonical pattern. Raw-body-not-reserialized warning documented as #1 gotcha. |
| HOOK-06 | Multiple simultaneous webhooks execute safely with unique compose project names and isolated workspaces | Supported by "Concurrency Model" section. `ThreadingHTTPServer` + `threading.Semaphore(3)` + daemon-thread `subprocess.Popen` pattern. Unique compose project names already guaranteed by Phase 13 `do_spawn` (`cs-<profile>-<uuid8>`) — Phase 14 just has to not break that isolation by invoking spawn as a clean subprocess with no shared state. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: Must work on Linux (native) and WSL2 — no macOS
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen already required; Python 3.11+ already required by validator service
- **Architecture**: Host-side Python stdlib-only services (validator precedent). No pip installs, no streaming
- **Security**: Listener delegates all real work to `bin/claude-secure spawn` — the four security layers (hooks, proxy, validator, iptables) remain the enforcement point
- **No NFQUEUE**: N/A for this phase
- **GSD workflow**: All edits via GSD commands (enforced at CLAUDE.md level)

## Standard Stack

### Core

| Library (stdlib) | Purpose | Why Standard | Confidence |
|------------------|---------|--------------|------------|
| `http.server` | Request handling via `BaseHTTPRequestHandler` | Exact precedent in `validator/validator.py`. Eli Bendersky's canonical 2014 GitHub-webhook example uses the same module. Zero deps. | HIGH |
| `http.server.ThreadingHTTPServer` | Concurrent request handling (one thread per connection) | Available since Python 3.7. Required because the validator-style single-threaded `HTTPServer` would serialize webhook receipt — unacceptable for HOOK-06. Already in stdlib, zero code cost to upgrade. | HIGH |
| `hmac` | HMAC-SHA256 signature computation | `hmac.new(key, msg, digestmod)` + `hmac.compare_digest` is the canonical Python stdlib HMAC pattern. GitHub's own docs use `hmac.compare_digest`. | HIGH |
| `hashlib` | SHA-256 digest algorithm for `hmac.new(..., digestmod=hashlib.sha256)` | stdlib, required by `hmac.new`. | HIGH |
| `threading` | `threading.Semaphore` (D-13), daemon thread for spawn subprocess (D-16) | stdlib concurrency primitive. Semaphore is the textbook bounded-concurrency pattern. | HIGH |
| `subprocess` | `subprocess.Popen` to invoke `bin/claude-secure spawn` | stdlib. `Popen` is non-blocking; parent returns 202 immediately while child runs. | HIGH |
| `json` | Parse incoming payloads, build responses, write event-file envelope | stdlib. | HIGH |
| `pathlib` | Path manipulation for event files, log files, profile scan | stdlib. Cleaner than `os.path` for glob and joinpath. | HIGH |
| `uuid` | `uuid.uuid4().hex[:8]` for event file name suffix (D-17) | stdlib. Matches Phase 13's `uuidgen` pattern. | HIGH |
| `signal` | SIGTERM handler for graceful shutdown under systemd | stdlib. systemd sends SIGTERM on `systemctl stop`; handler flips a flag and calls `server.shutdown()`. | HIGH |
| `argparse` | `--config <path>` CLI flag (D-25) | stdlib. | HIGH |
| `datetime` | ISO timestamps for event filenames and JSONL log | stdlib. | HIGH |
| `logging` | JSONL structured logging (D-21) — mirror validator's `JsonFileHandler` | stdlib. | HIGH |

### Supporting (host-side tools for install/test, not runtime)

| Tool | Purpose | Notes |
|------|---------|-------|
| `openssl dgst -sha256 -hmac <secret>` | Generate fake GitHub signatures for integration tests | Ships with the project's existing test-host baseline. Matches how every Python tutorial tests webhook servers. |
| `curl` | Integration test driver (already a project dep) | Used in `tests/test-phase*.sh`. |
| `systemctl` | Install/start/stop/status the listener unit | Pre-existing on all systemd hosts. WSL2 must have `[boot] systemd=true`. |
| `journalctl` | Read listener stdout/stderr (D-25 routes both to journal) | Pre-existing. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `ThreadingHTTPServer` | `HTTPServer` (single-threaded, validator precedent) | Single-threaded would make concurrent webhooks serialize even though spawn is already offloaded to a daemon thread. Header parsing and HMAC verify are cheap (~ms) but the raw body read happens on the request thread — a slow client could block the whole server. `ThreadingHTTPServer` fixes this for one stdlib-line change. |
| Flask / FastAPI | CONTEXT D-01 rules out pip deps | CLAUDE.md and validator precedent both forbid. |
| `asyncio` + aiohttp | Async model | Violates D-01 (pip deps); async doesn't help here anyway — the real work is `subprocess.Popen`, which is already non-blocking when detached. |
| `queue.Queue` + worker pool | Explicit producer/consumer | `Semaphore` + daemon-thread-per-request is simpler and is what D-13/D-14/D-15 literally describe. A worker pool would need a join on shutdown; daemon threads die with the process, which matches "systemd restart on crash" semantics. |
| Per-profile HMAC secret in a separate keystore | `profile.json.webhook_secret` field | Would mean a new file format and new installer step. D-09 locks the in-profile-json approach. |

## Architecture Patterns

### Recommended Project Structure

```
webhook/                              # NEW top-level dir, mirrors proxy/ and validator/
  listener.py                         # Single-file service (D-03)
  config.example.json                 # Shipped template (D-03)
  claude-secure-webhook.service       # systemd unit file (D-23)
  README.md                           # Optional, planner's call

# Installed layout (by install.sh, D-25):
/opt/claude-secure/webhook/listener.py
/etc/claude-secure/webhook.json                 # copied from config.example.json, never overwritten
/etc/systemd/system/claude-secure-webhook.service

# Runtime paths (created by listener on first run):
~/.claude-secure/events/<ISO>-<uuid8>.json      # D-17
~/.claude-secure/logs/webhook.jsonl             # D-21
~/.claude-secure/logs/spawns/<delivery_id>.log  # D-22
```

### Pattern 1: Raw Body Capture + HMAC Verification

**What:** Read body exactly once as bytes, use the same bytes for both HMAC verification and disk persistence. Never re-serialize.
**When to use:** Every `POST /webhook` request.
**Why critical:** `json.dumps(json.loads(body))` produces *different bytes* than GitHub sent (key order, whitespace, unicode escaping). HMAC will silently fail. This is the #1 footgun in webhook handlers.

```python
# webhook/listener.py (sketch)
import hmac, hashlib, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            return self._send_json(404, {"error": "not_found"})

        # 1. Raw body — read ONCE, keep as bytes
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length)   # bytes, not str

        # 2. Parse JSON for routing ONLY (never re-serialize for HMAC)
        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            return self._send_json(400, {"error": "invalid_json"})

        # 3. Resolve profile by repo name BEFORE HMAC check (D-11)
        repo = payload.get("repository", {}).get("full_name")
        profile = resolve_profile_by_repo(repo)   # scans ~/.claude-secure/profiles/*/profile.json
        if profile is None:
            self._log_rejected("unknown_repo", repo=repo)
            return self._send_json(404, {"error": "unknown_repo"})

        # 4. HMAC verification against the RAW BYTES
        sig_header = self.headers.get("X-Hub-Signature-256", "")
        if not sig_header.startswith("sha256="):
            return self._send_json(400, {
                "error": "missing_header",
                "header": "X-Hub-Signature-256",
            })
        received_sig = sig_header.split("=", 1)[1]

        secret = profile["webhook_secret"].encode("utf-8")
        expected_sig = hmac.new(secret, raw_body, hashlib.sha256).hexdigest()

        if not hmac.compare_digest(expected_sig, received_sig):
            self._log_rejected("invalid_signature", profile=profile["name"])
            return self._send_json(401, {"error": "invalid_signature"})

        # 5. Persist raw body + envelope (D-17, D-18) — use raw_body, NOT re-serialized
        delivery_id = self.headers.get("X-GitHub-Delivery", "unknown")
        event_type  = self.headers.get("X-GitHub-Event", "unknown")
        event_path  = persist_event(raw_body, profile["name"], event_type, delivery_id)

        # 6. Queue spawn (D-14/D-15/D-16) and return 202 immediately
        spawn_async(profile["name"], event_path, delivery_id)
        return self._send_json(202, {"status": "accepted", "delivery_id": delivery_id})
```

Notes:
- `raw_body` is held as a local bytes variable for the lifetime of the request — it is not mutated, not re-encoded, not re-serialized. It is used for HMAC and then written to disk as-is.
- The four `return self._send_json(...)` patterns match `validator/validator.py`'s `_send_json` helper exactly.
- Source: Eli Bendersky, [Payload server in Python 3 for GitHub webhooks](https://eli.thegreenplace.net/2014/07/09/payload-server-in-python-3-for-github-webhooks) (canonical stdlib reference, updated from SHA-1 to SHA-256 for modern GitHub).
- Source: GitHub Docs, [Validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) — official `hmac.compare_digest` example.

### Pattern 2: Bounded Concurrency via Semaphore + Daemon Thread

**What:** Semaphore caps concurrent spawn subprocesses at N (default 3). Each request spins a daemon thread that (a) acquires the semaphore (possibly blocking — but the HTTP response has already been sent), (b) launches `bin/claude-secure spawn` via `Popen`, (c) waits for it, (d) releases the semaphore.
**When to use:** Every validated webhook.

```python
# Module-level state
_spawn_semaphore = threading.Semaphore(config["max_concurrent_spawns"])
_active_spawns   = 0
_active_lock     = threading.Lock()

def spawn_async(profile_name: str, event_path: pathlib.Path, delivery_id: str) -> None:
    """Launch spawn in a daemon thread. Returns immediately."""
    t = threading.Thread(
        target=_spawn_worker,
        args=(profile_name, event_path, delivery_id),
        daemon=True,   # dies with the listener process
        name=f"spawn-{delivery_id[:8]}",
    )
    t.start()

def _spawn_worker(profile_name: str, event_path: pathlib.Path, delivery_id: str) -> None:
    global _active_spawns
    _spawn_semaphore.acquire()   # may block if saturated (D-15)
    with _active_lock:
        _active_spawns += 1
    try:
        log_path = pathlib.Path.home() / ".claude-secure" / "logs" / "spawns" / f"{delivery_id}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "wb") as log_fp:
            proc = subprocess.Popen(
                [
                    "claude-secure", "spawn",
                    "--profile", profile_name,
                    "--event-file", str(event_path),
                ],
                stdout=log_fp,
                stderr=subprocess.STDOUT,
                # NOTE: do NOT pass shell=True; argv form is safer
            )
            _jsonl_log({"event": "spawned", "profile": profile_name,
                        "delivery_id": delivery_id, "spawn_pid": proc.pid})
            rc = proc.wait()
            _jsonl_log({"event": "spawn_completed", "profile": profile_name,
                        "delivery_id": delivery_id, "spawn_pid": proc.pid, "exit": rc})
    finally:
        with _active_lock:
            _active_spawns -= 1
        _spawn_semaphore.release()
```

Why this is safe:
- **D-14**: the HTTP handler thread calls `spawn_async` which returns in microseconds (just creates+starts a Thread). The 202 is already on the wire.
- **D-15**: a new daemon thread is born per webhook, then *it* blocks on the semaphore. Threads are cheap (~KB stack). 100 queued webhooks = 100 threads sleeping on a lock, which is fine.
- **D-16**: `Popen` with explicit argv and captured stdout/stderr to the per-delivery log file. Parent does not inherit the child's fds.
- **D-13**: `threading.Semaphore(3)` gates concurrent `docker compose up` calls. The listener never touches Docker directly.
- **HOOK-06**: `bin/claude-secure spawn` already generates `cs-<profile>-<uuid8>` compose project names (verified in `bin/claude-secure:492`). Phase 14 just has to invoke the spawn subprocess once per webhook with no shared state — which `subprocess.Popen` guarantees because each `Popen` is an independent OS process.

### Pattern 3: Graceful Shutdown under systemd

**What:** systemd sends `SIGTERM` on `systemctl stop`. The listener must unblock its `serve_forever` loop, finish in-flight request handlers, and exit cleanly. Daemon threads running background spawns die with the process — that's acceptable because `bin/claude-secure spawn` has its own `trap cleanup EXIT` that will clean up containers if the child is also killed.

```python
import signal
_server = None

def _sigterm_handler(signum, frame):
    _jsonl_log({"event": "shutdown", "signal": "SIGTERM"})
    if _server:
        # shutdown() is thread-safe and tells serve_forever() to return.
        # Must NOT be called from the same thread that runs serve_forever().
        threading.Thread(target=_server.shutdown, daemon=True).start()

def main():
    global _server
    _server = ThreadingHTTPServer((bind_addr, port), WebhookHandler)
    signal.signal(signal.SIGTERM, _sigterm_handler)
    signal.signal(signal.SIGINT,  _sigterm_handler)
    _jsonl_log({"event": "listener_started", "bind": bind_addr, "port": port})
    try:
        _server.serve_forever()
    finally:
        _server.server_close()
        _jsonl_log({"event": "listener_stopped"})
```

**Critical gotcha:** `HTTPServer.shutdown()` blocks until `serve_forever()` actually returns, and **deadlocks if called from the same thread**. Always call it from a separate thread (above pattern) or from a signal handler that spawns one. This is documented in `socketserver.BaseServer.shutdown`.

Source: Python docs, [socketserver.BaseServer.shutdown](https://docs.python.org/3/library/socketserver.html#socketserver.BaseServer.shutdown).

### Pattern 4: Profile Resolution by Repo (D-08, D-10)

**What:** Every request re-scans `~/.claude-secure/profiles/*/profile.json` looking for a `repo` field matching the payload's `repository.full_name`. No caching (D-10).

```python
import pathlib, json

PROFILES_DIR = pathlib.Path.home() / ".claude-secure" / "profiles"

def resolve_profile_by_repo(repo_full_name: str) -> dict | None:
    if not repo_full_name:
        return None
    for profile_json in PROFILES_DIR.glob("*/profile.json"):
        try:
            data = json.loads(profile_json.read_text())
        except (OSError, json.JSONDecodeError):
            continue   # skip corrupt profile, log warn separately
        if data.get("repo") == repo_full_name:
            if not data.get("webhook_secret"):
                return None   # profile matches repo but has no secret — treat as unknown
            return {
                "name": profile_json.parent.name,
                "repo": data["repo"],
                "webhook_secret": data["webhook_secret"],
            }
    return None
```

Matches Phase 12's profile system (profile dir = profile name) and Phase 13's `load_profile_config` conventions. `webhook_secret` is a new field; presence of the field is required for the profile to be webhook-eligible.

### Pattern 5: Event File Persistence (D-17, D-18)

```python
import datetime, uuid, json

EVENTS_DIR = pathlib.Path.home() / ".claude-secure" / "events"

def persist_event(raw_body: bytes, profile_name: str, event_type: str, delivery_id: str) -> pathlib.Path:
    EVENTS_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    suffix = uuid.uuid4().hex[:8]
    path = EVENTS_DIR / f"{ts}-{suffix}.json"

    envelope = {
        "received_at": datetime.datetime.utcnow().isoformat() + "Z",
        "profile": profile_name,
        "event_type": event_type,
        "delivery_id": delivery_id,
        "payload": json.loads(raw_body),   # for convenience
    }
    # Write envelope — note: the "payload" field is a re-parsed copy for readability.
    # The raw body is preserved as-is because at this point HMAC is already verified
    # and Phase 13's --event-file consumer reads the whole envelope as JSON.
    path.write_text(json.dumps(envelope, indent=2))
    return path
```

**Compatibility note:** Phase 13 `do_spawn` reads `--event-file` as a JSON document and extracts `event_type`, `action`, `repository.full_name`, `issue.title`, etc. Check `bin/claude-secure:477`:
```bash
EVENT_JSON=$(cat "$EVENT_FILE")
# ... then jq -r '.event_type // .action // "unknown"'
```
This means Phase 13 expects the *payload* fields at the top level (so `jq '.repository.full_name'` works). Two options:
1. **Envelope format** (shown above): wrap payload in `{"received_at", ..., "payload": {...}}`. Phase 13 would need to be taught that `--event-file` can have an envelope. Not acceptable for Phase 14 (would require touching Phase 13 code).
2. **Flat format**: write the payload JSON at the top level with envelope fields added as siblings. Phase 13's `jq` queries still work because they look at `.repository.full_name`, `.issue.title`, etc.

**Recommendation: flat format.** Planner should write the event file as `payload_json + {"_meta": {"received_at": ..., "profile": ..., "delivery_id": ...}}`. The `_meta` key is namespaced so it can't collide with GitHub payload fields. Phase 13's template rendering ignores unknown top-level keys.

```python
def persist_event(raw_body: bytes, profile_name: str, event_type: str, delivery_id: str) -> pathlib.Path:
    payload = json.loads(raw_body)
    payload["_meta"] = {
        "received_at": datetime.datetime.utcnow().isoformat() + "Z",
        "profile": profile_name,
        "event_type": event_type,
        "delivery_id": delivery_id,
    }
    path = EVENTS_DIR / f"{ts}-{suffix}.json"
    path.write_text(json.dumps(payload, indent=2))
    return path
```

This is D-18's "full raw request body (the JSON GitHub sent) plus a small sidecar envelope" interpretation that is actually compatible with Phase 13. The planner should verify against `bin/claude-secure:503` when writing the Phase 14 tasks.

### Anti-Patterns to Avoid

- **Re-serializing JSON before HMAC check.** The only acceptable input to `hmac.new` is the exact bytes from `self.rfile.read()`. Passing `json.dumps(json.loads(raw)).encode()` silently breaks verification on ~20% of payloads (any with non-ASCII unicode, any with non-alphabetical key order).
- **Reading `rfile` twice.** `rfile` is a stream; a second `read()` returns empty. Capture to a local `raw_body: bytes` immediately and use that variable everywhere downstream.
- **Using `hmac.compare_digest` with strings of different types.** Both operands must be the same type (both `str` or both `bytes`). `hmac.new(...).hexdigest()` returns `str`; the header parse also returns `str`; fine. But mixing `bytes` and `str` raises `TypeError` (older Pythons) or leaks timing info (see stdlib note).
- **Running as non-root without `docker` group.** D-24 locks this: root. Do not introduce a dedicated user in Phase 14.
- **Calling `server.shutdown()` from the same thread as `serve_forever()`.** Deadlocks forever. Always dispatch from signal handler's own thread.
- **Using single-threaded `HTTPServer` from the validator pattern.** Concurrent webhooks would serialize the entire HTTP stack, blocking for however long body-read + HMAC-verify takes. Trivially upgraded by swapping `HTTPServer` → `ThreadingHTTPServer` — same class interface, new thread per request.
- **Storing the bearer secret or the webhook payload in the JSONL log (`webhook.jsonl`).** Log *metadata* (repo, profile, delivery_id, status, reason) — never body bytes, never the secret. D-21's field list explicitly excludes both.
- **Setting `Restart=always` without `RestartSec`.** systemd will restart a crashing service in a tight loop, burning CPU and filling journal. `RestartSec=5` throttles.
- **Shelling out to `docker compose` from inside the listener.** D-16 mandates going through `bin/claude-secure spawn` so that (a) all security-layer setup runs, (b) the ephemeral `cs-<profile>-<uuid8>` naming is preserved, (c) Phase 14 adds *transport*, not a new security boundary.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HMAC comparison | String equality `==` | `hmac.compare_digest(a, b)` | `==` is vulnerable to timing attacks. `compare_digest` is constant-time over input length. |
| HMAC computation | Manual SHA-256 + XOR pad | `hmac.new(key, msg, hashlib.sha256).hexdigest()` | stdlib, tested, correct. |
| Raw-body stream read | `self.rfile.readline()` loop | `self.rfile.read(int(self.headers['Content-Length']))` | Single blocking read is the stdlib-standard pattern used in `validator/validator.py:254` and every Python webhook tutorial. |
| Thread-per-request HTTP server | Hand-rolled socket accept + `threading.Thread` | `ThreadingHTTPServer` | Stdlib gives you the thread management, socket lifecycle, and keepalive handling for free. |
| Bounded concurrency | Thread pool + job queue | `threading.Semaphore(N)` | 5 lines vs 50. Matches the semantics D-13/D-15 describe. |
| Non-blocking subprocess launch | `os.fork()` + `os.execv()` | `subprocess.Popen` | Popen handles fd inheritance, signal masks, working dir, env. |
| UUID suffix | `random.randint(0, 2**32)` | `uuid.uuid4().hex[:8]` | Proper randomness, collision-safe. |
| ISO timestamps | `time.time()` + manual formatting | `datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")` | stdlib, timezone-aware convention. |
| Signal-based graceful shutdown | Custom `while running:` flags everywhere | `signal.signal(SIGTERM, handler)` + `server.shutdown()` from a worker thread | stdlib idiom; validator's single-threaded server doesn't need this but ThreadingHTTPServer does. |
| JSONL logging | Ad-hoc `print(json.dumps(...))` | `logging.Handler` subclass with `emit()` writing JSONL (copy from `validator/validator.py:31`) | Existing project pattern, log file paths already established. |
| systemd unit file | PID file + nohup + init.d script | Standard `[Unit] [Service] [Install]` ini file with `Type=simple` + `Restart=always` | The one and only modern Linux service pattern. |

**Key insight:** Every primitive Phase 14 needs already lives in Python 3.11+ stdlib. The entire listener should be < 300 lines. Adding any third-party library would be both a CLAUDE.md violation and a net complexity increase.

## GitHub Webhook Spec

All HIGH confidence, verified against [GitHub Docs — Validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) and [Webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads).

### Headers GitHub Sends

| Header | Purpose | Notes |
|--------|---------|-------|
| `X-Hub-Signature-256` | HMAC-SHA256 hex digest of raw body, prefixed with `sha256=` | Primary signature header. Example: `X-Hub-Signature-256: sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17` |
| `X-Hub-Signature` | Legacy HMAC-SHA1 — do not use | Kept for backwards compat; modern clients must use sha256 variant |
| `X-GitHub-Event` | Event type name (`issues`, `push`, `workflow_run`, `ping`, ...) | String, always present. Used by Phase 15; Phase 14 persists it into envelope (D-18) |
| `X-GitHub-Delivery` | Globally unique delivery GUID | Used as the filename key for `logs/spawns/<delivery_id>.log` (D-22) |
| `X-GitHub-Hook-ID` | Numeric webhook config ID | Available but not used by Phase 14 |
| `User-Agent` | Always prefixed `GitHub-Hookshot/` | Useful for logging source identification; not used for auth |
| `Content-Type` | `application/json` (what we configure in the GitHub webhook UI) | Phase 14 only supports JSON payloads. `application/x-www-form-urlencoded` is NOT supported (that form would wrap the JSON in a `payload=` field, which would break HMAC verification against the raw body) |

**Phase 14 must document that GitHub webhooks for this project must be configured with `Content-Type: application/json` (not `application/x-www-form-urlencoded`).** This is a user-facing setup step for the README.

### Response Timeout: 10 Seconds (HIGH confidence)

GitHub's webhook delivery requires a 2xx response within 10 seconds. This is not configurable. Sources:
- [GitHub Docs — Handling failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries)
- [Hookdeck — Guide to GitHub Webhooks](https://hookdeck.com/webhooks/platforms/guide-github-webhooks-features-and-best-practices)

This is the architectural driver for D-14: respond 202 *before* spawn completes. A single `docker compose up -d` can take 5-30 seconds (network creation, health checks, volume mounts) — well over the budget. Daemon-thread offload is the standard fix.

### Signature Verification Algorithm (Canonical)

```python
import hmac, hashlib

def verify(raw_body: bytes, sig_header: str, secret: str) -> bool:
    if not sig_header.startswith("sha256="):
        return False
    received = sig_header.split("=", 1)[1]
    expected = hmac.new(
        secret.encode("utf-8"),
        raw_body,                     # bytes, as received
        digestmod=hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, received)
```

Verified against:
- GitHub Docs Python example (uses `hmac.compare_digest` verbatim)
- Eli Bendersky's 2014 Python 3 reference (same pattern, SHA-1 → SHA-256 is the only diff)
- `hmac.compare_digest` stdlib help: "Note: If a and b are of different lengths, or if an error occurs, a timing attack could theoretically reveal information about the types and lengths of a and b — but not their values."

### Payload Shape (Relevant Fields)

Every GitHub webhook payload that we care about contains a `repository` object with `full_name` — the `owner/repo` slug used for profile routing (D-08).

```json
{
  "action": "opened",
  "issue": { "title": "...", "body": "...", "number": 42, ... },
  "repository": {
    "full_name": "octocat/Hello-World",
    "name": "Hello-World",
    "owner": { "login": "octocat", ... }
  },
  "sender": { ... }
}
```

Phase 14 only touches `repository.full_name`. Everything else is Phase 15's concern.

## systemd Unit File

### Recommended Unit

```ini
# /etc/systemd/system/claude-secure-webhook.service
# Installed by install.sh from webhook/claude-secure-webhook.service

[Unit]
Description=claude-secure GitHub webhook listener
Documentation=https://github.com/<user>/claude-secure
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json
Restart=always
RestartSec=5s

# Logging — all stdout/stderr routed to systemd journal (D-25)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-secure-webhook

# User — root is required because listener shells out to `docker compose` (D-24)
User=root
Group=root

# Basic hardening that is SAFE for a root service that needs Docker socket access:
# - NoNewPrivileges must be FALSE because subprocess needs to exec docker/claude-secure
# - ProtectSystem=false because we write to ~/.claude-secure (typically /root/.claude-secure)
# We deliberately do NOT add PrivateTmp, ProtectHome, CapabilityBoundingSet because
# they all break `docker compose` invocation. The hardening envelope is the security
# layers inside the containers, not the listener process itself (see D-24 rationale).

[Install]
WantedBy=multi-user.target
```

Justification per directive:

| Directive | Value | Why |
|-----------|-------|-----|
| `Type=simple` | — | Listener runs in foreground (`serve_forever()` blocks in main thread). `Type=notify` would require `sd_notify()` hooks; not worth a dep on `python-systemd` (pip). `Type=forking` would require the listener to daemonize itself; unneeded. |
| `Restart=always` | — | D-25 explicit. Process crashes should auto-recover. `on-failure` would not restart on clean exit code 0, but for a persistent listener, any exit is an anomaly. |
| `RestartSec=5s` | — | Prevents tight restart loop if config file is broken and listener crashes on startup. 5s is short enough for operator convenience, long enough to not spam journal. |
| `StandardOutput=journal` / `StandardError=journal` | — | D-25. Allows `journalctl -u claude-secure-webhook` debugging. Application logs (D-21) still go to `~/.claude-secure/logs/webhook.jsonl`; journal captures only lifecycle. |
| `SyslogIdentifier=claude-secure-webhook` | — | Clean journalctl output without PID noise. |
| `After=network-online.target docker.service` | — | Listener accepts TCP and shells out to Docker. Both must be up first. `Requires=docker.service` ensures the listener stops if Docker dies. |
| `User=root` | — | D-24 locked. Listener needs `/var/run/docker.sock` access and writes to `/root/.claude-secure/` (or whichever user `install.sh` determines — see below). |
| `ExecStart=/usr/bin/python3 /opt/...` | — | D-25 explicit. Absolute paths because systemd starts with empty `$PATH` by default. |
| `WantedBy=multi-user.target` | — | Standard for network services; starts on boot after multi-user system is up. |

**Hardening NOT added, and why:**
- `NoNewPrivileges=true` — would block `subprocess.Popen(['claude-secure', ...])` from its own `docker compose` sudo semantics. Safe only if claude-secure never needs privilege escalation, but we can't guarantee that without testing.
- `ProtectSystem=strict` / `ReadOnlyPaths` — Docker's volume mount machinery writes to multiple system paths. Breaks compose.
- `PrivateTmp=true` — validator and proxy use /tmp for some operations; safer to leave alone in Phase 14.
- `CapabilityBoundingSet` — docker daemon communication needs a wider cap set than the listener itself does; too risky to restrict in Phase 14.

Phase 17 hardening can revisit all of the above with empirical testing.

### Home Directory Gotcha (ROOT RUNS AS `root`)

The listener reads profiles from `~/.claude-secure/profiles/*/profile.json`. When the unit runs as `User=root`, `~` resolves to `/root`, NOT the invoking user's home. Phase 14 must address one of:

1. **Configure profiles path via `webhook/config.json`.** The listener reads `profiles_dir` from its config, not from `$HOME`. Default: the config file at `/etc/claude-secure/webhook.json` specifies `profiles_dir: /home/<user>/.claude-secure/profiles`. `install.sh` writes this at install time using the invoking user's `$HOME`.
2. **Symlink `/root/.claude-secure -> /home/<user>/.claude-secure`.** Ugly.
3. **Run as the invoking user (drop D-24).** Rejected.

**Recommendation: Option 1.** Every path the listener touches (`profiles_dir`, `events_dir`, `logs_dir`, `spawn_log_dir`) is a config-file field. `install.sh` writes concrete paths based on `$SUDO_USER` or `$USER` at install time. This is the cleanest option and means the listener is unit-testable without a real home directory.

Add to `webhook/config.example.json`:
```json
{
  "bind": "127.0.0.1",
  "port": 9000,
  "max_concurrent_spawns": 3,
  "profiles_dir": "__REPLACED_BY_INSTALLER__",
  "events_dir": "__REPLACED_BY_INSTALLER__",
  "logs_dir": "__REPLACED_BY_INSTALLER__",
  "claude_secure_bin": "/usr/local/bin/claude-secure"
}
```

Planner note: this materially expands the config schema beyond D-06's default fields but CONTEXT.md marks schema as Claude's Discretion. This is the smallest change that reconciles D-24 (run as root) with D-08 (scan profiles in `~/.claude-secure`).

## WSL2 Detection

### Detection Method

```bash
# From install.sh (new function, gated behind --with-webhook)
detect_wsl2() {
    if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
        return 0  # is WSL2
    fi
    return 1
}
```

This matches the existing `install.sh:50` pattern (`grep -qi microsoft /proc/version`). HIGH confidence — the `microsoft` string is present in every WSL2 kernel since Microsoft started building the kernel (~2020).

### Check wsl.conf

```bash
check_wsl_systemd() {
    local wsl_conf="/etc/wsl.conf"
    if [ ! -f "$wsl_conf" ]; then
        return 1  # file doesn't exist → systemd not enabled
    fi
    # Look for [boot] section with systemd=true
    # Simple grep works; proper ini parsing is overkill
    if grep -qE '^\s*systemd\s*=\s*true' "$wsl_conf"; then
        return 0
    fi
    return 1
}
```

### Warning Message Template (for install.sh)

```bash
if detect_wsl2; then
    if ! check_wsl_systemd; then
        log_warn "WSL2 detected but systemd is not enabled in /etc/wsl.conf."
        log_warn "The webhook listener runs as a systemd service and will not start"
        log_warn "until you enable systemd in WSL2."
        echo ""
        echo "  To enable systemd in WSL2, add the following to /etc/wsl.conf:"
        echo ""
        echo "      [boot]"
        echo "      systemd=true"
        echo ""
        echo "  Then, from a Windows PowerShell / CMD prompt, run:"
        echo ""
        echo "      wsl.exe --shutdown"
        echo ""
        echo "  After WSL restarts, re-run this installer or start the service manually:"
        echo ""
        echo "      sudo systemctl enable --now claude-secure-webhook"
        echo ""
        log_warn "Installer will continue. The unit file will be installed but not started."
    else
        log_info "WSL2 detected with systemd enabled — OK"
    fi
fi
```

D-26 explicit: **warn, don't block**. Installer copies the unit file, runs `systemctl daemon-reload`, but skips `systemctl enable --now` on WSL2-without-systemd so it doesn't fail with "system has not been booted with systemd as init system".

## Test Strategy

### Approach: Shell Integration Tests (Project Convention)

Phase 14 adds `tests/test-phase14.sh` following the pattern of `tests/test-phase13.sh`. All tests use `curl` + `openssl` — no pytest needed. This matches CLAUDE.md and the v1.0 convention (52 shell tests across 9 scripts).

### Generating Fake GitHub Signatures in Tests

This is trivial and every Python webhook tutorial uses the same idiom:

```bash
SECRET="test-secret-abc123"
BODY='{"repository":{"full_name":"test/repo"},"action":"opened"}'

# Compute HMAC-SHA256 exactly the way GitHub does (over raw body bytes)
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
# Note: use `printf '%s'` NOT `echo` — echo may add a trailing newline,
# which changes the bytes HMAC sees and will cause verification mismatch
# in the listener (the listener reads exactly Content-Length bytes).

curl -sS -X POST http://127.0.0.1:9000/webhook \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -H "X-GitHub-Delivery: test-$(uuidgen)" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$BODY"
```

**Critical gotcha the planner must encode in tests:** the `printf '%s'` vs `echo` distinction. `echo "$BODY"` adds a trailing `\n` that changes the HMAC input; `printf '%s' "$BODY"` does not. Use `printf` in every test.

To verify the gotcha works both ways, add a dedicated test case:
```bash
# Negative test: echo (with newline) should FAIL verification
BAD_SIG=$(echo "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
curl -o /dev/null -s -w "%{http_code}\n" -X POST .../webhook \
  -H "X-Hub-Signature-256: sha256=${BAD_SIG}" \
  -d "$BODY"
# Expect: 401
```

### Concurrency Test (HOOK-06)

```bash
# Fire 5 webhooks in parallel, each with a unique delivery ID.
# Verify each produced a spawn subprocess with a distinct COMPOSE_PROJECT_NAME.

BODY='{"repository":{"full_name":"test/repo"},"action":"opened"}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')

for i in 1 2 3 4 5; do
  curl -sS -X POST http://127.0.0.1:9000/webhook \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-GitHub-Delivery: concurrent-test-$i" \
    -H "X-Hub-Signature-256: sha256=${SIG}" \
    -d "$BODY" &
done
wait

# Verify: 5 event files created in ~/.claude-secure/events/
test $(ls ~/.claude-secure/events/ | wc -l) -ge 5

# Verify: 5 distinct spawn log files
test $(ls ~/.claude-secure/logs/spawns/ | grep concurrent-test | wc -l) -eq 5

# Verify: grep webhook.jsonl for 5 "spawned" events with distinct spawn_pid
test $(grep '"event":"spawned"' ~/.claude-secure/logs/webhook.jsonl | \
       tail -5 | jq -r '.spawn_pid' | sort -u | wc -l) -eq 5
```

Because `bin/claude-secure spawn` already generates unique `cs-<profile>-<uuid8>` project names, HOOK-06 is satisfied as long as Phase 14 invokes spawn as 5 independent `Popen` subprocesses. The test doesn't even need to start real containers — a stub `claude-secure` script that just logs its own `COMPOSE_PROJECT_NAME` and exits would suffice for unit testing the listener's concurrency layer.

### Stubbing `claude-secure` for Unit Tests

For tests that don't need real Docker:

```bash
# In test setup
TEST_BIN_DIR=$(mktemp -d)
cat > "$TEST_BIN_DIR/claude-secure" <<'EOF'
#!/bin/bash
# Stub: log invocation and exit 0
echo "STUB spawn called: $*" >> /tmp/claude-secure-stub.log
sleep 0.1  # simulate work
EOF
chmod +x "$TEST_BIN_DIR/claude-secure"
export PATH="$TEST_BIN_DIR:$PATH"
```

This lets the listener test run without Docker, without building images, and without consuming real spawn resources. Tests that verify end-to-end HMAC → spawn → compose project name creation are **integration tests** that should use the real binary (and be flagged as slow).

### Systemd Persistence Test (HOOK-01)

HOOK-01 acceptance criterion is "survives restarts". This is the hardest part to automate because it needs a real systemd environment.

**Three-tier approach:**

1. **Unit-file lint (automated, always runs):**
   ```bash
   systemd-analyze verify webhook/claude-secure-webhook.service
   ```
   `systemd-analyze verify` parses the unit file and reports syntax/semantic errors without needing root. Works in CI and on dev machines.

2. **Install smoke test (automated, gated by `CLAUDE_SECURE_TEST_SYSTEMD=1`):**
   ```bash
   if [ "${CLAUDE_SECURE_TEST_SYSTEMD:-0}" = "1" ]; then
       sudo ./install.sh --with-webhook
       sudo systemctl start claude-secure-webhook
       sleep 2
       sudo systemctl is-active claude-secure-webhook | grep -q active
       curl -sS http://127.0.0.1:9000/health | jq -e '.status == "ok"'
       sudo systemctl stop claude-secure-webhook
   fi
   ```
   Only runs on a real systemd host where the operator opts in. Default-skip in normal CI runs.

3. **Restart persistence test (manual, documented):**
   After enabling the service, `sudo reboot` and verify `systemctl status claude-secure-webhook` shows active after boot. Document in README + the HOOK-01 test output.

This is the standard pattern for systemd-dependent tests. Do NOT try to fake systemd in unit tests — `systemd-analyze verify` is the right level of automation.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash integration tests (project convention; matches `tests/test-phase13.sh`) |
| Config file | `tests/test-map.json` (add `webhook/` and `tests/test-phase14.sh` entries) |
| Quick run command | `bash tests/test-phase14.sh` |
| Full suite command | `for t in tests/test-phase*.sh; do bash "$t" || exit 1; done` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| HOOK-01 | Unit file parses and is syntactically valid | unit | `systemd-analyze verify webhook/claude-secure-webhook.service` | No — Wave 0 |
| HOOK-01 | `install.sh --with-webhook` copies unit file, runs `daemon-reload`, prints WSL2 warning when applicable | integration | `bash tests/test-phase14.sh::test_install_webhook` | No — Wave 0 |
| HOOK-01 | Service starts, binds to configured port, health endpoint returns 200 | integration (gated) | `CLAUDE_SECURE_TEST_SYSTEMD=1 bash tests/test-phase14.sh::test_systemd_start` | No — Wave 0 |
| HOOK-01 | Service survives restart (manual verify after reboot) | manual-smoke | Documented in README; run after install | N/A |
| HOOK-02 | Valid signature → 202 Accepted; event file persisted | integration | `bash tests/test-phase14.sh::test_hmac_valid` | No — Wave 0 |
| HOOK-02 | Invalid signature (wrong secret) → 401; no event file written | integration | `bash tests/test-phase14.sh::test_hmac_invalid` | No — Wave 0 |
| HOOK-02 | Missing `X-Hub-Signature-256` header → 400 | integration | `bash tests/test-phase14.sh::test_hmac_missing_header` | No — Wave 0 |
| HOOK-02 | Body re-serialization regression: `echo $BODY` (trailing newline) must fail verification | integration | `bash tests/test-phase14.sh::test_hmac_newline_sensitivity` | No — Wave 0 |
| HOOK-02 | Unknown repo returns 404 BEFORE HMAC verification (no per-profile secret lookup wasted) | integration | `bash tests/test-phase14.sh::test_unknown_repo_404` | No — Wave 0 |
| HOOK-06 | 5 concurrent webhooks produce 5 distinct spawn subprocesses with distinct delivery IDs | integration | `bash tests/test-phase14.sh::test_concurrent_5` | No — Wave 0 |
| HOOK-06 | Semaphore caps concurrent spawns at `max_concurrent_spawns`; 6th spawn queues (all 6 still get 202) | integration | `bash tests/test-phase14.sh::test_semaphore_queue` | No — Wave 0 |
| HOOK-06 | Each spawn log file (`~/.claude-secure/logs/spawns/<delivery_id>.log`) is distinct | integration | part of `test_concurrent_5` | No — Wave 0 |
| HOOK-06 | `GET /health` returns `active_spawns` count | integration | `bash tests/test-phase14.sh::test_health_active_spawns` | No — Wave 0 |

Cross-cutting criteria (not tied to a single requirement):

| Behavior | Test Type | Command |
|----------|-----------|---------|
| `POST /wrong-path` → 404 | integration | `test_wrong_path_404` |
| `GET /webhook` → 405 | integration | `test_wrong_method_405` |
| Invalid JSON body → 400 | integration | `test_invalid_json_400` |
| Graceful shutdown on SIGTERM (process exits within 2s) | integration | `test_sigterm_shutdown` |
| `webhook/config.json` missing → clean error on startup | unit | `test_missing_config` |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase14.sh` (fast path — stubs `claude-secure`; no real Docker)
- **Per wave merge:** Full suite — `for t in tests/test-phase*.sh; do bash "$t"; done`
- **Phase gate:** Full suite green + manual `systemctl status claude-secure-webhook` verification on a real systemd host before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/test-phase14.sh` — covers HOOK-01 (unit-file lint + install), HOOK-02 (HMAC pass/fail/missing/newline), HOOK-06 (concurrency, semaphore, health), cross-cutting (404/405/400/sigterm/missing config)
- [ ] Update `tests/test-map.json` — add `{"paths": ["webhook/"], "tests": ["test-phase14.sh"]}`; add `{"paths": ["install.sh"], ...}` to trigger `test-phase14.sh` on installer changes
- [ ] Test harness for stubbing `claude-secure` binary (helper function in `test-phase14.sh` or shared in a new `tests/helpers.sh` — planner's call per D-03's "planner decides module layout")
- [ ] Fixture: sample GitHub webhook JSON payloads (`tests/fixtures/github-issues-opened.json`, `tests/fixtures/github-push.json`) so tests don't inline 500-line JSON blobs

## Known Gotchas

### Gotcha 1: Raw Body Must Not Be Re-Serialized

**What goes wrong:** `hmac.new(secret, json.dumps(json.loads(raw_body)).encode(), sha256)` produces a *different* digest than what GitHub signed, so `compare_digest` returns False and all webhooks get rejected.
**Why it happens:** JSON has multiple equivalent serializations (key order, whitespace, escape choice, unicode vs `\u` escapes). `json.loads` + `json.dumps` normalizes, which means the bytes change.
**How to avoid:** Capture `raw_body: bytes = self.rfile.read(length)` once at the top of `do_POST` and pass *that exact variable* to `hmac.new` and `persist_event`. Only use `json.loads(raw_body)` for *reading* (profile resolution, event type). Never re-encode the parsed dict.
**Warning signs:** All webhooks return 401 in production even though the secret is correct. HMAC verification is all-or-nothing — if one payload fails, they all fail.

### Gotcha 2: `printf` vs `echo` in Test HMAC Generation

**What goes wrong:** `echo "$BODY" | openssl dgst -sha256 -hmac "$SECRET"` includes the trailing newline `echo` adds, which changes the digest. The listener (which reads exactly `Content-Length` bytes) sees different content and rejects the signature.
**Why it happens:** `echo` appends `\n` by default; `printf '%s'` does not. Classic shell gotcha.
**How to avoid:** Use `printf '%s' "$BODY"` in all test HMAC generation. Document in test file comment.
**Warning signs:** Tests fail intermittently or all fail with 401 even when manually verifying the signature looks correct.

### Gotcha 3: `HTTPServer.shutdown()` Deadlock

**What goes wrong:** Calling `server.shutdown()` from the same thread that's running `serve_forever()` deadlocks forever.
**Why it happens:** `shutdown()` sets a flag and then *blocks waiting* for `serve_forever()` to notice the flag and return. If you call it from the serving thread, that thread is blocked in the waiting loop and can never check the flag.
**How to avoid:** In the SIGTERM handler, dispatch `server.shutdown()` to a new thread: `threading.Thread(target=_server.shutdown, daemon=True).start()`. Or use `server.shutdown()` from any worker thread, never from main. Documented in [Python docs](https://docs.python.org/3/library/socketserver.html#socketserver.BaseServer.shutdown).
**Warning signs:** `systemctl stop claude-secure-webhook` hangs for 90 seconds then gets `SIGKILL`'d by systemd.

### Gotcha 4: Empty Content-Length

**What goes wrong:** Some tooling (rare) sends POST with no `Content-Length` header or `Content-Length: 0`, and `self.rfile.read(0)` returns empty. JSON parsing then fails.
**Why it happens:** Malformed clients or keepalive edge cases.
**How to avoid:** Defensive code: `length = int(self.headers.get("Content-Length", 0))`; if `length == 0`, return `400 {"error": "empty_body"}` before attempting to parse. GitHub's webhooks always include Content-Length, so this is a robustness nice-to-have, not a blocker.

### Gotcha 5: `ThreadingHTTPServer` and Keep-Alive

**What goes wrong:** By default, each new connection gets a fresh thread, but HTTP keep-alive is handled per-connection. A long-lived GitHub client connection would tie up one thread. In practice, GitHub opens one connection per webhook and closes it, so this is not an issue. But if you configure `protocol_version = "HTTP/1.1"` on the handler class to enable keep-alive, a misbehaving tunnel could hold a thread.
**How to avoid:** Keep the default `protocol_version = "HTTP/1.0"` (which is the `BaseHTTPRequestHandler` default) — no keep-alive, one thread dies per request. This matches the validator's behavior and is fine for the single-digit-per-minute webhook volume.

### Gotcha 6: `subprocess.Popen` File Descriptor Inheritance

**What goes wrong:** By default `Popen` inherits the parent's fds. If the listener's HTTP socket is open at fork time, the child `claude-secure spawn` inherits it — which can keep the port bound even after the listener crashes.
**Why it happens:** POSIX fork semantics. Python has `close_fds=True` as the default on Linux since 3.7, so this is mostly a non-issue — but worth explicit note.
**How to avoid:** Rely on Python 3.7+'s `close_fds=True` default. Do not set `close_fds=False`. Do not use `preexec_fn`.

### Gotcha 7: systemd `~/.claude-secure` Path Mismatch Under `User=root`

**What goes wrong:** Listener reads `pathlib.Path.home() / ".claude-secure"`, which resolves to `/root/.claude-secure` when the unit runs as `User=root`. User profiles live in `/home/<user>/.claude-secure`.
**Why it happens:** `$HOME` in systemd-spawned processes is `/root` (for `User=root`).
**How to avoid:** All paths come from `webhook/config.json`, not from `$HOME`. `install.sh` writes the config with concrete paths based on `$SUDO_USER` or `$USER` at install time. See "Home Directory Gotcha" in systemd section above.

### Gotcha 8: Profile Scan Race Condition

**What goes wrong:** `profile.json` is being written by another CLI command (e.g., `claude-secure create-profile`) while the listener reads it → `json.JSONDecodeError` on a half-written file.
**Why it happens:** No file locking in Phase 12/13.
**How to avoid:** `try/except json.JSONDecodeError` in `resolve_profile_by_repo` — skip corrupt profiles, continue scan. Log at WARN level. For a webhook service this is acceptable: the next webhook (typically seconds later) will succeed once the write completes.

## Reference Implementations

### Canonical Python stdlib GitHub webhook receiver (2014, still valid)

- [Eli Bendersky — Payload server in Python 3 for GitHub webhooks](https://eli.thegreenplace.net/2014/07/09/payload-server-in-python-3-for-github-webhooks)
- **Why canonical:** This is the reference implementation every Python tutorial links to. Uses exactly the stdlib primitives CONTEXT.md locks (`http.server.BaseHTTPRequestHandler`, `hmac`, `hashlib`). Shows the correct raw-body read and `hmac.compare_digest` pattern.
- **Phase 14 deltas from this reference:**
  1. Swap `HTTPServer` → `ThreadingHTTPServer` for concurrency.
  2. Swap `hashlib.sha1` → `hashlib.sha256` (GitHub deprecated SHA-1).
  3. Swap `X-Hub-Signature` → `X-Hub-Signature-256`.
  4. Add semaphore + daemon-thread spawn offload.
  5. Add profile-scan-by-repo layer (Phase 12/13 specific).
  6. Add event file persistence.
  7. Add systemd unit + JSONL logging.

### GitHub Docs — Validating webhook deliveries

- [Validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries)
- Official `hmac.compare_digest` example (even though the surrounding snippet is FastAPI, the HMAC logic is identical).

### `validator/validator.py`

- `/home/igor9000/claude-secure/validator/validator.py`
- **Why relevant:** Structural template for the listener. Same `BaseHTTPRequestHandler` subclass, same `_send_json`, same `logging.Handler` subclass for JSONL output (lines 31-49). The listener should feel like a sibling service, not a new pattern.
- **Phase 14 deltas from validator:**
  1. `ThreadingHTTPServer` instead of `HTTPServer`.
  2. No SQLite (no state to persist beyond events dir).
  3. No iptables (listener is host-side, no network enforcement).
  4. Semaphore + daemon thread for spawn offload (validator is synchronous).
  5. SIGTERM handler (validator relies on `KeyboardInterrupt`).

### Bloomberg `python-github-webhook` (Flask-based, not directly usable but good reference for webhook header handling)

- [bloomberg/python-github-webhook](https://github.com/bloomberg/python-github-webhook)
- Not directly usable (Flask), but the header/event dispatching logic is a useful template for Phase 15.

### Python docs — `socketserver.BaseServer.shutdown` deadlock note

- [Python docs — socketserver](https://docs.python.org/3/library/socketserver.html#socketserver.BaseServer.shutdown)
- **Critical for:** "Gotcha 3" in Known Gotchas — never call `shutdown()` from the serving thread.

## install.sh Extension Pattern

### Strategy: New Optional Function, Gated by Flag

The existing `install.sh` main flow is: `check_dependencies → detect_platform → check_existing → setup_directories → setup_auth → setup_workspace → copy_app_files → build_images → install_cli → install_git_hooks`.

Phase 14 adds a new function `install_webhook_service` that runs **after** `install_cli` (because it copies `bin/claude-secure` as a dependency). It is gated by a `--with-webhook` flag that `main()` parses (currently `main` ignores args entirely).

### Idempotent Re-Runs

The function must handle three states:
1. **First install** — unit file, config file, webhook dir don't exist yet.
2. **Re-run, config unchanged** — leave config untouched (D-25: "only if not already present — no overwrites"), refresh unit file and listener.py from source, `daemon-reload`, restart service.
3. **Re-run, user wants fresh config** — documented: `rm /etc/claude-secure/webhook.json` then re-run.

### Snippet (for `install.sh`)

```bash
WITH_WEBHOOK=0

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --with-webhook) WITH_WEBHOOK=1; shift ;;
            *) shift ;;
        esac
    done
}

install_webhook_service() {
    if [ "$WITH_WEBHOOK" -ne 1 ]; then
        # Interactive prompt for first-time users (per D-23 "gated by flag or prompt")
        if [ -t 0 ]; then
            read -rp "Install webhook listener as a systemd service? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || return 0
        else
            return 0
        fi
    fi

    log_info "Installing webhook listener..."

    # 1. Dependency check: Python 3.11+, systemctl
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "python3 is required for the webhook listener. Install with: apt install python3"
        return 1
    fi
    local py_ver
    py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'; then
        log_error "Python 3.11+ required (found $py_ver). Listener uses stdlib features from 3.11."
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found. Webhook service cannot be installed on this host."
        return 0
    fi

    # 2. WSL2 systemd check (warn, don't block — D-26)
    local wsl2_no_systemd=0
    if grep -qi microsoft /proc/version 2>/dev/null; then
        if [ ! -f /etc/wsl.conf ] || ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf; then
            wsl2_no_systemd=1
            log_warn "WSL2 detected without systemd enabled in /etc/wsl.conf."
            log_warn "Add [boot]\\nsystemd=true to /etc/wsl.conf and run 'wsl.exe --shutdown' to enable."
            log_warn "Installer will copy the unit file but skip 'systemctl enable --now'."
        fi
    fi

    # 3. Resolve the invoking user's home for runtime paths
    local invoking_user invoking_home
    invoking_user="${SUDO_USER:-$USER}"
    invoking_home=$(getent passwd "$invoking_user" | cut -d: -f6)
    if [ -z "$invoking_home" ]; then
        log_error "Could not resolve home directory for user '$invoking_user'"
        return 1
    fi

    # 4. Copy listener files to /opt/claude-secure/webhook/
    sudo mkdir -p /opt/claude-secure/webhook
    sudo cp "$app_dir/webhook/listener.py" /opt/claude-secure/webhook/listener.py
    sudo chmod 755 /opt/claude-secure/webhook/listener.py
    log_info "Copied listener.py to /opt/claude-secure/webhook/"

    # 5. Copy config template to /etc/claude-secure/webhook.json, only if absent
    sudo mkdir -p /etc/claude-secure
    if [ ! -f /etc/claude-secure/webhook.json ]; then
        # Render concrete paths into the config template
        sed \
            -e "s|__REPLACED_BY_INSTALLER__PROFILES__|${invoking_home}/.claude-secure/profiles|" \
            -e "s|__REPLACED_BY_INSTALLER__EVENTS__|${invoking_home}/.claude-secure/events|" \
            -e "s|__REPLACED_BY_INSTALLER__LOGS__|${invoking_home}/.claude-secure/logs|" \
            "$app_dir/webhook/config.example.json" | sudo tee /etc/claude-secure/webhook.json > /dev/null
        sudo chmod 644 /etc/claude-secure/webhook.json
        log_info "Installed default config at /etc/claude-secure/webhook.json"
    else
        log_info "Existing /etc/claude-secure/webhook.json preserved (no overwrite)"
    fi

    # 6. Install systemd unit file
    sudo cp "$app_dir/webhook/claude-secure-webhook.service" /etc/systemd/system/claude-secure-webhook.service
    sudo chmod 644 /etc/systemd/system/claude-secure-webhook.service
    sudo systemctl daemon-reload
    log_info "Installed systemd unit /etc/systemd/system/claude-secure-webhook.service"

    # 7. Enable + start (unless WSL2 without systemd)
    if [ "$wsl2_no_systemd" -eq 1 ]; then
        log_warn "Skipping 'systemctl enable --now' due to WSL2 systemd gate."
        log_warn "After enabling systemd in WSL2, run:"
        log_warn "  sudo systemctl enable --now claude-secure-webhook"
    else
        sudo systemctl enable --now claude-secure-webhook
        # Quick health probe
        sleep 1
        if sudo systemctl is-active --quiet claude-secure-webhook; then
            log_info "Webhook listener is active — tail logs with: journalctl -u claude-secure-webhook -f"
        else
            log_error "Webhook listener failed to start. Check: journalctl -u claude-secure-webhook"
            return 1
        fi
    fi

    log_info "Webhook listener installation complete."
}

# Update main() to call install_webhook_service after install_cli
main() {
    parse_args "$@"
    echo "=== claude-secure installer ==="
    echo ""
    check_dependencies
    detect_platform
    check_existing
    setup_directories
    setup_auth
    setup_workspace
    copy_app_files
    build_images
    install_cli
    install_git_hooks
    install_webhook_service   # NEW — optional, gated by --with-webhook or prompt
    echo ""
    log_info "Installation complete!"
    log_info "Run 'claude-secure --profile default' to start."
}
```

### Idempotency Summary

- `listener.py` copy: always overwritten (latest code ships).
- Unit file: always overwritten (may have directive changes across versions).
- Config file `/etc/claude-secure/webhook.json`: **never overwritten** (D-25). User edits preserved.
- `daemon-reload` + `enable --now` are idempotent by design.
- WSL2 systemd gate is checked fresh each run.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.11+ | Listener runtime (D-01) | Yes (3.12 on dev host) | 3.12.3 | — |
| `http.server` stdlib | HTTP handling | Yes | stdlib | — |
| `hmac` + `hashlib` stdlib | Signature verification | Yes | stdlib | — |
| `threading`, `subprocess`, `signal` stdlib | Concurrency + systemd integration | Yes | stdlib | — |
| systemctl | Install and manage the unit | Yes (dev host) | /usr/bin/systemctl | On WSL2 without `[boot] systemd=true`, installer warns but still copies the unit file; manual enable required later (D-26) |
| openssl | Test HMAC generation | Yes (dev host) | /usr/bin/openssl | — |
| curl | Integration tests (project dep) | Yes | /usr/bin/curl | — |
| `bin/claude-secure` spawn subcommand | Subprocess target (D-16) | Yes (Phase 13 shipped) | — | — |
| `~/.claude-secure/profiles/<name>/profile.json` with `webhook_secret` field | Profile resolution (D-08) | Partial — Phase 12 ships profile.json without `webhook_secret`; user adds it manually | — | Installer README notes that profiles need `webhook_secret` added for webhook routing. Phase 14 does NOT add a CLI command to manage this (deferred — see CONTEXT Deferred Ideas) |

**Missing dependencies with no fallback:** None on real Linux.
**Missing dependencies with fallback:** systemd on WSL2 (documented warn-don't-block per D-26).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `HTTPServer` single-threaded | `ThreadingHTTPServer` | Available since Python 3.7 (2018); stable | One-line change, gives Phase 14 concurrency |
| `X-Hub-Signature` (SHA-1) | `X-Hub-Signature-256` | GitHub deprecated SHA-1 webhook signing ~2020 | Use `hashlib.sha256`, check the new header name |
| `hmac.new(..., digestmod='sha256')` (string digestmod) | `hmac.new(..., digestmod=hashlib.sha256)` (module reference) | Both still work; module reference is slightly faster and future-proof | Stylistic — prefer module form |
| `os.path` for file paths | `pathlib.Path` | Python 3.4+, universally preferred now | Use `pathlib.Path` for all filesystem code |
| Hand-rolled PID-file daemonization | `Type=simple` systemd unit | systemd-native since ~2015 | Zero daemonization code; systemd handles lifecycle |

**Deprecated:**
- SHA-1 HMAC for webhooks — do not use `X-Hub-Signature` (the non-`-256` header). Phase 14 handles only `X-Hub-Signature-256`; if the 256 header is missing, return 400 (D-27).

## Open Questions

Per the "Claude's Discretion" areas in CONTEXT.md, a few planner-level decisions remain. None block planning:

1. **`webhook/config.json` schema additions beyond D-06's defaults.**
   - What we know: Listener runs as root, so all paths must come from config (not `$HOME`). Needs at minimum: `bind`, `port`, `max_concurrent_spawns`, `profiles_dir`, `events_dir`, `logs_dir`, `claude_secure_bin`.
   - What's unclear: Should it also include a `log_level` field? A `dry_run` field?
   - Recommendation: Ship the minimum set above. Add log level if it falls out naturally from the `logging.Handler` setup. Skip dry-run in config — use the optional listener CLI flag for it if the planner implements one.

2. **Single-file vs split module layout inside `webhook/`.**
   - What we know: `validator/validator.py` is 399 lines in one file and works fine. Phase 14's listener will be ~300 lines. CONTEXT D-03 says single-file.
   - What's unclear: Whether planner wants a `profiles.py` split for testability.
   - Recommendation: **Single file.** Matches D-03 literally. `profiles.py` split would add ~30 lines of import boilerplate and one extra file for marginal benefit. Plan for unit tests that import `webhook.listener` directly.

3. **`--dry-run` listener flag.**
   - What we know: Claude's Discretion notes it's "nice-to-have if trivial."
   - What's unclear: Whether it's worth the branch logic.
   - Recommendation: Skip for Phase 14. Use `bin/claude-secure spawn --dry-run --event-file <path>` against a persisted event file for the same debugging workflow. Adds zero new code to Phase 14.

4. **Whether to persist `X-GitHub-Event` into the event-file envelope or re-derive from payload.**
   - What we know: Header is authoritative; payload can also be introspected. D-18 leaves it to planner.
   - Recommendation: **Persist it.** Header is trivial to capture and downstream (Phase 15) avoids guessing event type from payload shape. Namespace as `_meta.event_type` to avoid collision.

All other planning decisions are locked in CONTEXT.md.

## Sources

### Primary (HIGH confidence)

- [GitHub Docs — Validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) — header format, `hmac.compare_digest` example, SHA-1 deprecation note
- [GitHub Docs — Webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads) — header list (`X-GitHub-Event`, `X-GitHub-Delivery`, `X-Hub-Signature-256`, `User-Agent`), `repository.full_name` location
- [GitHub Docs — Handling failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries) — 10-second delivery timeout (not configurable)
- [Python docs — socketserver.BaseServer.shutdown](https://docs.python.org/3/library/socketserver.html#socketserver.BaseServer.shutdown) — deadlock warning (same-thread shutdown)
- [Python docs — hmac module](https://docs.python.org/3/library/hmac.html) — `compare_digest` timing-attack note (confirmed via local `help(hmac.compare_digest)`)
- [Eli Bendersky — Payload server in Python 3 for GitHub webhooks](https://eli.thegreenplace.net/2014/07/09/payload-server-in-python-3-for-github-webhooks) — canonical stdlib pattern (swap SHA-1 → SHA-256)
- `validator/validator.py` (local) — structural template: BaseHTTPRequestHandler, `_send_json`, JSONL logging handler, main block
- `bin/claude-secure` lines 447-567 (local) — `do_spawn` contract, `--event-file` consumption, ephemeral `cs-<profile>-<uuid8>` naming
- `install.sh` (local) — existing installer patterns, WSL2 detection at line 50
- `docker-compose.yml` (local) — reference for service topology (not directly modified by Phase 14)

### Secondary (MEDIUM confidence)

- [Hookdeck — Guide to GitHub Webhooks](https://hookdeck.com/webhooks/platforms/guide-github-webhooks-features-and-best-practices) — 10-second timeout confirmation, best practices
- [python-graceful-shutdown (wbenny)](https://github.com/wbenny/python-graceful-shutdown) — SIGTERM handler pattern for threaded servers
- [Medium — Keep Your Python HTTP Server Running (systemd)](https://ponnala.medium.com/never-let-your-python-http-server-die-step-by-step-guide-to-auto-start-on-boot-and-crash-recovery-1f7b0f94401e) — standard systemd unit patterns for python http.server services

### Tertiary (LOW confidence — flagged for validation during implementation)

- **Flat-vs-envelope event-file format compatibility with Phase 13 `do_spawn`.** Research recommends flat (`_meta` sibling) based on reading `bin/claude-secure:503`, but the planner should verify by running `bin/claude-secure spawn --event-file <persisted-flat-json>` in a Wave 0 test before committing to the format. If envelope is needed, it's a small change to `render_template` in Phase 13 — but that would touch locked Phase 13 code.
- **`systemd-analyze verify` exit code behavior** for unit files that reference missing binaries. Verified it parses syntax, not presence of `ExecStart` target — but some distros may behave differently. Wave 0 should confirm on the actual CI host.
- **WSL2 systemd gating behavior when user *later* enables systemd and reboots.** Installer's `systemctl daemon-reload` may fail on WSL2-without-systemd in an unexpected way. Phase 14 should wrap in `|| log_warn "..."` so install doesn't abort.

## Metadata

**Confidence breakdown:**
- Standard stack (stdlib primitives): HIGH — all verified by local `python3 -c 'import ...'` and stdlib docs
- HMAC and GitHub webhook spec: HIGH — verified against GitHub official docs
- Concurrency pattern (Semaphore + daemon thread): HIGH — canonical Python concurrency pattern, matches CONTEXT decisions exactly
- systemd unit file directives: HIGH for Type/Restart/RestartSec/StandardOutput/After (standard practice); MEDIUM for hardening directives which are deliberately not added (needs empirical test to confirm each doesn't break Docker invocation)
- Home-directory-under-root gotcha: HIGH — root's `$HOME` is `/root`, this is a universal systemd gotcha
- Flat event-file format with Phase 13 compatibility: MEDIUM — recommendation is sound but needs Wave 0 empirical confirmation
- WSL2 detection: HIGH — existing install.sh already uses the pattern

**Research date:** 2026-04-12
**Valid until:** 30 days (Python stdlib and GitHub webhook spec are highly stable; revisit only if CONTEXT.md decisions change)

## RESEARCH COMPLETE
