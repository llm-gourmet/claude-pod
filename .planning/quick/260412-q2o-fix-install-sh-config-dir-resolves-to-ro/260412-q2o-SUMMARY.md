---
phase: quick
plan: 260412-q2o
subsystem: installer
tags: [install, sudo, home-resolution, config-dir]
dependency_graph:
  requires: []
  provides: [sudo-safe-install]
  affects: [install.sh]
tech_stack:
  added: []
  patterns: [SUDO_USER detection, getent passwd home resolution]
key_files:
  modified:
    - install.sh
decisions:
  - "Use script-level _invoking_user/_invoking_home variables (underscore prefix) to avoid collision with the local invoking_user/invoking_home inside install_webhook_service"
  - "getent passwd lookup is robust across /etc/passwd and LDAP/NIS whereas ~username tilde expansion is shell-dependent"
metrics:
  duration: 3min
  completed: 2026-04-12
  tasks_completed: 1
  files_changed: 1
---

# Quick Task 260412-q2o: Fix install.sh CONFIG_DIR Resolves to /root Under Sudo

**One-liner:** Resolve invoking user's home via SUDO_USER + getent so `sudo ./install.sh` installs under the real user's home, not /root.

## Objective

`install.sh` used `$HOME` to set `CONFIG_DIR`, workspace default, and the CLI fallback path. Under `sudo`, `$HOME` is `/root`, so the entire installation landed in `/root/.claude-secure/` — unusable without manual intervention.

## What Was Done

### Task 1: Early invoking-user home resolution

Added a three-line block at script scope (before `PLATFORM=""`):

```bash
_invoking_user="${SUDO_USER:-$USER}"
_invoking_home="$(getent passwd "$_invoking_user" | cut -d: -f6)"
if [ -z "$_invoking_home" ]; then
  echo "ERROR: Could not resolve home directory for user '$_invoking_user'" >&2
  exit 1
fi
CONFIG_DIR="$_invoking_home/.claude-secure"
```

Then propagated `_invoking_home` to:
- `setup_workspace()` — workspace path prompt default and fallback value
- `install_cli()` — all four `$HOME` references in the `~/.local/bin` fallback branch

The `_` prefix avoids collision with the local `invoking_user`/`invoking_home` variables already present in `install_webhook_service()`.

## Verification

- `bash -n install.sh` passes (syntax ok)
- `grep -c '$HOME' install.sh` returns 0
- `_invoking_home` covers CONFIG_DIR, setup_workspace, and install_cli

## Deviations from Plan

None — plan executed exactly as written.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1    | 2e1820a | fix(quick-260412-q2o): resolve invoking-user home to avoid /root under sudo |

## Self-Check: PASSED

- install.sh exists and is modified: confirmed
- Commit 2e1820a exists: confirmed
- 0 `$HOME` references remain: confirmed
