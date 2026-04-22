## Context

`install.sh` places files in several locations: the config directory `~/.claude-secure/`, the CLI binary at `/usr/local/bin/claude-secure` (or `~/.local/bin/`), shared templates at `/usr/local/share/claude-secure/`, and optionally systemd units and `/opt/claude-secure/`. The installer also builds Docker images and installs git hooks into the project's `.git/hooks/` directory.

The uninstaller mirrors `install.sh` in structure: it sources `lib/platform.sh` for the same user/home resolution logic, discovers what was installed from known paths, and removes items in reverse installation order.

## Goals / Non-Goals

**Goals:**
- Remove every artifact placed by `install.sh` without leaving orphans
- Provide `--dry-run` to preview removals before committing
- Provide `--keep-data` to remove binaries/services while preserving user data in `~/.claude-secure/`
- Prompt for confirmation before deleting user data (`~/.claude-secure/`)
- Handle partial installs gracefully — warn on missing items, don't abort
- Mirror `install.sh`'s sudo escalation logic (try direct, then sudo)

**Non-Goals:**
- Uninstalling host package manager dependencies (docker, jq, curl) — claude-secure did not install these
- Purging Docker volumes or user workspaces created at runtime
- Handling macOS Docker Desktop — same constraint as the installer (Linux/WSL2 only)

## Decisions

**1. Source `lib/platform.sh` for user/home resolution**

The same `SUDO_USER`/`USER` dance and `getent`/`dscl` fallbacks from `install.sh` must be replicated. Sourcing the shared library avoids drift. Alternative: inline the logic — rejected because it creates two copies to keep in sync.

**2. Read `~/.claude-secure/config.sh` for `APP_DIR` and `PLATFORM`**

Rather than re-detecting, source the existing `config.sh` to know where app files were installed and which platform was used. If `config.sh` is missing (partial install), fall back to defaults. Alternative: re-detect everything — more fragile and doesn't handle the `~/.local/bin` vs `/usr/local/bin` split correctly without running the same detection logic.

**3. Removal order: services → binary → shared → data**

Stop and disable systemd services first (avoids "unit not found" during removal), then remove the binary (prevents new processes starting), then shared templates, then the config dir last (it contains the data users care most about). Alternative: any order — rejected because removing the config dir first would leave a running service pointing at nothing.

**4. Docker image removal is opt-in via `--remove-images` flag**

Docker images are large but not harmful to leave. Some users may want to keep them for reinstall speed. Default behavior: warn that images exist and print the `docker rmi` command. With `--remove-images`: remove them. Alternative: always remove — too aggressive; image rebuild is slow.

**5. `--dry-run` prints `[DRY-RUN] would remove: <path>` for each action**

Every destructive operation is wrapped in a `run_or_dry` helper: `run_or_dry rm -rf "$path"` either prints or executes. This single abstraction makes dry-run correct by construction rather than a separate code path.

## Risks / Trade-offs

- **Interrupted uninstall leaves partial state** → Mitigation: each removal step is idempotent (check before delete); the script can be re-run safely.
- **Docker daemon not running** → Mitigation: wrap `docker` calls in `if docker info >/dev/null 2>&1`; warn and continue if unavailable.
- **Systemd not available (WSL2 without systemd)** → Mitigation: check `command -v systemctl` before any systemd operations; skip with a note.
- **User ran installer as root (SUDO_USER not set)** → Mitigation: same fallback as installer — `${SUDO_USER:-$USER}`.
- **`~/.local/bin/claude-secure` vs `/usr/local/bin/claude-secure`** → Mitigation: check both paths and remove whichever exists.
