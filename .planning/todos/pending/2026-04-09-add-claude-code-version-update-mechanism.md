---
created: 2026-04-09T09:15:56.078Z
title: Add Claude Code version update mechanism
area: tooling
files:
  - claude/Dockerfile
  - bin/claude-secure
  - docker-compose.yml
---

## Problem

Claude Code inside the container is pinned to whatever version was installed at image build time (currently v2.1.96). There is no way for the user to update Claude Code to a newer version without manually rebuilding the Docker image. The `claude-secure update` command only does `git pull && docker compose build`, which rebuilds from scratch but doesn't make it obvious that this updates Claude Code too.

Users need either:
1. An auto-update mechanism that checks for new Claude Code versions on container start
2. A dedicated `claude-secure upgrade` command that rebuilds the claude image with the latest Claude Code version
3. Version pinning in the Dockerfile with a clear update path

Note: `DISABLE_AUTOUPDATER=1` is currently set to prevent Claude Code's built-in updater from making external calls (it would fail anyway on the isolated network). Any update mechanism must work through the Docker build process.

## Solution

Options to evaluate:
- Add `claude-secure upgrade` subcommand that runs `docker compose build --no-cache claude` to force npm to fetch the latest `@anthropic-ai/claude-code`
- Pin a specific version in the Dockerfile (`npm install -g @anthropic-ai/claude-code@X.Y.Z`) and update it via a script or `claude-secure update`
- Show current vs latest version on `claude-secure status` so the user knows when an update is available
