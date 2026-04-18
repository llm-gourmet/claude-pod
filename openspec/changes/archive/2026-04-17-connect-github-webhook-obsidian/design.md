## Context

claude-secure's webhook listener (`listener.py`) already receives GitHub push events, resolves a profile by `repository.full_name`, and calls `claude-secure spawn --profile <name> --event-file <path>`. The spawn command reads the event JSON and renders a prompt template via `render_template` in `bin/claude-secure`. The template engine substitutes named tokens (`{{COMMIT_SHA}}`, `{{BRANCH}}`, etc.) extracted from the event JSON.

Currently, the GitHub push payload's `commits[]` array — which contains per-commit `added`, `modified`, and `removed` file lists — is not exposed to templates. Templates can only reference the HEAD commit SHA. To detect TODO file changes across all commits in a push, templates need access to the full `commits[]` array.

No profile exists for `llm-gourmet/obsidian`. The webhook listener routes by `repo` field in `profile.json`; without a matching profile, all obsidian pushes are rejected with 404.

The webhook listener binds to `127.0.0.1:9000` and is unreachable from GitHub. A reverse proxy is required.

## Goals / Non-Goals

**Goals:**
- Expose `commits[]` from push payloads as `{{COMMITS_JSON}}` in all prompt templates
- Create `obsidian` profile that routes `llm-gourmet/obsidian` push events to Claude
- Custom prompt template that determines TODO changes from event JSON alone (no git, no network)
- Caddy reverse proxy making port 9000 reachable by GitHub

**Non-Goals:**
- Actual TODO content parsing or diff inspection (Phase 2)
- Writing results back to GitHub (comments, commits) — Phase 2
- Loop prevention for report pushes — not applicable in Phase 1 (no report_repo configured)
- Modifying the webhook listener or validator

## Decisions

**D-01: Add `{{COMMITS_JSON}}` to `render_template` (not to listener)**

The token is extracted in `render_template` inside `bin/claude-secure` — the same function that handles all other push tokens. This keeps event-JSON parsing centralised and means all profiles automatically gain access to the token with no listener changes.

Alternative: pass the commits array as an extra CLI arg in `spawn`. Rejected — spawn already passes the full event JSON; re-parsing in a new code path duplicates logic.

**D-02: Profile-specific prompt template (not default override)**

The TODO-scanner prompt lives at `~/.claude-secure/profiles/obsidian/prompts/push.md`. The `resolve_template` fallback chain checks profile-specific templates before global defaults, so `jad` and other profiles are unaffected.

Alternative: overwrite `webhook/templates/push.md` in the repo. Rejected — breaks all other profiles.

**D-03: Phase 1 uses event-JSON-only (no git access)**

The commits array in the GitHub push payload already contains `added` and `modified` file lists per commit. Claude can identify `projects/*/todo.md` changes purely from this data without git fetch or GitHub API calls. This eliminates workspace setup, whitelist changes, and network access concerns for Phase 1.

**D-04: Caddy for reverse proxy**

Caddy provides automatic HTTPS via Let's Encrypt with a one-block Caddyfile config, zero certificate management overhead. If no domain is available for Phase 1 testing, HTTP on port 80 is acceptable (GitHub supports HTTP webhooks; HMAC provides integrity).

Alternative: Nginx. Rejected — requires manual TLS certificate management (certbot cron etc.) and more verbose config for a single-route proxy.

**D-05: No `report_repo` in Phase 1**

Spawn output (Claude's stdout) is captured in `~/.claude-secure/logs/spawns/<delivery_id>.log`. The user verifies the scan result by tailing this file. Configuring `report_repo` pointing back to the obsidian repo would create a push-loop (report push re-triggers the webhook) and requires loop-prevention config — unnecessary overhead for Phase 1.

## Risks / Trade-offs

- **`{{COMMITS_JSON}}` token size**: A force-push with many commits could produce a large JSON blob in the prompt. Mitigation: Claude's context window is large enough for typical push events; if needed, Phase 2 can limit to `commits[-1]` (HEAD only).
- **Pattern matching in prompt**: Claude must correctly pattern-match `projects/*/todo.md`. Mitigation: the prompt uses an explicit glob pattern with examples; Phase 1 testing will validate.
- **HTTP-only webhook (no domain)**: Payload is unencrypted in transit. Mitigation: HMAC-SHA256 secret still authenticates the sender. Acceptable for Phase 1; upgrade to HTTPS when domain is available.
- **`.env` shared with jad**: Both profiles use the same OAuth token. Mitigation: token is scoped to Claude Code; no extra risk vs. current setup.

## Migration Plan

1. Edit `bin/claude-secure` — add `{{COMMITS_JSON}}` token (one code block, backward-compatible; existing templates that don't use the token are unaffected)
2. Create `profiles/obsidian/` directory with `profile.json`, `.env`, `prompts/push.md`
3. Restart `claude-secure-webhook` systemd service (picks up new profile on next request — no downtime)
4. Install Caddy, write Caddyfile, enable service
5. Configure GitHub webhook (URL + secret + push event)
6. Verify: push a test commit touching `projects/test/todo.md` and check spawn log

Rollback: remove `profiles/obsidian/` → listener returns 404 for all obsidian events. No other profiles affected.

## Open Questions

- Does the VPS have a domain name? (determines Caddy HTTP vs HTTPS config)
- Should `.env` be a symlink to `profiles/jad/.env` or a copy? (copy is safer for independent rotation)
