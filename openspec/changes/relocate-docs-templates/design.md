## Context

Bootstrap-docs templates currently live inside the app bundle at `$APP_DIR/scripts/templates/` (i.e. `~/.claude-pod/app/scripts/templates/`). `_bootstrap_docs_find_templates` resolves this via a three-path fallback: dev-layout (`$self_dir/../scripts/templates`), APP_DIR, and `/usr/local/share/claude-pod/scripts/templates`. `_bootstrap_docs_scaffold` hardcodes every filename it copies (`VISION.md`, `AGREEMENTS.md`, etc.).

Problems:
1. App bundle is overwritten on every `install.sh` run — templates are not stable across upgrades without also touching /usr/local/share.
2. Three-path resolution exists solely to support running from the source tree without installing — a dev-only convenience that leaks into the installed runtime.
3. Hardcoded filenames mean adding or removing a template requires a code change in three places (bin/claude-pod, scripts/new-project.sh, tests).

## Goals / Non-Goals

**Goals:**
- Single authoritative template path: `$CONFIG_DIR/docs-templates/` (`~/.claude-pod/docs-templates/`)
- `install.sh` populates that path from `scripts/templates/` in the repo
- `_bootstrap_docs_scaffold` copies all content from the templates dir dynamically — no hardcoded filenames
- `scripts/new-project.sh` uses the same dynamic approach
- Fallback chain in `_bootstrap_docs_find_templates` removed

**Non-Goals:**
- Changing template file content
- Supporting multiple template sets or profiles
- Dev-without-install workflow (run `install.sh` first)

## Decisions

### D1: Target path is `$CONFIG_DIR/docs-templates/`

**Decision**: Templates live at `$CONFIG_DIR/docs-templates/`, not inside `$APP_DIR`.

**Rationale**: Config dir (`~/.claude-pod/`) is the user-owned, stable location. App dir is an implementation detail that gets replaced on upgrade. Separating templates from the app bundle makes them durable across reinstalls and gives users a well-known place to add custom templates.

**Alternatives considered**:
- Keep `/usr/local/share/claude-pod/scripts/templates/` — requires sudo on many systems, still separate from user config, adds install complexity.
- Keep `$APP_DIR/scripts/templates/` — survives only because it's inside the app bundle; gets wiped on `cp -r` reinstall.

### D2: Dynamic scaffold via `cp -r`

**Decision**: Replace the hardcoded `cp` list with a single `cp -r "$templates_dir/." "$project_dir/"`.

**Rationale**: Any file or subdirectory present in `docs-templates/` gets scaffolded automatically. No code change needed to add or remove a template. Preserves the existing `decisions/`, `ideas/`, `done/` subdirectory structure.

**Alternatives considered**:
- `find … -name "*.md"` loop — more selective but loses subdirectory structure and requires a loop to mirror paths.
- Explicit list but read from a manifest file — adds indirection without benefit over dynamic copy.

### D3: Remove fallback chain entirely

**Decision**: `_bootstrap_docs_find_templates` becomes a one-liner returning `$CONFIG_DIR/docs-templates/`, with a clear error if the dir is missing (prompt to re-run `install.sh`).

**Rationale**: The dev-layout fallback was a convenience for in-repo development. With templates in config dir, developers run `install.sh` once; the installed path always works.

## Risks / Trade-offs

- **Existing installations have templates in the old path** → Mitigation: `install.sh` creates `docs-templates/` and copies templates there; re-running install migrates automatically.
- **`cp -r` copies non-md files too** → Acceptable; the templates dir should only contain intended scaffold files. If a stray file lands there, it gets scaffolded — low risk, easy to discover.
- **No dev-without-install path** → Mitigation: document in CONTRIBUTING that `install.sh --dev` (or plain `install.sh`) is required before running commands locally.

## Migration Plan

1. `install.sh` updated to `mkdir -p "$CONFIG_DIR/docs-templates"` and `cp -r "$templates_src/." "$CONFIG_DIR/docs-templates/"` (replacing the /usr/local/share block).
2. `_bootstrap_docs_find_templates` simplified to return `$CONFIG_DIR/docs-templates/` or error.
3. `_bootstrap_docs_scaffold` replaced with `cp -r "$templates_dir/." "$project_dir/"`.
4. `scripts/new-project.sh` updated similarly (reads `$CONFIG_DIR/docs-templates/`).
5. Tests updated to seed fixtures into a temp `docs-templates/` dir and set `CONFIG_DIR` accordingly.
6. Existing users: re-run `install.sh` — new templates dir is created, old app-bundle templates remain but are ignored.
