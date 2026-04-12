---
phase: 14-webhook-listener
plan: 04
subsystem: infra
tags: [bash, install.sh, systemd, wsl2, webhook, idempotency]

# Dependency graph
requires:
  - phase: 14-webhook-listener
    provides: "webhook/listener.py (14-02), webhook/config.example.json (14-02), webhook/claude-secure-webhook.service (14-03), tests/test-phase14.sh (14-01)"
provides:
  - "install.sh --with-webhook flag that installs the listener as a root systemd service"
  - "Idempotent installer path: listener.py and unit file refresh on every run, webhook.json is preserved"
  - "WSL2 systemd gate (warn, don't block) per D-26"
  - "Installer-side sentinel substitution for /etc/claude-secure/webhook.json using the invoking user's home"
affects:
  - 15-event-routing
  - 16-audit-log
  - install-docs

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "parse_args() bash flag parsing pattern for install.sh"
    - "Sentinel substitution pattern (__REPLACED_BY_INSTALLER__*__) for host config templates"
    - "Warn-don't-block WSL2 gating pattern for systemd-dependent installers"
    - "Idempotency pattern: always-overwrite code + never-overwrite user config"

key-files:
  created: []
  modified:
    - install.sh

key-decisions:
  - "parse_args() lives at the top of main() so all flag state is populated before any install_* function runs"
  - "install_webhook_service() is called AFTER install_git_hooks in main() so git hooks always land (they are not optional)"
  - "WSL2 gate warns but does not block — install.sh still copies files and runs daemon-reload; only systemctl enable --now is skipped"
  - "Invoking user home is resolved via SUDO_USER fallback then getent passwd, so sudo ./install.sh still substitutes the human's home path into webhook.json (reconciles D-24 root service with D-08 per-user profile scan)"
  - "webhook.json is NEVER overwritten — this is the contract for re-runs. listener.py and the unit file are always refreshed so bug fixes ship on re-install"

patterns-established:
  - "install.sh flag parsing: parse_args() mutates globals before main() body runs"
  - "Two-tier file freshness: code artifacts (listener.py, .service) always overwrite; user config (webhook.json) is preserved if present"

requirements-completed: [HOOK-01]

# Metrics
duration: 8min
completed: 2026-04-12
---

# Phase 14 Plan 04: Install.sh Webhook Integration Summary

**`install.sh --with-webhook` installs the webhook listener as a root systemd service idempotently, with sentinel path substitution and a WSL2 warn-don't-block gate.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-04-12T09:12:30Z (approx)
- **Completed:** 2026-04-12T09:20:46Z
- **Tasks:** 1
- **Files modified:** 1
- **Lines added to install.sh:** 131 (target ~100 — slightly over because of the WSL2 warning block's copy-pastable snippet)

## Accomplishments

- `install.sh` now recognizes `--with-webhook` via a new `parse_args()` helper and `WITH_WEBHOOK=0` global.
- New `install_webhook_service()` function handles the full lifecycle:
  1. Gate on flag or interactive prompt (non-interactive + no flag = skip silently).
  2. Python 3.11+ check.
  3. `systemctl` availability check (missing = warn + skip, not an error).
  4. WSL2 detection via `grep -qi microsoft /proc/version` + `/etc/wsl.conf` systemd check; prints copy-pastable config snippet + `wsl.exe --shutdown` instructions.
  5. Invoking-user home resolution via `SUDO_USER` → `getent passwd`.
  6. `listener.py` → `/opt/claude-secure/webhook/` (always refresh).
  7. Sentinel substitution of `__REPLACED_BY_INSTALLER__{PROFILES,EVENTS,LOGS}__` into `/etc/claude-secure/webhook.json` (only if target does not exist).
  8. Unit file → `/etc/systemd/system/claude-secure-webhook.service` (always refresh) + `daemon-reload`.
  9. `systemctl enable --now claude-secure-webhook` + 1s sleep + `is-active` probe (unless WSL2-gated).
- `main()` now runs `parse_args "$@"` as its first line and calls `install_webhook_service` after `install_git_hooks` — all existing install_* calls preserved in their original order.
- `tests/test-phase14.sh` is now **16/16 green** (full suite verified outside sandbox).

## Task Commits

1. **Task 1: Add parse_args, install_webhook_service, and main() call site to install.sh** — `b964782` (feat)

**Plan metadata commit:** pending (docs commit after self-check)

## Files Created/Modified

- `install.sh` — Added `WITH_WEBHOOK=0` global, `parse_args()`, `install_webhook_service()`, and two new lines in `main()` (`parse_args "$@"` at top + `install_webhook_service` after `install_git_hooks`). All existing functions preserved verbatim.

## Decisions Made

- **Placement of `install_webhook_service` call in `main()`:** Positioned after `install_git_hooks` (which is itself the last install_* call before the old trailing `log_info` block) so that installing git hooks and the webhook service are cleanly separated and the webhook is last. Git hooks run unconditionally; webhook is conditional on the flag/prompt, so failing the webhook step leaves the rest of the install intact.
- **`systemctl daemon-reload` failure is non-fatal:** On WSL2 without systemd, `daemon-reload` can fail (no systemd PID 1). We downgrade that to a warning because the unit file is still on disk and will be picked up after the user enables systemd and restarts WSL.
- **`install_webhook_service` returns 0 (not 1) when systemctl is missing:** A host without systemd is a legitimate scenario (non-systemd Linux, WSL2 pre-boot systemd), not an installer failure.

## Deviations from Plan

None — plan executed exactly as written. The plan's action block was used verbatim (including the inline implementation sketch from 14-RESEARCH) with only minor cosmetic changes: some `--` comment dashes were rendered as `--` (plain ASCII) in the bash source to avoid any risk of UTF-8 dash characters ending up in a shell script.

## Issues Encountered

- **Sandbox environmental failure for `test_unit_file_lint`:** When running `bash tests/test-phase14.sh` inside the Claude Code sandbox (read-only temp dir), `systemd-analyze verify` fails with `Failed to setup working directory: Read-only file system`. This causes `test_unit_file_lint` to report FAIL in sandboxed runs, yielding 15/16. Running the **same test** outside the sandbox yields 16/16 green — confirmed with `dangerouslyDisableSandbox: true`. The unit file itself is valid; this is purely an environmental artifact of running `systemd-analyze` under a sandbox that denies writes to its working directory. Not in scope for plan 14-04 (the unit file ships from plan 14-03). No fix applied; logged here for future awareness.

## Phase 14 Final Test Suite Result

- **16 / 16 passing** (full `bash tests/test-phase14.sh` run, unsandboxed)
- HOOK-01 (unit file + installer + gated systemd start): 3/3
- HOOK-02 (HMAC valid/invalid/missing/newline + unknown repo): 5/5
- HOOK-06 (concurrent 5 + semaphore queue + health active_spawns): 3/3
- Cross-cutting (404 / 405 / 400 / sigterm shutdown): 4/4
- Config (missing config exits nonzero): 1/1

## Idempotency Edge Cases

- **First-run scenario:** All files copied, `webhook.json` generated fresh from `config.example.json` with substituted paths, service enabled and started.
- **Re-run scenario:** `listener.py` and unit file overwrite cleanly. `webhook.json` is preserved — installer logs `"Existing /etc/claude-secure/webhook.json preserved (no overwrite)"`. `systemctl enable --now` is a no-op if already enabled. `daemon-reload` is always safe to re-run.
- **WSL2-no-systemd scenario:** Files still copied. `daemon-reload` falls through to its warning path. `enable --now` is skipped entirely. User gets a clear next-steps message.
- **Flag-less non-interactive scenario:** Function returns 0 silently — CI can run `./install.sh` without hitting the webhook path unexpectedly.

## User Setup Required

None new — the webhook listener needs a `webhook_secret` field in each profile's `profile.json`, but that requirement was already documented by plans 14-02 and 14-03 and is echoed by the installer itself at the end of `install_webhook_service()`.

## Next Phase Readiness

- **HOOK-01 fully delivered.** The webhook listener can be installed with a single command: `sudo ./install.sh --with-webhook`.
- **Phase 14 complete.** All three phase-14 requirements (HOOK-01, HOOK-02, HOOK-06) have passing automated tests.
- **Phase 15 ready to start:** event-type routing and prompt template selection can now assume the listener is running and is persisting raw payloads at `~/.claude-secure/events/<ts>-<uuid8>.json`.

## Self-Check: PASSED

- `.planning/phases/14-webhook-listener/14-04-SUMMARY.md` — FOUND
- Commit `b964782` — FOUND in git log
- `install_webhook_service` — FOUND in install.sh
- `parse_args "$@"` — FOUND in install.sh main()
- `--with-webhook` — FOUND in install.sh
- `__REPLACED_BY_INSTALLER__PROFILES__` — FOUND in install.sh
- `/proc/version` — FOUND in install.sh (WSL2 detection)
- `tests/test-phase14.sh` — 16/16 passing (unsandboxed)

---
*Phase: 14-webhook-listener*
*Plan: 04*
*Completed: 2026-04-12*
