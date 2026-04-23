## Why

The project has been renamed from `claude-secure` to `claude-pod`, but the codebase still contains hundreds of references to the old name across binary names, config paths, log paths, systemd unit names, Python/Bash variable names, and documentation. These stale references create confusion, make the CLI feel inconsistent, and mean installed artifacts (systemd units, config dirs, log dirs) use the wrong name on end-user systems.

## What Changes

- **CLI binary**: `bin/claude-secure` → `bin/claude-pod` and installed at `/usr/local/bin/claude-pod`
- **Config directory**: `~/.claude-secure/` → `~/.claude-pod/` (profiles, events, docs, webhooks, logs)
- **Container config path**: `/etc/claude-secure/` → `/etc/claude-pod/` (hooks, profile.json)
- **Log path**: `/var/log/claude-secure/` → `/var/log/claude-pod/`
- **Systemd units**: `claude-secure-webhook`, `claude-secure-reaper` → `claude-pod-webhook`, `claude-pod-reaper`
- **Python/Bash identifiers**: `claude_secure_bin`, `claude_secure_bootstrap_path`, etc. → `claude_pod_bin`, `claude_pod_bootstrap_path`
- **Installer sed substitutions**: all `__REPLACED_BY_INSTALLER__*` tokens and their target paths updated
- **Docker Compose**: volume mounts and env vars referencing old paths updated
- **Documentation**: README.md, CLAUDE.md, openspec specs updated to use new name
- **Tests and fixtures**: all test scripts and fixture JSON files updated

## Capabilities

### Modified Capabilities

- All existing capabilities remain functionally identical; this is a pure rename with no behavioral change
- The installed CLI entrypoint becomes `claude-pod` instead of `claude-secure`
- User-facing paths (config dir, logs) use `claude-pod` naming

## Impact

- Breaking change for existing installs: users must re-install or migrate `~/.claude-secure/` → `~/.claude-pod/`
- All source files across `bin/`, `install.sh`, `uninstall.sh`, `run-tests.sh`, `docker-compose.yml`, `claude/`, `tests/`, `openspec/specs/`, and `config/` are affected
