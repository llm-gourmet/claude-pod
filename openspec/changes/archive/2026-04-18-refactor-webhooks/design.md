## Context

The webhook subsystem currently has three overlapping config layers:

- `~/.claude-secure/webhook-listener.env` — shell env file; written by `--set-bind`, `--set-port`, `--set-token`; read by `_webhook_listener_load_config()` in `bin/claude-secure` for status display only
- `/etc/claude-secure/webhook.json` — JSON config; written only by `--set-token` (with sudo fallback); read by `listener.py` `Config` class for all runtime settings. Root-owned because the systemd service has no `User=` directive and runs as root.
- `~/.claude-secure/profiles/<name>/profile.json` — per-profile config; holds `webhook_secret`, `repo`, event filters; currently does NOT hold `github_token`

The listener uses `github_token` from `webhook.json` to call `api.github.com` for commit diffs (TODO detection). This is a per-repo operation routed through the profile, but the token is global — different repos requiring different GitHub PATs cannot be supported.

## Goals / Non-Goals

**Goals:**
- `~/.claude-secure/webhooks/webhook.json` is the single listener config store (bind, port, operational settings)
- `github_token` lives in `profile.json`, resolved at request time per repo
- systemd service runs as the installing user (`User=<username>`), not root
- CLI writes to `~/.claude-secure/webhooks/webhook.json` directly — no sudo, no env file
- Installer creates the new path and sets `User=` in the service unit

**Non-Goals:**
- Changing listener HTTP logic, HMAC verification, event filtering, or spawn behavior
- Supporting multiple listener instances (single listener per host, multiple profiles)
- Auto-migrating existing installations (one manual step per user, documented)

## Decisions

### D-01: ~/.claude-secure/webhooks/ as config location

**Decision**: Webhook listener config moves to `~/.claude-secure/webhooks/webhook.json`.

**Rationale**: The `webhooks/` subdirectory is clearly scoped — it's not a profile (profiles are per-repo workspaces), and it's not system config (nothing here requires root). Keeping it under `~/.claude-secure/` follows the same convention as all other user-owned config in the project. The `webhooks/` subdirectory leaves room for future per-webhook artifacts (e.g., delivery replay files) without polluting `~/.claude-secure/` root.

**Alternatives considered**:
- Keep `/etc/claude-secure/webhook.json` — requires sudo for every config write; root-ownership is unnecessary overhead for a user-space service.
- Use `~/.claude-secure/webhook.json` (no subdirectory) — flat; harder to distinguish from profile-level config at a glance.

### D-02: User= in systemd service unit

**Decision**: Installer writes `User=<installing-user>` into `/etc/systemd/system/claude-secure-webhook.service` at install time. The `--config` path in `ExecStart` is updated to the absolute expanded path (e.g., `/home/igor9000/.claude-secure/webhooks/webhook.json`).

**Rationale**: Port 9000 doesn't need root. Running as root is unnecessary privilege for a process that only reads config, calls GitHub API, and execs `claude-secure spawn`. With `User=` set, `~/.claude-secure/` is naturally accessible.

**Implementation**: Installer uses `$(id -un)` to get the current user and `$HOME` to resolve the absolute path. Both are substituted into the service unit before `systemctl daemon-reload`.

### D-03: github_token moves to profile.json

**Decision**: Remove `github_token` from `webhook.json` and add it as an optional field in `profile.json`. `resolve_profile_by_repo()` returns it in the profile dict. Call sites in `listener.py` switch from `config.github_token` to `profile.get("github_token", "")`.

**Rationale**: The token is used exclusively to fetch commit diffs for a specific repo — it's a per-repo credential, not a listener-level setting. Placing it in `profile.json` alongside `webhook_secret` (the other per-repo credential) is consistent and enables different PATs per repo.

**Fallback**: If `github_token` is absent or empty in `profile.json`, TODO detection is skipped (fail-open, same as current behavior when the global token is empty).

### D-04: jq for CLI JSON read/write, no sudo

**Decision**: Replace `_webhook_listener_set_config_key()` and `_webhook_listener_load_config()` with inline `jq` expressions targeting `~/.claude-secure/webhooks/webhook.json`. No sudo required.

**Pattern** (write-then-move for atomicity):
```bash
WEBHOOK_JSON="${WEBHOOK_CONFIG:-$HOME/.claude-secure/webhooks/webhook.json}"
tmp=$(mktemp)
jq --arg v "$value" '.key = $v' "$WEBHOOK_JSON" > "$tmp" && mv "$tmp" "$WEBHOOK_JSON"
```

### D-05: --set-token writes to profile.json, not webhook.json

**Decision**: `claude-secure webhook-listener --set-token` now writes `github_token` into a profile's `profile.json`, not into `webhook.json`. The flag requires `--profile <name>` to know which profile to update (or prompts if only one profile exists).

**Rationale**: Token follows the data it unlocks. Writing to the right profile avoids accidental cross-repo token sharing.

**Alternative considered**: Keep `--set-token` writing to `webhook.json` as a global — rejected because this is exactly the multi-repo problem we're solving.

### D-06: Template path simplification

**Decision**: Template discovery: `$WEBHOOK_TEMPLATES_DIR` → `/opt/claude-secure/webhook/templates`. Drop `$WEBHOOK_REPORT_TEMPLATES_DIR` and the dev-checkout path heuristic.

**Rationale**: Two env vars for the same purpose is unnecessary. Dev environments set `$WEBHOOK_TEMPLATES_DIR` explicitly.

## Risks / Trade-offs

- **Existing installations** → `github_token` disappears from `webhook.json`; users must re-run `--set-token --profile <name>` per profile. Documented in migration plan.
- **`User=` in systemd requires daemon-reload** → Installer handles this. If the service was previously running as root, the socket/port is released before the user-mode service starts — no conflict.
- **profile.json write permissions** → `profile.json` is user-owned (same user as the service). No permission issues.
- **`resolve_profile_by_repo()` fail-open** → If `github_token` is missing from a profile, TODO detection is silently skipped. This is the existing behavior for an empty global token; no regression.

## Migration Plan

1. Run `sudo ./install.sh --with-webhook` (re-run; upgrades service unit and creates new config path)
2. Per profile: `claude-secure webhook-listener --set-token <pat> --profile <name>`
3. Set bind/port if non-default: `claude-secure webhook-listener --set-bind <addr> --set-port <port>`
4. Restart service: `sudo systemctl restart claude-secure-webhook`
5. Verify: `claude-secure webhook-listener status`
6. Delete old files: `rm ~/.claude-secure/webhook-listener.env` and `sudo rm /etc/claude-secure/webhook.json`

**Rollback**: Revert the PR. Old env file and `/etc/` config still exist during migration window.
