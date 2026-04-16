## Why

When `install.sh` finds missing host dependencies, it aborts and lists what the user must install manually. For simple packages this is unnecessary friction — the installer already runs as root and can install them directly.

## What Changes

- After detecting missing installable packages (`curl`, `jq`, `uuidgen`, `python3`), the installer prompts the user to auto-install them instead of aborting
- Package manager is detected automatically (`apt-get`, `dnf`, `pacman`)
- `docker` and `docker compose` remain manual-only (too complex, too consequential)
- After auto-installing `python3`, version is checked (3.11+ required for webhook listener); if version is insufficient, a clear error with PPA instructions is shown
- If no supported package manager is found, falls back to current behavior (list + abort)

## Capabilities

### New Capabilities

- `host-dep-auto-install`: Detect installable missing packages, prompt user, install via the host package manager, then re-verify

### Modified Capabilities

<!-- none — no existing specs to delta -->

## Impact

- `install.sh`: `check_dependencies()` — split missing deps into installable vs. manual; add auto-install prompt + package manager detection + post-install re-verification
- `install.sh`: webhook listener python3 check (line ~440) — same pattern: offer auto-install before hard error
- No changes to `bin/claude-secure`, proxy, validator, or docker-compose
