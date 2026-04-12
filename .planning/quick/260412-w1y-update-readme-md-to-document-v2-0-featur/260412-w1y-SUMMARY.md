---
phase: quick-260412-w1y
plan: 01
subsystem: docs
tags: [readme, documentation, v2.0, profiles, webhook, spawn, reap]
dependency_graph:
  requires: []
  provides: [updated-readme-v2.0]
  affects: [README.md]
tech_stack:
  added: []
  patterns: []
key_files:
  created: []
  modified:
    - README.md
decisions:
  - Used `default-executions.jsonl` path (LOG_PREFIX="${name}-" confirmed from bin/claude-secure source)
  - Obtained current README from main branch via git checkout before applying changes
metrics:
  duration: 5min
  completed: 2026-04-12
  tasks_completed: 2
  files_changed: 3
---

# Phase quick-260412-w1y Plan 01: Update README.md to Document v2.0 Features Summary

**One-liner:** Added Profiles section with profile.json table, spawn/reap/replay commands in Usage, Webhook Listener section with webhook.json config, corrected audit log path to `default-executions.jsonl`, updated Installation to show `sudo` and `--with-webhook`, and replaced stale test table with phases 12-17.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add Profiles section, update Usage and Installation | 3a8ae71 | README.md, bin/claude-secure, webhook/listener.py |
| 2 | Add Webhook Listener section, fix audit log path, update test table | 5a8a9a5 | README.md |

## Changes Applied

Six targeted changes were applied to README.md:

**Change A (Profiles section):** Inserted `## Profiles` after `## Configuration` and before `## Logging`. Includes directory layout, how to create a profile, and profile.json field table with all nine fields.

**Change B (Usage section):** Added second command block after existing Usage block covering `--profile`, spawn, replay, reap, and list commands.

**Change C (Installation section):** Changed `./install.sh` to `sudo ./install.sh`, added `--with-webhook` variant, and added two bullet points explaining sudo requirement and what `--with-webhook` installs.

**Change D (Webhook Listener section):** Inserted `## Webhook Listener` before `## Phase 17`. Covers installation, webhook.json config table, profile fields required for routing, manual startup, and log tailing.

**Change E (Audit log path fix):** Changed `executions.jsonl` to `default-executions.jsonl` in the Audit log subsection (path in narrative and three jq examples). Reason: `LOG_PREFIX="${name}-"` so the default profile writes to `default-executions.jsonl`, not `executions.jsonl`.

**Change F (Test table):** Replaced the stale table (test-phase6, test-phase7, test-phase9) with the current table covering phases 1-4 and 12-17 including `test-phase17-e2e.sh`.

## Deviations from Plan

**1. [Rule 3 - Blocking] Checked out main branch README before applying changes**
- **Found during:** Pre-task setup
- **Issue:** The worktree was on branch `worktree-agent-ad4a1ae1` based on an old v1.0 commit. The README in the worktree was the old v1.0 version (missing Phase 16/17, using `--instance` not `--profile`). The plan was authored against the current main branch README.
- **Fix:** Used `git checkout main -- README.md bin/claude-secure webhook/listener.py` to bring the current main branch files into the worktree before applying the plan's changes.
- **Files modified:** README.md, bin/claude-secure, webhook/listener.py
- **Commit:** 3a8ae71

## Verification Results

```
Profiles section:            1  (>= 1 required)
webhook_secret occurrences:  2  (>= 1 required)
spawn --event occurrences:   2  (>= 1 required)
sudo ./install.sh:           4  (>= 1 required)
with-webhook occurrences:    7  (>= 2 required)
## Webhook Listener:         1  (>= 1 required)
default-executions.jsonl:    4  (>= 1 required)
test-phase17-e2e.sh:         1  (>= 1 required)
Stale executions.jsonl:      0  (== 0 required)
```

All six success criteria met.

## Self-Check: PASSED

- README.md exists and contains all six required changes
- Commits 3a8ae71 and 5a8a9a5 exist in git log
