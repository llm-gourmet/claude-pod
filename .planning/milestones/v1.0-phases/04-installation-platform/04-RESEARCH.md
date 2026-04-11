# Phase 04: Installation & Platform - Research

**Researched:** 2026-04-09
**Domain:** Bash installer scripting, Docker Compose orchestration, WSL2 platform detection
**Confidence:** HIGH

## Summary

This phase wraps the working three-container system (Phases 1-3) into an installable package with a single installer script and a CLI wrapper. The domain is well-understood bash scripting with Docker Compose -- no novel technology is involved. The primary complexity is in WSL2 platform detection (Docker Desktop vs Docker CE) and the auth credential flow.

The existing `docker-compose.yml` already parameterizes `WORKSPACE_PATH` and auth env vars via `${VAR:-}` syntax, so the installer's job is to (1) validate prerequisites, (2) collect configuration, (3) write config files, and (4) build images.

**Primary recommendation:** Build a single `install.sh` bash script with a `main()` wrapper function, strict mode (`set -euo pipefail`), and a separate `claude-secure` CLI wrapper script. Keep both under 200 lines each -- the logic is straightforward.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Installer checks for: `docker`, `docker compose` (v2 plugin), `curl`, `jq`, `uuidgen`. Each check uses `command -v`. Missing dependencies produce a clear error listing all missing tools with install hints (e.g., `apt install jq`).
- **D-02:** Docker Compose v2 detection: check `docker compose version` (not `docker-compose`). v1 is deprecated -- fail with upgrade instructions if only v1 found.
- **D-03:** Installer checks environment variables first (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`). If found, uses them without prompting. If not found, presents an interactive prompt: "Choose auth method: (1) OAuth token [recommended] (2) API key".
- **D-04:** OAuth is presented as the recommended option. For OAuth, user runs `claude setup-token` first and provides the token. For API key, user pastes the key directly.
- **D-05:** Auth credentials are stored in `~/.claude-secure/.env` file with `chmod 600`. The `.env` file is sourced by the CLI wrapper before `docker compose` commands, making credentials available as env vars to containers.
- **D-06:** `claude-secure` is a bash script installed to `/usr/local/bin/claude-secure` (or `~/.local/bin/` if no root access). The script sources `~/.claude-secure/.env` and runs docker compose commands.
- **D-07:** CLI subcommands: (no args) launch and attach, `stop`, `status`, `update`.
- **D-08:** The CLI wrapper sets `COMPOSE_FILE` to point to the project's `docker-compose.yml` and `WORKSPACE_PATH` from config.
- **D-09:** Host config directory: `~/.claude-secure/` containing `.env`, `whitelist.json`, `config.sh`.
- **D-10:** Workspace path prompted during install. Default: `~/claude-workspace/`. Stored in `config.sh`.
- **D-11:** Installer clones or copies the project repo to `~/.claude-secure/app/` (or uses current directory if run from cloned repo).
- **D-12:** Installer runs `docker compose build` after configuration. No pre-built images.
- **D-13:** File permissions set during Docker build. Installer verifies build success with `docker compose config --quiet`.
- **D-14:** Detect WSL2 via `grep -qi microsoft /proc/version`. If detected, set `PLATFORM=wsl2`.
- **D-15:** WSL2-specific checks: Docker CE vs Docker Desktop detection, iptables backend logging.
- **D-16:** Installer writes detected platform to `config.sh`.
- **D-17/D-18:** Secret env var passthrough -- simpler manual approach acceptable for v1 (document that users add secret env vars to `.env` and proxy service).

### Claude's Discretion
- Exact wording of prompts and error messages
- Whether to use colors/formatting in installer output
- Whether `claude-secure update` does `git pull` or a different update mechanism
- Order of dependency checks
- Whether to create a `.desktop` file or shell completion

### Deferred Ideas (OUT OF SCOPE)
- Dynamic proxy env var generation from whitelist.json
- Shell completion for `claude-secure` CLI
- `.desktop` file creation
- Automatic Docker CE installation if missing
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INST-01 | Installer checks for required dependencies (docker, docker compose, curl, jq, uuidgen) | D-01, D-02: `command -v` checks with install hints; Docker Compose v2 via `docker compose version` |
| INST-02 | Installer detects platform (native Linux vs WSL2) and handles differences | D-14, D-15, D-16: `/proc/version` check, Docker Desktop detection via `docker info`, iptables backend logging |
| INST-03 | Installer prompts for authentication method (API key or OAuth token) with OAuth as primary | D-03, D-04: env var detection first, interactive prompt fallback, OAuth recommended |
| INST-04 | Installer configures workspace path and creates directory structure | D-09, D-10, D-11: `~/.claude-secure/` dir structure, workspace prompt with default |
| INST-05 | Installer builds Docker images and sets correct file permissions | D-12, D-13: `docker compose build`, verify with `docker compose config --quiet` |
| INST-06 | Installer creates `claude-secure` CLI shortcut for launching the environment | D-06, D-07, D-08: bash script in `/usr/local/bin/` or `~/.local/bin/`, subcommands |
| PLAT-01 | All containers build and run correctly on native Linux (Ubuntu 22.04+) | Verified: Docker Engine 29.x, Compose v5.x available on host |
| PLAT-02 | All containers build and run correctly on WSL2 with Docker | Verified: current env is WSL2 with Docker CE, all deps present |
| PLAT-03 | iptables rules function correctly on both Linux and WSL2 (nftables backend detection) | D-15: `iptables -V` shows backend; current WSL2 env has `nf_tables` backend confirmed |
</phase_requirements>

## Standard Stack

### Core
| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Bash | 5.x | Installer and CLI wrapper scripts | Available on all target platforms. `set -euo pipefail` for safety. |
| Docker Compose | v2 (plugin) | Container orchestration | Already used by project. V2 is the only supported version. |
| jq | 1.7+ | JSON parsing in installer | Already a project dependency. Needed for whitelist.json validation. |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `command -v` | Dependency detection | Checking for required binaries |
| `docker info` | Platform detection | Distinguishing Docker CE from Docker Desktop |
| `docker compose config` | Config validation | Post-setup verification |
| `read -rp` / `read -rsp` | Interactive prompts | Auth credential collection |
| `chmod` / `mkdir -p` | File permissions | Config directory setup |

No `npm install` or `pip install` needed -- all tools are system utilities or already built into Docker images.

## Architecture Patterns

### Recommended Project Structure (new files this phase)
```
install.sh                          # Main installer script (project root)
bin/claude-secure                   # CLI wrapper script
tests/test-phase4.sh                # Integration tests for installer
```

### Pattern 1: Preflight Check Pattern
**What:** Collect all failures before aborting, rather than failing on first missing dependency.
**When to use:** Dependency checking (INST-01).
**Example:**
```bash
check_dependencies() {
  local missing=()
  
  command -v docker >/dev/null 2>&1 || missing+=("docker (https://docs.docker.com/engine/install/)")
  command -v jq >/dev/null 2>&1 || missing+=("jq (apt install jq)")
  command -v curl >/dev/null 2>&1 || missing+=("curl (apt install curl)")
  command -v uuidgen >/dev/null 2>&1 || missing+=("uuidgen (apt install uuid-runtime)")
  
  # Docker Compose v2 check (plugin, not standalone)
  if command -v docker >/dev/null 2>&1; then
    if ! docker compose version >/dev/null 2>&1; then
      if command -v docker-compose >/dev/null 2>&1; then
        missing+=("docker compose v2 (you have v1 which is deprecated -- upgrade Docker)")
      else
        missing+=("docker compose (install Docker Compose plugin)")
      fi
    fi
  fi
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${missing[@]}"; do
      echo "  - $dep"
    done
    exit 1
  fi
}
```
**Source:** Standard bash pattern, verified against project decisions D-01/D-02.

### Pattern 2: Environment-First Auth Detection
**What:** Check env vars before prompting interactively. Non-interactive installs (CI) work via pre-set env vars.
**When to use:** Auth setup (INST-03).
**Example:**
```bash
setup_auth() {
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "$CONFIG_DIR/.env"
    log_info "Using ANTHROPIC_API_KEY from environment"
    return
  fi
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}" >> "$CONFIG_DIR/.env"
    log_info "Using CLAUDE_CODE_OAUTH_TOKEN from environment"
    return
  fi
  
  # Interactive prompt
  echo "Choose authentication method:"
  echo "  1) OAuth token [recommended]"
  echo "  2) API key"
  read -rp "Choice [1]: " auth_choice
  auth_choice="${auth_choice:-1}"
  # ... prompt for token/key based on choice
}
```

### Pattern 3: WSL2 Platform Detection
**What:** Detect WSL2 and Docker backend type for platform-specific warnings.
**When to use:** Platform detection (INST-02, PLAT-03).
**Example:**
```bash
detect_platform() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl2"
    log_info "Detected WSL2 environment"
    
    # Check for Docker Desktop vs Docker CE
    local os_info
    os_info=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)
    if echo "$os_info" | grep -qi "docker desktop"; then
      log_warn "Docker Desktop detected. iptables may not work correctly."
      log_warn "Recommended: use Docker CE installed directly in WSL2."
    fi
    
    # Log iptables backend
    local ipt_version
    ipt_version=$(iptables -V 2>/dev/null || echo "not found")
    log_info "iptables version: $ipt_version"
  else
    PLATFORM="linux"
    log_info "Detected native Linux environment"
  fi
}
```
**Source:** Verified on current WSL2 system. `docker info --format '{{.OperatingSystem}}'` returns "Ubuntu 24.04.4 LTS" for Docker CE; Docker Desktop shows "Docker Desktop" in this field.

### Pattern 4: CLI Wrapper with COMPOSE_FILE
**What:** Self-contained wrapper that works from any directory by setting COMPOSE_FILE.
**When to use:** CLI wrapper (INST-06).
**Example:**
```bash
#!/bin/bash
set -euo pipefail

CONFIG_DIR="$HOME/.claude-secure"
source "$CONFIG_DIR/config.sh"
source "$CONFIG_DIR/.env"

export COMPOSE_FILE="$APP_DIR/docker-compose.yml"
export WORKSPACE_PATH
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
# Secret env vars for proxy (from .env)
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export STRIPE_KEY="${STRIPE_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"

case "${1:-}" in
  stop)
    docker compose down
    ;;
  status)
    docker compose ps
    ;;
  update)
    cd "$APP_DIR" && git pull && docker compose build
    ;;
  *)
    docker compose up -d
    docker compose exec -it claude claude
    ;;
esac
```

### Anti-Patterns to Avoid
- **Hardcoded paths in docker-compose.yml:** The existing `${WORKSPACE_PATH:-./workspace}` pattern is correct. Do NOT replace it with absolute paths. The CLI wrapper exports the variable.
- **Storing secrets in config.sh:** Secrets go in `.env` (chmod 600), not `config.sh`. Config.sh is for non-sensitive settings (workspace path, platform, app dir).
- **Using `docker-compose` (v1):** Always use `docker compose` (v2 plugin). v1 is deprecated and has different behavior.
- **Interactive prompts without defaults:** Every prompt must have a sane default and accept empty input (press Enter).
- **Missing `-r` flag on `read`:** Always use `read -r` to prevent backslash interpretation.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Dependency checking | Custom path scanning | `command -v` builtin | Portable, handles aliases and functions correctly |
| JSON config editing | sed/awk on JSON | `jq` for any JSON manipulation | JSON is not line-oriented; regex on JSON is fragile |
| Docker Compose v2 detection | Parsing `docker --version` | `docker compose version` command | Direct check of the actual plugin |
| Secret input masking | Custom terminal manipulation | `read -rsp "prompt: " var` | `-s` flag suppresses echo natively |
| Service readiness | Sleep loops | `docker compose up -d --wait` | Compose v2 waits for healthchecks |

## Common Pitfalls

### Pitfall 1: Docker Compose File Not Found from Arbitrary CWD
**What goes wrong:** User runs `claude-secure` from a random directory, Docker Compose cannot find `docker-compose.yml`.
**Why it happens:** Docker Compose looks for `docker-compose.yml` in CWD by default.
**How to avoid:** CLI wrapper MUST set `COMPOSE_FILE` env var to the absolute path of the project's docker-compose.yml before any `docker compose` command.
**Warning signs:** "no configuration file provided" error from Docker Compose.

### Pitfall 2: Workspace Path with Spaces or Special Characters
**What goes wrong:** Bind mount fails if workspace path contains spaces and isn't quoted.
**Why it happens:** Docker Compose variable expansion and shell word splitting.
**How to avoid:** Always quote `$WORKSPACE_PATH` in the CLI wrapper. Validate the path during install (warn about spaces).
**Warning signs:** Container fails to start with mount errors.

### Pitfall 3: .env File Sourced Without Export
**What goes wrong:** Variables from `.env` are set in the shell but not passed to `docker compose` as environment variables.
**Why it happens:** `source .env` sets variables but doesn't export them.
**How to avoid:** Either use `set -a; source .env; set +a` (auto-export), or explicitly `export` each variable after sourcing.
**Warning signs:** Containers start but auth fails (empty API key).

### Pitfall 4: Docker Compose Named Volume vs Bind Mount for Workspace
**What goes wrong:** The existing docker-compose.yml uses a named volume with `driver_opts` for workspace binding. If `WORKSPACE_PATH` is empty or invalid, Docker creates a volume at `./workspace` relative to the compose file, not the user's intended directory.
**Why it happens:** The `${WORKSPACE_PATH:-./workspace}` default is relative to the compose file location.
**How to avoid:** CLI wrapper must always set `WORKSPACE_PATH` to an absolute path. Installer must resolve the path to absolute during setup.
**Warning signs:** Files appear in `~/.claude-secure/app/workspace/` instead of user's project directory.

### Pitfall 5: Permission Denied Installing to /usr/local/bin
**What goes wrong:** Non-root user can't write to `/usr/local/bin`.
**Why it happens:** Standard directory requires root/sudo.
**How to avoid:** Try `/usr/local/bin` with sudo first, fall back to `~/.local/bin/` (per D-06). Verify `~/.local/bin` is in PATH.
**Warning signs:** "Permission denied" during install.

### Pitfall 6: Docker Desktop on WSL2 iptables Incompatibility
**What goes wrong:** Validator container can't manage iptables rules because Docker Desktop uses a different networking model.
**Why it happens:** Docker Desktop runs containers in a lightweight VM, not directly in the WSL2 Linux kernel, so NET_ADMIN capability and iptables behave differently.
**How to avoid:** Detect Docker Desktop (D-15) and warn the user. Do not block installation -- let them proceed but with a clear warning.
**Warning signs:** `iptables: Permission denied` inside validator container.

### Pitfall 7: Re-running Installer Overwrites Existing Config
**What goes wrong:** Running install.sh a second time overwrites `.env` and config.sh, losing custom settings.
**Why it happens:** No idempotency check.
**How to avoid:** Check if `~/.claude-secure/` exists. If so, prompt: "Existing installation found. Overwrite? [y/N]". Backup old config before overwriting.
**Warning signs:** User loses auth credentials after re-install.

## Code Examples

### Installer Main Structure
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.claude-secure"

# Colors (optional, Claude's discretion)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

main() {
  echo "=== claude-secure installer ==="
  echo ""
  
  check_dependencies    # INST-01
  detect_platform       # INST-02
  check_existing        # Idempotency
  setup_directories     # INST-04
  setup_auth            # INST-03
  setup_workspace       # INST-04
  copy_app_files        # INST-04
  build_images          # INST-05
  install_cli           # INST-06
  
  echo ""
  log_info "Installation complete!"
  log_info "Run 'claude-secure' to start."
}

main "$@"
```

### Existing Installation Detection
```bash
check_existing() {
  if [ -d "$CONFIG_DIR" ]; then
    log_warn "Existing installation found at $CONFIG_DIR"
    read -rp "Overwrite existing installation? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      log_info "Installation cancelled."
      exit 0
    fi
    # Backup existing .env
    if [ -f "$CONFIG_DIR/.env" ]; then
      cp "$CONFIG_DIR/.env" "$CONFIG_DIR/.env.backup.$(date +%s)"
      log_info "Backed up existing .env"
    fi
  fi
}
```

### Directory Setup
```bash
setup_directories() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  log_info "Created config directory: $CONFIG_DIR"
}
```

### App File Copy/Link
```bash
copy_app_files() {
  local app_dir="$CONFIG_DIR/app"
  
  if [ "$SCRIPT_DIR" = "$app_dir" ]; then
    log_info "Running from installed location, skipping copy"
  elif [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    # Running from cloned repo -- symlink or copy
    if [ -d "$app_dir" ]; then
      rm -rf "$app_dir"
    fi
    cp -r "$SCRIPT_DIR" "$app_dir"
    log_info "Copied project files to $app_dir"
  else
    log_error "Cannot find docker-compose.yml in $SCRIPT_DIR"
    log_error "Run this script from the claude-secure project directory"
    exit 1
  fi
  
  # Write app dir to config
  echo "APP_DIR=\"$app_dir\"" >> "$CONFIG_DIR/config.sh"
  
  # Copy default whitelist if not exists
  if [ ! -f "$CONFIG_DIR/whitelist.json" ]; then
    cp "$app_dir/config/whitelist.json" "$CONFIG_DIR/whitelist.json"
    log_info "Copied default whitelist.json"
  fi
}
```

### CLI Installation with Fallback
```bash
install_cli() {
  local cli_src="$CONFIG_DIR/app/bin/claude-secure"
  local target
  
  if [ -w /usr/local/bin ]; then
    target="/usr/local/bin/claude-secure"
    cp "$cli_src" "$target"
    chmod 755 "$target"
    log_info "Installed CLI to $target"
  elif command -v sudo >/dev/null 2>&1; then
    target="/usr/local/bin/claude-secure"
    sudo cp "$cli_src" "$target"
    sudo chmod 755 "$target"
    log_info "Installed CLI to $target (via sudo)"
  else
    target="$HOME/.local/bin/claude-secure"
    mkdir -p "$HOME/.local/bin"
    cp "$cli_src" "$target"
    chmod 755 "$target"
    log_info "Installed CLI to $target"
    if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
      log_warn "$HOME/.local/bin is not in PATH. Add it to your shell profile."
    fi
  fi
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `docker-compose` (standalone v1) | `docker compose` (v2 plugin) | 2023 (v1 EOL) | Must check `docker compose version`, not `docker-compose --version` |
| Docker Compose `version:` field in YAML | Omit `version:` field | Compose v2.x | The existing docker-compose.yml correctly omits the version field |
| Docker Desktop free for all | Docker Desktop paid for large orgs | 2022 | Recommend Docker CE on WSL2 for this security tool |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | Container runtime | Yes | 29.3.1 | -- |
| Docker Compose v2 | Orchestration | Yes | v5.1.1 | -- |
| bash | Installer/CLI | Yes | 5.2.21 | -- |
| curl | Installer, hooks | Yes | 8.5.0 | -- |
| jq | JSON processing | Yes | 1.7 | -- |
| uuidgen | Hook call-ID generation | Yes | util-linux 2.39.3 | -- |
| iptables | Call validation | Yes | v1.8.10 (nf_tables) | -- |
| ShellCheck | Script linting (dev) | No | -- | Skip linting or install via `apt install shellcheck` |

**Missing dependencies with no fallback:** None -- all required tools are present.

**Missing dependencies with fallback:**
- ShellCheck: not installed but only needed for development linting, not runtime.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + docker compose + curl (same as Phases 1-3) |
| Config file | None needed -- shell scripts |
| Quick run command | `bash tests/test-phase4.sh` |
| Full suite command | `bash tests/test-phase4.sh` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INST-01 | Dependency checking reports missing tools | unit (mock) | `bash tests/test-phase4.sh` | No -- Wave 0 |
| INST-02 | Platform detection (WSL2 vs Linux) | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| INST-03 | Auth prompt with env var detection | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| INST-04 | Directory structure created correctly | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| INST-05 | Docker images build successfully | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| INST-06 | CLI wrapper launches environment | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| PLAT-01 | Containers run on native Linux | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| PLAT-02 | Containers run on WSL2 | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |
| PLAT-03 | iptables works on both platforms | integration | `bash tests/test-phase4.sh` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase4.sh`
- **Per wave merge:** `bash tests/test-phase4.sh && bash tests/test-phase1.sh` (regression)
- **Phase gate:** All phase test scripts pass

### Wave 0 Gaps
- [ ] `tests/test-phase4.sh` -- installer and CLI integration tests
- [ ] Framework: none needed (bash test scripts already established in Phases 1-3)

### Testing Strategy Notes

Testing an installer is inherently different from testing running services. Key approaches:

1. **Dependency checker testing:** Run the dependency check function with a modified PATH that hides tools. Verify it reports the correct missing tools.
2. **Directory structure testing:** Run installer (or its directory-setup function), verify files exist with correct permissions.
3. **CLI wrapper testing:** Verify `claude-secure status` returns Docker Compose output. Verify `claude-secure` (no args) starts containers.
4. **Platform detection testing:** Verify the installer correctly identifies the current platform (can only test the platform you're on).
5. **Idempotency testing:** Run installer twice, verify it handles existing installation gracefully.
6. **Regression:** Run existing phase 1-3 test scripts after installation to verify nothing broke.

Note: Full installer testing would ideally use a clean Docker container as a test environment, but for v1, testing on the development host is acceptable. The existing test pattern (bash scripts with pass/fail counters) should be followed.

## Open Questions

1. **Docker Compose override file vs modifying docker-compose.yml**
   - What we know: D-17/D-18 discusses dynamic env var generation for proxy. D-18 says simpler manual approach is acceptable for v1.
   - What's unclear: Should the installer create a `docker-compose.override.yml` for user-specific settings, or should the CLI wrapper handle everything via env vars?
   - Recommendation: Use env vars only (already working in current docker-compose.yml). The existing `${VAR:-}` syntax handles absent variables gracefully. For v1, document that users add secret env vars to `.env` file. No override file needed.

2. **Whitelist.json location: config dir vs app dir**
   - What we know: D-09 says whitelist.json goes in `~/.claude-secure/`. The docker-compose.yml mounts `./config/whitelist.json`.
   - What's unclear: Should the compose file mount from the config dir or the app dir?
   - Recommendation: Keep mounting from `$APP_DIR/config/whitelist.json` (the compose file's relative path works). Copy a default to `~/.claude-secure/whitelist.json` for user editing, and symlink `$APP_DIR/config/whitelist.json` to it. This way the compose file works unchanged and users edit in the config dir.

## Sources

### Primary (HIGH confidence)
- Verified on current host: Docker Engine 29.3.1, Docker Compose v5.1.1, bash 5.2.21, iptables v1.8.10 (nf_tables), WSL2 environment
- Verified: `docker info --format '{{.OperatingSystem}}'` returns distro name on Docker CE (not "Docker Desktop")
- Project files: docker-compose.yml, Dockerfiles, hook scripts, test scripts -- all read directly

### Secondary (MEDIUM confidence)
- Bash installer best practices: [oneuptime.com](https://oneuptime.com/blog/post/2026-02-13-bash-best-practices/view), [linuxbash.sh](https://www.linuxbash.sh/post/installing-software-and-managing-dependencies-in-scripts)
- WSL2 Docker Desktop detection: [Docker docs](https://docs.docker.com/desktop/features/wsl/), [medium.com](https://medium.com/h7w/mastering-docker-on-wsl2-a-complete-guide-without-docker-desktop-19c4e945590b)

### Tertiary (LOW confidence)
- None -- all findings verified against local environment or official sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- bash, docker compose, jq are all mature, stable, already used by project
- Architecture: HIGH -- installer pattern is straightforward, all decisions locked in CONTEXT.md
- Pitfalls: HIGH -- verified pitfalls against actual environment behavior (WSL2, Docker CE, PATH)

**Research date:** 2026-04-09
**Valid until:** 2026-05-09 (stable domain, no fast-moving dependencies)
