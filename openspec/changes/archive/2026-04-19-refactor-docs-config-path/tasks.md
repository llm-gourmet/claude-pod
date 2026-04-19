## 1. Config & Installer

- [x] 1.1 Add `"docs_dir": "__REPLACED_BY_INSTALLER__DOCS__"` to `webhook/config.example.json`
- [x] 1.2 In `install.sh`: add `mkdir -p "$CONFIG_DIR/docs"` alongside the existing `profiles` mkdir
- [x] 1.3 In `install.sh`: add `sed` replacement for `__REPLACED_BY_INSTALLER__DOCS__` → `${invoking_home}/.claude-secure/docs` (mirroring the `PROFILES` replacement)

## 2. Listener (listener.py)

- [x] 2.1 Add `self.docs_dir` to `Config.__init__`: `self.docs_dir = pathlib.Path(data["docs_dir"]) if data.get("docs_dir") else None`
- [x] 2.2 Refactor `resolve_profile_by_repo` to loop over `[config.profiles_dir, config.docs_dir]`, skipping `None` entries, keeping `profiles_dir`-first priority
- [x] 2.3 Pass `config` (or `docs_dir`) into `resolve_profile_by_repo` call sites so the new arg is available

## 3. CLI (bin/claude-secure)

- [x] 3.1 In profile-loading section of `cmd_spawn` / profile loader: probe `$CONFIG_DIR/docs/$PROFILE/` as fallback when `$CONFIG_DIR/profiles/$PROFILE/profile.json` does not exist
- [x] 3.2 Update `resolve_template`: after failing step 2 (`profiles/` prompts dir), check `$CONFIG_DIR/docs/$PROFILE/prompts/${event_type}.md` before falling through to system default
- [x] 3.3 Update `resolve_report_template`: same pattern — add `docs/` fallback between profile dir and system default
- [x] 3.4 Update `--set-token` profile discovery in `cmd_webhook_listener`: combine profiles from `profiles/` and `docs/` when checking for single-profile shortcut

## 4. Tests

- [x] 4.1 `tests/test-phase13.sh`: add `docs_dir` to test fixture `config.json`; add a test case spawning with a profile in `docs_dir`
- [x] 4.2 `tests/test-phase15.sh`: add `docs_dir` to fixture config; add template resolution test where profile is in `docs/`
- [x] 4.3 `tests/test-phase16.sh`: add `docs_dir` to fixture config; verify `resolve_report_template` fallback through `docs/`
- [x] 4.4 Add test: `docs_dir` absent from config → listener starts without error

## 5. Documentation

- [x] 5.1 Update `README.md` (or relevant section) to document `docs/` directory, `docs_dir` config key, and manual migration steps from `profiles/obsidian/` to `docs/obsidian/`
