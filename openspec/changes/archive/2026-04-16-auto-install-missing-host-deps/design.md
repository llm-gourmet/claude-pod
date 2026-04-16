## Context

`check_dependencies()` in `install.sh` currently collects all missing deps into a single `missing` array and exits with an error listing them. The function runs after `macos_bootstrap_deps` (which already auto-installs brew deps on macOS), so auto-install precedent exists in the codebase. The installer requires root (`sudo`), so package installation is always available.

The webhook listener check (line ~439) is a separate, later guard — same pattern, separate fix needed there.

## Goals / Non-Goals

**Goals:**
- Auto-install `curl`, `jq`, `uuidgen`, `python3` when missing and a known package manager is present
- Single y/n confirmation before installing (list what will be installed)
- Detect package manager: `apt-get` (Debian/Ubuntu/WSL2), `dnf` (Fedora/RHEL), `pacman` (Arch)
- Post-install re-verify each package; fail clearly if still missing
- For `python3`: re-verify version ≥ 3.11 after install; show PPA hint if too old
- If no known package manager: fall through to current behavior (list + exit)

**Non-Goals:**
- Auto-installing `docker` or `docker compose` — too complex, user must do this consciously
- Auto-adding PPAs or third-party repos (e.g., deadsnakes) — too invasive
- macOS support — macOS path already handled by `macos_bootstrap_deps` via Homebrew
- Silent install (always prompt)

## Decisions

**D1: Split missing array into `auto_installable` and `manual_only`**

`docker` and `docker compose` go to `manual_only` always. The rest go to `auto_installable` when a package manager is detected. This keeps the existing error path intact for docker and unknown-PM cases.

**D2: Single prompt listing all auto-installable packages**

One `read -rp "Install missing packages? [y/N]: "` after listing them. Not per-package. Keeps UX simple and consistent with how the installer handles other choices.

**D3: Package name mapping per PM**

Each PM has different package names:

| Logical | apt-get | dnf | pacman |
|---------|---------|-----|--------|
| curl | curl | curl | curl |
| jq | jq | jq | jq |
| uuidgen | uuid-runtime | util-linux | util-linux |
| python3 | python3 | python3 | python3 |

Implemented as a simple `case "$pkg"` inside a `for` loop.

**D4: Post-install re-verify via `command -v` (and version check for python3)**

After the install block, re-run `command -v` for each package. For python3, re-run the version check. If any still fail, exit with an error — don't silently continue.

**D5: Webhook listener python3 check adopts same pattern**

Replace the hard `log_error + return 1` at line ~440 with an offer to auto-install, then re-check version. Keeps the two guards consistent.

## Risks / Trade-offs

- [Risk] `apt-get install` on WSL2 may require `apt-get update` first → Mitigation: run `apt-get update -qq` before install (quiet, non-fatal if it fails)
- [Risk] `python3` from package manager is < 3.11 on older Ubuntu → Mitigation: post-install version check + clear message pointing to `deadsnakes` PPA, no auto-PPA
- [Risk] User says y but doesn't have network → Mitigation: package manager exits non-zero, we catch it and report

## Migration Plan

No migration needed — purely additive. Existing behavior preserved when package manager not found or user declines.
