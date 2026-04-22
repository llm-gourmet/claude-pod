## 1. Script Scaffolding

- [x] 1.1 Create `uninstall.sh` at project root with bash 4+ re-exec guard (mirrors `install.sh` opening)
- [x] 1.2 Source `lib/platform.sh` and replicate user/home resolution (`SUDO_USER`, `getent`/`dscl` fallbacks)
- [x] 1.3 Parse CLI flags: `--dry-run`, `--keep-data`, `--remove-images`
- [x] 1.4 Implement `run_or_dry` helper that prints `[DRY-RUN] would remove: ...` or executes the command
- [x] 1.5 Implement `log_info`, `log_warn`, `log_error` with same color scheme as `install.sh`
- [x] 1.6 Load `~/.claude-secure/config.sh` if present to get `APP_DIR` and `PLATFORM`; fall back to defaults

## 2. Removal Functions

- [x] 2.1 Implement `remove_cli_binary`: check `/usr/local/bin/claude-secure` then `~/.local/bin/claude-secure`, remove whichever exists (with sudo if needed), warn if neither found
- [x] 2.2 Implement `remove_shared_templates`: remove `/usr/local/share/claude-secure/` with sudo if needed; warn if absent
- [x] 2.3 Implement `remove_opt_dir`: remove `/opt/claude-secure/` with sudo if needed; warn if absent
- [x] 2.4 Implement `remove_systemd_services`: check `command -v systemctl`; stop + disable + remove unit files for `claude-secure-webhook`, `claude-secure-reaper.service`, `claude-secure-reaper.timer`; call `daemon-reload`; handle each missing unit with a warning
- [x] 2.5 Implement `remove_docker_images`: gate on `--remove-images` flag; check `docker info`; remove images with `claude-secure` prefix; if flag absent, print image names and manual command
- [x] 2.6 Implement `remove_config_dir`: skip if `--keep-data`; prompt for confirmation (check TTY); remove `~/.claude-secure/` on `y`; skip with warning if non-interactive or user declines

## 3. Non-Interactive and Edge Cases

- [x] 3.1 Detect non-TTY stdin in `remove_config_dir` and skip with printed manual command
- [x] 3.2 Ensure every removal step is idempotent (check-before-delete, no `set -e` abort on missing paths)
- [x] 3.3 Propagate `--dry-run` through all removal functions via `run_or_dry`

## 4. Summary Output

- [x] 4.1 Collect removed/skipped items in arrays throughout execution
- [x] 4.2 Print final summary: list of removed paths, list of skipped paths, any manual follow-up commands (e.g., `docker rmi` if `--remove-images` not set)

## 5. Validation

- [x] 5.1 Run `shellcheck uninstall.sh` and fix all warnings
- [x] 5.2 Test `--dry-run` on a machine with a full install: verify no files are touched
- [x] 5.3 Test `--keep-data`: verify `~/.claude-secure/` survives while binary and shared dirs are removed
- [x] 5.4 Test full uninstall: verify clean state, no orphan files in known paths
- [x] 5.5 Test with missing items (partial install): verify warnings emitted and script exits 0
