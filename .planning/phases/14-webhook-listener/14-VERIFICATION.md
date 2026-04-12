---
phase: 14-webhook-listener
verified: 2026-04-12T00:00:00Z
status: passed
score: 3/3 must-haves verified (HOOK-01, HOOK-02, HOOK-06)
verdict: PASS
---

# Phase 14: Webhook Listener Verification Report

**Phase Goal:** Deliver a host-side systemd-managed webhook listener that authenticates GitHub webhooks via HMAC-SHA256, persists payloads, and dispatches `claude-secure spawn` with bounded concurrency — satisfying HOOK-01, HOOK-02, HOOK-06.

**Verdict:** PASS

**Re-verification:** No — initial verification.

---

## Goal Achievement

### Observable Truths (from HOOK-01/02/06 acceptance criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Webhook listener runs as a host-side systemd service receiving GitHub webhooks (HOOK-01) | VERIFIED | `webhook/claude-secure-webhook.service` parses cleanly under `systemd-analyze verify` (exit 0); `install.sh:install_webhook_service` copies unit to `/etc/systemd/system/`, runs `systemctl daemon-reload`, and enables via `systemctl enable --now`; listener binds `127.0.0.1:9000` and responds on `/health` and `/webhook`. |
| 2 | Every incoming webhook is verified via HMAC-SHA256 signature against raw payload body (HOOK-02) | VERIFIED | `listener.py:284` reads raw bytes via `self.rfile.read(int(self.headers["Content-Length"]))`; `listener.py:341-343` computes HMAC directly on `raw_body` bytes (no JSON roundtrip); `hmac.compare_digest` used at line 345. Four HMAC tests pass: valid, invalid, missing header, newline sensitivity. Unknown-repo 404 fires at line 315 **before** HMAC check at line 341. Invalid-sig / unknown-repo payloads are **not** persisted (test `test_hmac_invalid` asserts event-dir count unchanged). |
| 3 | Multiple simultaneous webhooks execute safely with unique compose project names and isolated workspaces (HOOK-06) | VERIFIED | `threading.Semaphore(max_concurrent_spawns=3)` at line 427; daemon-thread `spawn_async` at line 177 queues behind semaphore; `/health` endpoint reports `active_spawns` counter under lock. Tests `test_concurrent_5` (5 parallel 202s + 5 distinct stub invocations), `test_semaphore_queue` (6 requests with max=3 all return 202 and all drain), `test_health_active_spawns` (observed active_spawns ≥ 1 during overlap) all pass. Unique compose project names are delegated to Phase 13's `do_spawn` via `--event-file` handoff, which this phase invokes at line 202. |

**Score:** 3/3 truths verified.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `webhook/listener.py` | Python stdlib-only webhook service | VERIFIED | 461 lines, only stdlib imports (argparse, datetime, hashlib, hmac, json, logging, pathlib, signal, subprocess, sys, threading, uuid, http.server). All D-01..D-27 decisions reflected in code. |
| `webhook/config.example.json` | JSON config template with installer placeholders | VERIFIED | Contains `bind`, `port`, `max_concurrent_spawns`, `profiles_dir`, `events_dir`, `logs_dir`, `claude_secure_bin`. Placeholders match install.sh sed targets. |
| `webhook/claude-secure-webhook.service` | systemd unit with D-25 directives | VERIFIED | `Type=simple`, `ExecStart=/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json`, `Restart=always`, `RestartSec=5s`, `StandardOutput=journal`, `StandardError=journal`, `User=root`, `After=network-online.target docker.service`, `Requires=docker.service`, `WantedBy=multi-user.target`. `systemd-analyze verify` returns 0. Hardening directives deliberately omitted with inline rationale (matches D-24 justification). |
| `install.sh` extension | Idempotent `install_webhook_service()` + `--with-webhook` flag | VERIFIED | Function at line 276; flag parsed at line 23. Python 3.11+ check, systemctl check, WSL2 detection + warn-not-block, home-dir resolution via `getent passwd $SUDO_USER`, sed-replace placeholders, `--no-overwrite` guard on `/etc/claude-secure/webhook.json`, `daemon-reload`, `enable --now`, helpful post-install hints for editing `profile.json`'s `webhook_secret`. |
| `tests/test-phase14.sh` | 16 integration tests covering HOOK-01/02/06 + cross-cutting | VERIFIED | Executable; 16 tests run; full suite green (16/16) when executed with systemd-analyze writable. |
| `tests/fixtures/github-issues-opened.json` | GitHub Issues webhook payload | VERIFIED | Valid JSON dict. |
| `tests/fixtures/github-push.json` | GitHub push webhook payload | VERIFIED | Valid JSON dict. |
| `tests/test-map.json` | Extended with webhook/install.sh mappings | VERIFIED | `webhook/` → `test-phase14.sh`, `install.sh` → `test-phase14.sh` (added alongside existing mappings), `bin/claude-secure` → `test-phase14.sh`. |

---

## Key Link Verification (Wiring)

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `listener.py:_spawn_worker` | `bin/claude-secure spawn` | `subprocess.Popen([claude_secure_bin, "spawn", "--profile", name, "--event-file", str(event_path)])` | WIRED | Line 200-211. Flags match Phase 13 `do_spawn` contract (bin/claude-secure:464 parses `--event-file`). Output captured to per-delivery log file. |
| `listener.py:do_POST` | profile resolution | `resolve_profile_by_repo(profiles_dir, repository.full_name)` scans `*/profile.json` | WIRED | Line 107-133. Matches per D-08/D-09: reads `webhook_secret` from profile.json. Mid-write skip logic present (Gotcha 8). |
| `listener.py:do_POST` | event persistence | `persist_event(events_dir, raw_body, profile, event_type, delivery_id)` | WIRED | Line 139-165. Writes raw body (parsed only to inject `_meta` sidecar, matches D-18). Filename `<ISO8601Z>-<uuid8>.json`. |
| `listener.py:do_POST` | async spawn | `spawn_async(profile["name"], event_path, delivery_id)` | WIRED | Line 389; persist call on line 361 executes **before** spawn_async (D-17 ordering honored). 202 returned immediately after spawn_async (D-14). |
| HMAC verification | raw body bytes | `hmac.new(secret_bytes, raw_body, hashlib.sha256)` | WIRED | Line 341-343. No `json.dumps` intermediary — raw bytes flow directly from `rfile.read` to `hmac.new`. |
| Unknown-repo short-circuit | 404 before HMAC | `if profile is None: return 404` | WIRED | Line 315-323 executes **before** line 326 signature parsing. Verified by `test_unknown_repo_404` which asserts no `invalid_signature` log line for the delivery. |
| SIGTERM shutdown | serve_forever thread safety | `threading.Thread(target=_server.shutdown, daemon=True).start()` from signal handler | WIRED | Line 413. Gotcha 3 avoided. `test_sigterm_shutdown` exits within 2s, not the 90s systemd fallback. |
| `install.sh` | `/opt/claude-secure/webhook/listener.py` | `sudo cp "$app_dir/webhook/listener.py" /opt/claude-secure/webhook/listener.py` | WIRED | Line 344. Matches D-25 path requirement. |
| `install.sh` | `/etc/claude-secure/webhook.json` | sed-replace placeholders, `[ ! -f ]` guard, `sudo tee` | WIRED | Line 350-357. Idempotent (no overwrite if present). |

---

## Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| listener.py HMAC | `raw_body: bytes` | `self.rfile.read(Content-Length)` (HTTP socket) | Yes — bytes from wire | FLOWING |
| persist_event | `raw_body` + parsed JSON (for `_meta`) | Same raw_body passed through; parsed dict only used for `_meta` injection | Yes — raw body preserved for LLM consumption | FLOWING |
| spawn_async | `event_path` | `persist_event` returns real `pathlib.Path` | Yes | FLOWING |
| `/health` `active_spawns` | `_active_spawns` global | Incremented/decremented under `_active_lock` inside `_spawn_worker` | Yes — `test_health_active_spawns` observed non-zero values during overlap | FLOWING |
| `claude-secure spawn` subprocess | `--event-file <path>` arg | Real path produced by `persist_event` | Yes (stubbed in test harness; real path in production) | FLOWING |

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| systemd unit parses | `systemd-analyze verify webhook/claude-secure-webhook.service` | exit 0 (unsandboxed) | PASS |
| HMAC valid path | `test_hmac_valid` (curl + openssl sig + 202 + event file present) | PASS | PASS |
| HMAC invalid path | `test_hmac_invalid` (wrong secret + 401 + no new event file) | PASS | PASS |
| HMAC missing header | `test_hmac_missing_header` (no X-Hub-Signature-256 + 400) | PASS | PASS |
| HMAC newline contamination rejected | `test_hmac_newline_sensitivity` (echo-generated sig + 401) | PASS | PASS |
| Unknown repo short-circuits | `test_unknown_repo_404` (valid-shape sig for unregistered repo + 404 + no invalid_signature log) | PASS | PASS |
| 5 concurrent webhooks dispatch | `test_concurrent_5` (5 parallel 202s + ≥5 event files + ≥5 stub invocations) | PASS | PASS |
| Semaphore queues excess | `test_semaphore_queue` (6 requests, max=3, all 202, all drain) | PASS | PASS |
| Health reports active_spawns | `test_health_active_spawns` (poll /health during overlap) | PASS | PASS |
| Wrong path 404 | `test_wrong_path_404` | PASS | PASS |
| Wrong method 405 | `test_wrong_method_405` | PASS | PASS |
| Invalid JSON 400 | `test_invalid_json_400` | PASS | PASS |
| SIGTERM clean shutdown | `test_sigterm_shutdown` (within 2s) | PASS | PASS |
| Missing config exits non-zero | `test_missing_config` (rc ≠ 0, ≠ 124) | PASS | PASS |
| install.sh grep contract | `test_install_webhook` (all expected strings present) | PASS | PASS |
| Gated systemctl start | `test_systemd_start` (env-gated, no-op here) | PASS (no-op) | PASS |

**Full suite result:** 16/16 passing (sandbox run was 15/16 due to `systemd-analyze` requiring writable tempdir; unsandboxed run is 16/16).

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| HOOK-01 | 14-03-PLAN (systemd unit) + 14-04-PLAN (installer) | Webhook listener runs as a host-side systemd service receiving GitHub webhooks | SATISFIED | `webhook/claude-secure-webhook.service` (systemd-analyze clean), `install.sh:install_webhook_service`, WSL2 warn-not-block per D-26, D-25 directives verbatim, listener actually binds and responds. |
| HOOK-02 | 14-02-PLAN (listener.py) | Every incoming webhook is verified via HMAC-SHA256 signature against raw payload body | SATISFIED | Raw-bytes HMAC at `listener.py:341-343`, `hmac.compare_digest` timing-safe comparison, unknown-repo 404 fires before HMAC per D-11, invalid-sig payloads not persisted per D-19. 4 dedicated HMAC tests pass. |
| HOOK-06 | 14-02-PLAN | Multiple simultaneous webhooks execute safely with unique compose project names and isolated workspaces | SATISFIED | `threading.Semaphore(max_concurrent_spawns=3)`, daemon-thread dispatch, `active_spawns` counter, queue-behind-202 semantics per D-15. Unique compose project names delegated to Phase 13 `do_spawn` (verified at `bin/claude-secure:447`). 3 concurrency tests pass. |

**Coverage:** 3/3 requirements scoped to Phase 14 are satisfied. REQUIREMENTS.md traceability table already reflects these as Complete.

---

## Anti-Patterns Found

**Scan targets:** `webhook/listener.py`, `webhook/claude-secure-webhook.service`, `webhook/config.example.json`, `install.sh:install_webhook_service`, `tests/test-phase14.sh`, fixtures.

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `webhook/listener.py` | 276-284 | Double-read of `Content-Length` header (parsed once for length check, re-parsed inside `self.rfile.read`) | INFO | Cosmetic redundancy — both reads return the same value. Not a correctness bug. The inline comment explicitly re-reads to make the `raw_body` assignment self-documenting per Gotcha 1. |
| `webhook/listener.py` | 171, 398 | Module-level mutable globals `_spawn_semaphore`, `_active_spawns`, `_active_lock`, `_config`, `_server` | INFO | Consistent with `validator/` project precedent and required for signal-handler access. Properly lock-guarded. Not a concern. |

**No blocker or warning anti-patterns found.** TODO/FIXME/placeholder/stub scans returned zero matches in any Phase 14 artifact.

---

## Cross-Phase Integration Check

The listener delegates to Phase 13's `bin/claude-secure spawn`:

- **Phase 13 contract** (`bin/claude-secure:447` `do_spawn`): accepts `--profile NAME`, `--event-file PATH`, generates ephemeral `COMPOSE_PROJECT_NAME`, handles cleanup.
- **Phase 14 call site** (`listener.py:200-211`): `subprocess.Popen([claude_secure_bin, "spawn", "--profile", profile_name, "--event-file", str(event_path)], stdout=log_fp, stderr=subprocess.STDOUT)`.

Flags and argument order match. Event-file shape (raw GitHub payload with `_meta` sidecar) is exactly what `do_spawn` consumes. Output redirected to per-delivery log file per D-22. HOOK-07 replay is implicitly enabled by the persisted file — verified by inspection but not exercised directly in this phase (scoped to Phase 15 per CONTEXT).

---

## Sandbox Note

One test (`test_unit_file_lint`) failed in sandboxed runs because `systemd-analyze verify` needs to write to a working directory and the sandbox is read-only for that path. Running unsandboxed produced 16/16 green. The test harness itself is correct — this is purely a CI/sandbox restriction, not a code defect. The unit file parses cleanly.

---

## Human Verification Required

The following items remain manual-only per `14-VALIDATION.md` and cannot be verified programmatically:

| Behavior | Requirement | Why Manual |
|----------|-------------|------------|
| Service survives host reboot | HOOK-01 | Requires real systemd + reboot. |
| WSL2 systemd warning prints with mutated `/etc/wsl.conf` | HOOK-01 | Requires WSL2 host without `[boot] systemd=true`. Static inspection of `install.sh:309-329` confirms the message content and warn-not-block behavior. |
| GitHub → real webhook → spawn completes end-to-end | HOOK-01, HOOK-02, HOOK-06 | Requires public tunnel + real GitHub webhook configuration. |

None of these block the Phase 14 close — they are post-deployment smoke tests.

---

## Gaps Summary

**None.** All three requirements (HOOK-01, HOOK-02, HOOK-06) are satisfied. All 16 integration tests pass (unsandboxed). Critical gotchas (raw-body HMAC, `datetime.UTC`, stdlib-only, unknown-repo-before-HMAC, invalid-sig not persisted) are verified in source. systemd unit matches D-25 verbatim. install.sh is idempotent and warns without blocking on WSL2. Cross-phase integration with Phase 13 `do_spawn` is correctly wired.

**Verdict: PASS — Phase 14 may close and the auto-advance chain may proceed.**

---

*Verified: 2026-04-12*
*Verifier: Claude (gsd-verifier)*
