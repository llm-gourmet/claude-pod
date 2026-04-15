---
status: awaiting_human_verify
trigger: "whitelist-placeholder-stale: User changed whitelist.json placeholder but proxy logs show old value"
created: 2026-04-10T00:00:00Z
updated: 2026-04-10T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED - docker-compose.yml mounts ./config/whitelist.json which is a regular file, not the symlink the installer intended
test: Verified file is regular (not symlink), user edited ~/.claude-secure/whitelist.json which is a different file
expecting: N/A - root cause confirmed
next_action: Fix docker-compose.yml to use env var for whitelist path, update launcher to export it

## Symptoms

expected: After editing whitelist.json secrets entry to "placeholder": "REDACTED_GITHUB_TOKEN", the proxy logs should show this new placeholder name.
actual: Proxy logs still show "placeholder": "PLACEHOLDER_GITHUB" in the redaction_map log entries.
errors: No errors - the proxy works, just uses stale placeholder names.
reproduction: Edit whitelist.json to change placeholder value, then make API calls through the proxy and check logs.
started: Happens after whitelist edit. The proxy may be caching config or reading from a different file.

## Eliminated

## Evidence

- timestamp: 2026-04-10T00:00:00Z
  checked: proxy/proxy.js config loading logic
  found: loadWhitelist() called inside request handler (line 128) - correctly re-reads on every request from WHITELIST_PATH
  implication: Proxy code is NOT caching. Problem is upstream of the proxy code.

- timestamp: 2026-04-10T00:01:00Z
  checked: docker-compose.yml volume mounts
  found: Line 49 mounts ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro - relative to compose project dir
  implication: Container reads from /home/igor9000/claude-secure/config/whitelist.json

- timestamp: 2026-04-10T00:02:00Z
  checked: /home/igor9000/claude-secure/config/whitelist.json vs /home/igor9000/.claude-secure/whitelist.json
  found: Two different files. Repo copy has PLACEHOLDER_GITHUB, user copy has REDACTED_GITHUB_TOKEN. Repo copy is a regular file (not symlink).
  implication: User edited the wrong file (or rather, the intended symlink was broken)

- timestamp: 2026-04-10T00:03:00Z
  checked: install.sh line 202
  found: Installer creates symlink ln -sf "$CONFIG_DIR/whitelist.json" "$app_dir/config/whitelist.json" but config/whitelist.json is git-tracked
  implication: Any git operation (pull, checkout, reset) overwrites symlink with committed regular file. Design flaw.

## Resolution

root_cause: docker-compose.yml mounts ./config/whitelist.json (a git-tracked regular file) into the proxy container. The installer creates a symlink from this path to ~/.claude-secure/whitelist.json, but any git operation (pull, checkout, update command) overwrites the symlink with the committed file. User edits to ~/.claude-secure/whitelist.json are never seen by the proxy.
fix: (1) docker-compose.yml now uses ${WHITELIST_FILE:-./config/whitelist.json} for all three whitelist volume mounts, (2) bin/claude-secure exports WHITELIST_FILE=$CONFIG_DIR/whitelist.json so the launcher always points at the user's copy, (3) install.sh no longer creates a fragile symlink
verification: pending human verification - restart containers and check proxy logs for updated placeholder
files_changed: [docker-compose.yml, bin/claude-secure, install.sh]
