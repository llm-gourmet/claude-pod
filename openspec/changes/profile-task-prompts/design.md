## Context

Claude-secure spawns a headless Claude Code instance per webhook event. The spawn passes two key inputs: a task prompt via `-p` and an optional system prompt via `--system-prompt`. Currently, `-p` content is resolved from a template system with global fallbacks (`/opt/claude-secure/webhook/templates/`), while `--system-prompt` comes exclusively from `profile.json`. This forces users to configure behavior in two unrelated places and makes the global templates a hard dependency.

The profile directory (`~/.claude-secure/profiles/<name>/`) is already the right abstraction — it owns workspace, secrets, and identity. This change makes it the single source of truth for spawn context as well.

## Goals / Non-Goals

**Goals:**
- All spawn context (task + system prompt) resolvable from the profile directory alone
- Per-event-type overrides for both task and system prompt
- `default.md` fallback so profiles don't need an entry for every possible event type
- Clean break: old code removed, existing profiles migrated automatically by update script
- Workflow-ready: clean per-profile configuration supports future multi-step spawn chains
- Remove global template directories from the install

**Non-Goals:**
- Cross-profile template sharing or inheritance
- Dynamic template rendering with `{{TOKEN}}` substitution (removed — Claude receives event context via the event JSON and can fetch what it needs from the repo)
- Report templates (`report-templates/`) — separate concern, handled by Phase 16 report channel
- Backward compatibility with `profile.json` `system_prompt` field — migration script handles the transition

## Decisions

**D-01 — Remove token substitution (`{{BRANCH}}`, `{{COMMIT_SHA}}`, etc.)**

Current templates substitute event fields into the task prompt. This is removed. The task file is passed to Claude as-is; Claude has repo access and can run `git show`, `git log`, etc. to get what it needs.

Why: Token substitution adds complexity (render_template, _substitute_token_from_file) and couples template authors to the event JSON schema. Claude can derive the same information autonomously.

Alternative considered: Keep substitution as opt-in. Rejected — it creates two mental models and the benefit is marginal when Claude has git access.

**D-02 — Resolution chain for task (`-p`)**

```
1. profiles/<name>/tasks/<event_type>.md    ← event-specific
2. profiles/<name>/tasks/default.md         ← profile default
```

If neither exists, spawn fails with a clear error message listing the checked paths.

Why: Two levels give flexibility without complexity. `default.md` handles profiles that respond the same way to all events. Event-specific files handle profiles that differentiate.

**D-03 — Resolution chain for system prompt (`--system-prompt`)**

```
1. profiles/<name>/system_prompts/<event_type>.md   ← event-specific
2. profiles/<name>/system_prompts/default.md        ← profile default
```

If neither exists, `--system-prompt` is omitted from the Claude invocation.

Why: Two levels, no legacy fallback. The migration script ensures all existing `system_prompt` values are moved to files before the new code runs. Clean interface, no dead paths.

**D-04 — Remove `/opt/claude-secure/webhook/templates/` from runtime**

The global template directories are removed from the installer and from `resolve_template()`. The `resolve_template()` function itself is replaced by two simpler functions: `resolve_task_file()` and `resolve_system_prompt_file()`.

Why: Removing the global fallback makes the profile directory truly self-contained.

**D-05 — Profile creation scaffolds `tasks/` and `system_prompts/`**

`claude-secure profile <name> create` generates `tasks/default.md` and `system_prompts/default.md` with minimal placeholders. New profiles are immediately spawn-ready.

**D-06 — `profile.json` `system_prompt` field removed**

The field is removed from the schema. The migration script extracts any existing value into `system_prompts/default.md` and strips the field from `profile.json`. No two mechanisms for the same thing.

**D-07 — Automatic migration via `scripts/migrate-profile-prompts.sh`**

`claude-secure update` runs the migration script as part of the update process. The script:
- For each profile: if `profile.json` has `system_prompt`, write it to `system_prompts/default.md` and remove the field
- For each profile: if `prompts/` directory exists, move files to `tasks/`, remove `prompts/`
- Idempotent — safe to run multiple times

Why: Users should not need to manually migrate. The update command already exists as the natural hook for this.

## Risks / Trade-offs

[Risk] Migration script runs but profile already has `system_prompts/default.md`.  
→ Mitigation: Script is idempotent — skips if target file already exists.

[Risk] Removing token substitution breaks existing `task.md` files that use `{{COMMIT_SHA}}`.  
→ Mitigation: `{{TOKEN}}` syntax passed as literal string to Claude, visible immediately in `--dry-run`. Migration script does not touch task file content.

[Risk] Users don't know what event_type strings to use as filenames.  
→ Mitigation: `claude-secure spawn --dry-run` prints the resolved event_type and the paths checked.

## Open Questions

- Should `--dry-run` also print the resolved system prompt content, or just the path?
- Should `profile validate` check that at least one task file exists?
