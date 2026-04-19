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

**API key with a custom base URL** (corporate gateway or Azure OpenAI-compatible endpoint):

```bash
sudo -E ANTHROPIC_API_KEY="$KEY" REAL_ANTHROPIC_BASE_URL="https://yourcompany.com/anthropic/v1" ./install.sh
```

The interactive installer also prompts for the base URL when you choose auth method 2 (API key).

---

## Host file locations

Everything on the host falls into two trees:

| Path | Owner | Purpose |
|------|-------|---------|
| `~/.claude-secure/profiles/<name>/` | user | Per-profile secrets (`.env`), whitelist, and config (`profile.json`) |
| `~/.claude-secure/docs/<name>/` | user | Docs-oriented profiles (e.g. Obsidian vault configs); same structure as `profiles/` |
| `~/.claude-secure/app/` | user | Copy of the project tree (updated by `claude-secure update`) |
| `~/.claude-secure/logs/` | user | Structured logs written by the listener (`webhook.jsonl`) |
| `~/.claude-secure/webhooks/webhook.json` | user (600) | Webhook listener runtime config: bind address, port, operational settings |
| `~/.claude-secure/profiles/<name>/profile.json` | user | Also holds `github_token` (per-repo GitHub PAT for TODO detection) and `webhook_secret` |
| `/etc/systemd/system/claude-secure-webhook.service` | root | Systemd unit for the webhook listener (runs as installing user via `User=`) |
| `/opt/claude-secure/` | root | Installed app files: `webhook/listener.py`, templates, reaper script |
| `/usr/local/bin/claude-secure` | root | CLI wrapper |

**Warum `~/.claude-secure/webhooks/` und nicht `/etc/`?**

Der systemd-Service läuft als installierender User (`User=<username>` in der Unit), nicht als root — Port 9000 braucht keine Root-Rechte. Damit ist `~/.claude-secure/` direkt zugänglich, kein `sudo` nötig. Der `webhooks/`-Unterordner trennt Listener-Betriebsconfig klar von Profil-Config (Profile sind per-Repo-Workspaces mit eigenen Secrets und Whitelists).

---

## Auth variables

Two variables control where traffic goes:

| Variable | Set in | Purpose |
|----------|--------|---------|
| `ANTHROPIC_API_KEY` | profile `.env` | API key sent upstream by the proxy |
| `CLAUDE_CODE_OAUTH_TOKEN` | profile `.env` | OAuth token (preferred over API key) |
| `REAL_ANTHROPIC_BASE_URL` | profile `.env` | Proxy upstream — defaults to `https://api.anthropic.com` |
| `ANTHROPIC_BASE_URL` | docker-compose (internal) | Always `http://proxy:8080` — do **not** put this in `.env` |

> **Naming note:** `ANTHROPIC_BASE_URL` in the Claude container always points at the proxy (hardcoded). The proxy uses `REAL_ANTHROPIC_BASE_URL` to reach the actual Anthropic endpoint. If you accidentally write `ANTHROPIC_BASE_URL` in your `.env`, claude-secure auto-remaps it to `REAL_ANTHROPIC_BASE_URL` at startup so the proxy gets the correct value.

Auth variables are loaded exclusively from the profile `.env` via Docker Compose `env_file`. They are **not** listed in the `environment` block, so no host-side default can accidentally shadow a real value.

Example `.env` for API key + corporate gateway:

```bash
# ~/.claude-secure/profiles/<name>/.env
ANTHROPIC_API_KEY=sk-your-api-key
REAL_ANTHROPIC_BASE_URL=https://yourcompany.com/anthropic/v1

# project secrets (redacted by proxy before reaching LLM context)
GITHUB_TOKEN=ghp_xxx
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
  .env              # secrets: GITHUB_TOKEN, etc.
  whitelist.json    # per-profile domain whitelist
```

`profile.json` key fields:

| Field | Description |
|-------|-------------|
| `workspace` | Absolute path to the project workspace |
| `repo` | `owner/repo` — used for webhook routing |
| `system_prompt` | System prompt injected via `--system-prompt` for every session (interactive and headless) |
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

claude-secure bootstrap-docs --add-connection --name <n> --repo <url> --token <pat>  # Add connection
claude-secure bootstrap-docs --list-connections                                       # List connections
claude-secure bootstrap-docs --connection <name> <path>                               # Scaffold project docs

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

## Webhook Listener

A single listener process on the VPS handles all repos. There is no second listener — GitHub webhooks from every repo hit port 9000, and the listener routes each event by matching `repository.full_name` in the payload against each profile's `repo` field. Every profile gets its own `webhook_secret`; HMAC is verified per-profile before dispatch.

### Status

```bash
claude-secure webhook-listener status
```

```
Webhook Listener Status
  Bind:     127.0.0.1:9000
  Systemd:  active
  Health:   ok
```

### Configuration

```bash
claude-secure webhook-listener --set-bind <addr>          # Bind address (default: 127.0.0.1)
claude-secure webhook-listener --set-port <port>          # Port (default: 9000)
```

Bind and port are persisted to `~/.claude-secure/webhooks/webhook.json`. Override the path with `$WEBHOOK_CONFIG`.

#### GitHub token (per repo)

The listener uses a GitHub PAT to fetch commit diffs for TODO detection. Each profile stores its own token, so different repos can use different PATs.

```bash
claude-secure webhook-listener --set-token <github-pat> --profile <name>
```

Persisted to `~/.claude-secure/profiles/<name>/profile.json`. If only one profile exists, `--profile` can be omitted. Replace only when rotating the PAT.

#### Template directory

Prompt templates are loaded from `/opt/claude-secure/webhook/templates` by default. Override with:

```bash
export WEBHOOK_TEMPLATES_DIR=/path/to/custom/templates
```

### Docs-oriented profiles

Profiles for documentation tools (e.g. an Obsidian vault) can live under `~/.claude-secure/docs/<name>/` instead of `~/.claude-secure/profiles/<name>/`. The structure is identical — `profile.json`, `.env`, `whitelist.json`, `prompts/`. The listener and CLI probe both directories; `profiles/` takes priority when a name collision occurs.

```bash
# Move an existing profile to docs/
mv ~/.claude-secure/profiles/obsidian ~/.claude-secure/docs/obsidian
```

The `docs_dir` key in `~/.claude-secure/webhooks/webhook.json` points at the docs directory (set by the installer). If absent or empty the listener only scans `profiles_dir` — no change in behaviour for existing installs.

**Migrating from profiles/ to docs/:**
1. Move the profile directory: `mv ~/.claude-secure/profiles/obsidian ~/.claude-secure/docs/obsidian`
2. Restart the listener: `sudo systemctl restart claude-secure-webhook`
3. Verify: `claude-secure webhook-listener status`

### Adding a second repo

Each repo gets its own profile with its own `webhook_secret` and `github_token`. The listener port stays unchanged.

1. Create a profile with `repo` set to the new `owner/repo`:
   ```bash
   claude-secure --profile myproject2
   # enter owner/repo when prompted
   ```
2. Add `webhook_secret` and optionally a repo-specific `github_token` to the profile:
   ```bash
   # ~/.claude-secure/profiles/myproject2/profile.json
   # add: "webhook_secret": "<secret>"
   claude-secure webhook-listener --set-token <pat> --profile myproject2
   ```
3. Register a GitHub webhook on the repo:
   - **URL:** `https://<vps>:9000/`
   - **Secret:** same value as `webhook_secret` above
   - **Content type:** `application/json`

No new listener, no new port — the existing systemd service routes events by matching `repository.full_name` against each profile's `repo` field.

---

## Bootstrap Docs

Scaffold a standard project documentation structure into a remote git repo — no Docker, no Claude involved, runs directly on the host.

```bash
# Register a named connection (repeat for each docs repo)
claude-secure bootstrap-docs --add-connection --name work-docs \
  --repo https://github.com/you/vault.git --token ghp_... [--branch main]

# Manage connections
claude-secure bootstrap-docs --list-connections
claude-secure bootstrap-docs --remove-connection work-docs

# Scaffold a new project (path is relative to repo root)
claude-secure bootstrap-docs --connection work-docs projects/JAD
claude-secure bootstrap-docs --connection work-docs custom/my-project
```

Creates under `<path>/`:
```
VISION.md        GOALS.md        AGREEMENTS.md
TODOS.md         TASKS.md
decisions/       ideas/          done/
```

Each file is seeded from `scripts/templates/`. Connections stored in `~/.claude-secure/docs-bootstrap/connections.json` (mode 600, dir mode 700) — tokens never touch Claude or Docker.

