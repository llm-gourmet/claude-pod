#!/usr/bin/env python3
"""claude-secure webhook listener.

Receives GitHub webhook POSTs, verifies HMAC-SHA256 against the raw body,
persists the payload, and hands off to `claude-secure spawn` via subprocess.

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
import pathlib
import signal
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ---------------------------------------------------------------------------
# Event filter (Phase 15: D-05..D-10)
# ---------------------------------------------------------------------------
# D-06: Sane defaults when profile.webhook_event_filter is omitted.
# Empty arrays for labels/workflows mean "match anything in that category".
DEFAULT_FILTER = {
    "issues": {"actions": ["opened", "labeled"], "labels": []},
    "push": {"branches": ["main", "master"]},
    "workflow_run": {"conclusions": ["failure"], "workflows": []},
}


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


def apply_event_filter(profile: dict, event_type: str, payload: dict):
    """Return (allowed: bool, reason: str). `reason` is empty when allowed.

    D-05..D-10. Zero I/O: takes the already-loaded profile dict, does dict
    lookups only. Sub-millisecond per call (Pitfall 3).
    """
    base = event_type.split("-", 1)[0]
    fcfg = (profile.get("webhook_event_filter") or {}).get(base)
    if fcfg is None:
        fcfg = DEFAULT_FILTER.get(base)
    if fcfg is None:
        # Unknown base event type -- not an error, just filter out (D-04).
        # This catches `ping` and any other event GitHub may add.
        return (False, f"unsupported_event:{base}")

    if base == "issues":
        action = payload.get("action", "") if isinstance(payload, dict) else ""
        if fcfg.get("actions") and action not in fcfg["actions"]:
            return (False, f"issue_action_not_matched:{action}")
        required_labels = fcfg.get("labels") or []
        if required_labels:
            issue = payload.get("issue") or {}
            labels = {
                lbl.get("name", "")
                for lbl in issue.get("labels", [])
                if isinstance(lbl, dict)
            }
            if not labels.intersection(required_labels):
                return (False, "issue_labels_not_matched")
        return (True, "")

    if base == "push":
        # D-09: Loop prevention FIRST (before branch matching), so a bot
        # push to main is still filtered.
        bot_users = profile.get("webhook_bot_users") or []
        pusher = ((payload.get("pusher") or {}).get("name") or "")
        if pusher and pusher in bot_users:
            return (False, "loop_prevention")
        ref = payload.get("ref", "") or ""
        if ref.startswith("refs/heads/"):
            branch = ref[len("refs/heads/"):]
        else:
            branch = ref
        allowed_branches = fcfg.get("branches") or []
        if allowed_branches and branch not in allowed_branches:
            return (False, f"branch_not_matched:{branch}")
        return (True, "")

    if base == "workflow_run":
        action = payload.get("action") if isinstance(payload, dict) else None
        if action != "completed":
            return (False, f"workflow_action_not_completed:{action}")
        wr = payload.get("workflow_run") or {}
        conclusion = wr.get("conclusion") or ""
        allowed_conclusions = fcfg.get("conclusions") or []
        if allowed_conclusions and conclusion not in allowed_conclusions:
            return (False, f"workflow_conclusion_not_matched:{conclusion}")
        allowed_workflows = fcfg.get("workflows") or []
        if allowed_workflows:
            wf_name = (
                (payload.get("workflow") or {}).get("name")
                or wr.get("name")
                or ""
            )
            if wf_name not in allowed_workflows:
                return (False, f"workflow_name_not_matched:{wf_name}")
        return (True, "")

    return (False, f"unsupported_event:{base}")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
class Config:
    """Runtime configuration loaded from webhook/config.json."""

    def __init__(self, data: dict):
        self.bind = data.get("bind", "127.0.0.1")
        self.port = int(data["port"])
        self.max_concurrent_spawns = int(data.get("max_concurrent_spawns", 3))
        self.profiles_dir = pathlib.Path(data["profiles_dir"])
        self.events_dir = pathlib.Path(data["events_dir"])
        self.logs_dir = pathlib.Path(data["logs_dir"])
        self.claude_secure_bin = data.get(
            "claude_secure_bin", "/usr/local/bin/claude-secure"
        )


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
# Profile resolution (D-08, Pattern 4)
# ---------------------------------------------------------------------------
def resolve_profile_by_repo(profiles_dir: pathlib.Path, repo_full_name: str):
    """Scan profiles_dir for a profile whose `repo` matches repo_full_name.

    Returns dict {name, repo, webhook_secret, webhook_event_filter,
    webhook_bot_users} or None. The filter + bot_users fields are loaded
    here (single disk read) so that Phase 15's apply_event_filter can work
    against an in-memory dict with zero I/O (Pitfall 3).

    Gotcha 8: profile.json may be mid-write during scan; skip on parse error.
    """
    if not repo_full_name:
        return None
    if not profiles_dir.exists():
        return None
    for profile_json in profiles_dir.glob("*/profile.json"):
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


def spawn_async(profile_name: str, event_path: pathlib.Path, delivery_id: str):
    """Launch a daemon thread that will acquire the semaphore and spawn."""
    t = threading.Thread(
        target=_spawn_worker,
        args=(profile_name, event_path, delivery_id),
        daemon=True,
        name=f"spawn-{delivery_id[:12]}",
    )
    t.start()


def _spawn_worker(profile_name: str, event_path: pathlib.Path, delivery_id: str):
    """Worker thread: acquire semaphore, run claude-secure spawn, log result."""
    global _active_spawns
    _spawn_semaphore.acquire()  # may block if saturated (D-15)
    with _active_lock:
        _active_spawns += 1
    try:
        spawns_dir = _config.logs_dir / "spawns"
        spawns_dir.mkdir(parents=True, exist_ok=True)
        log_path = spawns_dir / f"{delivery_id}.log"
        with open(log_path, "wb") as log_fp:
            # close_fds=True is the Python 3.7+ default on POSIX (Gotcha 6).
            # Pass CONFIG_DIR derived from profiles_dir so the spawn works
            # regardless of which user $HOME the process runs under (e.g. root
            # when invoked from systemd).
            spawn_env = os.environ.copy()
            spawn_env["CONFIG_DIR"] = str(_config.profiles_dir.parent)
            proc = subprocess.Popen(
                [
                    _config.claude_secure_bin,
                    "spawn",
                    "--profile",
                    profile_name,
                    "--event-file",
                    str(event_path),
                ],
                stdout=log_fp,
                stderr=subprocess.STDOUT,
                env=spawn_env,
            )
            log_event(
                event="spawned",
                profile=profile_name,
                delivery_id=delivery_id,
                spawn_pid=proc.pid,
            )
            rc = proc.wait()
            log_event(
                event="spawn_completed",
                profile=profile_name,
                delivery_id=delivery_id,
                spawn_pid=proc.pid,
                exit_code=rc,
            )
    except Exception as exc:
        log_event(
            event="spawn_error",
            profile=profile_name,
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

    server_version = "claude-secure-webhook/1.0"

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

        profile = resolve_profile_by_repo(_config.profiles_dir, repo)

        # D-11: unknown repo -> 404 BEFORE HMAC check
        if profile is None:
            log_event(
                event="rejected",
                repo=repo,
                reason="unknown_repo",
                source_ip=self.client_address[0],
                status_code=404,
            )
            return self._send_json(404, {"error": "unknown_repo"})

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

        # D-05..D-10: per-profile filter between HMAC and persist.
        # D-07: filtered events log + return 202 WITHOUT persisting or spawning.
        allowed, reason = apply_event_filter(profile, event_type, payload)
        if not allowed:
            log_event(
                event="filtered",
                profile=profile["name"],
                repo=repo,
                delivery_id=delivery_id,
                event_type=event_type,
                reason=reason,
                status_code=202,
            )
            return self._send_json(
                202, {"status": "filtered", "reason": reason}
            )

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

        spawn_async(profile["name"], event_path, delivery_id)
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

    ap = argparse.ArgumentParser(description="claude-secure webhook listener")
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
