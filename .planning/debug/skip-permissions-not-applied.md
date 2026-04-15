---
status: upstream_bug
trigger: "Claude Code inside Docker should start with --dangerously-skip-permissions but user gets prompted for tool call confirmations"
created: 2026-04-09T00:00:00Z
updated: 2026-04-11T00:00:00Z
---

## Current Focus

Resolved — upstream Claude Code regression, not a claude-secure bug.

## Symptoms

expected: Claude Code starts with --dangerously-skip-permissions and never asks for tool call confirmations (all auto-approved)
actual: User gets prompted for permission before tool calls execute
errors: None -- it just doesn't run in skip-permissions mode
reproduction: Run `claude-secure` -> try any tool call -> permission prompt appears
started: Unknown -- user just noticed

## Root Cause

Two issues found:

### 1. Missing flag (FIXED in claude-secure)

bin/claude-secure line 99 (now line 347) was missing `--dangerously-skip-permissions`.
Fixed: flag added to `docker compose exec -it claude claude --dangerously-skip-permissions`.

### 2. Upstream Claude Code regression (NOT fixable by us)

Claude Code v2.1.78+ introduced a regression in `cli.js` function `nvY()` that hardcodes
certain directories (`.claude/`, `.git/`, `.vscode/`, `.idea/`) as "unsafe to write" —
**regardless of `--dangerously-skip-permissions` flag, settings, or PreToolUse hooks**.

- Last working version: v2.1.77
- Tracking issues: anthropics/claude-code#36168, #36192, #32559, #39523 (meta-issue, 12+ dupes)
- Fix promised by maintainer @bcherny on 2026-03-20 but still broken through v2.1.85
- Affects CLI flag, `permissions.defaultMode: "bypassPermissions"`, and hook `permissionDecision: "allow"`

### C compiler / slim image (NOT related)

Investigated whether `node:22-slim` missing a C compiler could cause permission issues.
Conclusion: Dockerfile already installs `build-essential` + `python3`, so native modules
(`better-sqlite3`, `node-pty`, `hnswlib-node`, `diskusage`) compile correctly. Not related.

## Decision

Wait for upstream fix. Not pinning to v2.1.77 — too old, loses other improvements.
Document as known issue.

## Eliminated

- Missing flag in bin/claude-secure (fixed)
- C compiler / slim image missing build tools (already addressed in Dockerfile)
- Native module compilation failures (build-essential handles this)

## Evidence

- timestamp: 2026-04-09T00:00:00Z
  checked: bin/claude-secure line 99 (the default start command)
  found: `docker compose exec -it claude claude` -- no --dangerously-skip-permissions flag
  implication: The flag is simply never passed to the claude CLI

- timestamp: 2026-04-09T00:00:00Z
  checked: docker-compose.yml command for claude service
  found: `command: ["sleep", "infinity"]` -- container stays alive, claude is launched via exec
  implication: The flag must be on the exec invocation in bin/claude-secure, not in compose

- timestamp: 2026-04-11T00:00:00Z
  checked: GitHub issues for anthropics/claude-code
  found: Regression in v2.1.78+ — nvY() function hardcodes protected dirs, ignores bypass mode
  implication: Cannot fix from our side, must wait for upstream

- timestamp: 2026-04-11T00:00:00Z
  checked: claude/Dockerfile for C compiler / build tools
  found: build-essential, python3 already installed — native modules compile fine
  implication: Slim image is not the cause of permission prompts
