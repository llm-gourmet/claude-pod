## Context

Currently, a profile's security configuration lives in three separate files:

- `profile.json`: workspace, system_prompt, and assorted webhook/docs fields
- `.env`: secret values (`GITHUB_TOKEN=ghp_xxx`, `CLAUDE_CODE_OAUTH_TOKEN=...`)
- `whitelist.json`: the mapping between a secret and its domain(s) and redaction placeholder

The core security primitive — "this key authenticates to these domains, and should appear as this token in Anthropic-bound requests" — is conceptually one thing, split across two files with a loose string reference (`env_var`) as the link.

`readonly_domains` in `whitelist.json` is dead code (defined, never read by the hook). `max_turns` and all webhook-specific fields in `profile.json` are out-of-scope for the profile abstraction.

## Goals / Non-Goals

**Goals:**
- Single config file per profile (`profile.json`) containing all non-secret configuration
- `.env` reduced to raw secret values only
- `whitelist.json` eliminated entirely
- Schema is minimal and CLI-friendly (each field maps to a clear CLI flag)
- All consumers (hook, proxy, CLI) updated to read from new location

**Non-Goals:**
- Migration tooling for existing installs (no migration; users recreate or hand-edit)
- Validating that secrets in `.env` match entries in `profile.json` at runtime
- Moving OAuth token out of `.env` (it stays there — it's a secret value, not config)

## Decisions

**D1: Merge whitelist.json into profile.json**

The `secrets[]` array moves into `profile.json`. Rationale: it's config (schema/metadata), not a secret value. The actual values stay in `.env`. This eliminates one file per profile and makes the config self-describing.

Alternative considered: keep `whitelist.json` but rename it. Rejected — two files is still two files.

**D2: Rename `placeholder` → `redacted`**

`placeholder` implies a substitute standing in for something. `redacted` conveys intent: this value is what Anthropic sees instead of the real key. Clearer at a glance in CLI output.

**D3: Remove `readonly_domains` with no replacement**

The hook allows GET requests to any domain unconditionally (per `CALL-04`). `readonly_domains` was never enforced. Removing it without replacement maintains existing behavior while reducing surface area.

**D4: Remove webhook/docs fields from profile.json**

`repo`, `webhook_secret`, `report_repo`, `report_branch`, `report_path_prefix`, `docs_repo`, `docs_branch`, `docs_project_dir` are connection/integration concerns, already moved to `connections.json` in a prior refactor. They have no place in the core profile schema.

**D5: Remove `max_turns` from profile.json**

`max_turns` is a runtime invocation parameter, not a profile identity. Removing it simplifies the schema. Can be reintroduced as a CLI flag if needed.

## New Schema

**profile.json**:
```json
{
  "workspace": "/home/user/my-workspace",
  "system_prompt": "You are a helpful assistant.",
  "secrets": [
    {
      "env_var": "GITHUB_TOKEN",
      "redacted": "REDACTED_GITHUB",
      "domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    },
    {
      "env_var": "STRIPE_KEY",
      "redacted": "REDACTED_STRIPE",
      "domains": ["api.stripe.com"]
    }
  ]
}
```

**.env** (unchanged structure, narrowed content):
```bash
CLAUDE_CODE_OAUTH_TOKEN=ey...
GITHUB_TOKEN=ghp_aaa
STRIPE_KEY=sk_live_xxx
```

## Consumer Changes

| Consumer | Change |
|----------|--------|
| `pre-tool-use.sh` | Read `secrets[].domains` from `profile.json` instead of `whitelist.json` secrets `allowed_domains`; remove `domain_in_readonly()` function |
| Proxy (Node.js) | Build redaction map from `profile.json` `secrets[].{env_var, redacted}` instead of `whitelist.json` |
| `bin/claude-secure` | `create_profile`: write new schema; `validate_profile`: check `workspace` + `secrets[]` valid; remove `whitelist.json` copy step |
| `install.sh` | Write new `profile.json` schema; remove `whitelist.json` copy step |

## Risks / Trade-offs

- **Existing installs break silently**: The hook and proxy will fail to find secrets if run against old-format profiles. Accepted — no migration, users are informed via docs/README.
- **`whitelist.json` template in `config/` deleted**: Any tooling that references it directly will error. Low risk — only the installer used it.

## Open Questions

None — all decisions resolved in explore session.
