# Phase 8: Container Tooling -- Full Dev Environment - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-10
**Phase:** 08-container-tooling-full-dev-environment-for-claude-secure
**Areas discussed:** Container tool selection

---

## Scope Clarification

User clarified that Phase 8 was poorly described in the roadmap. The original name "container tooling -- full dev environment" was interpreted as Makefile/test runner/linting, but the actual intent is:

**Problem:** The Claude container uses `node:22-slim` with minimal tools (curl, jq, uuid-runtime, dnsutils). This is insufficient for productive development with Claude Code inside the container.

**Actual scope:** Expand the Dockerfile to install essential development tools so Claude Code can work on real projects.

---

## Tool Categories

| Option | Description | Selected |
|--------|-------------|----------|
| Core dev tools | git, build-essential, ca-certificates, openssh-client, wget | ✓ |
| Python ecosystem | python3, python3-pip, python3-venv | ✓ |
| Editor/file tools | vim/nano, less, tree, file, zip/unzip | |
| Network/debug tools | net-tools, iputils-ping, iproute2, strace | |

**User's choice:** Core dev tools + Python ecosystem
**Notes:** User specifically mentioned wanting git, python3, python3-pip, build-essential, ca-certificates, ssh

---

## Search Tools

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, add ripgrep + fd-find | Claude Code works better with fast search tools | ✓ |
| Just the basics | Stick with grep/find from coreutils | |

**User's choice:** Yes, add ripgrep + fd-find

---

## Image Size

| Option | Description | Selected |
|--------|-------------|----------|
| Size doesn't matter | Developer productivity over image size | ✓ |
| Keep it lean | Only strictly necessary tools | |

**User's choice:** Size doesn't matter

---

## Claude's Discretion

- Dockerfile layer organization and caching strategy
- `--no-install-recommends` usage
- Package ordering

## Deferred Ideas

None
