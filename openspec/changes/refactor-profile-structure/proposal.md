## Why

Profile configuration is split across three files (`profile.json`, `.env`, `whitelist.json`), but the core concept — a secret key authorized for specific domains, redacted in Anthropic-bound requests — is one thing. This split forces redundant wiring and makes profiles hard to manage from a CLI.

## What Changes

- **BREAKING**: `whitelist.json` is removed; secrets and domain config move into `profile.json` under a `secrets[]` array
- `secrets[]` entries use `redacted` instead of `placeholder` (clearer intent)
- `readonly_domains` is removed — it was never enforced by the hook (dead code)
- `max_turns` is removed from `profile.json` — not a profile concern
- Webhook-specific fields (`repo`, `webhook_secret`, `report_repo`, `report_branch`, `report_path_prefix`, `docs_repo`, `docs_branch`, `docs_project_dir`) are removed from `profile.json` — they belong in connection config
- `profile.json` schema narrows to: `workspace`, `system_prompt`, `secrets[]`
- `.env` retains only secret values: `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) + one var per secret entry
- The hook (`pre-tool-use.sh`) and proxy read domain/redaction config from `profile.json` instead of `whitelist.json`

## Capabilities

### New Capabilities

- `profile-schema`: Unified profile schema — `profile.json` as single config file with `workspace`, `system_prompt`, and `secrets[]` (each entry: `env_var`, `redacted`, `domains[]`)

### Modified Capabilities

- `apikey-auth`: `.env` structure changes — only auth token + secret env vars, no other fields

## Impact

- `claude/hooks/pre-tool-use.sh`: reads domain whitelist from `profile.json` secrets instead of `whitelist.json`
- `proxy/` (Node.js): reads redaction map from `profile.json` secrets instead of `whitelist.json`
- `bin/claude-secure`: `create_profile` writes new `profile.json` schema; `validate_profile` checks new required fields; `list_profiles` display adapts
- `install.sh`: writes new `profile.json` schema on fresh install
- `config/whitelist.json`: deleted (template no longer needed)
- Test fixtures in `tests/fixtures/profile-*/`: updated to new schema
- Test phases 9, 12, 13, 14, 15, 16, 17 need fixture/assertion updates
