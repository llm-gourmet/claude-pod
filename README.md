# claude-secure

Run Claude Code inside a Docker sandbox where no secret can leave without your permission.

---

## Installation

**Prerequisites:** Docker Engine 24+, Docker Compose v2, `curl`, `jq`, `uuidgen`

Supported platforms: Linux (native), WSL2

```bash
git clone <repo-url>
cd claude-secure
sudo ./install.sh

# With webhook listener + container reaper (optional)
sudo ./install.sh --with-webhook
```

The installer builds Docker images, installs `claude-secure` to `/usr/local/bin`, copies the project tree to `~/.claude-secure/app/`, and writes a default profile at `~/.claude-secure/profiles/default/`.

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

## CLI

```bash
# Profile setup
claude-secure profile create <name>   # Create a profile interactively, then exit
claude-secure profile <name>          # Show profile info (workspace, secrets, status)

# Profile config
claude-secure profile <name> secret list
claude-secure profile <name> secret add <KEY> [<value>] [--redacted <TOKEN>] [--domains d1,d2,...]
claude-secure profile <name> secret remove <KEY>

# Task + system prompt: edit files under the profile directory (see "Tasks and system prompts")
#   ~/.claude-secure/profiles/<name>/tasks/default.md          (task prompt, required)
#   ~/.claude-secure/profiles/<name>/system_prompts/default.md (system prompt, optional)

# Session
claude-secure start <name>            # Start an interactive Claude Code session
claude-secure                         # Superuser mode (all profiles merged)

# Headless and replay
claude-secure spawn <name> --event '<json>'
claude-secure spawn <name> --event-file <path>
claude-secure replay <name> <delivery-id>

# Management
claude-secure status [name]           # Container status (all if no name given)
claude-secure stop [name]             # Stop containers (all if no name given)
claude-secure remove <name>           # Stop containers and delete profile config
claude-secure logs <name>             # Tail all log files [hook|anthropic|iptables|clear]
claude-secure list                    # List profiles and running state

# System
claude-secure update                  # Pull latest source, rebuild, update CLI
claude-secure upgrade                 # Rebuild Claude image with latest Claude Code
claude-secure reap                    # Clean up orphaned containers and stale events
claude-secure help                    # Show all commands

# Webhook listener
claude-secure gh-webhook-listener status
claude-secure gh-webhook-listener --add-connection --name <n> --repo owner/repo --webhook-secret <s> [--profile <p>]
claude-secure gh-webhook-listener --remove-connection <name>
claude-secure gh-webhook-listener --list-connections
claude-secure gh-webhook-listener --set-profile <profile> --name <name>
claude-secure gh-webhook-listener --set-bind <addr>
claude-secure gh-webhook-listener --set-port <port>

# Docs bootstrap
claude-secure bootstrap-docs --add-connection --name <n> --repo <url> --token <pat>
claude-secure bootstrap-docs --list-connections
claude-secure bootstrap-docs --remove-connection <name>
claude-secure bootstrap-docs --connection <name> <path>
```

**Log flags** — append to any command:

```bash
claude-secure start myapp log:hook        # Hook script decisions
claude-secure start myapp log:anthropic   # Proxy metadata
claude-secure start myapp log:bodies      # Proxy full request/response bodies
claude-secure start myapp log:iptables    # Validator/iptables events
claude-secure start myapp log:all         # Everything (metadata, no bodies)
```

---

## Profiles

A profile is a named workspace with its own credentials, secrets, and allowed domains.

### Creating a profile

```bash
claude-secure profile create myapp
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
~/.claude-secure/profiles/<name>/
  profile.json            # workspace path, secrets[], optional repo
  .env                    # auth token/key and raw secret values (mode 600)
  tasks/
    default.md            # task prompt passed to Claude as -p (required)
    <event_type>.md       # optional per-event override (e.g. push.md, issues-opened.md)
  system_prompts/
    default.md            # system prompt passed as --system-prompt (optional)
    <event_type>.md       # optional per-event override
```

`tasks/default.md` and `system_prompts/default.md` are scaffolded automatically by `profile create`.

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

The system prompt is no longer stored in `profile.json`. Existing installations are migrated automatically by `claude-secure update` (`system_prompt` → `system_prompts/default.md`).

`profile.json` is re-read on every request — no restart needed after edits.

### `.env` file

Holds the auth credential and any additional secrets:

```bash
# ~/.claude-secure/profiles/<name>/.env
CLAUDE_CODE_OAUTH_TOKEN=your-oauth-token   # or ANTHROPIC_API_KEY=...
# REAL_ANTHROPIC_BASE_URL=https://yourcompany.com/v1  # optional

GITHUB_TOKEN=ghp_xxx    # each secret must also have an entry in profile.json secrets[]
```

Edit `.env` directly to add or rotate secrets. A container restart (`stop` + `start`) is required if you change the auth credential.

### Managing secrets

```bash
# List secrets
claude-secure profile myapp secret list

# Add or update a secret (value prompted silently if omitted — recommended)
claude-secure profile myapp secret add GITHUB_TOKEN
claude-secure profile myapp secret add GITHUB_TOKEN --redacted REDACTED_GITHUB --domains github.com,api.github.com

# Remove a secret
claude-secure profile myapp secret remove GITHUB_TOKEN
```

- `--redacted` defaults to `REDACTED_<KEY>` if omitted.
- `--domains` is a comma-separated list with no spaces.
- `secret add` writes the raw value to `.env` (mode 600) and upserts the metadata in `profile.json secrets[]`.
- Redaction changes take effect immediately (no restart). A container restart is required for the new env var to be visible inside Claude.

### Tasks and system prompts

Per-profile markdown files under the profile directory drive what Claude does and how it behaves:

```
~/.claude-secure/profiles/<name>/
  tasks/
    default.md            # required — passed as -p to Claude
    <event_type>.md       # optional — takes precedence for spawn events
  system_prompts/
    default.md            # optional — passed as --system-prompt
    <event_type>.md       # optional — takes precedence for spawn events
```

Resolution chain used by `start` and `spawn`:

- **Task prompt** — `tasks/<event_type>.md` → `tasks/default.md`. If neither exists, spawn fails with the checked paths printed.
- **System prompt** — `system_prompts/<event_type>.md` → `system_prompts/default.md`. If neither exists, `--system-prompt` is omitted.

Files are passed to Claude as-is (no token substitution). The event JSON is available to the spawn; Claude can run `git show`, `git log`, etc. to gather context.

Edit the files directly — changes take effect on the next `start` or `spawn`, no restart needed. Use `claude-secure spawn <name> --event '<json>' --dry-run` to verify which files resolve and preview the rendered content.

---

## Webhooks

A single webhook listener handles all repos. GitHub webhooks from every repo hit one port; the listener routes each event by matching `repository.full_name` against entries in `connections.json`. Each connection has its own `webhook_secret`; HMAC is verified per-connection before dispatch.

### Connections

Connections are stored in `~/.claude-secure/webhooks/connections.json` (mode 600).

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique connection identifier |
| `repo` | yes | `owner/repo` — matched against incoming `repository.full_name` |
| `webhook_secret` | yes | HMAC-SHA256 secret configured in GitHub |
| `profile` | no | Profile name to spawn — defaults to `name` if omitted |

```bash
# Add a connection (profile defaults to name)
claude-secure gh-webhook-listener --add-connection \
  --name myrepo --repo org/myrepo --webhook-secret <secret>

# Add a connection with a different profile name
claude-secure gh-webhook-listener --add-connection \
  --name myrepo --repo org/myrepo --webhook-secret <secret> --profile myrepo-docs

# Change the profile for an existing connection
claude-secure gh-webhook-listener --set-profile myrepo-docs --name myrepo

# List connections (secret redacted; profile shown when it differs from name)
claude-secure gh-webhook-listener --list-connections

# Remove a connection
claude-secure gh-webhook-listener --remove-connection myrepo
```

### Status

```bash
claude-secure gh-webhook-listener status
```

```
Webhook Listener Status
  Bind:     127.0.0.1:9000
  Systemd:  active
  Health:   ok
```

### Configuration

```bash
claude-secure gh-webhook-listener --set-bind <addr>   # default: 127.0.0.1
claude-secure gh-webhook-listener --set-port <port>   # default: 9000
```

Settings persisted to `~/.claude-secure/webhooks/webhook.json`.

### Adding a repo

1. Add a connection:
   ```bash
   claude-secure gh-webhook-listener --add-connection \
     --name myrepo --repo org/myrepo --webhook-secret <secret>
   ```
2. Register a GitHub webhook on the repo:
   - **URL:** `https://<host>:9000/webhook`
   - **Secret:** same value as `--webhook-secret`
   - **Content type:** `application/json`

No new listener, no new port — the existing systemd service routes by `repo` field.

### Loop prevention / skip filters

When claude-secure acts on a GitHub event (pushes, comments, labels), it can trigger new webhook deliveries and re-spawn itself. Skip filters prevent this by matching events before the spawn decision.

**Add a filter** (applies to all applicable event types automatically):

```bash
claude-secure gh-webhook-listener filter add "[skip-claude]" --name myrepo
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
claude-secure gh-webhook-listener filter list --name myrepo
claude-secure gh-webhook-listener filter remove "[skip-claude]" --name myrepo
```

Skipped events return HTTP 200 and a `skipped` entry is written to `webhook.jsonl`. Multiple filter values can be active on a connection simultaneously.

### Docs-oriented profiles

Profiles for documentation tools (e.g. an Obsidian vault) can live under `~/.claude-secure/docs/<name>/` instead of `~/.claude-secure/profiles/<name>/`. The structure is identical. The listener and CLI probe both directories; `profiles/` takes priority on name collision.

---

## Docs Bootstrap

Scaffold a standard project documentation structure into a remote git repo — no Docker, no Claude, runs directly on the host.

```bash
# Register a named connection
claude-secure bootstrap-docs --add-connection --name work-docs \
  --repo https://github.com/you/vault.git --token ghp_... [--branch main]

# Manage connections
claude-secure bootstrap-docs --list-connections
claude-secure bootstrap-docs --remove-connection work-docs

# Scaffold a new project
claude-secure bootstrap-docs --connection work-docs projects/myproject
```

Creates under `<path>/`:
```
VISION.md   GOALS.md   AGREEMENTS.md
TODOS.md    TASKS.md
decisions/  ideas/     done/
```

Each file is seeded from `scripts/templates/`. Connections stored in `~/.claude-secure/docs-bootstrap/connections.json` (mode 600) — tokens never touch Claude or Docker.

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
| `~/.claude-secure/profiles/<name>/` | user | Per-profile secrets (`.env`) and config (`profile.json`) |
| `~/.claude-secure/docs/<name>/` | user | Docs-oriented profiles; same structure as `profiles/` |
| `~/.claude-secure/app/` | user | Copy of the project tree (updated by `claude-secure update`) |
| `~/.claude-secure/logs/` | user | Structured logs written by services |
| `~/.claude-secure/webhooks/webhook.json` | user (600) | Webhook listener runtime config |
| `~/.claude-secure/webhooks/connections.json` | user (600) | Webhook connections |
| `~/.claude-secure/docs-bootstrap/connections.json` | user (600) | Docs-bootstrap connections |
| `/etc/systemd/system/claude-secure-webhook.service` | root | Systemd unit for the webhook listener |
| `/opt/claude-secure/` | root | Installed app files: `webhook/listener.py`, templates, reaper script |
| `/usr/local/bin/claude-secure` | root | CLI wrapper |

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

Every `Bash`, `WebFetch`, and `WebSearch` tool call passes through a hook script at `/etc/claude-secure/hooks/pre-tool-use.sh` inside the Claude container (root-owned, not writable by the Claude process).

The hook:
1. Extracts the target domain from the tool call payload
2. Checks the domain against `secrets[].domains[]` in `profile.json`
3. On allow: generates a UUID call-ID, registers it with the validator, returns allow
4. On block: returns block with a reason — Claude sees the rejection and cannot retry

### Network enforcement (validator + iptables)

The validator shares the Claude container's network namespace (`network_mode: service:claude`). When the hook registers a call-ID, the validator adds a time-limited iptables rule permitting that specific outbound connection. Any connection attempt without a registered call-ID is rejected at the packet level — even if the hook is somehow bypassed.
