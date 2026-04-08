# Phase 04: Installation & Platform - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-09
**Phase:** 04-installation-platform
**Areas discussed:** Auth setup flow, CLI wrapper design, Workspace and config paths, WSL2 detection strategy
**Mode:** auto (all decisions auto-selected with recommended defaults)

---

## Auth Setup Flow

| Option | Description | Selected |
|--------|-------------|----------|
| Interactive prompt with env var fallback | Check env vars first, prompt if missing. OAuth recommended. | ✓ |
| Config file only | User edits config file manually, no interactive prompt | |
| Env vars only | Require env vars to be set before running installer | |

**User's choice:** Interactive prompt with env var fallback (auto-selected)
**Notes:** Matches project constraint that OAuth is primary auth method. Env var check first enables non-interactive CI usage.

---

## CLI Wrapper Design

| Option | Description | Selected |
|--------|-------------|----------|
| Shell wrapper with subcommands | Bash script in /usr/local/bin with start/stop/status/update | ✓ |
| Shell alias | Simple alias in .bashrc/.zshrc | |
| Docker compose profile | Use docker compose profiles to expose commands | |

**User's choice:** Shell wrapper with subcommands (auto-selected)
**Notes:** Provides discoverability and can set COMPOSE_FILE/WORKSPACE_PATH so claude-secure works from any directory.

---

## Workspace and Config Paths

| Option | Description | Selected |
|--------|-------------|----------|
| ~/.claude-secure/ for config, user-specified workspace | Config in user home, workspace prompted during install | ✓ |
| XDG directories | Config in $XDG_CONFIG_HOME, data in $XDG_DATA_HOME | |
| /opt/claude-secure/ | System-wide installation | |

**User's choice:** ~/.claude-secure/ for config, user-specified workspace (auto-selected)
**Notes:** Simple, predictable location. No root needed for config. Workspace path flexible.

---

## WSL2 Detection Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| /proc/version check | grep -qi microsoft /proc/version | ✓ |
| WSL_DISTRO_NAME env var | Check if WSL_DISTRO_NAME is set | |
| uname -r check | Check for -microsoft suffix in kernel version | |

**User's choice:** /proc/version check (auto-selected)
**Notes:** Most reliable across WSL2 distributions. Also check for Docker Desktop vs Docker CE.

---

## Claude's Discretion

- Exact wording of prompts and error messages
- Color/formatting in installer output
- Update mechanism details
- Dependency check ordering
- Shell completion

## Deferred Ideas

- Dynamic proxy env var generation from whitelist.json
- Shell completion for claude-secure CLI
- .desktop file creation
- Automatic Docker CE installation
