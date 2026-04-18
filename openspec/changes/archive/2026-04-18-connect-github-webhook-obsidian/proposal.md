## Why

The `llm-gourmet/obsidian` repo contains project TODO files at `projects/*/todo.md`. When changes land on master, there is no automated way to detect new or updated TODOs — developers must check manually. This change wires a GitHub webhook into the existing claude-secure infrastructure so that every push to master automatically triggers a Claude session that scans the commit for TODO changes.

## What Changes

- Add `{{COMMITS_JSON}}` template token to `render_template` in `bin/claude-secure`, exposing the full `commits[]` array (added/modified/removed per commit) to prompt templates
- Create a new claude-secure profile `obsidian` mapped to `llm-gourmet/obsidian` with push event filter (master/main only)
- Create a profile-specific prompt template `prompts/push.md` that scans `{{COMMITS_JSON}}` for `projects/*/todo.md` paths and outputs a one-line result
- Install and configure Caddy as a reverse proxy exposing `localhost:9000` (webhook listener) publicly on port 80/443
- Configure a GitHub webhook in `llm-gourmet/obsidian` pointing to the Caddy endpoint with HMAC secret

## Capabilities

### New Capabilities

- `obsidian-todo-scanner`: Detect new/modified `projects/*/todo.md` files on push to master and emit a structured scan result. Phase 1: event-JSON-only (no git access, no file reads).
- `commits-json-token`: Expose `commits[]` array from GitHub push payloads as `{{COMMITS_JSON}}` in all prompt templates, enabling templates to inspect per-commit file lists without git access.

### Modified Capabilities

<!-- No existing spec-level requirements are changing. -->

## Impact

- `bin/claude-secure` — `render_template` function gains one new token extraction block (~5 lines of bash)
- New files under `~/.claude-secure/profiles/obsidian/` (profile.json, .env, prompts/push.md) — no changes to shared infrastructure
- Caddy installed on VPS host — new system dependency, but isolated to the transport layer
- Webhook listener (`/etc/claude-secure/webhook.json`, systemd service) — no code changes; only a new profile entry is added
