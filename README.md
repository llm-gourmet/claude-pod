# claude-pod

Run Claude Code inside a Docker sandbox where no secret can leave without your permission

---

## Quickstart

**Prerequisites:** Docker Engine 24+, Docker Compose v2, `curl`, `jq`, `uuidgen` — Linux or WSL2.

**1. Install**

```bash
git clone <repo-url>
cd claude-pod
sudo bash install.sh
```

**2. Get an OAuth token** (first time only)

```bash
# on a machine where you already installed claude
claude setup-token
```

> Using an API key instead? See [Installation](#installation) for the `ANTHROPIC_API_KEY` option.

**3. Create a profile**

```bash
# creates a new profile. Each profile requires the its own Anthropic-Auth via Oauth / Api Key

claude-pod profile create myapp

# creates
# ~/.claude-pod/profiles/myapp/.env
# ~/.claude-pod/profiles/myapp/profile.json
# ~/.claude-pod/profiles/myapp/system_prompts/
```

**4. Add a secret**

```bash
# Key Features of this package are used in this command
claude-pod profile myapp secret add GITHUB_TOKEN gh_xyxyxyxyxyx --redacted REDACTED_GITHUB_TOKEN --domains "github.com","api.github.com","raw.githubusercontent.com"

# You set GITHUB_TOKEN with its real value and provide the redacted name REDACTED_GITHUB_TOKEN which will be sent to anthropic in case claude tries to send your secret to the API
# the 3 domains are whitelisted and allow to have sent Payload ( and auth )
# Only the domains from ~/.claude-pod/profiles/<name>/profile.json are whitelisted and allowed to receive payload

```

**5. Start a session**

```bash
claude-pod start myapp
```

Claude Code is now running inside the Docker sandbox — no secret can leave without passing through the security layers.

**6. Edit the system prompt**

`profile create` scaffolds a system prompt stub that drives Claude's behavior on every session and spawn:

```bash
# System prompt (optional) — Claude's persona and constraints.
nano ~/.claude-pod/profiles/myapp/system_prompts/default.md
```

For event-driven spawns you can add per-event overrides (`push.md`, `issues-opened.md`, …). The full webhook event JSON is always appended to the human-turn prompt automatically — Claude receives the raw payload without needing to call any API.

**7. Set up a GitHub webhook**

If you installed without `--with-webhook`, reinstall first:

```bash
sudo bash install.sh --with-webhook
```

Then register the connection and verify the listener:

```bash
# Link the GitHub repo to the myapp profile
claude-pod gh-webhook-listener --add-connection \
  --name myapp --repo org/myapp --webhook-secret mysecretvalue

# Should show: Systemd: active, Health: ok
claude-pod gh-webhook-listener status
```

Register the webhook on GitHub: **Settings → Webhooks → Add webhook**

| Field | Value |
|---|---|
| Payload URL | `https://<your-host>:9000/webhook` |
| Content type | `application/json` |
| Secret | `mysecretvalue` |

GitHub sends a ping on creation — the listener responds HTTP 200.

**8. (Optional) Bootstrap documentation**

Scaffold a standard documentation structure into a remote git repo — runs on the host, no Docker or Claude involved:

```bash
# Register the target repo once
claude-pod bootstrap-docs --add-connection --name work-docs \
  --repo https://github.com/you/vault.git --token ghp_...

# Scaffold a new project inside it
claude-pod bootstrap-docs --connection work-docs projects/myapp
```

Creates `VISION.md`, `GOALS.md`, `AGREEMENTS.md`, `TODOS.md`, `TASKS.md`, `decisions/`, `ideas/`, `done/` under `projects/myapp/`.

**9. Test the webhook**

Before relying on real GitHub events, verify the full pipeline locally:

```bash
# Dry run — preview which system-prompt file resolves and show rendered content
claude-pod spawn myapp \
  --event '{"action":"opened","repository":{"full_name":"org/myapp"}}' \
  --dry-run

# Live test — spawn Claude with a synthetic event
claude-pod spawn myapp \
  --event '{"action":"opened","repository":{"full_name":"org/myapp"}}'

# Follow the output in real time
claude-pod logs myapp
```

Use GitHub's **Redeliver** button (Settings → Webhooks → Recent Deliveries) to replay a real event once everything is wired up.

**Next steps:** [Profiles](#profiles) — credentials & secrets · [Webhooks](#webhooks) — full webhook reference · [Docs Bootstrap](#docs-bootstrap) — documentation scaffolding · [CLI](#cli) — full command reference.

---

## Installation

**Prerequisites:** Docker Engine 24+, Docker Compose v2, `curl`, `jq`, `uuidgen`

Supported platforms: Linux (native), WSL2

```bash
git clone <repo-url>
cd claude-pod
sudo ./install.sh

# With webhook listener + container reaper (optional)
sudo ./install.sh --with-webhook
```

The installer builds Docker images, installs `claude-pod` to `/usr/local/bin`, copies the project tree to `~/.claude-pod/app/`, and writes a default profile at `~/.claude-pod/profiles/default/`.

**Non-interactive install** — export the auth variable before running:

```bash
# OAuth token (recommended)
sudo -E CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" ./install.sh

# API key
sudo -E ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" ./install.sh

# API key with a custom base URL (corporate gateway)
sudo -E ANTHROPIC_API_KEY="$KEY" REAL_ANTHROPIC_BASE_URL="https://yourcompany.com/v1" ./install.sh
```

---

## Uninstallation

```bash
# Preview what would be removed (no changes made)
claude-pod uninstall --dry-run

# Full uninstall — removes binary, systemd services, /opt/claude-pod/, shared templates
# Prompts before deleting ~/.claude-pod/ (contains your API keys and profiles)
claude-pod uninstall

# Keep user data, remove everything else
claude-pod uninstall --keep-data

# Also remove Docker images built by the installer
claude-pod uninstall --remove-images
```

The uninstaller is idempotent — if something is already absent it warns and continues. Exit code is always 0.

---

## CLI

```bash
# Profile setup
claude-pod profile create <name>   # Create a profile interactively, then exit
claude-pod profile <name>          # Show profile info (workspace, secrets, status)

# Profile config
claude-pod profile <name> secret list
claude-pod profile <name> secret add <KEY> [<value>] [--redacted <TOKEN>] [--domains d1,d2,...]
claude-pod profile <name> secret remove <KEY>

# System prompt: edit files under the profile directory (see "System prompts")
#   ~/.claude-pod/profiles/<name>/system_prompts/default.md (system prompt, optional)

# Session
claude-pod start <name>            # Start an interactive Claude Code session
claude-pod                         # Superuser mode (all profiles merged)

# Headless and replay
claude-pod spawn <name> --event '<json>'
claude-pod spawn <name> --event-file <path>
claude-pod replay <name> <delivery-id>

# Management
claude-pod status [name]           # Container status (all if no name given)
claude-pod stop [name]             # Stop containers (all if no name given)
claude-pod remove <name>           # Stop containers and delete profile config
claude-pod logs <name>             # Tail all log files [hook|anthropic|iptables|clear]
claude-pod list                    # List profiles and running state

# System
claude-pod update                  # Pull latest source, rebuild, update CLI
claude-pod upgrade                 # Rebuild Claude image with latest Claude Code
claude-pod reap                    # Clean up orphaned containers and stale events
claude-pod uninstall               # Remove claude-pod completely
claude-pod uninstall --dry-run     # Preview what would be removed
claude-pod uninstall --keep-data   # Remove binaries/services, preserve ~/.claude-pod/
claude-pod uninstall --remove-images  # Also remove Docker images
claude-pod help                    # Show all commands

# Webhook listener
claude-pod gh-webhook-listener status
claude-pod gh-webhook-listener --add-connection --name <n> --repo owner/repo --webhook-secret <s> [--profile <p>]
claude-pod gh-webhook-listener --remove-connection <name>
claude-pod gh-webhook-listener --list-connections
claude-pod gh-webhook-listener --set-profile <profile> --name <name>
claude-pod gh-webhook-listener --set-bind <addr>
claude-pod gh-webhook-listener --set-port <port>

# Skip filters (loop prevention)
claude-pod gh-webhook-listener filter add "<value>" --name <connection>
claude-pod gh-webhook-listener filter list --name <connection>
claude-pod gh-webhook-listener filter remove "<value>" --name <connection>

# Docs bootstrap
claude-pod bootstrap-docs --add-connection --name <n> --repo <url> --token <pat>
claude-pod bootstrap-docs --list-connections
claude-pod bootstrap-docs --remove-connection <name>
claude-pod bootstrap-docs --connection <name> <path>
```

**Log flags** — append to any command:

```bash
claude-pod start myapp log:hook        # Hook script decisions
claude-pod start myapp log:anthropic   # Proxy metadata
claude-pod start myapp log:bodies      # Proxy full request/response bodies
claude-pod start myapp log:iptables    # Validator/iptables events
claude-pod start myapp log:all         # Everything (metadata, no bodies)
```

---

## Profiles

A profile is a named workspace with its own credentials, secrets, and allowed domains.

### Creating a profile

```bash
claude-pod profile create myapp
```

Interactive setup prompts:

1. **Workspace path** — absolute path where the project is mounted inside the container. Default: `~/claude-workspace-<name>`. Created if it doesn't exist.
2. **Copy credentials** — if another profile with a `.env` already exists, you are offered to copy its auth credentials.
3. **Auth method**:
   - `1` (default) — OAuth token. Run `claude setup-token` first.
   - `2` — API key. Optionally enter a custom base URL; leave blank for `https://api.anthropic.com`.

The command writes `profile.json` and `.env`, then exits without starting any containers.

Profile names must be lowercase alphanumeric and hyphens, max 63 characters.

### Profile directory layout

```
~/.claude-pod/profiles/<name>/
  profile.json            # workspace path, secrets[], optional repo
  .env                    # auth token/key and raw secret values (mode 600)
  system_prompts/
    default.md            # system prompt passed as --system-prompt (optional)
    <event_type>.md       # optional per-event override
```

`system_prompts/default.md` is scaffolded automatically by `profile create`.

### `profile.json` schema

```json
{
  "workspace": "/path/to/project",
  "repo": "owner/repo",
  "secrets": [
    {
      "env_var": "GITHUB_TOKEN",
      "redacted": "REDACTED_GITHUB",
      "domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    }
  ]
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `workspace` | yes | Absolute path mounted as the project workspace |
| `repo` | no | `owner/repo` — used by `spawn` to resolve this profile from an incoming webhook event |
| `secrets[].env_var` | yes | Env variable name (must also appear in `.env`) |
| `secrets[].redacted` | no | Opaque token substituted in LLM context instead of the real value |
| `secrets[].domains` | no | Outbound domains the hook allows when this secret is in use |

The system prompt is no longer stored in `profile.json`. Existing installations are migrated automatically by `claude-pod update` (`system_prompt` → `system_prompts/default.md`).

`profile.json` is re-read on every request — no restart needed after edits.

### `.env` file

Holds the auth credential and any additional secrets:

```bash
# ~/.claude-pod/profiles/<name>/.env
CLAUDE_CODE_OAUTH_TOKEN=your-oauth-token   # or ANTHROPIC_API_KEY=...
# REAL_ANTHROPIC_BASE_URL=https://yourcompany.com/v1  # optional

GITHUB_TOKEN=ghp_xxx    # each secret must also have an entry in profile.json secrets[]
```

Edit `.env` directly to add or rotate secrets. A container restart (`stop` + `start`) is required if you change the auth credential.

### Managing secrets

```bash
# List secrets
claude-pod profile myapp secret list

# Add or update a secret (value prompted silently if omitted — recommended)
claude-pod profile myapp secret add GITHUB_TOKEN
claude-pod profile myapp secret add GITHUB_TOKEN --redacted REDACTED_GITHUB --domains github.com,api.github.com

# Remove a secret
claude-pod profile myapp secret remove GITHUB_TOKEN
```

- `--redacted` defaults to `REDACTED_<KEY>` if omitted.
- `--domains` is a comma-separated list with no spaces.
- `secret add` writes the raw value to `.env` (mode 600) and upserts the metadata in `profile.json secrets[]`.
- Redaction changes take effect immediately (no restart). A container restart is required for the new env var to be visible inside Claude.

### System prompts

The system prompt drives Claude's persona, role, and constraints. It is optional: if no file is found, `--system-prompt` is omitted and Claude runs with no injected persona.

```
~/.claude-pod/profiles/<name>/
  system_prompts/
    default.md            # optional — passed as --system-prompt
    <event_type>.md       # optional — takes precedence for spawn events
```

Resolution chain used by `start` and `spawn`:

- **System prompt** — `system_prompts/<event_type>.md` → `system_prompts/default.md`. If neither exists, `--system-prompt` is omitted.

**Spawn human-turn prompt** — `spawn` always passes the following hardcoded text as the human-turn `-p` argument:

> Review the event payload and follow the instructions in the system prompt.

The full webhook event JSON is **always appended** to the human-turn prompt as a fenced code block — Claude receives the raw payload directly without needing to call any API. Claude can also run `git show`, `git log`, etc. for additional context.

**Interactive sessions** — `start` opens a Claude Code session without any `-p` argument; the user interacts directly.

Edit `system_prompts/` files directly — changes take effect on the next `start` or `spawn`, no restart needed. Use `claude-pod spawn <name> --event '<json>' --dry-run` to preview the resolved system prompt and rendered content.

---

## Webhooks

A single webhook listener handles all repos. GitHub webhooks from every repo hit one port; the listener routes each event by matching `repository.full_name` against entries in `connections.json`. Each connection has its own `webhook_secret`; HMAC is verified per-connection before dispatch.

### Connections

Connections are stored in `~/.claude-pod/webhooks/connections.json` (mode 600).

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique connection identifier |
| `repo` | yes | `owner/repo` — matched against incoming `repository.full_name` |
| `webhook_secret` | yes | HMAC-SHA256 secret configured in GitHub |
| `profile` | no | Profile name to spawn — defaults to `name` if omitted |

```bash
# Add a connection (profile defaults to name)
claude-pod gh-webhook-listener --add-connection \
  --name myrepo --repo org/myrepo --webhook-secret <secret>

# Add a connection with a different profile name
claude-pod gh-webhook-listener --add-connection \
  --name myrepo --repo org/myrepo --webhook-secret <secret> --profile myrepo-docs

# Change the profile for an existing connection
claude-pod gh-webhook-listener --set-profile myrepo-docs --name myrepo

# List connections (secret redacted; profile shown when it differs from name)
claude-pod gh-webhook-listener --list-connections

# Remove a connection
claude-pod gh-webhook-listener --remove-connection myrepo
```

### Status

```bash
claude-pod gh-webhook-listener status
```

```
Webhook Listener Status
  Bind:     127.0.0.1:9000
  Systemd:  active
  Health:   ok
```

### Configuration

```bash
claude-pod gh-webhook-listener --set-bind <addr>   # default: 127.0.0.1
claude-pod gh-webhook-listener --set-port <port>   # default: 9000
```

Settings persisted to `~/.claude-pod/webhooks/webhook.json`.

### Adding a repo

1. Add a connection:
   ```bash
   claude-pod gh-webhook-listener --add-connection \
     --name myrepo --repo org/myrepo --webhook-secret <secret>
   ```
2. Register a GitHub webhook on the repo:
   - **URL:** `https://<host>:9000/webhook`
   - **Secret:** same value as `--webhook-secret`
   - **Content type:** `application/json`

No new listener, no new port — the existing systemd service routes by `repo` field.

### Loop prevention / skip filters

When claude-pod acts on a GitHub event (pushes, comments, labels), it can trigger new webhook deliveries and re-spawn itself. Skip filters prevent this by matching events before the spawn decision.

**Add a filter** (applies to all applicable event types automatically):

```bash
claude-pod gh-webhook-listener filter add "[skip-claude]" --name myrepo
```

Output shows which mechanisms the filter applies to:

```
Filter "[skip-claude]" added to connection "myrepo":
  push events          → commit message prefix
  pr/issues/discussion → label match
  comments/reviews     → body prefix
  workflow/check/etc   → not applicable (no free-text field)
```

**How matching works:**

| Event type | Filter applied as |
|---|---|
| `push` | Prefix of every commit message — skips only if **ALL** commits match |
| `pull_request`, `issues`, `discussion` | Label name exact match |
| `issue_comment`, `pull_request_review`, `pull_request_review_comment` | Prefix of comment/review body |
| `workflow_run`, `check_run`, `create`, `delete`, etc. | Not applicable — always spawns |

**List and remove:**

```bash
claude-pod gh-webhook-listener filter list --name myrepo
claude-pod gh-webhook-listener filter remove "[skip-claude]" --name myrepo
```

Skipped events return HTTP 200 and a `skipped` entry is written to `webhook.jsonl`. Multiple filter values can be active on a connection simultaneously.

### Docs-oriented profiles

Profiles for documentation tools (e.g. an Obsidian vault) can live under `~/.claude-pod/docs/<name>/` instead of `~/.claude-pod/profiles/<name>/`. The structure is identical. The listener and CLI probe both directories; `profiles/` takes priority on name collision.

---

## Ubuntu: Exposing the Webhook Listener

The listener binds to `127.0.0.1:9000` by default — local only. GitHub must POST to a public HTTPS URL. Three options:

### Option A — nginx reverse proxy (recommended)

```bash
sudo apt install nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/claude-webhook`:

```nginx
server {
    server_name webhook.example.com;

    location /webhook {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Enable and issue a certificate:

```bash
sudo ln -s /etc/nginx/sites-available/claude-webhook /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d webhook.example.com
```

GitHub webhook URL: `https://webhook.example.com/webhook`

The listener stays on `127.0.0.1` — never exposed directly to the internet.

### Option B — direct port (simpler, no TLS)

```bash
# Change bind address
claude-pod gh-webhook-listener --set-bind 0.0.0.0

# Open the firewall
sudo ufw allow 9000/tcp
sudo ufw reload
```

GitHub webhook URL: `http://<server-ip>:9000/webhook`

GitHub requires HTTPS for production webhooks. HTTP works only with **Disable SSL verification** enabled on the webhook settings page — not recommended outside of LAN setups.

### Option C — ngrok (local development)

```bash
ngrok http 9000
```

ngrok prints a temporary public HTTPS URL (e.g. `https://abc123.ngrok.io`).

GitHub webhook URL: `https://abc123.ngrok.io/webhook`

The URL changes on every restart. Use a paid ngrok plan for a stable domain, or switch to Option A for a permanent setup.

---

## Docs Bootstrap

Scaffold a standard project documentation structure into a remote git repo — no Docker, no Claude, runs directly on the host.

```bash
# Register a named connection
claude-pod bootstrap-docs --add-connection --name work-docs \
  --repo https://github.com/you/vault.git --token ghp_... [--branch main]

# Manage connections
claude-pod bootstrap-docs --list-connections
claude-pod bootstrap-docs --remove-connection work-docs

# Scaffold a new project
claude-pod bootstrap-docs --connection work-docs projects/myproject
```

Creates under `<path>/`:
```
VISION.md   GOALS.md   AGREEMENTS.md
TODOS.md    TASKS.md
decisions/  ideas/     done/
```

Template files are read from `~/.claude-pod/docs-templates/` — populate this directory with your own files before running `bootstrap-docs`. Connections stored in `~/.claude-pod/docs-bootstrap/connections.json` (mode 600) — tokens never touch Claude or Docker.

---

## Auth Variables

| Variable | Set in | Purpose |
|----------|--------|---------|
| `ANTHROPIC_API_KEY` | profile `.env` | API key sent upstream by the proxy |
| `CLAUDE_CODE_OAUTH_TOKEN` | profile `.env` | OAuth token (preferred over API key) |
| `REAL_ANTHROPIC_BASE_URL` | profile `.env` | Proxy upstream — defaults to `https://api.anthropic.com` |
| `ANTHROPIC_BASE_URL` | docker-compose (internal) | Always `http://proxy:8080` — do **not** put this in `.env` |

`ANTHROPIC_BASE_URL` inside the Claude container always points at the proxy (hardcoded in docker-compose). The proxy uses `REAL_ANTHROPIC_BASE_URL` to reach the actual Anthropic endpoint.

Auth variables are loaded exclusively from the profile `.env` via Docker Compose `env_file`. They are not listed in the `environment` block.

Example `.env`:

```bash
ANTHROPIC_API_KEY=sk-your-api-key
REAL_ANTHROPIC_BASE_URL=https://yourcompany.com/anthropic/v1   # optional

GITHUB_TOKEN=ghp_xxx
```

---

## Host File Locations

| Path | Owner | Purpose |
|------|-------|---------|
| `~/.claude-pod/profiles/<name>/` | user | Per-profile secrets (`.env`) and config (`profile.json`) |
| `~/.claude-pod/docs/<name>/` | user | Docs-oriented profiles; same structure as `profiles/` |
| `~/.claude-pod/app/` | user | Copy of the project tree (updated by `claude-pod update`) |
| `~/.claude-pod/logs/` | user | Structured logs written by services |
| `~/.claude-pod/webhooks/webhook.json` | user (600) | Webhook listener runtime config |
| `~/.claude-pod/webhooks/connections.json` | user (600) | Webhook connections |
| `~/.claude-pod/docs-bootstrap/connections.json` | user (600) | Docs-bootstrap connections |
| `/etc/systemd/system/claude-pod-webhook.service` | root | Systemd unit for the webhook listener |
| `/opt/claude-pod/` | root | Installed app files: `webhook/listener.py`, templates, reaper script |
| `/usr/local/bin/claude-pod` | root | CLI wrapper |

---

## Architecture

See [docs/architecture.md](docs/architecture.md) for Mermaid diagrams covering the container topology and the full call chain from tool invocation through secret redaction and iptables enforcement.

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

### Network isolation

The `claude-internal` Docker network has `internal: true` — no external access by default. The proxy is the only container on both networks and is the single exit point to `api.anthropic.com`.

### Secret redaction (proxy)

Every request to Anthropic is buffered in full, scanned against `profile.json`, and secret values replaced with opaque redacted tokens before forwarding. Responses are scanned in reverse — redacted tokens restored to real values for Claude to use, but real values never appear in LLM context sent upstream.

The `secrets[]` array in `profile.json` drives both redaction and domain enforcement:

```json
{
  "secrets": [
    {
      "env_var": "GITHUB_TOKEN",
      "redacted": "REDACTED_GITHUB",
      "domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    }
  ]
}
```

`profile.json` is re-read on every request — no restart needed after edits.

### PreToolUse hook

Every `Bash`, `WebFetch`, and `WebSearch` tool call passes through a hook script at `/etc/claude-pod/hooks/pre-tool-use.sh` inside the Claude container (root-owned, not writable by the Claude process).

The hook:
1. Extracts the target domain from the tool call payload
2. Checks the domain against `secrets[].domains[]` in `profile.json`
3. On allow: generates a UUID call-ID, registers it with the validator, returns allow
4. On block: returns block with a reason — Claude sees the rejection and cannot retry

### Network enforcement (validator + iptables)

The validator shares the Claude container's network namespace (`network_mode: service:claude`). When the hook registers a call-ID, the validator adds a time-limited iptables rule permitting that specific outbound connection. Any connection attempt without a registered call-ID is rejected at the packet level — even if the hook is somehow bypassed.
