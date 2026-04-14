# claude-secure

Run Claude Code inside a Docker sandbox where no secret can leave without your permission.

---

## Installation

**Prerequisites:** Docker Engine 24+, Docker Compose v2, `curl`, `jq`, `uuidgen`

Supported platforms: Linux (native), WSL2, macOS with Docker Desktop ≥ 4.44.3

```bash
git clone <repo-url>
cd claude-secure
sudo ./install.sh

# Also install webhook listener + container reaper (optional)
sudo ./install.sh --with-webhook
```

The installer builds Docker images, installs the `claude-secure` CLI to `/usr/local/bin`, and writes security hooks to `/etc/claude-secure/` (root-owned, not writable by the Claude process).

On first run it prompts for:
- Auth: OAuth token (`claude setup-token`) or API key
- Workspace path (default: `~/claude-workspace`)

---

## CLI

```bash
# Interactive session (superuser — all profiles merged)
claude-secure

# Interactive session scoped to a profile
claude-secure --profile <name>

# Headless agent session (GitHub event trigger)
claude-secure --profile <name> spawn --event '<json>'
claude-secure --profile <name> spawn --event-file <path>

# Replay a webhook delivery
claude-secure --profile <name> replay <delivery-id>
```

### Profiles

A profile is a named workspace with its own secrets, whitelist, and doc repo binding.

```bash
# Create (or enter) a profile — prompts for workspace path and credentials
claude-secure --profile myproject
```

Profile directory layout:
```
~/.claude-secure/profiles/<name>/
  profile.json      # workspace, repo, docs_repo, max_turns, etc.
  .env              # secrets: GITHUB_TOKEN, DOCS_REPO_TOKEN, etc.
  whitelist.json    # per-profile domain whitelist
```

`profile.json` key fields:

| Field | Description |
|-------|-------------|
| `workspace` | Absolute path to the project workspace |
| `repo` | `owner/repo` — used for webhook routing |
| `docs_repo` | HTTPS URL of doc repo (v4.0) |
| `docs_branch` | Doc repo branch (default: `main`) |
| `docs_project_dir` | Path inside doc repo for this profile (e.g. `projects/myapp`) |
| `max_turns` | Max Claude turns per headless spawn |

---

## Commands

```bash
claude-secure                          # Interactive session (superuser)
claude-secure --profile <name>         # Interactive session (profile-scoped)

claude-secure stop                     # Stop all containers
claude-secure status                   # Container status + Claude Code version
claude-secure list                     # List all profiles and running status
claude-secure update                   # Pull latest source, rebuild, update CLI
claude-secure upgrade                  # Rebuild Claude image with latest Claude Code

claude-secure --profile <name> spawn --event '<json>'    # Headless spawn
claude-secure --profile <name> replay <delivery-id>      # Replay webhook
claude-secure reap                     # Clean up orphaned containers and stale events

claude-secure --profile <name> profile init-docs         # Bootstrap doc repo layout

claude-secure help                     # Show all commands
```

### Log flags (append to any command)

```bash
claude-secure log:hook        # Hook script decisions
claude-secure log:anthropic   # Proxy metadata
claude-secure log:bodies      # Proxy full request/response bodies
claude-secure log:iptables    # Validator/iptables events
claude-secure log:all         # Everything
```

---

## Architecture

```
                        +---------------------------+
                        |     claude-external       |
                        |       (network)           |
                        +---------------------------+
                              |              |
                              |         api.anthropic.com
                              |
                  +-----------+-----------+
                  |       proxy           |
                  |  (Node.js)            |
                  |  - HTTP :8080         |
                  |  - HTTPS :443         |
                  |  - secret redaction   |
                  |  - buffered req/res   |
                  |  - DNS alias:         |
                  |    api.anthropic.com  |
                  +-----------+-----------+
                              |
                  +-----------+-----------+
                  |   claude-internal     |
                  |   (network,           |
                  |    internal: true)    |
                  +-----------+-----------+
                              |
          +-------------------+-------------------+
          |                                       |
+---------+---------+               +-------------+---------+
|      claude       |               |       validator       |
| (Ubuntu, Claude   |               | (Python, SQLite,      |
|  Code CLI)        | <- shared ->  |  iptables)            |
| - PreToolUse hook |   network     | - call-ID registry    |
| - workspace mount |   namespace   | - iptables rules      |
+-------------------+               +-------------+---------+
```

Four layers enforce the security guarantees:

### 1. Network isolation

The `claude-internal` Docker network has `internal: true` — no external access by default. The proxy is the only container on both networks and is the single exit point to `api.anthropic.com`.

### 2. Secret redaction (proxy)

Every request to Anthropic is buffered in full, scanned against `whitelist.json`, and secret values replaced with opaque placeholders before forwarding. Responses are scanned in reverse — placeholders restored to real values for Claude to use, but the real values never appear in LLM context sent upstream.

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com"]
    }
  ],
  "readonly_domains": ["google.com", "docs.anthropic.com"]
}
```

The whitelist is re-read on every request — no restart needed after edits.

### 3. PreToolUse hook

Every `Bash`, `WebFetch`, and `WebSearch` tool call passes through a hook script at `/etc/claude-secure/hooks/pre-tool-use.sh` (root-owned, not writable by the Claude process).

The hook:
1. Extracts the target domain from the tool call payload
2. Checks the domain against `whitelist.json`
3. On allow: generates a UUID call-ID, registers it with the validator, returns allow
4. On block: returns block with a reason — Claude sees the rejection and cannot retry

### 4. Network enforcement (validator + iptables)

The validator shares the claude container's network namespace (`network_mode: service:claude`). When the hook registers a call-ID, the validator adds a time-limited iptables rule permitting that specific outbound connection. Any connection attempt without a registered call-ID is rejected at the packet level — even if the hook is somehow bypassed.

---

## Doc Repo (v4.0)

Every agent session can read project context from and write reports to a private doc repo. The write token (`DOCS_REPO_TOKEN`) lives in the profile `.env` on the host and is never mounted into the Claude container.

```json
// profile.json
{
  "docs_repo":        "https://github.com/you/claude-docs.git",
  "docs_branch":      "main",
  "docs_project_dir": "projects/myapp"
}
```

```bash
# ~/.claude-secure/profiles/<name>/.env
DOCS_REPO_TOKEN=github_pat_xxx   # host-only, never reaches the container
```

At spawn time:
- The doc repo's `projects/<slug>/` subtree is shallow-cloned and bind-mounted read-only at `/agent-docs/` inside the container — agents can read context, not push
- After Claude exits, a host-side async shipper pushes the session report to `projects/<slug>/reports/YYYY/MM/<date>-<session-id>.md`
- A Stop hook ensures a report spool is written before Claude exits — shipper picks it up even if the container crashes

Bootstrap a new doc project layout:

```bash
claude-secure --profile myapp profile init-docs
# Creates: todo.md, architecture.md, vision.md, ideas.md, specs/, reports/INDEX.md
```
