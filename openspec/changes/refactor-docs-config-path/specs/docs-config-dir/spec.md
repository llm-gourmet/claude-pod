## ADDED Requirements

### Requirement: docs_dir is a supported config key in webhook config
The webhook `config.json` SHALL support an optional `docs_dir` key that points to a directory of docs-oriented profiles. When present, the listener SHALL scan `docs_dir` for profile configs in addition to `profiles_dir`. When absent or empty, listener behaviour SHALL be unchanged.

#### Scenario: docs_dir present — profile resolved from docs dir
- **WHEN** `config.json` contains `"docs_dir": "/home/user/.claude-secure/docs"` and `~/.claude-secure/docs/obsidian/profile.json` exists with a matching `repo`
- **THEN** `resolve_profile_by_repo` returns that profile with `name: "obsidian"`

#### Scenario: docs_dir absent — existing profiles_dir behaviour unchanged
- **WHEN** `config.json` has no `docs_dir` key
- **THEN** listener starts without error and only scans `profiles_dir`

#### Scenario: Profile in profiles_dir takes priority over docs_dir
- **WHEN** both `profiles_dir/foo/profile.json` and `docs_dir/foo/profile.json` exist with the same `repo`
- **THEN** the profile from `profiles_dir` is returned

### Requirement: install.sh creates docs directory and injects docs_dir placeholder
`install.sh` SHALL create `~/.claude-secure/docs/` on install/upgrade and SHALL inject the absolute path into `config.json` via the `__REPLACED_BY_INSTALLER__DOCS__` placeholder (matching the existing pattern for `profiles_dir`).

#### Scenario: Fresh install creates docs dir
- **WHEN** `install.sh` runs on a system where `~/.claude-secure/docs/` does not exist
- **THEN** `~/.claude-secure/docs/` is created

#### Scenario: config.json contains resolved docs_dir after install
- **WHEN** `install.sh` generates `config.json` from `config.example.json`
- **THEN** `docs_dir` in `config.json` equals the absolute path to `~/.claude-secure/docs/`

### Requirement: bin/claude-secure resolves templates from docs dir
`bin/claude-secure`'s `resolve_template` and `resolve_report_template` SHALL check `$CONFIG_DIR/docs/$PROFILE/` as a fallback when `$CONFIG_DIR/profiles/$PROFILE/` does not contain the requested template. The `--profile` flag SHALL work whether the named profile lives in `profiles/` or `docs/`.

#### Scenario: Template resolved from docs dir when absent in profiles
- **WHEN** `~/.claude-secure/profiles/obsidian/prompts/push.md` does not exist but `~/.claude-secure/docs/obsidian/prompts/push.md` does
- **THEN** `resolve_template push` returns the path under `docs/`

#### Scenario: Profile dir probed in both locations for profile.json load
- **WHEN** `--profile obsidian` is passed and `profiles/obsidian/` does not exist but `docs/obsidian/` does
- **THEN** `profile.json` and `.env` are loaded from `docs/obsidian/`
