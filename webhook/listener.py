#!/usr/bin/env python3
"""claude-pod webhook listener.

Receives GitHub webhook POSTs, verifies HMAC-SHA256 against the raw body,
persists the payload, and hands off to `claude-pod spawn` via subprocess.

Locked decisions: see .planning/phases/14-webhook-listener/14-CONTEXT.md D-01..D-27.

GOTCHA 1 (critical): the raw body bytes captured by self.rfile.read(length)
MUST be passed verbatim to hmac.new AND to the event-file writer. NEVER
round-trip through json.loads + re-encoding -- that produces different
bytes and breaks HMAC verification silently on ~20% of payloads.

GOTCHA 3: SIGTERM handler must dispatch server.shutdown() on a DIFFERENT
thread than serve_forever() or it deadlocks for 90s until systemd SIGKILLs.
"""
import argparse
import datetime
import hashlib
import hmac
import json
import logging
import os
import pathlib
import signal
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def compute_event_type(headers, payload: dict) -> str:
    """Collapse (X-GitHub-Event, payload.action) into composite type string.

    D-01: Examples:
        ('issues', 'opened')          -> 'issues-opened'
        ('issues', 'labeled')         -> 'issues-labeled'
        ('push', None)                -> 'push'
        ('workflow_run', 'completed') -> 'workflow_run-completed'
        ('ping', None)                -> 'ping'

    `headers` may be a dict or BaseHTTPRequestHandler.headers (HTTPMessage);
    both support .get().
    """
    base = (headers.get("X-GitHub-Event") or "").strip()
    if not base:
        return "unknown"
    action = payload.get("action") if isinstance(payload, dict) else None
    if isinstance(action, str) and action:
        return f"{base}-{action}"
    return base


# ---------------------------------------------------------------------------
# Loop-prevention skip filter evaluation
# ---------------------------------------------------------------------------
def _filter_matches_one(base: str, payload: dict, filter_value: str) -> "tuple[bool, str]":
    """Check if a single filter value matches the given event type + payload.

    Returns (matched, reason). Non-applicable event types always return False.
    """
    if base == "push":
        commits = payload.get("commits")
        if not commits:
            return False, ""
        if all(
            isinstance(c, dict) and c.get("message", "").startswith(filter_value)
            for c in commits
        ):
            return True, "all commits prefixed"
        return False, ""
    if base in ("pull_request", "issues", "discussion"):
        labels = payload.get("labels") or []
        if any(isinstance(lbl, dict) and lbl.get("name") == filter_value for lbl in labels):
            return True, "label match"
        return False, ""
    if base in ("issue_comment", "pull_request_review", "pull_request_review_comment"):
        key = "review" if base == "pull_request_review" else "comment"
        obj = payload.get(key) or {}
        body = obj.get("body") if isinstance(obj, dict) else None
        if isinstance(body, str) and body.startswith(filter_value):
            return True, "body prefix"
        return False, ""
    # workflow_run, check_run, create, delete, deployment, ping, etc.
    return False, ""


def evaluate_skip_filters(
    event_type: str, payload: dict, skip_filters: list
) -> "tuple[bool, str, str]":
    """Return (should_skip, matched_filter_value, reason) given the event and connection filters.

    Uses the base event type (part before first '-') for dispatch so that composite
    types like 'pull_request-opened' match the 'pull_request' rule.
    """
    if not skip_filters:
        return False, "", ""
    base = event_type.split("-")[0]
    for fv in skip_filters:
        matched, reason = _filter_matches_one(base, payload, fv)
        if matched:
            return True, fv, reason
    return False, "", ""


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
class Config:
    """Runtime configuration loaded from webhook/config.json."""

    def __init__(self, data: dict):
        self.bind = data.get("bind", "127.0.0.1")
        self.port = int(data.get("port", 9000))
        self.max_concurrent_spawns = int(data.get("max_concurrent_spawns", 3))
        self.profiles_dir = pathlib.Path(data["profiles_dir"])
        self.docs_dir = pathlib.Path(data["docs_dir"]) if data.get("docs_dir") else None
        self.webhooks_dir = pathlib.Path(data["webhooks_dir"]) if data.get("webhooks_dir") else None
        self.events_dir = pathlib.Path(data["events_dir"])
        self.logs_dir = pathlib.Path(data["logs_dir"])
        self.claude_pod_bin = data.get(
            "claude_pod_bin", "/usr/local/bin/claude-pod"
        )
        self.config_dir = data.get("config_dir") or ""


def load_config(path: pathlib.Path) -> Config:
    if not path.exists():
        print(f"ERROR: config file not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    try:
        with open(path) as f:
            return Config(json.load(f))
    except (json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"ERROR: invalid config file {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)


# ---------------------------------------------------------------------------
# JSONL structured logger (D-21)
# ---------------------------------------------------------------------------
class JsonlHandler(logging.Handler):
    """Writes structured JSON log entries to webhook.jsonl."""

    def __init__(self, filepath: pathlib.Path):
        super().__init__()
        self.filepath = filepath
        self.filepath.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def emit(self, record):
        try:
            data = getattr(record, "data", {}) or {}
            entry = {
                "ts": datetime.datetime.now(datetime.UTC).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
                **data,
            }
            line = json.dumps(entry) + "\n"
            with self._lock:
                with open(self.filepath, "a") as f:
                    f.write(line)
        except Exception:
            # Logging must never raise
            pass


logger = logging.getLogger("webhook")


def log_event(**kwargs):
    """Emit a structured JSONL log record."""
    record = logger.makeRecord(
        "webhook", logging.INFO, "", 0, "", (), None
    )
    record.data = kwargs
    logger.handle(record)


# ---------------------------------------------------------------------------
# Connection resolution — reads ~/.claude-pod/webhooks/connections.json
# ---------------------------------------------------------------------------
def resolve_connection_by_repo(
    webhooks_dir: "pathlib.Path | None",
    repo_full_name: str,
):
    """Read connections.json and return the entry whose `repo` matches repo_full_name.

    Returns dict {name, repo, webhook_secret} or None.
    Extra fields in connections.json (webhook_event_filter, github_token, etc.)
    are silently ignored for backward compatibility.
    """
    if not repo_full_name or webhooks_dir is None:
        return None
    connections_path = webhooks_dir / "connections.json"
    try:
        data = json.loads(connections_path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    for entry in data:
        if entry.get("repo") == repo_full_name:
            secret = entry.get("webhook_secret")
            if not secret:
                return None
            return {
                "name": entry["name"],
                "repo": repo_full_name,
                "webhook_secret": secret,
                "profile": entry.get("profile") or entry["name"],
                "skip_filters": entry.get("skip_filters") or [],
            }
    return None


# ---------------------------------------------------------------------------
# Profile resolution (D-08, Pattern 4) — kept for reference; no longer used
# ---------------------------------------------------------------------------
def resolve_profile_by_repo(
    profiles_dir: pathlib.Path,
    repo_full_name: str,
    docs_dir: "pathlib.Path | None" = None,
):
    """Scan profiles_dir (then docs_dir) for a profile whose `repo` matches repo_full_name.

    profiles_dir is checked first so project profiles take priority over docs
    profiles when both directories contain a profile for the same repo.

    Returns dict {name, repo, webhook_secret, webhook_event_filter,
    webhook_bot_users} or None. The filter + bot_users fields are loaded
    here (single disk read) so that Phase 15's apply_event_filter can work
    against an in-memory dict with zero I/O (Pitfall 3).

    Gotcha 8: profile.json may be mid-write during scan; skip on parse error.
    """
    if not repo_full_name:
        return None
    for search_dir in [profiles_dir, docs_dir]:
        if search_dir is None or not search_dir.exists():
            continue
        for profile_json in search_dir.glob("*/profile.json"):
            try:
                data = json.loads(profile_json.read_text())
            except (OSError, json.JSONDecodeError):
                # Profile mid-write or unreadable -- skip and continue
                continue
            if data.get("repo") == repo_full_name:
                secret = data.get("webhook_secret")
                if not secret:
                    # Profile exists but has no webhook secret configured
                    return None
                return {
                    "name": profile_json.parent.name,
                    "repo": repo_full_name,
                    "webhook_secret": secret,
                    "webhook_event_filter": data.get("webhook_event_filter") or {},
                    "webhook_bot_users": data.get("webhook_bot_users") or [],
                    "todo_path_pattern": data.get("todo_path_pattern") or "",
                    "github_token": data.get("github_token") or "",
                }
    return None


# ---------------------------------------------------------------------------
# Event file persistence (D-17, D-18, Pattern 5 flat format)
# ---------------------------------------------------------------------------
def persist_event(
    events_dir: pathlib.Path,
    raw_body: bytes,
    profile_name: str,
    event_type: str,
    delivery_id: str,
) -> pathlib.Path:
    """Write the raw github payload + _meta sidecar to events_dir.

    Filename: <ISO8601Z>-<uuid8>.json
    The raw_body was already used for HMAC verification; here we parse it
    ONLY to inject the _meta key. We never re-serialize for HMAC.
    """
    events_dir.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now(datetime.UTC)
    ts = now.strftime("%Y%m%dT%H%M%SZ")
    suffix = uuid.uuid4().hex[:8]
    path = events_dir / f"{ts}-{suffix}.json"
    payload = json.loads(raw_body)
    payload["event_type"] = event_type           # D-02: canonical top-level field
    payload["_meta"] = {
        "received_at": now.isoformat().replace("+00:00", "Z"),
        "profile": profile_name,
        "event_type": event_type,                # kept for backward compat (D-02)
        "delivery_id": delivery_id,
    }
    path.write_text(json.dumps(payload, indent=2))
    return path


# ---------------------------------------------------------------------------
# Semaphore-bounded spawn worker (Pattern 2, D-13..D-16)
# ---------------------------------------------------------------------------
_spawn_semaphore: threading.Semaphore = None  # set in main()
_active_spawns = 0
_active_lock = threading.Lock()
_config: Config = None  # set in main()


def spawn_async(connection_name: str, event_path: pathlib.Path, delivery_id: str):
    """Launch a daemon thread that will acquire the semaphore and spawn."""
    t = threading.Thread(
        target=_spawn_worker,
        args=(connection_name, event_path, delivery_id),
        daemon=True,
        name=f"spawn-{delivery_id[:12]}",
    )
    t.start()


def _spawn_worker(connection_name: str, event_path: pathlib.Path, delivery_id: str):
    """Worker thread: acquire semaphore, call claude-pod spawn, log outcome."""
    global _active_spawns
    _spawn_semaphore.acquire()  # may block if saturated (D-15)
    with _active_lock:
        _active_spawns += 1
    try:
        log_event(event="spawn_start", connection=connection_name, delivery_id=delivery_id)
        log_path = _config.logs_dir / f"spawn-{delivery_id[:12]}.log"
        try:
            spawn_env = None
            if _config.config_dir:
                spawn_env = os.environ.copy()
                spawn_env["CONFIG_DIR"] = _config.config_dir
            result = subprocess.run(
                [_config.claude_pod_bin, "spawn", connection_name, "--event-file", str(event_path)],
                capture_output=True,
                text=True,
                env=spawn_env,
            )
            log_path.write_text(result.stdout + result.stderr)
            if result.returncode == 0:
                log_event(event="spawn_done", connection=connection_name, delivery_id=delivery_id)
            else:
                log_event(
                    event="spawn_error",
                    connection=connection_name,
                    delivery_id=delivery_id,
                    exit_code=result.returncode,
                )
        except Exception as exc:
            log_event(
                event="spawn_exception",
                connection=connection_name,
                delivery_id=delivery_id,
                error=str(exc),
            )
    finally:
        with _active_lock:
            _active_spawns -= 1
        _spawn_semaphore.release()


# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------
class WebhookHandler(BaseHTTPRequestHandler):
    """HTTP handler for /webhook and /health endpoints."""

    server_version = "claude-pod-webhook/1.0"

    # Silence default stderr access log; we use structured JSONL logging.
    def log_message(self, fmt, *args):
        return

    def _send_json(self, code: int, body: dict):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            pass

    def do_GET(self):
        if self.path == "/health":
            with _active_lock:
                n = _active_spawns
            log_event(event="health", active_spawns=n, status_code=200)
            return self._send_json(200, {"status": "ok", "active_spawns": n})
        if self.path == "/webhook":
            return self._send_json(405, {"error": "method_not_allowed"})
        return self._send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/webhook":
            return self._send_json(404, {"error": "not_found"})

        # --- GOTCHA 1: read raw body exactly once, keep as bytes ---
        # These bytes are the SOLE input to hmac.new. Never re-serialize.
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            length = 0
        if length <= 0:
            return self._send_json(400, {"error": "empty_body"})
        raw_body: bytes = self.rfile.read(int(self.headers["Content-Length"]))

        # Parse payload for routing only. NEVER pass parsed dict to HMAC.
        try:
            payload = json.loads(raw_body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            log_event(
                event="rejected",
                reason="invalid_json",
                source_ip=self.client_address[0],
                status_code=400,
            )
            return self._send_json(400, {"error": "invalid_json"})

        if not isinstance(payload, dict):
            log_event(
                event="rejected",
                reason="invalid_json",
                source_ip=self.client_address[0],
                status_code=400,
            )
            return self._send_json(400, {"error": "invalid_json"})

        repo = None
        repo_obj = payload.get("repository")
        if isinstance(repo_obj, dict):
            repo = repo_obj.get("full_name")

        profile = resolve_connection_by_repo(_config.webhooks_dir, repo)

        # D-11: unknown repo -> 404 BEFORE HMAC check
        if profile is None:
            log_event(
                event="rejected",
                repo=repo,
                reason="unknown_connection",
                source_ip=self.client_address[0],
                status_code=404,
            )
            return self._send_json(404, {"error": "unknown_connection"})

        # HMAC verification against RAW BYTES (Gotcha 1)
        sig_header = self.headers.get("X-Hub-Signature-256", "")
        if not sig_header.startswith("sha256="):
            log_event(
                event="rejected",
                profile=profile["name"],
                reason="missing_header",
                source_ip=self.client_address[0],
                status_code=400,
            )
            return self._send_json(
                400,
                {"error": "missing_header", "header": "X-Hub-Signature-256"},
            )
        received_sig = sig_header.split("=", 1)[1]
        secret_bytes = profile["webhook_secret"].encode("utf-8")
        expected_sig = hmac.new(
            secret_bytes, raw_body, hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(expected_sig, received_sig):
            log_event(
                event="rejected",
                profile=profile["name"],
                reason="invalid_signature",
                source_ip=self.client_address[0],
                status_code=401,
            )
            return self._send_json(401, {"error": "invalid_signature"})

        # Persist payload + enqueue spawn
        delivery_id = self.headers.get(
            "X-GitHub-Delivery", f"nodelivery-{uuid.uuid4().hex[:8]}"
        )

        # D-01: composite event type from header + payload.action
        event_type = compute_event_type(self.headers, payload)

        # Loop-prevention: evaluate skip_filters before spawning
        should_skip, filter_value, skip_reason = evaluate_skip_filters(
            event_type, payload, profile.get("skip_filters") or []
        )
        if should_skip:
            log_event(
                event="skipped",
                connection=profile["name"],
                delivery_id=delivery_id,
                filter_value=filter_value,
                reason=skip_reason,
            )
            return self._send_json(200, {"status": "skipped", "filter_value": filter_value})

        try:
            event_path = persist_event(
                _config.events_dir,
                raw_body,
                profile["name"],
                event_type,
                delivery_id,
            )
        except Exception as exc:
            log_event(
                event="rejected",
                profile=profile["name"],
                reason=f"persist_failed:{exc}",
                delivery_id=delivery_id,
                status_code=500,
            )
            return self._send_json(
                500, {"error": "persist_failed", "detail": str(exc)}
            )

        # D-23: new 'routed' log event — accepted into the spawn pipeline
        log_event(
            event="routed",
            profile=profile["name"],
            repo=repo,
            delivery_id=delivery_id,
            event_type=event_type,
            status_code=202,
        )

        # Retain Phase 14 'received' log line for backward compatibility.
        log_event(
            event="received",
            profile=profile["name"],
            repo=repo,
            delivery_id=delivery_id,
            event_type=event_type,
            status_code=202,
        )

        spawn_async(profile["profile"], event_path, delivery_id)
        return self._send_json(
            202, {"status": "accepted", "delivery_id": delivery_id}
        )


# ---------------------------------------------------------------------------
# Graceful shutdown (Pattern 3, Gotcha 3)
# ---------------------------------------------------------------------------
_server: ThreadingHTTPServer = None


def _sigterm_handler(signum, frame):
    """SIGTERM/SIGINT handler: dispatch shutdown on a separate thread.

    Gotcha 3: server.shutdown() blocks until serve_forever() returns, and
    must NEVER be called from the serving thread or it deadlocks.
    """
    try:
        sig_name = signal.Signals(signum).name
    except ValueError:
        sig_name = str(signum)
    log_event(event="shutdown", signal=sig_name)
    if _server is not None:
        threading.Thread(target=_server.shutdown, daemon=True).start()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global _server, _spawn_semaphore, _config

    ap = argparse.ArgumentParser(description="claude-pod webhook listener")
    ap.add_argument("--config", required=True, type=pathlib.Path)
    args = ap.parse_args()

    _config = load_config(args.config)
    _spawn_semaphore = threading.Semaphore(_config.max_concurrent_spawns)

    # Wire up JSONL logger
    _config.logs_dir.mkdir(parents=True, exist_ok=True)
    logger.setLevel(logging.INFO)
    logger.addHandler(JsonlHandler(_config.logs_dir / "webhook.jsonl"))
    logger.propagate = False

    _server = ThreadingHTTPServer(
        (_config.bind, _config.port), WebhookHandler
    )
    signal.signal(signal.SIGTERM, _sigterm_handler)
    signal.signal(signal.SIGINT, _sigterm_handler)

    log_event(
        event="listener_started",
        bind=_config.bind,
        port=_config.port,
        max_concurrent_spawns=_config.max_concurrent_spawns,
    )
    try:
        _server.serve_forever()
    finally:
        _server.server_close()
        log_event(event="listener_stopped")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"ERROR: listener crashed: {exc}", file=sys.stderr)
        sys.exit(1)
