# Stack Research: v2.0 Headless Agent Mode Additions

**Domain:** Event-driven ephemeral agent spawning (webhook listener, profile system, headless execution, report delivery)
**Researched:** 2026-04-11
**Confidence:** HIGH (official docs verified for Claude Code headless mode, Agent SDK, and Octokit; mature stable libraries)

**Scope:** This document covers ONLY the new technologies needed for v2.0. The existing v1.0 stack (Docker Compose, Node.js 22 proxy, Python 3.11 validator, iptables, Bash hooks, SQLite) is validated and unchanged.

## Recommended Stack Additions

### Claude Code Execution (Headless)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Claude Code CLI (`-p` flag) | latest (2.1.x) | Non-interactive Claude Code execution inside containers | Official headless mode. `-p` (or `--print`) runs non-interactively, prints output, exits. Combined with `--output-format json` gives structured results with session ID and metadata. Already installed in claude container. No additional dependency. | HIGH |
| `--allowedTools` flag | -- | Granular tool permission per spawn | Prefix-match syntax (e.g., `Bash(git *)`) controls exactly which tools are auto-approved. Per-profile tool lists mean each service gets minimum required permissions. | HIGH |
| `--max-turns` flag | -- | Prevent runaway execution | Limits agentic turns before stopping. Critical for ephemeral instances where cost/time must be bounded. | HIGH |
| `--append-system-prompt` | -- | Per-event-type instructions | Injects event-specific context (issue body, CI failure log, push diff) without replacing Claude Code's built-in system prompt. | HIGH |
| `--bare` flag | -- | Clean, reproducible headless runs | Skips hooks, skills, plugins, MCP servers, auto memory, CLAUDE.md auto-discovery. Recommended for scripted/SDK calls per official docs. Will become default for `-p` in a future release. Use explicit `--settings` and `--append-system-prompt` to load only what's needed. | HIGH |

**Decision: CLI `-p` over Agent SDK.** The Agent SDK (`@anthropic-ai/claude-agent-sdk`) is the newer programmatic interface with TypeScript/Python packages. However, for claude-secure v2.0, CLI `-p` is the right choice because:
1. The claude container already has Claude Code CLI installed -- zero new dependencies
2. The SDK requires `ANTHROPIC_API_KEY` (no OAuth support), while CLI supports OAuth tokens
3. CLI invocation via `docker compose exec` or container entrypoint is simpler than embedding an SDK process
4. The SDK spawns its own Claude Code process internally anyway -- adds a layer with no benefit in our containerized model
5. `--output-format json` gives structured output (result, session_id, usage metadata) sufficient for report extraction
6. The security wrapper's proxy and hooks work transparently with CLI -- SDK would need separate integration

**If reconsidered later:** The Agent SDK becomes attractive if we need programmatic hooks (PreToolUse/PostToolUse callbacks in code), subagent orchestration, or streaming message inspection. For v2.0's "spawn, run, collect result" pattern, CLI is simpler and proven.

### Webhook Listener (Host Process)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Node.js | 22 LTS | Webhook listener runtime | Already required on host for the project. LTS until April 2027. Async I/O is ideal for a webhook server that spawns Docker processes. | HIGH |
| Node.js `http` (stdlib) | -- | HTTP server for webhook endpoint | Same zero-dependency philosophy as the proxy. A webhook listener is ~60 lines: parse JSON body, verify signature, dispatch handler. No framework needed. | HIGH |
| Node.js `crypto` (stdlib) | -- | HMAC-SHA256 webhook signature verification | GitHub sends `x-hub-signature-256` header. `crypto.createHmac('sha256', secret).update(body).digest('hex')` verifies authenticity. Standard pattern, no library needed. | HIGH |
| Node.js `child_process` (stdlib) | -- | Spawn `docker compose` commands | `child_process.spawn('docker', ['compose', ...])` to launch ephemeral instances. Async, non-blocking, captures stdout/stderr for logging. | HIGH |

**Decision: stdlib `http` over `@octokit/webhooks`.** The `@octokit/webhooks` package (v13.x) provides typed event handling and signature verification. However:
- It adds an npm dependency to a security tool (counter to project philosophy)
- Signature verification is 5 lines with `crypto.createHmac`
- We handle 3 event types (issues, push, workflow_run) -- no need for a typed event system
- The listener runs on the host, not inside the security boundary, but minimizing dependencies remains good practice

**If reconsidered later:** Use `@octokit/webhooks` if event types grow beyond 5-6 or if GitHub changes their signature scheme.

### Profile System (Configuration)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| JSON files | -- | Profile configuration (`profiles/{name}/profile.json`) | Consistent with existing `whitelist.json` pattern. Contains: allowed domains, env file path, workspace path, allowed tools, max turns, system prompt additions. | HIGH |
| Bash | 5.x | Profile loader in `claude-secure` CLI | Extends existing CLI with `--profile NAME` flag. Reads profile config, sets COMPOSE_PROJECT_NAME, mounts correct workspace, loads profile-specific .env. | HIGH |
| Docker Compose `--env-file` | v2.24+ | Per-profile environment injection | `docker compose --env-file profiles/svc/.env up` loads profile-specific secrets. Already supported by Compose v2. | HIGH |
| Docker Compose bind mounts | v2.24+ | Per-profile workspace mounting | Override workspace volume via `-v` or environment variable in compose file. Profile config specifies workspace path on host. | HIGH |

**No new technology needed.** The profile system is a configuration layer using existing tools: JSON for config, Bash for CLI integration, Docker Compose for runtime parameterization. Each profile directory (`profiles/{name}/`) contains:
- `profile.json` -- allowed domains, tools, max turns, event handlers
- `.env` -- service-specific secrets
- `whitelist.json` -- service-specific secret-to-placeholder mappings

### Report Delivery (Writing to External Repo)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| `git` CLI | 2.x | Clone, commit, push to documentation repo | Already in the claude container. Standard git operations inside the container, through the security proxy. No API abstraction needed. | HIGH |
| `gh` CLI | 2.x | PR creation on documentation repo (optional) | If reports should go through PR review. `gh pr create --title "..." --body "..."` is non-interactive. Already available or easily added to container. | MEDIUM |
| SSH deploy key or GitHub PAT | -- | Auth for pushing to docs repo | Deploy key (read-write, scoped to single repo) is more secure than a PAT. Loaded via profile's `.env`, mapped into container. Must be in whitelist.json for redaction. | HIGH |

**Decision: `git` CLI over Octokit REST API.** Using `@octokit/rest` for programmatic commits (create blob, create tree, create commit, update ref) is possible but:
- Adds an npm dependency where none is needed
- The claude container already has `git` installed
- Claude Code itself can run `git commit` and `git push` via Bash tool -- the headless task prompt can instruct it to commit results
- Git operations go through the security proxy and validator as normal whitelisted calls

**Two report delivery patterns:**

1. **Claude-driven (recommended for v2.0):** The headless prompt instructs Claude to write the report file and commit/push it. Git push goes through the validator (docs repo domain whitelisted in profile). Simplest -- no new code needed.

2. **Host-driven (fallback):** Webhook listener extracts the result from `--output-format json` stdout, writes it to a cloned docs repo on the host, commits and pushes. More control but requires host-side git operations outside Docker.

### Process Management (Host)

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| systemd | system | Webhook listener daemon management | Standard on all target platforms (Linux, WSL2). `systemctl --user` for user-level service. Auto-restart on crash, journal logging, boot start. | HIGH |
| systemd user service | -- | Run listener without root | `~/.config/systemd/user/claude-secure-webhook.service` runs as the developer's user. Has access to Docker socket and project files. | HIGH |

**systemd unit file pattern:**
```ini
[Unit]
Description=claude-secure webhook listener
After=network.target docker.service

[Service]
Type=simple
ExecStart=/usr/bin/node /path/to/claude-secure/webhook/listener.js
Restart=on-failure
RestartSec=5
Environment=WEBHOOK_SECRET=<from-env>
Environment=WEBHOOK_PORT=9876
WorkingDirectory=/path/to/claude-secure

[Install]
WantedBy=default.target
```

## Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Node.js `fs/promises` (stdlib) | -- | Read profile configs, write logs | Profile JSON loading in webhook listener |
| Node.js `path` (stdlib) | -- | Path resolution for profiles/workspaces | Profile directory resolution |
| Node.js `url` (stdlib) | -- | Parse webhook request URLs | Route matching in listener |
| `jq` | 1.7+ | Parse `--output-format json` results in Bash | Extracting result/session_id from Claude CLI output |

## Installation

```bash
# No new packages to install -- all stdlib

# Webhook listener setup (host-side)
mkdir -p webhook/
# Create listener.js (Node.js stdlib http server)
# Create systemd user service file

# Profile setup
mkdir -p profiles/
# Create profiles/{service-name}/profile.json
# Create profiles/{service-name}/.env
# Create profiles/{service-name}/whitelist.json

# Claude container additions (Dockerfile)
# gh CLI (optional, for PR creation): apt-get install gh
# Deploy keys: mounted via Docker volume from profile config
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Claude CLI `-p` | `@anthropic-ai/claude-agent-sdk` (TypeScript) | If you need programmatic hooks, streaming message inspection, subagent orchestration, or SDK-native session management. Requires `ANTHROPIC_API_KEY` (no OAuth). Adds dependency. |
| Claude CLI `-p` | `@anthropic-ai/claude-agent-sdk` (Python) | Same as TypeScript SDK. Python variant (`pip install claude-agent-sdk`). Better if webhook listener were Python. |
| Node.js stdlib `http` | `@octokit/webhooks` (v13.x) | If handling many GitHub event types (>5-6) or if GitHub changes signature verification scheme. Adds typed event handling. |
| Node.js stdlib `http` | Express + webhook middleware | If the listener needs to serve additional HTTP endpoints (dashboard, health checks, API). Overkill for a single-purpose webhook receiver. |
| `git` CLI in container | `@octokit/rest` (npm) | If you need to create commits without cloning (via GitHub API blob/tree/commit). Useful for repos too large to clone. Adds npm dependency. |
| `git` CLI in container | GitHub Actions (external) | If the webhook should trigger a GitHub Action instead of a local container. Moves execution to GitHub's infrastructure. Loses local security context and secret isolation. |
| systemd user service | PM2 | If you prefer Node.js-native process management. Adds global npm dependency. systemd is already on the system and more reliable. |
| systemd user service | Docker container for listener | If you want the listener containerized too. But it needs Docker socket access to spawn containers, creating a "Docker-in-Docker" situation. Host process is simpler. |
| JSON profile files | YAML profile files | If profiles become complex enough to benefit from YAML's readability (comments, multi-line strings). JSON is consistent with existing whitelist.json. |
| SSH deploy key | GitHub App installation token | If deploying to multiple repos or needing fine-grained permissions. More complex setup. Deploy key is simpler for single-repo writes. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `@anthropic-ai/claude-agent-sdk` for v2.0 | Adds dependency, requires API key (no OAuth), spawns CLI internally anyway, needs separate integration with proxy/hooks security layers | Claude Code CLI `-p` with `--output-format json` |
| Express/Fastify for webhook listener | Framework overhead for a single-endpoint webhook receiver. Same argument as proxy -- security tool should minimize dependencies | Node.js stdlib `http` |
| `@octokit/webhooks` for signature verification | npm dependency for 5 lines of `crypto.createHmac`. Counter to zero-dependency host-side philosophy | Node.js `crypto.createHmac('sha256', secret)` |
| `@octokit/rest` for report commits | npm dependency where `git push` suffices. Claude container already has git. Report commits are simple single-file additions | `git` CLI inside container |
| Docker-in-Docker for webhook listener | Listener needs Docker socket access to spawn containers. Running it inside Docker creates privilege escalation complexity and socket forwarding issues | Host-side Node.js process managed by systemd |
| PM2 / forever / nodemon for listener | Global npm dependencies for process management. systemd is already present, more reliable, supports journal logging, boot start | systemd user service |
| `--dangerously-skip-permissions` | Blanket permission bypass. Unsafe even in containers -- a prompt injection could `rm -rf` the workspace | `--allowedTools` with explicit tool list per profile |
| Webhook listener in Python | Would add a second runtime to the host. Node.js is already required for the project. Consistency matters. | Node.js webhook listener |
| Redis/PostgreSQL for event queue | Massive overkill for a solo-dev tool processing a few events per day. In-memory queue or direct spawn is sufficient | Direct `child_process.spawn` per event, with optional file-based queue for retry |
| ngrok/Cloudflare Tunnel for webhook exposure | Adds external dependency for exposing webhook to internet. Fine for development but not for production daemon | Direct port exposure or reverse proxy (nginx) already on host |

## Stack Patterns by Architecture Layer

### Webhook Flow (Host -> Docker)

```
GitHub --[POST]--> Webhook Listener (host:9876)
                        |
                   Verify HMAC-SHA256 signature
                   Parse event type + payload
                   Load profile for target repo
                        |
                   child_process.spawn('docker', ['compose',
                     '--project-name', profile.instance,
                     '--env-file', profile.envFile,
                     'run', '--rm', 'claude',
                     'claude', '-p', prompt,
                     '--bare',
                     '--output-format', 'json',
                     '--max-turns', profile.maxTurns,
                     '--allowedTools', profile.allowedTools,
                     '--append-system-prompt', eventPrompt
                   ])
                        |
                   Capture stdout (JSON result)
                   Log result + cleanup
```

### Profile Directory Layout

```
profiles/
  service-a/
    profile.json      # { "workspace": "/path/to/repo", "maxTurns": 25, ... }
    .env               # SERVICE_A_API_KEY=xxx, GITHUB_TOKEN=xxx
    whitelist.json     # Service-specific secret mappings
  service-b/
    profile.json
    .env
    whitelist.json
```

### Headless Execution Pattern

```bash
# Minimal headless invocation
claude -p "$PROMPT" \
  --bare \
  --output-format json \
  --max-turns 25 \
  --allowedTools "Read,Edit,Bash(git *),Glob,Grep" \
  --append-system-prompt "$EVENT_CONTEXT"

# Extract result
echo "$OUTPUT" | jq -r '.result'
```

### Report Delivery Pattern (Claude-driven)

```bash
# System prompt addition for report delivery
REPORT_PROMPT="After completing your analysis, write a markdown report to
./reports/YYYY-MM-DD-{event-type}-{brief-slug}.md and commit it with
'git add reports/ && git commit -m \"report: {summary}\" && git push origin main'.
The docs repo is already cloned at the working directory."
```

## Version Compatibility

| Component | Compatible With | Notes |
|-----------|-----------------|-------|
| Claude Code CLI `-p` | Claude Code 2.1.x+ | `-p` flag has been stable since early Claude Code releases. `--bare` is newer but documented as stable. |
| `--output-format json` | Claude Code 2.1.x+ | Returns `{ result, session_id, is_error, ... }`. Schema stable per official docs. |
| `--max-turns` | Claude Code 2.1.x+ | Limits agentic loop iterations. Available in both CLI and SDK. |
| `--allowedTools` prefix match | Claude Code 2.1.x+ | `Bash(git *)` syntax. Space before `*` is significant -- documented gotcha. |
| Node.js 22 LTS | Ubuntu 22.04+ / WSL2 | Already validated in v1.0. Webhook listener uses same runtime. |
| systemd user services | Ubuntu 22.04+ / WSL2 | `systemctl --user` requires `loginctl enable-linger $USER` for services to persist after logout. WSL2 may need systemd enabled via `/etc/wsl.conf`. |
| `x-hub-signature-256` | GitHub Webhooks API | SHA-256 HMAC. Replaced older SHA-1 `x-hub-signature`. Always use SHA-256. |

## Integration Points with Existing v1.0 Stack

| v1.0 Component | How v2.0 Interacts | Changes Needed |
|----------------|-------------------|----------------|
| Docker Compose topology | Webhook listener spawns instances via `docker compose run --rm` | Add `--rm` flag support; may need `run` service definition vs `up` |
| COMPOSE_PROJECT_NAME | Profile system sets this per-service for instance isolation | Already works -- profiles just parameterize it |
| Anthropic proxy | Headless Claude traffic flows through proxy as usual | None -- transparent to headless mode |
| Validator + iptables | Call-IDs registered by hooks during headless execution | None -- hooks fire the same in headless mode |
| PreToolUse hooks | Run inside container during headless execution | Verify hooks work with `--bare` flag (they should -- `--bare` skips only project-level config, not container-installed hooks) |
| whitelist.json | Per-profile whitelist loaded via volume mount | Compose file needs parameterized whitelist path from profile |
| .env / env_file | Per-profile .env loaded via `--env-file` | Already supported by Docker Compose |
| Structured logging | Headless runs write to same log directory | Add event ID / profile name to log context |
| Multi-instance support | Each profile spawns with unique COMPOSE_PROJECT_NAME | Already works -- profiles are a higher-level abstraction over instances |

## Sources

- [Claude Code headless mode docs](https://code.claude.com/docs/en/headless) -- verified `-p`, `--bare`, `--output-format`, `--max-turns`, `--allowedTools` flags. HIGH confidence.
- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) -- verified SDK architecture (spawns CLI internally), TypeScript/Python packages, API key requirement. HIGH confidence.
- [Claude Code permission modes](https://code.claude.com/docs/en/permission-modes) -- verified `--allowedTools` prefix match syntax, `--dangerously-skip-permissions` risks. HIGH confidence.
- [@octokit/webhooks npm](https://www.npmjs.com/package/@octokit/webhooks) -- verified v13.x, signature verification API. MEDIUM confidence (version from Dec 2025 publish date).
- [Octokit REST.js](https://octokit.github.io/rest.js/) -- verified programmatic git commit API (blob/tree/commit/updateRef). MEDIUM confidence.
- Training data (Node.js crypto HMAC, child_process.spawn, systemd service files) -- HIGH confidence, stable APIs for years.
- Training data (Docker Compose `run --rm`, `--env-file`) -- HIGH confidence, standard Docker Compose features.

---
*Stack research for: claude-secure v2.0 headless agent mode*
*Researched: 2026-04-11*
