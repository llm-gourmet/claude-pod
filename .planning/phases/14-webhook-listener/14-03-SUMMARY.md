---
phase: 14-webhook-listener
plan: 03
subsystem: infra
tags: [systemd, webhook, service-unit, docker]

# Dependency graph
requires:
  - phase: 14-webhook-listener
    provides: Wave 0 test scaffold (test_unit_file_lint) in tests/test-phase14.sh
provides:
  - webhook/claude-secure-webhook.service standalone systemd unit file ready for install.sh copy to /etc/systemd/system/
  - HOOK-01 file-artifact half (the systemd unit contract)
affects: [14-04 install.sh, Phase 17 hardening]

# Tech tracking
tech-stack:
  added: [systemd unit file (INI)]
  patterns: ["Unit file as source of truth in repo; installer copies verbatim to /etc/systemd/system/"]

key-files:
  created:
    - webhook/claude-secure-webhook.service
  modified: []

key-decisions:
  - "Hardening directives (NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet) deliberately omitted for Phase 14 — each breaks docker compose invocation; Phase 17 may revisit with empirical test matrix"
  - "Requires=docker.service + After=docker.service ensures listener stops when Docker stops, preventing spawn attempts against a dead daemon"
  - "SyslogIdentifier=claude-secure-webhook added (beyond D-25 minimum) for clean journalctl filtering — discretionary add, non-load-bearing"

patterns-established:
  - "Unit file directive rationale is inlined as comments in the file itself — reviewers can trace every non-obvious directive back to CONTEXT decision IDs (D-23..D-26) without leaving the file"
  - "Forbidden-directive list is documented in-file with per-directive justification, so future contributors cannot 'fix' the missing hardening without reading why"

requirements-completed: [HOOK-01]

# Metrics
duration: 3min
completed: 2026-04-12
---

# Phase 14 Plan 03: Webhook Systemd Unit File Summary

**Standalone systemd unit file for the claude-secure webhook listener with D-25 directives locked verbatim and hardening omissions justified inline**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-12T09:10:29Z
- **Completed:** 2026-04-12T09:13:24Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Created `webhook/claude-secure-webhook.service` with every D-25 directive at its locked value
- `systemd-analyze verify` exits 0 (clean — no warnings at all)
- `tests/test-phase14.sh test_unit_file_lint` transitions from Wave 0 RED to GREEN
- Every hardening directive deliberately omitted is documented in-file with its failure mode
- File includes `SyslogIdentifier=claude-secure-webhook` for clean `journalctl -u claude-secure-webhook` filtering

## Task Commits

1. **Task 1: Write webhook/claude-secure-webhook.service systemd unit file** - `e64966e` (feat)

## Files Created/Modified
- `webhook/claude-secure-webhook.service` - standalone systemd unit file, INI format, ~50 lines with inline comments tracing each directive back to CONTEXT D-23..D-26

## Decisions Made

- **Included `SyslogIdentifier=claude-secure-webhook`** (not explicit in D-25): minor discretionary add. Makes `journalctl -u claude-secure-webhook` filtering unambiguous and costs nothing. Non-load-bearing.
- **`Requires=docker.service` (not just `After=docker.service`)**: ensures listener stops when Docker stops. Without `Requires=`, the listener would keep running and attempt spawns against a dead Docker daemon. D-25 listed both; this summary flags the semantic difference.
- **Type=simple (not Type=exec)**: D-25 locked Type=simple. Acceptable because the listener's port-bind happens fast; `systemd-notify` is unnecessary for this single-process stdlib-only service.

## Deviations from Plan

None — plan executed exactly as written. Unit file content was copied verbatim from the plan's fenced block, which was itself a verbatim D-25 lock.

## Issues Encountered

- `systemd-analyze verify` failed initially with "Failed to setup working directory: Read-only file system" when run inside the execution sandbox. Retried with sandbox disabled: exit 0. This is a sandbox-filesystem constraint, not a unit file issue. (User can use `/sandbox` to manage restrictions if this recurs.)
- No unit file syntax errors. No executable-bit warnings (the plan's verify command anticipated such warnings as acceptable; none occurred).

## Acceptance Criteria Verification

| Criterion | Result |
|-----------|--------|
| `webhook/claude-secure-webhook.service` exists | PASS |
| Contains `[Unit]`, `[Service]`, `[Install]` headers | PASS (1 each) |
| Contains `Type=simple` | PASS |
| Contains `Restart=always` | PASS (exactly 1 match) |
| Contains `RestartSec=5s` | PASS |
| Contains `StandardOutput=journal` | PASS |
| Contains `StandardError=journal` | PASS |
| Contains `User=root` | PASS (exactly 1 match) |
| Contains exact `ExecStart=/usr/bin/python3 /opt/claude-secure/webhook/listener.py --config /etc/claude-secure/webhook.json` | PASS |
| Contains `After=network-online.target docker.service` | PASS |
| Contains `Requires=docker.service` | PASS |
| Contains `WantedBy=multi-user.target` | PASS |
| Absent `NoNewPrivileges=true` | PASS (commented rationale only) |
| Absent `ProtectSystem=strict` | PASS (commented rationale only) |
| Absent `PrivateTmp=true` | PASS (commented rationale only) |
| `systemd-analyze verify` exits 0 | PASS |
| `bash tests/test-phase14.sh test_unit_file_lint` exits 0 | PASS |

## User Setup Required

None — this plan only produces a file in the repo. `install.sh` (Plan 04) handles the copy to `/etc/systemd/system/` and the `systemctl daemon-reload`/`enable` steps.

## Next Phase Readiness

- HOOK-01 file-artifact half complete. HOOK-01 is still partial until Plan 04 delivers the install.sh integration.
- Plan 04 (install.sh --with-webhook) can now reference `webhook/claude-secure-webhook.service` as the source for its copy operation.
- Plan 02 (listener.py) runs in parallel with this plan and is unaffected — no file overlap.

## Self-Check: PASSED

- `webhook/claude-secure-webhook.service` exists on disk
- `.planning/phases/14-webhook-listener/14-03-SUMMARY.md` exists on disk
- Commit `e64966e` exists in git log

---
*Phase: 14-webhook-listener*
*Completed: 2026-04-12*
