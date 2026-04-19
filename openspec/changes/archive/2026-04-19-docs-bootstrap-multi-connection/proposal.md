## Why

`bootstrap-docs` currently supports exactly one docs repository per installation, stored as a flat `.env` file. Users who maintain multiple docs repositories (e.g. one per team, one personal knowledge base) must overwrite the config each time they switch targets. A named-connection model eliminates this friction.

## What Changes

- New config location: `~/.claude-secure/docs-bootstrap/connections.json` (replaces `~/.claude-secure/docs-bootstrap.env`)
- Each connection has a unique `name`, `repo`, `token`, and optional `branch` (default: `main`)
- `--connection <name>` flag required when running `bootstrap-docs <path>`
- New management flags: `--add-connection`, `--remove-connection`, `--list-connections`
- Old `--set-repo`, `--set-token`, `--set-branch` flags removed
- No migration from old `.env` format

## Capabilities

### New Capabilities

- `docs-bootstrap-connections`: Multi-connection config storage and management for bootstrap-docs (add, remove, list, select by name)

### Modified Capabilities

- `bootstrap-docs-command`: Requirements change — connection selection via `--connection`, config path changes, management flags change

## Impact

- `bin/claude-secure`: `cmd_bootstrap_docs`, `_bootstrap_docs_load_config`, `_bootstrap_docs_set_config_key` rewritten
- `~/.claude-secure/docs-bootstrap.env`: superseded (not deleted by tool, no migration)
- `install.sh`: no changes needed (does not touch `docs-bootstrap.env` or the new dir)
- Tests covering bootstrap-docs config flags will need updating
