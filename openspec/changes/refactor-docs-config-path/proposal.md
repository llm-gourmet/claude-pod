## Why

Docs-oriented profiles (e.g. `obsidian`) are semantically different from project profiles (`default`, `jad`) but currently live in the same `~/.claude-secure/profiles/` directory. Separating them into `~/.claude-secure/docs/` makes the intent clear and allows different tooling, permissions, or lifecycle management for docs configs without affecting project profiles.

## What Changes

- Add `~/.claude-secure/docs/` as a first-class config directory (parallel to `profiles/`)
- Add `docs_dir` field to `config.example.json` (alongside existing `profiles_dir`)
- `listener.py`: `resolve_profile_by_repo` scans both `profiles_dir` and `docs_dir`
- `bin/claude-secure`: `resolve_template` checks `docs_dir`-based profile dirs
- `install.sh`: creates `docs/` directory and sets `docs_dir` placeholder in config
- Existing `~/.claude-secure/profiles/obsidian/` content migrates to `~/.claude-secure/docs/obsidian/`

## Capabilities

### New Capabilities

- `docs-config-dir`: New `~/.claude-secure/docs/<name>/` directory for docs-oriented profiles, with `docs_dir` config key and scanner support in listener and CLI

### Modified Capabilities

- `webhook-listener-cli`: `resolve_profile_by_repo` extended to scan `docs_dir` in addition to `profiles_dir`

## Impact

- `webhook/config.example.json` — new `docs_dir` field
- `webhook/listener.py` — `Config` dataclass + `resolve_profile_by_repo`
- `bin/claude-secure` — `resolve_template`, install path for `docs/` dir
- `install.sh` — `mkdir docs/`, sed replacement for `docs_dir` placeholder
- `tests/test-phase13.sh`, `test-phase15.sh`, `test-phase16.sh` — fixture paths updated
- No breaking change to existing `profiles/` behaviour; `docs_dir` is optional (defaults to empty / skipped if absent)
