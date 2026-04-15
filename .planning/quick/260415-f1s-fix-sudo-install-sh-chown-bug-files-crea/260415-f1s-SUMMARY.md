---
phase: quick-260415-f1s
plan: 01
subsystem: installer
tags: [installer, sudo, permissions, chown, bugfix]
requirements: [FIX-01]
dependency-graph:
  requires: []
  provides:
    - "CONFIG_DIR and workspace directories owned by invoking user after sudo install"
    - "logs/ directory retains 777 mode post-chown for multi-UID container writes"
  affects: [install.sh]
tech-stack:
  added: []
  patterns:
    - "SUDO_USER-based invoking-user resolution already established in prior quick task 260412-q2o; this task extends that pattern to post-write ownership reclaim"
key-files:
  created: []
  modified:
    - install.sh
decisions:
  - "chown -R runs in main() AFTER install_git_hooks and BEFORE install_webhook_service so $CONFIG_DIR/app/.git/hooks/ from the hook install is included but /opt/claude-secure, /etc/systemd, and /usr/local/bin system paths from the webhook install remain root-owned"
  - "chmod 777 on $CONFIG_DIR/logs is re-applied after the recursive chown — although chown -R preserves modes, making the 777 explicit is a defence-in-depth guarantee for the three-UID container write pattern (claude:1001, node:1000, root:0)"
  - "Workspace chown lives inside setup_workspace() because ws_path is a function-local variable not reachable from main() — simpler than hoisting ws_path to a global"
  - "Non-sudo case is a deliberate no-op: when SUDO_USER is unset, _invoking_user=$USER and chown user:user on user-owned files changes nothing"
metrics:
  duration: "~1min"
  completed: "2026-04-15"
  tasks: 1
  files: 1
---

# Quick Task 260415-f1s: Fix sudo install.sh chown bug Summary

Two surgical chown calls added to install.sh so that after `sudo bash install.sh` the invoking user owns `$CONFIG_DIR` recursively and the workspace directory, while system paths remain root-owned.

## Objective

Fix the sudo install.sh chown bug. When `sudo bash install.sh` runs, all files and directories created under `$CONFIG_DIR` (`~/.claude-secure/`) were root-owned, causing the real user to hit "Permission denied" when reading the `chmod 600` `profiles/default/.env`.

## Implementation

### Edit 1 — `setup_workspace()` (install.sh line 328)

Added a single `chown` call immediately after `mkdir -p "$ws_path"`:

```bash
mkdir -p "$ws_path"
chown "$_invoking_user:$_invoking_user" "$ws_path"
```

This is scoped inside the function because `ws_path` is a function-local variable — hoisting it to a global would be a larger refactor with no benefit.

### Edit 2 — `main()` (install.sh lines 619-624)

Between `install_git_hooks` and `install_webhook_service`, inserted:

```bash
# Reclaim ownership of CONFIG_DIR for the invoking user (sudo creates as root).
# install_cli + install_git_hooks + install_webhook_service deliberately leave
# system paths (/usr/local/bin, /etc/systemd, /opt/claude-secure) as root.
chown -R "$_invoking_user:$_invoking_user" "$CONFIG_DIR"
chmod 777 "$CONFIG_DIR/logs"
```

**Placement rationale:**
- AFTER `copy_app_files` (creates `$CONFIG_DIR/app/`)
- AFTER `install_git_hooks` (writes into `$CONFIG_DIR/app/.git/hooks/`)
- BEFORE `install_webhook_service` (which writes to `/opt/claude-secure`, `/etc/systemd/system`, `/etc/claude-secure` — all deliberately root-owned)

**Why the explicit `chmod 777` on logs:** `chown -R` preserves modes, so the 777 set in `setup_directories` would carry through. The re-apply is defence-in-depth: the three containers write as different UIDs (claude:1001, node:1000, root:0) and a silent permission downgrade on logs would break the whole logging pipeline.

## Verification

1. `bash -n install.sh` — syntax OK
2. `grep` for the three markers:
   - `chown "$_invoking_user:$_invoking_user" "$ws_path"` — line 328
   - `chown -R "$_invoking_user:$_invoking_user" "$CONFIG_DIR"` — line 623
   - `chmod 777 "$CONFIG_DIR/logs"` — lines 232 (original) and 624 (new)
3. Exhaustive `chown` search across install.sh returns exactly two new lines (328, 623) — no `chown` on `/usr/local/bin`, `/opt/claude-secure`, or `/etc/systemd/system`.
4. Logic trace: `main()` call order is `setup_directories → setup_auth → setup_workspace → copy_app_files → build_images → install_cli → install_git_hooks → [new chown -R + chmod 777] → install_webhook_service`. The new chown captures everything the real user should own and leaves every subsequent system-path write untouched.

## Success Criteria (live-verification)

The success criteria below are runtime `stat` checks that require an actual `sudo bash install.sh` run on a fresh system (Docker build + OAuth token prompt cannot be executed in this editing session). They are documented here for the next install test:

- `stat -c '%U' ~/.claude-secure` → invoking user, not root
- `stat -c '%U' ~/.claude-secure/profiles/default/.env` → invoking user
- `stat -c '%U %a' ~/.claude-secure/logs` → `<user> 777`
- `stat -c '%U' ~/claude-workspace` → invoking user
- `stat -c '%U' /usr/local/bin/claude-secure` → root (unchanged)

## Deviations from Plan

None — plan executed exactly as written. Both edits match the plan's specified code verbatim.

## Self-Check: PASSED

- install.sh modified (line 328 ws_path chown, lines 619-624 main() chown+chmod block)
- Commit `c945d07` exists: `git log --oneline | grep c945d07` → `c945d07 fix(quick-260415-f1s): chown CONFIG_DIR + workspace to invoking user after sudo install`
- `bash -n install.sh` — syntax OK
- All three grep markers found at expected line numbers
