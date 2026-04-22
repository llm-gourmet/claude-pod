## Why

Users who have installed claude-secure need a clean, reliable way to remove it. Manual removal is error-prone — the CLI binary, config directory, Docker images, shared templates, and optional systemd services are scattered across the filesystem, and leaving any of them behind causes confusion or silent failures on reinstall.

## What Changes

- New `uninstall.sh` script at the project root that reverses every action performed by `install.sh`
- Removes the CLI binary from `/usr/local/bin/claude-secure` or `~/.local/bin/claude-secure`
- Removes the config directory `~/.claude-secure/` (with confirmation prompt — contains user data)
- Removes shared templates from `/usr/local/share/claude-secure/`
- Stops and removes optional systemd services (`claude-secure-webhook`, `claude-secure-reaper`)
- Removes `/opt/claude-secure/` webhook files
- Optionally removes Docker images built by the installer
- Removes git hooks installed to the project's `.git/hooks/` directory
- Provides `--dry-run` flag to preview what would be removed without making changes
- Provides `--keep-data` flag to preserve `~/.claude-secure/` user data while removing binaries/services

## Capabilities

### New Capabilities

- `uninstaller-script`: Bash script that cleanly reverses the claude-secure installation — removes CLI binary, config dir, shared templates, systemd services, and Docker images with confirmation prompts and dry-run support.

### Modified Capabilities

## Impact

- New file: `uninstall.sh` (project root, mirrors `install.sh` structure)
- No changes to existing files
- Requires `sudo` for system paths (same as installer)
- Docker daemon must be running to remove images (soft requirement — warns if unavailable)
