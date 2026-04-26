## 1. install.sh — new templates target

- [x] 1.1 Add `mkdir -p "$CONFIG_DIR/docs-templates"` to `setup_config_dir`
- [x] 1.2 Replace the existing bootstrap-docs template copy block (lines ~488-501) with `cp -r "$templates_src/." "$CONFIG_DIR/docs-templates/"`
- [x] 1.3 Remove the `/usr/local/share/claude-pod/scripts/templates` install path and sudo logic

## 2. bin/claude-pod — simplify template resolution

- [x] 2.1 Rewrite `_bootstrap_docs_find_templates` to return `$CONFIG_DIR/docs-templates/` directly
- [x] 2.2 Add error message "bootstrap-docs templates not found — re-run install.sh" when dir is missing
- [x] 2.3 Replace the hardcoded `cp` list in `_bootstrap_docs_scaffold` with `cp -r "$templates_dir/." "$project_dir/"`

## 3. scripts/new-project.sh — dynamic copy

- [x] 3.1 Replace hardcoded `cp "$TEMPLATES_DIR/FILE"` lines with `cp -r "$TEMPLATES_DIR/." "$PROJECT_DIR/"`
- [x] 3.2 Update `TEMPLATES_DIR` to read from `$CONFIG_DIR/docs-templates/` (use `$HOME/.claude-pod/docs-templates` as default)
- [x] 3.3 Add error + exit if `TEMPLATES_DIR` does not exist

## 4. tests/test-bootstrap-docs.sh — fixture migration

- [x] 4.1 Update all test fixtures that seed templates: point to a temp `docs-templates/` dir instead of `scripts/templates/`
- [x] 4.2 Set `CONFIG_DIR` env var in test setup so `_bootstrap_docs_find_templates` picks up the temp dir
- [x] 4.3 Verify BOOT-14 e2e test passes without GOALS.md in fixture

## 5. Verification

- [x] 5.1 Run `bash tests/test-bootstrap-docs.sh` — all tests pass
- [ ] 5.2 Run `install.sh` and confirm `~/.claude-pod/docs-templates/` is created and populated
- [ ] 5.3 Run `claude-pod bootstrap-docs --connection obsidian projects/test-verify` and confirm scaffold works
- [ ] 5.4 Confirm `scripts/new-project.sh test-proj` creates project with all template files
