## Context

The `webhook-listener` subcommand was introduced before multi-platform webhook support was considered. The implementation is GitHub-specific (HMAC-SHA256 with `X-Hub-Signature-256`, GitHub PAT storage, `X-GitHub-Event` header parsing). The name does not reflect this constraint.

## Goals / Non-Goals

**Goals:**
- Rename CLI subcommand from `webhook-listener` to `gh-webhook-listener` everywhere users or developers see it
- Update all code comments and test descriptions to use the new name
- Update README usage examples

**Non-Goals:**
- Renaming file names (`listener.py`, `claude-secure-webhook.service`, `Caddyfile.example`) — internal names, not user-facing
- Renaming config file keys inside `connections.json` / `webhook.json` — would break existing installs
- Any behavioral change

## Decisions

**Rename scope: CLI surface + comments only**
Renaming internal file names adds churn with no user benefit. The CLI command name is what users type and what scripts reference — that is the surface that needs to reflect GitHub specificity. Config key names are stored on disk and renaming them would require a migration step inconsistent with the scope of this change.

**No backward-compat alias**
This is a local developer tool, not a public API. A transitional alias would add permanent dead code. Users with existing scripts will see a clear error and can update.

## Risks / Trade-offs

- [Breaking change for existing scripts] → Documented in proposal. Single-developer tool; migration is a find-and-replace.
- [Spec file `webhook-listener-cli` keeps old folder name] → Acceptable; spec folder names are internal identifiers, not user-facing.

## Migration Plan

1. Update `bin/claude-secure`: command dispatch, all flag handlers, help strings
2. Update `tests/test-webhook-listener-cli.sh` and `tests/test-webhook-spawn.sh`
3. Update `webhook/listener.py` inline comments
4. Update README (if applicable)
5. Commit with `[skip-claude]` prefix
