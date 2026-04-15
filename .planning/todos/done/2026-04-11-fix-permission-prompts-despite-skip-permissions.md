---
created: 2026-04-11T12:46:01.157Z
title: Fix permission prompts despite dangerously-skip-permissions
area: tooling
files:
  - bin/claude-secure:347
  - claude/Dockerfile:1
  - .planning/debug/skip-permissions-not-applied.md
---

## Problem

User is still being prompted for confirmation (e.g., for `rm -rf`) despite running in `--dangerously-skip-permissions` mode. The flag was already added to `bin/claude-secure` line 347 (`docker compose exec -it claude claude --dangerously-skip-permissions`), so the original missing-flag bug is fixed.

User suspects the `node:22-slim` base image may be related. Slim images strip many utilities -- possibly a missing dependency that Claude Code needs to detect or enforce skip-permissions mode properly.

## Solution

Investigation needed:

1. **Verify the flag is actually reaching Claude Code**: exec into container and check `ps aux` or `/proc/*/cmdline` to confirm the flag is present at runtime.
2. **Check if slim image is missing something**: Compare `node:22-slim` vs `node:22` for tools Claude Code might need (e.g., `bash`, `stty`, `tput`, terminal capabilities). Claude Code may fall back to interactive mode if terminal detection fails.
3. **Check Claude Code's own permission logic**: Some operations (like `rm -rf`) may have model-level safety checks that are independent of `--dangerously-skip-permissions` (which controls the tool permission system, not the AI's judgment). Clarify whether the prompt is from the permission system or from Claude's own caution.
4. **Test with `node:22` (non-slim)**: Quick experiment to confirm or rule out the slim image hypothesis.
