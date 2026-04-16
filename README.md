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

The installer builds Docker images (the Claude container has the PreToolUse hook baked into `/etc/claude-secure/hooks/` at image-build time from `claude/hooks/`), installs the `claude-secure` CLI to `/usr/local/bin`, copies the project tree to `~/.claude-secure/app/`, and writes a default profile at `~/.claude-secure/profiles/default/` (containing `.env`, `whitelist.json`, `profile.json`).

On first run it prompts interactively for:
- Auth choice: OAuth token (recommended — run `claude setup-token` first) or API key
- Workspace path (default: `~/claude-workspace`)

For non-interactive installs, export `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` and pass `-E` to `sudo` so the variable survives the sudo environment scrub:

```bash
sudo -E CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" ./install.sh
```

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

A profile is a named workspace with its own secrets, whitelist, and report repo configuration.

```bash
# Create (or enter) a profile — prompts for workspace path and credentials
claude-secure --profile myproject
```

Profile directory layout:
```
~/.claude-secure/profiles/<name>/
  profile.json      # workspace, repo, report_repo, max_turns, etc.
  .env              # secrets: GITHUB_TOKEN, REPORT_REPO_TOKEN, etc.
  whitelist.json    # per-profile domain whitelist
```

`profile.json` key fields:

| Field | Description |
|-------|-------------|
| `workspace` | Absolute path to the project workspace |
| `repo` | `owner/repo` — used for webhook routing |
| `report_repo` | HTTPS URL of report repo |
| `report_branch` | Report repo branch (default: `main`) |
| `report_project_dir` | Subdirectory inside report repo for this profile (e.g. `projects/myapp`) |
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

Every `Bash`, `WebFetch`, and `WebSearch` tool call passes through a hook script at `/etc/claude-secure/hooks/pre-tool-use.sh` **inside the Claude container** (baked into the image at build time from `claude/hooks/pre-tool-use.sh`; root-owned, not writable by the Claude process).

The hook:
1. Extracts the target domain from the tool call payload
2. Checks the domain against `whitelist.json`
3. On allow: generates a UUID call-ID, registers it with the validator, returns allow
4. On block: returns block with a reason — Claude sees the rejection and cannot retry

### 4. Network enforcement (validator + iptables)

The validator shares the claude container's network namespace (`network_mode: service:claude`). When the hook registers a call-ID, the validator adds a time-limited iptables rule permitting that specific outbound connection. Any connection attempt without a registered call-ID is rejected at the packet level — even if the hook is somehow bypassed.

---

## Report Repo

Claude can commit and push to a private report repo at any point during a session using its Bash tool. The token (`REPORT_REPO_TOKEN`) is available inside the container and redacted by the proxy before any request reaches Anthropic.

```json
// profile.json
{
  "report_repo":        "https://github.com/you/claude-reports.git",
  "report_branch":      "main",
  "report_project_dir": "projects/myapp"
}
```

```bash
# ~/.claude-secure/profiles/<name>/.env
REPORT_REPO_TOKEN=github_pat_xxx
```

Inside the container, Claude has access to:
- `REPORT_REPO` — the repo URL
- `REPORT_BRANCH` — the branch
- `REPORT_PROJECT_DIR` — the subdirectory to work in
- `REPORT_REPO_TOKEN` — the PAT for authenticating git pushes

Claude pushes directly via `git` using these env vars. Network access to `github.com` is whitelisted when `REPORT_REPO_TOKEN` is configured.
