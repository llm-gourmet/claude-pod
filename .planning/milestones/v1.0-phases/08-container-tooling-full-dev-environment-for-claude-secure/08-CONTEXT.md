# Phase 8: Container Tooling -- Full Dev Environment for claude-secure - Context

**Gathered:** 2026-04-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Expand the Claude container image from a minimal `node:22-slim` base (currently: curl, jq, uuid-runtime, dnsutils) into a fully-equipped development environment. Claude Code running inside the container needs core dev tools, Python ecosystem, and fast search utilities to work productively on real projects.

This phase modifies `claude/Dockerfile` only. No changes to proxy, validator, hooks, or docker-compose.yml.

</domain>

<decisions>
## Implementation Decisions

### Tool Selection
- **D-01:** Install core dev tools: git, build-essential, ca-certificates, openssh-client, wget
- **D-02:** Install Python ecosystem: python3, python3-pip, python3-venv
- **D-03:** Install fast search tools for Claude Code: ripgrep (rg), fd-find
- **D-04:** Image size is not a concern -- developer productivity takes priority over keeping the image lean

### What NOT to Install
- **D-05:** No interactive editors (vim, nano) or file inspection tools (less, tree, zip) -- not requested
- **D-06:** No network/debug tools (net-tools, iputils-ping, iproute2, strace) -- not requested

### Claude's Discretion
- Exact ordering and layering of `apt-get install` commands in Dockerfile
- Whether to consolidate into one RUN layer or split for caching
- Whether `--no-install-recommends` should apply to all packages

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Container Configuration
- `claude/Dockerfile` -- Current Claude container build, line 4: existing apt-get install line to extend
- `docker-compose.yml` -- Container orchestration, env vars, volume mounts (verify no changes needed)

### Security Model
- `CLAUDE.md` -- Project constraints: root-owned hooks/settings, `cap_drop: ALL`, `no-new-privileges`

</canonical_refs>

<code_context>
## Existing Code Insights

### Current Dockerfile State
- Base image: `node:22-slim` (Debian bookworm)
- Already installed: `curl`, `jq`, `uuid-runtime`, `dnsutils`
- Uses `--no-install-recommends` to minimize size
- Non-root user `claude` created for running Claude Code
- Root-owned hooks and settings at `/etc/claude-secure/`

### Established Patterns
- Single `apt-get update && apt-get install` layer followed by `rm -rf /var/lib/apt/lists/*`
- All security-sensitive files are root-owned before `USER claude` directive

### Integration Points
- The `USER claude` directive must come after all root-owned file setup
- Any new tools must not interfere with the existing `npm install -g @anthropic-ai/claude-code`

</code_context>

<specifics>
## Specific Ideas

- User specifically mentioned wanting `git`, `curl` (already present), `python3`, `python3-pip`, `jq` (already present), `build-essential`, `ca-certificates`
- Also wants `ssh` (openssh-client) for potential git/SSH workflows
- ripgrep and fd-find for fast code searching (Claude Code works better with these)

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 08-container-tooling-full-dev-environment-for-claude-secure*
*Context gathered: 2026-04-10*
