## ADDED Requirements

### Requirement: Dry-run mode
The script SHALL support a `--dry-run` flag that prints every action that would be taken without modifying the filesystem, stopping services, or removing images.

#### Scenario: Dry-run prints actions without modifying state
- **WHEN** user runs `./uninstall.sh --dry-run`
- **THEN** each removal action is printed prefixed with `[DRY-RUN] would remove:` and no files are deleted, no services are stopped, and exit code is 0

### Requirement: Keep-data mode
The script SHALL support a `--keep-data` flag that removes binaries, shared templates, and systemd services while preserving the `~/.claude-secure/` config directory.

#### Scenario: Keep-data preserves user config
- **WHEN** user runs `./uninstall.sh --keep-data`
- **THEN** the CLI binary and shared templates are removed, systemd services are stopped/removed, but `~/.claude-secure/` is left intact

### Requirement: CLI binary removal
The script SHALL remove the `claude-secure` CLI binary from `/usr/local/bin/claude-secure` if it exists, or from `~/.local/bin/claude-secure` if that was the install location.

#### Scenario: Binary removed from system path
- **WHEN** `/usr/local/bin/claude-secure` exists
- **THEN** it is removed and `claude-secure` is no longer on PATH

#### Scenario: Binary removed from user path
- **WHEN** `/usr/local/bin/claude-secure` does not exist but `~/.local/bin/claude-secure` exists
- **THEN** `~/.local/bin/claude-secure` is removed

#### Scenario: Binary already absent
- **WHEN** neither path exists
- **THEN** the script logs a warning and continues without error

### Requirement: Config directory removal
The script SHALL prompt for confirmation before removing `~/.claude-secure/`, and only remove it after explicit `y` confirmation. Without `--keep-data`, the entire directory is removed.

#### Scenario: User confirms removal
- **WHEN** the script prompts and the user enters `y`
- **THEN** `~/.claude-secure/` is removed recursively

#### Scenario: User declines removal
- **WHEN** the script prompts and the user enters anything other than `y`
- **THEN** `~/.claude-secure/` is preserved and the script logs that it was skipped

#### Scenario: Non-interactive mode skips data removal
- **WHEN** stdin is not a TTY (piped/scripted invocation) and `--keep-data` is not set
- **THEN** the script logs a warning that `~/.claude-secure/` was not removed and prints the manual removal command

### Requirement: Shared templates removal
The script SHALL remove `/usr/local/share/claude-secure/` if it exists, using `sudo` if needed.

#### Scenario: Shared dir removed
- **WHEN** `/usr/local/share/claude-secure/` exists
- **THEN** it is removed recursively (with sudo if required)

#### Scenario: Shared dir absent
- **WHEN** `/usr/local/share/claude-secure/` does not exist
- **THEN** the script logs a warning and continues

### Requirement: Systemd service removal
The script SHALL stop, disable, and remove the `claude-secure-webhook`, `claude-secure-reaper`, and `claude-secure-reaper.timer` systemd units if `systemctl` is available and the units exist.

#### Scenario: Services stopped and removed
- **WHEN** `systemctl` is available and the units exist
- **THEN** each unit is stopped, disabled, its unit file removed from `/etc/systemd/system/`, and `systemctl daemon-reload` is called

#### Scenario: Systemd unavailable
- **WHEN** `systemctl` is not available (WSL2 without systemd)
- **THEN** the script logs that systemd is unavailable and prints the manual removal paths

#### Scenario: Unit does not exist
- **WHEN** a unit file is absent in `/etc/systemd/system/`
- **THEN** the script logs a warning and continues

### Requirement: Opt-in Docker image removal
The script SHALL support a `--remove-images` flag. Without this flag, the script SHALL print the names of installed Docker images and the command to remove them manually. With the flag, the script SHALL remove the Docker images built by the installer.

#### Scenario: Images listed when flag absent
- **WHEN** Docker images prefixed with `claude-secure` exist and `--remove-images` is not set
- **THEN** the script prints image names and the `docker rmi` command to remove them

#### Scenario: Images removed when flag present
- **WHEN** `--remove-images` is set and the Docker daemon is running
- **THEN** claude-secure Docker images are removed

#### Scenario: Docker unavailable
- **WHEN** `docker info` fails (daemon not running or docker not installed)
- **THEN** the script logs a warning and skips image removal without error

### Requirement: Webhook opt directory removal
The script SHALL remove `/opt/claude-secure/` if it exists, using `sudo` if needed.

#### Scenario: Opt dir removed
- **WHEN** `/opt/claude-secure/` exists
- **THEN** it is removed recursively (with sudo if required)

### Requirement: Graceful handling of missing items
The script SHALL NOT abort when an expected installed artifact is missing — it SHALL log a warning and continue with remaining removals.

#### Scenario: Missing artifact produces warning not error
- **WHEN** an expected path (binary, config dir, shared dir) does not exist
- **THEN** the script logs `[WARN] not found, skipping: <path>` and continues; exit code is 0

### Requirement: Summary output
The script SHALL print a summary at the end listing what was removed, what was skipped, and any manual steps remaining.

#### Scenario: Summary shown on completion
- **WHEN** the uninstall completes (with or without `--dry-run`)
- **THEN** the script prints a summary of removed items, skipped items, and any manual follow-up commands
