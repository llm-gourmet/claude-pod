## Why

Bootstrap-docs templates live inside the app bundle (`~/.claude-pod/app/scripts/templates/`), which is overwritten on every `install.sh` run and resolved via three fallback paths (dev layout, APP_DIR, /usr/local/share). This makes the template set fragile, installation-coupled, and unable to be customized without modifying app code. Moving templates to a stable config-owned directory and discovering them dynamically removes the coupling and lets users add or remove templates freely.

## What Changes

- Templates relocated from `~/.claude-pod/app/scripts/templates/` to `~/.claude-pod/docs-templates/`
- `install.sh` copies templates to `~/.claude-pod/docs-templates/` during installation (instead of `/usr/local/share/` or APP_DIR)
- `_bootstrap_docs_find_templates` fallback chain removed — single authoritative path: `$CONFIG_DIR/docs-templates/`
- `_bootstrap_docs_scaffold` no longer hardcodes filenames; instead copies all `*.md` files and subdirectories found in the templates dir
- `scripts/new-project.sh` updated to use the same dynamic discovery
- `scripts/templates/` directory in the repo is the canonical source; install.sh syncs it to `docs-templates/`

## Capabilities

### New Capabilities

_(none — this is a refactor of existing bootstrap-docs behaviour)_

### Modified Capabilities

- `docs-bootstrap`: Template resolution changes from multi-path fallback to single config-dir path; scaffold switches from hardcoded file list to dynamic directory copy.

## Impact

- `bin/claude-pod`: `_bootstrap_docs_find_templates` and `_bootstrap_docs_scaffold` functions
- `scripts/new-project.sh`: template copy block
- `install.sh`: template installation target path
- `tests/test-bootstrap-docs.sh`: template path setup in test fixtures
- Users who manually placed files in `/usr/local/share/claude-pod/scripts/templates/` — they must re-run `install.sh` to migrate
