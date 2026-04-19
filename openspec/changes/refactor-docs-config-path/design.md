## Context

`~/.claude-secure/profiles/` currently holds all profile configs regardless of purpose. Docs-oriented profiles (e.g. `obsidian`) share the same directory as project profiles (`default`, `jad`). The webhook listener discovers profiles by scanning `profiles_dir` for `profile.json` files. `bin/claude-secure`'s `resolve_template` and `resolve_report_template` hardcode `$CONFIG_DIR/profiles/$PROFILE` as the base path.

## Goals / Non-Goals

**Goals:**
- New `~/.claude-secure/docs/<name>/` directory works identically to `profiles/<name>/` for the listener and CLI
- `docs_dir` is optional in config — omitting it leaves existing behaviour unchanged
- `install.sh` creates the `docs/` directory and injects the `docs_dir` placeholder
- Profile resolution searches `docs_dir` after `profiles_dir` (predictable priority)

**Non-Goals:**
- No migration of existing `profiles/obsidian/` data (user does this manually or in a follow-up)
- No UI or new subcommands for managing docs profiles
- No change to how `profiles/` works for non-docs profiles

## Decisions

### D-1: `docs_dir` as optional config key, not a required second profiles dir

`Config` in `listener.py` reads `docs_dir` with `data.get("docs_dir")`, defaulting to `None`. `resolve_profile_by_repo` loops over a `[profiles_dir, docs_dir]` list, skipping `None` entries. This is backward-compatible: old `config.json` files without `docs_dir` continue to work.

**Alternative considered:** Merge `docs/` entries into `profiles_dir` at startup (copy or symlink). Rejected — adds filesystem side effects on every listener start; confusing when debugging which dir a profile came from.

### D-2: `bin/claude-secure` resolves docs profiles via `$DOCS_DIR` env var

`resolve_template` and `resolve_report_template` currently hardcode `$CONFIG_DIR/profiles/$PROFILE`. To support a profile living in `docs/`, we introduce a `DOCS_DIR` env var (default `$CONFIG_DIR/docs`). The resolution order becomes:

1. `$CONFIG_DIR/profiles/$PROFILE/prompts/` (existing)
2. `$CONFIG_DIR/docs/$PROFILE/prompts/` (new, only if dir exists)
3. Default system templates (unchanged)

The `--profile` flag is unchanged — the CLI probes both dirs and uses whichever one has the `profile.json`.

**Alternative considered:** New `--docs-profile` flag. Rejected — unnecessary complexity; the same `--profile obsidian` should just work regardless of whether the config lives in `profiles/` or `docs/`.

### D-3: `install.sh` creates `docs/` dir and injects placeholder

The installer creates `$CONFIG_DIR/docs/` alongside `$CONFIG_DIR/profiles/` and replaces `__REPLACED_BY_INSTALLER__DOCS__` in `config.example.json` (same pattern as `__REPLACED_BY_INSTALLER__PROFILES__`).

## Risks / Trade-offs

- Profile name collision (`profiles/foo/` and `docs/foo/` both exist) → listener takes `profiles_dir` first; CLI probes `profiles/` first. Documented, not an error.
- `docs_dir` absent from old configs → `None` skipped cleanly in the loop; no regression.
- Tests that build fixture profile dirs must add `docs_dir` to their config JSON → test fixtures updated in tasks.

## Migration Plan

1. Deploy code changes (listener, CLI, installer)
2. Run `install.sh` to create `~/.claude-secure/docs/` and update `config.json`
3. User manually moves `~/.claude-secure/profiles/obsidian/` to `~/.claude-secure/docs/obsidian/`
4. Restart webhook listener: `sudo systemctl restart claude-secure-webhook`
5. Rollback: set `docs_dir` to empty string in `config.json` and move dir back — no code change needed

## Open Questions

- Should `install.sh` offer to migrate an existing `profiles/obsidian/` automatically? (Deferred — user preference; manual migration is safe and auditable.)
