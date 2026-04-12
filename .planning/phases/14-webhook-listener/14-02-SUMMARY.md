---
phase: 14-webhook-listener
plan: 02
subsystem: webhook-listener
tags: [webhook, hmac, threading, stdlib, python]
requires:
  - 14-01 (test scaffold from Wave 0)
  - 13-02 (bin/claude-secure spawn subcommand + --event-file flag)
  - 12-CONTEXT (profile.json schema with repo + webhook_secret fields)
provides:
  - HOOK-02 (HMAC-SHA256 raw-body verification)
  - HOOK-06 (concurrent-safe dispatch via ThreadingHTTPServer + Semaphore)
  - "webhook/listener.py (single-file stdlib service)"
  - "webhook/config.example.json (installer template)"
affects:
  - Plan 14-03 (systemd unit will ExecStart /opt/claude-secure/webhook/listener.py)
  - Plan 14-04 (install.sh will sed-replace __REPLACED_BY_INSTALLER__ sentinels)
  - Phase 15 (will consume persisted event files + extend routing)
tech-stack:
  added:
    - "Python 3.11+ stdlib: http.server.ThreadingHTTPServer, hmac, threading.Semaphore, subprocess.Popen"
  patterns:
    - "Raw-body HMAC verification (never re-serialize)"
    - "Daemon thread + semaphore for async spawn dispatch"
    - "SIGTERM handler dispatches shutdown() on a worker thread (Gotcha 3)"
    - "Profile-scan-by-repo with JSONDecodeError resilience (Gotcha 8)"
    - "JSONL structured logging sibling of validator.py"
key-files:
  created:
    - webhook/listener.py
    - webhook/config.example.json
  modified: []
decisions:
  - "Honored D-01..D-27 in full; zero non-stdlib imports verified by AST walker"
  - "Unknown-repo check fires BEFORE HMAC verification (D-11) -- confirmed by test_unknown_repo_404"
  - "Used datetime.now(datetime.UTC) exclusively; datetime.utcnow is forbidden (Python 3.12+ deprecation)"
  - "Chose flat event-file format: github payload + top-level _meta key (Pattern 5)"
  - "Unknown-repo and invalid-signature payloads intentionally NOT persisted (D-19 hostile-payload hygiene)"
metrics:
  duration: ~35m
  completed: 2026-04-12
  tasks: 2
  files_created: 2
  lines_of_code: 470
---

# Phase 14 Plan 02: Webhook Listener Core Summary

**One-liner:** Single-file Python stdlib webhook listener delivering HOOK-02 (HMAC-SHA256 raw-body verification) and HOOK-06 (bounded concurrent dispatch via ThreadingHTTPServer + Semaphore) -- 461 lines, zero pip dependencies.

## What Was Built

### `webhook/listener.py` (461 lines)

Structural siblings of `validator/validator.py`: `BaseHTTPRequestHandler` subclass, `_send_json` helper, `logging.Handler` subclass for JSONL output, same single-file philosophy. Key primitives used:

| Primitive | Purpose |
| --- | --- |
| `http.server.ThreadingHTTPServer` | Per-request thread model (HOOK-06) |
| `hmac.new(secret, raw_body, hashlib.sha256)` | Signature computation on **raw bytes** (Gotcha 1) |
| `hmac.compare_digest(...)` | Timing-safe comparison |
| `threading.Semaphore(max_concurrent_spawns)` | Bounded concurrency (D-13, default 3) |
| `threading.Thread(daemon=True)` | Async spawn worker so 202 returns immediately (D-14) |
| `subprocess.Popen([claude_secure_bin, "spawn", ...])` | Delegate to Phase 13 CLI, no shell=True |
| `signal.signal(SIGTERM, ...)` + `threading.Thread(target=_server.shutdown)` | Gotcha 3 safe shutdown (must NOT call shutdown() from serving thread) |
| `datetime.datetime.now(datetime.UTC)` | Timezone-aware timestamps (no deprecated `utcnow`) |
| `pathlib.Path.glob("*/profile.json")` | Per-request profile scan, no caching (D-10) |

### `webhook/config.example.json` (9 lines)

Template shipped with the project. Uses `__REPLACED_BY_INSTALLER__PROFILES__` etc. sentinels that Plan 14-04's install.sh will sed-substitute based on `$SUDO_USER`'s home. Avoids Gotcha 7 (systemd `User=root` + `pathlib.Path.home()` = `/root/.claude-secure`).

## Test Results

Ran `bash tests/test-phase14.sh` after Task 1 and after Task 2. Both runs identical: **14/16 PASS, 2 FAIL**.

### Passing (all owned by Plan 14-02)

| Test | Proves |
| --- | --- |
| `test_hmac_valid` | POST with `printf '%s'`-signed body → 202, event file persisted |
| `test_hmac_invalid` | Wrong-secret signature → 401, NO event file created |
| `test_hmac_missing_header` | No `X-Hub-Signature-256` → 400 `{"error":"missing_header"}` |
| `test_hmac_newline_sensitivity` | `echo`-signed (trailing `\n`) body → 401. Proves raw bytes are read literally, not normalized. |
| `test_unknown_repo_404` | `repository.full_name: "unknown/repo"` → 404 **before** HMAC; log has `reason: unknown_repo`, not `invalid_signature` |
| `test_concurrent_5` | 5 parallel webhooks → 5× 202, 5 event files, 5 stub invocations |
| `test_semaphore_queue` | 6 parallel webhooks with `max_concurrent_spawns=3` → 6× 202 immediately, 6 stub calls eventually |
| `test_health_active_spawns` | `GET /health` during slow spawn → `active_spawns ≥ 1` |
| `test_wrong_path_404` | `POST /foo` → 404 `{"error":"not_found"}` |
| `test_wrong_method_405` | `GET /webhook` → 405 `{"error":"method_not_allowed"}` |
| `test_invalid_json_400` | Properly-signed `not json` → 400 `{"error":"invalid_json"}` |
| `test_sigterm_shutdown` | `kill -TERM` → process exits in <2s (Gotcha 3 avoided) |
| `test_missing_config` | `--config /nonexistent.json` → rc=2 within 1s |

### Failing (NOT owned by Plan 14-02)

| Test | Belongs to | Expected |
| --- | --- | --- |
| `test_unit_file_lint` | Plan 14-03 | `webhook/claude-secure-webhook.service` not yet created |
| `test_install_webhook` | Plan 14-04 | `install.sh` not yet extended with `--with-webhook` + `install_webhook_service` |

These match exactly the Wave 0 sampling map expectation: Plan 14-02 brings 12 tests green (plus `test_missing_config`), leaving the 2 file-level contract tests for the other Wave 1 plans.

## Acceptance Criteria Verification

All Task 1 and Task 2 acceptance criteria verified:

- `python3 -c "import ast; ast.parse(open('webhook/listener.py').read())"` → exit 0
- `grep` checks: `hmac.compare_digest`, `self.rfile.read(int(self.headers`, `threading.Semaphore`, `subprocess.Popen`, `signal.signal(signal.SIGTERM`, `threading.Thread(target=_server.shutdown`, `datetime.UTC`, `ThreadingHTTPServer` all present.
- `grep 'json\.dumps(json\.loads(raw_body))' webhook/listener.py` → 0 matches (anti-pattern absent; initial docstring mention was rephrased).
- `grep 'datetime\.utcnow' webhook/listener.py` → 0 matches.
- `hmac.new(... raw_body ...)` present (multi-line, verified via Python regex walker).
- AST module walker: imports restricted to `{argparse, datetime, hashlib, hmac, http, json, logging, pathlib, signal, subprocess, sys, threading, uuid}` — all stdlib.
- `jq -e '.bind == "127.0.0.1" and .port == 9000 and .max_concurrent_spawns == 3 ...'` → true.
- Config contains no `~` or `$HOME`.

## Deviations from Plan

### 1. [Rule 1 - Bug] Rephrased Gotcha 1 docstring to avoid literal anti-pattern

- **Found during:** Task 1 post-write grep
- **Issue:** Initial module docstring contained the literal text `json.dumps(json.loads(raw_body))` as a cautionary example. Acceptance criteria requires `grep 'json\.dumps(json\.loads(raw_body))' webhook/listener.py` to return zero matches.
- **Fix:** Reworded to "round-trip through json.loads + re-encoding" — semantically identical warning, no literal match.
- **Files modified:** `webhook/listener.py` (module docstring only)
- **Commit:** 5471097 (pre-commit amendment — caught before first commit)

### 2. [Rule 2 - Critical] Defensive `isinstance(payload, dict)` check

- **Found during:** Task 1 implementation (not in plan skeleton)
- **Issue:** The skeleton does `(payload.get("repository") or {}).get("full_name")` which assumes `payload` is a dict. A webhook with body `"just a string"` parses as a valid JSON string but would crash on `.get()`.
- **Fix:** Added `if not isinstance(payload, dict): return 400 invalid_json` immediately after `json.loads`. Preserves the invariant that `payload` is always dict-shaped before routing.
- **Files modified:** `webhook/listener.py` do_POST
- **Rule:** Rule 2 (missing input validation for a security-critical path)

### 3. [Rule 2 - Critical] `BrokenPipeError` guard in `_send_json`

- **Found during:** Task 1 implementation
- **Issue:** If the client disconnects mid-response (e.g., GitHub's 10s delivery timeout raced with a slow write), `self.wfile.write(payload)` would raise `BrokenPipeError` into a thread the server cannot recover from cleanly.
- **Fix:** Wrapped `self.wfile.write(payload)` in `try/except BrokenPipeError: pass`.
- **Files modified:** `webhook/listener.py` WebhookHandler._send_json
- **Rule:** Rule 2 (robustness in request-handling path)

### 4. [Rule 2 - Critical] JsonlHandler thread lock

- **Found during:** Task 1 implementation (not in plan skeleton)
- **Issue:** `JsonlHandler.emit` opens the log file + writes + closes from potentially many handler threads simultaneously under `ThreadingHTTPServer` + worker threads. While `open(..., "a")` + single-line writes are mostly atomic on Linux, interleaving can happen at > PIPE_BUF sizes.
- **Fix:** Added `threading.Lock` instance to `JsonlHandler`; wrap write with `with self._lock:`.
- **Files modified:** `webhook/listener.py` JsonlHandler
- **Rule:** Rule 2 (concurrency correctness in the log path; cheap)

### 5. [Rule 2] JSON parse wraps `UnicodeDecodeError` too

- **Found during:** Task 1 implementation
- **Issue:** `json.loads(raw_body)` on a non-UTF-8 body raises `UnicodeDecodeError`, not `JSONDecodeError`. Skeleton only caught the latter.
- **Fix:** Caught `(json.JSONDecodeError, UnicodeDecodeError)`.
- **Files modified:** `webhook/listener.py` do_POST
- **Rule:** Rule 2 (hostile-input hygiene)

### 6. [Rule 2] `load_config` catches malformed JSON + KeyError

- **Found during:** Task 1 implementation
- **Issue:** Skeleton raised a `SystemExit` string from `load_config` only for missing file. If config file exists but is malformed, the traceback would spill on stderr instead of a clean exit-2.
- **Fix:** `try/except (json.JSONDecodeError, KeyError, ValueError)` → print to stderr + `SystemExit(2)`.
- **Files modified:** `webhook/listener.py` load_config
- **Rule:** Rule 2 (clean error handling at boot time)

No deviations were architectural (Rule 4). All are defensive hardening on the skeleton.

## Auth Gates

None. All work was local file creation + test execution.

## Open Items for Downstream Plans

### For Plan 14-03 (systemd unit)
- `webhook/claude-secure-webhook.service` must reference `/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json` (D-25).
- Unit needs `Restart=always`, `RestartSec=5s`, `StandardOutput=journal`, `StandardError=journal`.
- `KillMode=mixed` + `TimeoutStopSec=5s` recommended because listener itself handles SIGTERM in <2s (proven by `test_sigterm_shutdown`).

### For Plan 14-04 (installer)
- `install.sh --with-webhook` must:
  1. Copy `webhook/listener.py` → `/opt/claude-secure/webhook/listener.py`
  2. `sed` substitute the three `__REPLACED_BY_INSTALLER__*__` markers in `webhook/config.example.json` using `$SUDO_USER`'s home, then copy to `/etc/claude-secure/webhook.json` (only if not already present).
  3. Copy `webhook/claude-secure-webhook.service` → `/etc/systemd/system/`, run `systemctl daemon-reload`.
  4. WSL2 check: grep `/etc/wsl.conf` for `[boot] systemd=true` and warn if missing (D-26).
- The listener reads `profiles_dir`, `events_dir`, `logs_dir`, `claude_secure_bin` from config — installer must write absolute paths, no `~`.

### For Phase 15 (event routing)
- Event files now ship with `_meta.event_type` field populated from `X-GitHub-Event` header. Phase 15 should read this rather than re-parsing the payload.
- Phase 15 will likely extend `bin/claude-secure spawn` to accept `--prompt-template <name>` and pick a template based on `_meta.event_type`. Listener change required: none (it already forwards `_meta.event_type`).

### Known Stubs
None. `webhook/listener.py` is a complete, runnable service. `webhook/config.example.json` ships with sentinel placeholders that are **intentionally unresolved** — Plan 14-04's installer resolves them. This is documented in the plan and is not a stub in the "empty UI data" sense.

## Self-Check: PASSED

- `webhook/listener.py` exists → FOUND (461 lines)
- `webhook/config.example.json` exists → FOUND (9 lines)
- Commit `5471097` (listener.py) → FOUND in git log
- Commit `4246eef` (config template) → FOUND in git log
- `bash tests/test-phase14.sh` → 14/16 (2 non-owned failures: test_unit_file_lint, test_install_webhook — belong to Plans 14-03 and 14-04)
- All acceptance criteria greps → verified
- Stdlib-only import assertion → verified
- No `datetime.utcnow` → verified
- No `json.dumps(json.loads(raw_body))` literal → verified
