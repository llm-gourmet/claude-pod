#!/usr/bin/env bash
# Phase 18 PORT-02: bash 4+ re-exec guard. Apple ships bash 3.2.57 forever;
# we re-exec into brew bash 5 so the rest of this script can use bash 4+ idioms.
# This block MUST remain bash 3.2 safe: no double-bracket tests, no lowercasing, no associative arrays.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  if command -v brew >/dev/null 2>&1; then
    __brew_bash="$(brew --prefix 2>/dev/null)/bin/bash"
    if [ -x "$__brew_bash" ]; then
      exec "$__brew_bash" "$0" "$@"
    fi
  fi
  echo "ERROR: bash 4+ required. On macOS run: brew install bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"
# Phase 18 PORT-01: prepend gnubin to PATH so plain date/stat/readlink/realpath
# resolve to GNU coreutils on macOS. No-op on Linux/WSL2.
if command -v claude_secure_bootstrap_path >/dev/null 2>&1; then
  claude_secure_bootstrap_path || true
fi

_invoking_user="${SUDO_USER:-$USER}"
_invoking_home="$(getent passwd "$_invoking_user" | cut -d: -f6)"
if [ -z "$_invoking_home" ]; then
  echo "ERROR: Could not resolve home directory for user '$_invoking_user'" >&2
  exit 1
fi
CONFIG_DIR="$_invoking_home/.claude-secure"
PLATFORM=""
app_dir=""
WITH_WEBHOOK=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# PLAT-03 + PLAT-04: detect Homebrew and bootstrap GNU bash + coreutils + jq.
# Called from check_dependencies() on macOS BEFORE the apt-style command audit.
macos_bootstrap_deps() {
  # PLAT-03: detect brew, do NOT auto-install
  if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew is required on macOS but is not installed."
    log_error ""
    log_error "Install Homebrew by running:"
    log_error "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    log_error ""
    log_error "Then re-run this installer."
    exit 1
  fi

  # PLAT-04: install bash, coreutils, jq via brew BEFORE any other macOS step
  log_info "Bootstrapping GNU tools via Homebrew..."
  local formula
  for formula in bash coreutils jq; do
    if brew list --formula "$formula" >/dev/null 2>&1; then
      log_info "  $formula already installed"
    else
      log_info "  installing $formula..."
      if ! brew install "$formula"; then
        log_error "brew install $formula failed"
        exit 1
      fi
    fi
  done

  # Post-bootstrap verification — fail loudly if anything is still missing
  local brew_prefix
  brew_prefix="$(brew --prefix 2>/dev/null)"
  if [ -z "$brew_prefix" ]; then
    log_error "brew --prefix returned empty after install"
    exit 1
  fi
  local missing=()
  [ -x "$brew_prefix/bin/bash" ] || missing+=("bash (run: brew install bash)")
  [ -d "$brew_prefix/opt/coreutils/libexec/gnubin" ] || missing+=("coreutils (run: brew install coreutils)")
  command -v jq >/dev/null 2>&1 || missing+=("jq (run: brew install jq)")
  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "Post-bootstrap verification FAILED. Still missing:"
    for m in "${missing[@]}"; do
      log_error "  - $m"
    done
    exit 1
  fi

  log_info "macOS bootstrap complete (brew_prefix=$brew_prefix)"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-webhook) WITH_WEBHOOK=1; shift ;;
      *) shift ;;
    esac
  done
}

# PLAT-05: verify Docker Desktop >= 4.44.3 is installed and running on macOS.
# Called from check_dependencies() only when detect_platform returns "macos".
# Requires GNU sort on PATH (for `sort -V`) — claude_secure_bootstrap_path
# must have run earlier in the Phase 18 prologue (line 23) before this.
check_docker_desktop_version() {
  local min_version="4.44.3"

  # 1. Docker daemon running?
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker Desktop is not running."
    log_error "Start Docker Desktop from /Applications/Docker.app and re-run the installer."
    exit 1
  fi

  # 2. Is this Docker Desktop (vs plain Docker Engine)?
  local server_line
  server_line="$(docker version 2>/dev/null | grep 'Server: Docker Desktop' || true)"
  if [ -z "$server_line" ]; then
    log_warn "Docker Desktop not detected in 'docker version' output."
    log_warn "If you are running plain Docker Engine, ensure it satisfies the equivalent of Docker Desktop >= ${min_version}."
    return 0
  fi

  # 3. Parse the version string "4.44.3" from "Server: Docker Desktop 4.44.3 (172823)".
  local dd_version
  dd_version="$(echo "$server_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$dd_version" ]; then
    log_warn "Could not parse Docker Desktop version string: ${server_line}"
    log_warn "Continuing — ensure Docker Desktop >= ${min_version} is installed."
    return 0
  fi

  # 4. Compare with GNU sort -V (Phase 18 prologue guarantees gnubin on PATH).
  # Semantics: printf both versions, sort -V, take the first line. If that
  # line equals dd_version AND dd_version != min_version, dd_version is older.
  local lowest
  lowest="$(printf '%s\n%s\n' "$min_version" "$dd_version" | sort -V | head -1)"
  if [ "$lowest" = "$dd_version" ] && [ "$dd_version" != "$min_version" ]; then
    log_error "Docker Desktop ${dd_version} is installed but >= ${min_version} is required."
    log_error "Upgrade Docker Desktop: https://docs.docker.com/desktop/release-notes/"
    exit 1
  fi

  log_info "Docker Desktop ${dd_version} satisfies >= ${min_version}"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt-get"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo ""
  fi
}

# Map logical command name to the package name for the given package manager.
pm_package_name() {
  local cmd="$1" pm="$2"
  case "$cmd" in
    uuidgen) case "$pm" in apt-get) echo "uuid-runtime" ;; *) echo "util-linux" ;; esac ;;
    *) echo "$cmd" ;;
  esac
}

check_dependencies() {
  local auto_installable=()  # commands that can be auto-installed
  local manual_only=()       # must be installed manually

  # PLAT-03 + PLAT-04: on macOS, install brew deps BEFORE auditing apt-style packages
  local _plat
  _plat="$(detect_platform)"
  if [ "$_plat" = "macos" ]; then
    macos_bootstrap_deps
  fi

  local _pm
  _pm="$(detect_package_manager)"

  # docker and docker-compose are always manual
  command -v docker >/dev/null 2>&1 || manual_only+=("docker (https://docs.docker.com/engine/install/)")

  # Docker Compose v2 check (plugin, not standalone)
  if command -v docker >/dev/null 2>&1; then
    if ! docker compose version >/dev/null 2>&1; then
      if command -v docker-compose >/dev/null 2>&1; then
        manual_only+=("docker compose v2 (you have v1 which is deprecated -- upgrade Docker)")
      else
        manual_only+=("docker compose (install Docker Compose plugin)")
      fi
    fi
  fi

  # PLAT-05: macOS-only Docker Desktop version gate.
  if [ "$_plat" = "macos" ]; then
    check_docker_desktop_version
  fi

  # Simple packages: auto-installable when a PM is available.
  # Explicit per-command checks preserve grep-ability for test assertions.
  command -v curl    >/dev/null 2>&1 || { [ -n "$_pm" ] && auto_installable+=(curl)    || manual_only+=("curl (install manually)"); }
  command -v jq      >/dev/null 2>&1 || { [ -n "$_pm" ] && auto_installable+=(jq)      || manual_only+=("jq (install manually)"); }
  command -v uuidgen >/dev/null 2>&1 || { [ -n "$_pm" ] && auto_installable+=(uuidgen) || manual_only+=("uuidgen (install manually)"); }
  command -v python3 >/dev/null 2>&1 || { [ -n "$_pm" ] && auto_installable+=(python3) || manual_only+=("python3 (install manually)"); }

  # Offer auto-install for installable packages
  if [ ${#auto_installable[@]} -gt 0 ]; then
    echo ""
    echo "Missing packages that can be installed automatically:"
    for _cmd in "${auto_installable[@]}"; do
      echo "  - $(pm_package_name "$_cmd" "$_pm") (provides: $_cmd)"
    done
    read -rp "Install missing packages with ${_pm}? [y/N]: " _ans
    if [[ "$_ans" =~ ^[Yy]$ ]]; then
      local _pkgs=()
      for _cmd in "${auto_installable[@]}"; do
        _pkgs+=("$(pm_package_name "$_cmd" "$_pm")")
      done
      case "$_pm" in
        apt-get) apt-get update -qq && apt-get install -y "${_pkgs[@]}" ;;
        dnf)     dnf install -y "${_pkgs[@]}" ;;
        pacman)  pacman -Sy --noconfirm "${_pkgs[@]}" ;;
      esac

      # Re-verify each installed command
      for _cmd in "${auto_installable[@]}"; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
          log_error "Failed to install '$_cmd'. Please install it manually and re-run."
          exit 1
        fi
      done

      # python3 version check after install
      if printf '%s\n' "${auto_installable[@]}" | grep -q '^python3$'; then
        local _py_ver
        _py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'; then
          log_error "Python 3.11+ required (found $_py_ver)."
          log_error "On Ubuntu/Debian: sudo add-apt-repository ppa:deadsnakes/ppa && sudo apt-get install python3.11"
          exit 1
        fi
      fi
    else
      manual_only+=("${auto_installable[@]}")
    fi
  fi

  if [ ${#manual_only[@]} -gt 0 ]; then
    log_error "Missing required dependencies:"
    for dep in "${manual_only[@]}"; do
      echo "  - $dep"
    done
    exit 1
  fi

  log_info "All dependencies satisfied"
}

check_existing() {
  if [ -d "$CONFIG_DIR" ]; then
    log_warn "Existing installation found at $CONFIG_DIR"
    read -rp "Overwrite existing installation? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      log_info "Installation cancelled."
      exit 0
    fi
    # Backup existing .env (check both old root-level and new instance location)
    if [ -f "$CONFIG_DIR/.env" ]; then
      cp "$CONFIG_DIR/.env" "$CONFIG_DIR/.env.backup.$(date +%s)"
      log_info "Backed up existing root-level .env"
    fi
    if [ -f "$CONFIG_DIR/profiles/default/.env" ]; then
      cp "$CONFIG_DIR/profiles/default/.env" "$CONFIG_DIR/profiles/default/.env.backup.$(date +%s)"
      log_info "Backed up existing default profile .env"
    fi
  fi
}

setup_directories() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  log_info "Created config directory: $CONFIG_DIR"

  # Create profiles directory for profile-based configuration
  mkdir -p "$CONFIG_DIR/profiles"
  log_info "Created profiles directory: $CONFIG_DIR/profiles"

  # Create logs directory for service logging (LOG_DIR in docker-compose)
  # chmod 755: owner has full access, others can read/traverse.
  # Container processes write via the bind mount where Docker maps UIDs.
  # If container UID mismatch causes write failures, the CLI wrapper's
  # mkdir -p at launch time can adjust permissions as needed.
  mkdir -p "$CONFIG_DIR/logs"
  # 777 required: three containers write as different UIDs (claude:1001, node:1000, root:0)
  chmod 777 "$CONFIG_DIR/logs"
  log_info "Created logs directory: $CONFIG_DIR/logs"
}

setup_auth() {
  local env_file="$CONFIG_DIR/profiles/default/.env"
  mkdir -p "$CONFIG_DIR/profiles/default"

  # Unified env-file writer. Rejects empty or newline-tainted values and writes
  # the file in a single redirection group so a mid-write abort can never leave
  # a truncated .env on disk. Optional args $3/$4: extra var name/value pair
  # (written only when value is non-empty, e.g. REAL_ANTHROPIC_BASE_URL).
  write_env_file() {
    local var_name="$1"
    local value="$2"
    local extra_name="${3:-}"
    local extra_value="${4:-}"
    if [ -z "$value" ]; then
      log_error "${var_name} was empty. Installation aborted — no .env written."
      exit 1
    fi
    case "$value" in
      *$'\n'*|*$'\r'*)
        log_error "${var_name} contains a newline or carriage return (paste buffer leakage?)."
        log_error "Installation aborted — no .env written."
        exit 1
        ;;
    esac
    {
      printf '%s=%s\n' "$var_name" "$value"
      if [ -n "$extra_name" ] && [ -n "$extra_value" ]; then
        printf '%s=%s\n' "$extra_name" "$extra_value"
      fi
      printf '\n'
      printf '# Add secrets below (must match env_var in whitelist.json)\n'
      printf '# Example: GITHUB_TOKEN=ghp_your_token_here\n'
    } > "$env_file"
    chmod 600 "$env_file"
  }

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    write_env_file "ANTHROPIC_API_KEY" "$ANTHROPIC_API_KEY"
    log_info "Using ANTHROPIC_API_KEY from environment"
    return
  fi

  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    write_env_file "CLAUDE_CODE_OAUTH_TOKEN" "$CLAUDE_CODE_OAUTH_TOKEN"
    log_info "Using CLAUDE_CODE_OAUTH_TOKEN from environment"
    return
  fi

  # Interactive prompt — require a real TTY on stdin.
  if [ ! -t 0 ]; then
    log_error "No TTY on stdin and neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN is set."
    log_error "Re-run with the token exported, e.g.:"
    log_error "  sudo -E CLAUDE_CODE_OAUTH_TOKEN=\"\$CLAUDE_CODE_OAUTH_TOKEN\" bash install.sh"
    log_error "Or run the installer from an interactive terminal."
    exit 1
  fi

  echo ""
  echo "Choose authentication method:"
  echo "  1) OAuth token [recommended]"
  echo "  2) API key"
  read -rp "Choice [1]: " auth_choice
  auth_choice="${auth_choice:-1}"

  case "$auth_choice" in
    2)
      read -rsp "API key: " key
      echo ""
      if [ -z "$key" ]; then
        log_error "API key was empty. Installation aborted — no .env written."
        exit 1
      fi
      echo "  Base URL (optional — leave empty for default Anthropic endpoint)"
      echo "  e.g. https://yourcompany.com/anthropic/v1"
      read -rp "Base URL [https://api.anthropic.com]: " base_url
      write_env_file "ANTHROPIC_API_KEY" "$key" "REAL_ANTHROPIC_BASE_URL" "$base_url"
      log_info "API key saved"
      ;;
    *)
      echo "Run 'claude setup-token' first to get your OAuth token."
      read -rsp "OAuth token: " token
      echo ""
      if [ -z "$token" ]; then
        log_error "OAuth token was empty. Installation aborted — no .env written."
        log_error "Get your token with: claude setup-token"
        exit 1
      fi
      write_env_file "CLAUDE_CODE_OAUTH_TOKEN" "$token"
      log_info "OAuth token saved"
      ;;
  esac
}

setup_workspace() {
  read -rp "Workspace path [$_invoking_home/claude-workspace]: " ws_path
  ws_path="${ws_path:-$_invoking_home/claude-workspace}"

  # Resolve to absolute path
  ws_path="$(realpath -m "$ws_path")"

  mkdir -p "$ws_path"
  chown "$_invoking_user:$_invoking_user" "$ws_path"

  # Write global config (APP_DIR written later by copy_app_files)
  cat > "$CONFIG_DIR/config.sh" <<CONF
PLATFORM="$PLATFORM"
CONF

  # Write profile config (workspace is per-profile)
  mkdir -p "$CONFIG_DIR/profiles/default"
  jq -n --arg ws "$ws_path" '{"workspace": $ws}' > "$CONFIG_DIR/profiles/default/profile.json"

  log_info "Workspace: $ws_path"
}

copy_app_files() {
  app_dir="$CONFIG_DIR/app"

  if [ "$SCRIPT_DIR" = "$app_dir" ]; then
    log_info "Running from installed location, skipping copy"
  elif [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    rm -rf "$app_dir" 2>/dev/null || true
    cp -r "$SCRIPT_DIR" "$app_dir"
    log_info "Copied project files to $app_dir"
  else
    log_error "Cannot find docker-compose.yml in $SCRIPT_DIR. Run from the claude-secure project directory."
    exit 1
  fi

  # Append APP_DIR to config.sh
  echo "APP_DIR=\"$app_dir\"" >> "$CONFIG_DIR/config.sh"

  # Copy whitelist template to default profile
  cp "$app_dir/config/whitelist.json" "$CONFIG_DIR/profiles/default/whitelist.json"
  log_info "Copied whitelist template to default profile"
}

build_images() {
  log_info "Building Docker images..."
  cd "$app_dir" && docker compose build
  docker compose config --quiet
  log_info "Docker images built successfully"
}

install_git_hooks() {
  local hooks_src="$app_dir/git-hooks"
  local hooks_dst
  hooks_dst="$(git -C "$app_dir" rev-parse --git-dir 2>/dev/null)/hooks" || return 0

  if [ ! -d "$hooks_src" ]; then
    return 0
  fi

  for hook in "$hooks_src"/*; do
    [ -f "$hook" ] || continue
    local name
    name="$(basename "$hook")"
    cp "$hook" "$hooks_dst/$name"
    chmod +x "$hooks_dst/$name"
  done
  log_info "Installed git hooks from git-hooks/"
}

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
    target="$_invoking_home/.local/bin/claude-secure"
    mkdir -p "$_invoking_home/.local/bin"
    cp "$cli_src" "$target"
    chmod 755 "$target"
    log_info "Installed CLI to $target"
    if ! echo "$PATH" | tr ':' '\n' | grep -q "$_invoking_home/.local/bin"; then
      log_warn "$_invoking_home/.local/bin is not in PATH. Add it to your shell profile."
    fi
  fi
}

install_webhook_service() {
  # Gate: either --with-webhook flag, or interactive confirm. Non-interactive + no flag = skip.
  if [ "$WITH_WEBHOOK" -ne 1 ]; then
    if [ -t 0 ]; then
      read -rp "Install webhook listener as a systemd service? [y/N]: " ans
      [[ "$ans" =~ ^[Yy]$ ]] || return 0
    else
      return 0
    fi
  fi

  log_info "Installing webhook listener..."

  # 1. Python 3.11+ check — offer auto-install if missing
  if ! command -v python3 >/dev/null 2>&1; then
    local _wh_pm
    _wh_pm="$(detect_package_manager)"
    if [ -n "$_wh_pm" ]; then
      echo "python3 is required for the webhook listener."
      read -rp "Install python3 with ${_wh_pm}? [y/N]: " _ans
      if [[ "$_ans" =~ ^[Yy]$ ]]; then
        case "$_wh_pm" in
          apt-get) apt-get update -qq && apt-get install -y python3 ;;
          dnf)     dnf install -y python3 ;;
          pacman)  pacman -Sy --noconfirm python3 ;;
        esac
      fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      log_error "python3 is required for the webhook listener. Install with: apt install python3"
      return 1
    fi
  fi
  local py_ver
  py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'; then
    log_error "Python 3.11+ required for the webhook listener (found $py_ver)."
    log_error "On Ubuntu/Debian: sudo add-apt-repository ppa:deadsnakes/ppa && sudo apt-get install python3.11"
    return 1
  fi

  # 2. systemctl check (not an error on WSL2-without-systemd; just skip)
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not found. Cannot install the webhook service on this host."
    return 0
  fi

  # 3. WSL2 systemd gate (D-26: warn, do not block)
  local wsl2_no_systemd=0
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if [ ! -f /etc/wsl.conf ] || ! grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf; then
      wsl2_no_systemd=1
      log_warn "WSL2 detected without systemd enabled in /etc/wsl.conf."
      log_warn "The webhook listener runs as a systemd service. To enable systemd in WSL2:"
      echo ""
      echo "  Add the following to /etc/wsl.conf:"
      echo ""
      echo "      [boot]"
      echo "      systemd=true"
      echo ""
      echo "  Then from a Windows PowerShell / CMD prompt run:"
      echo ""
      echo "      wsl.exe --shutdown"
      echo ""
      echo "  After WSL restarts, re-run the installer or start the service manually:"
      echo ""
      echo "      sudo systemctl enable --now claude-secure-webhook"
      echo ""
      log_warn "Installer will copy files but skip 'systemctl enable --now'."
    fi
  fi

  # 4. Resolve invoking user's home (D-24 + home-directory gotcha)
  local invoking_user invoking_home
  invoking_user="${SUDO_USER:-$USER}"
  invoking_home=$(getent passwd "$invoking_user" | cut -d: -f6 || true)
  if [ -z "$invoking_home" ]; then
    log_error "Could not resolve home directory for user '$invoking_user'"
    return 1
  fi
  log_info "Webhook paths will be rooted at: $invoking_home/.claude-secure/"

  # 5. Copy listener.py (always overwrite -- latest code ships)
  sudo mkdir -p /opt/claude-secure/webhook
  sudo cp "$app_dir/webhook/listener.py" /opt/claude-secure/webhook/listener.py
  sudo chmod 755 /opt/claude-secure/webhook/listener.py
  log_info "Copied listener.py to /opt/claude-secure/webhook/"

  # 5b. Copy default prompt templates (D-12: always refresh -- latest templates ship)
  sudo mkdir -p /opt/claude-secure/webhook/templates
  if [ -d "$app_dir/webhook/templates" ]; then
    sudo cp "$app_dir/webhook/templates/"*.md /opt/claude-secure/webhook/templates/
    sudo chmod 644 /opt/claude-secure/webhook/templates/*.md
    log_info "Copied default templates to /opt/claude-secure/webhook/templates/"
  else
    log_warn "Source directory $app_dir/webhook/templates not found -- skipping template copy"
  fi

  # 5c. Copy default Phase 16 report templates (always refresh -- latest templates ship).
  # Mirrors step 5b for the report-templates directory used by resolve_report_template
  # as the final fallback in the report-template resolution chain. We cp individual
  # files (never rm -rf) so operator-added custom templates in the same directory
  # survive reinstall.
  sudo mkdir -p /opt/claude-secure/webhook/report-templates
  if [ -d "$app_dir/webhook/report-templates" ]; then
    sudo cp "$app_dir/webhook/report-templates/"*.md /opt/claude-secure/webhook/report-templates/
    sudo chmod 644 /opt/claude-secure/webhook/report-templates/*.md
    sudo chmod 755 /opt/claude-secure/webhook/report-templates
    log_info "Copied default report templates to /opt/claude-secure/webhook/report-templates/"
  else
    log_warn "Source directory $app_dir/webhook/report-templates not found -- skipping report template copy"
  fi

  # 5d. Install reaper systemd unit + timer (Phase 17).
  # Mirrors step 7's pattern for the webhook listener: cp into
  # /etc/systemd/system/, mode 644. daemon-reload happens once in step 7 and
  # covers BOTH the reaper units (newly added here) and the webhook unit's
  # updated hardening directives from Phase 17 wave 1a. Always refresh: the
  # repo copies are the source of truth, no rm -rf of the destination.
  sudo cp "$app_dir/webhook/claude-secure-reaper.service" /etc/systemd/system/claude-secure-reaper.service
  sudo chmod 644 /etc/systemd/system/claude-secure-reaper.service
  sudo cp "$app_dir/webhook/claude-secure-reaper.timer" /etc/systemd/system/claude-secure-reaper.timer
  sudo chmod 644 /etc/systemd/system/claude-secure-reaper.timer
  log_info "Installed systemd unit /etc/systemd/system/claude-secure-reaper.service"
  log_info "Installed systemd unit /etc/systemd/system/claude-secure-reaper.timer"

  # 6. Copy config template (idempotent -- never overwrite existing config)
  sudo mkdir -p /etc/claude-secure
  if [ ! -f /etc/claude-secure/webhook.json ]; then
    sed \
      -e "s|__REPLACED_BY_INSTALLER__PROFILES__|${invoking_home}/.claude-secure/profiles|" \
      -e "s|__REPLACED_BY_INSTALLER__EVENTS__|${invoking_home}/.claude-secure/events|" \
      -e "s|__REPLACED_BY_INSTALLER__LOGS__|${invoking_home}/.claude-secure/logs|" \
      "$app_dir/webhook/config.example.json" | sudo tee /etc/claude-secure/webhook.json > /dev/null
    sudo chmod 644 /etc/claude-secure/webhook.json
    log_info "Installed default config at /etc/claude-secure/webhook.json"
  else
    log_info "Existing /etc/claude-secure/webhook.json preserved (no overwrite)"
  fi

  # 7. Install systemd unit file
  sudo cp "$app_dir/webhook/claude-secure-webhook.service" /etc/systemd/system/claude-secure-webhook.service
  sudo chmod 644 /etc/systemd/system/claude-secure-webhook.service
  sudo systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload failed (likely WSL2-no-systemd)"
  log_info "Installed systemd unit /etc/systemd/system/claude-secure-webhook.service"

  # 8. Enable + start (unless WSL2 gated)
  if [ "$wsl2_no_systemd" -eq 1 ]; then
    log_warn "Skipping 'systemctl enable --now' due to WSL2 systemd gate."
    log_warn "After enabling systemd in WSL2, run: sudo systemctl enable --now claude-secure-webhook"
  else
    if sudo systemctl enable --now claude-secure-webhook 2>/dev/null; then
      sleep 1
      if sudo systemctl is-active --quiet claude-secure-webhook; then
        log_info "Webhook listener is active -- tail logs with: journalctl -u claude-secure-webhook -f"
      else
        log_error "Webhook listener failed to start. Check: journalctl -u claude-secure-webhook"
        return 1
      fi
    else
      log_warn "Could not enable claude-secure-webhook (systemctl enable failed)."
      log_warn "Manually enable later with: sudo systemctl enable --now claude-secure-webhook"
    fi
  fi

  # 8b. Enable + start reaper timer (Phase 17; subject to the same WSL2 gate as step 8).
  if [ "$wsl2_no_systemd" -eq 1 ]; then
    log_warn "Skipping 'systemctl enable --now claude-secure-reaper.timer' due to WSL2 systemd gate."
    log_warn "After enabling systemd in WSL2, run: sudo systemctl enable --now claude-secure-reaper.timer"
  else
    if sudo systemctl enable --now claude-secure-reaper.timer 2>/dev/null; then
      if sudo systemctl is-active --quiet claude-secure-reaper.timer; then
        log_info "Reaper timer active -- runs every 5 minutes. View activity: journalctl -u claude-secure-reaper -f"
      else
        log_warn "Reaper timer enabled but not active yet. Check: systemctl status claude-secure-reaper.timer"
      fi
    else
      log_warn "Could not enable claude-secure-reaper.timer (systemctl enable failed)."
      log_warn "Manually enable later with: sudo systemctl enable --now claude-secure-reaper.timer"
    fi
  fi

  log_info "Webhook listener installation complete."
  log_info "NOTE: Each profile that should receive webhooks needs a 'webhook_secret' field"
  log_info "      added to its profile.json. Example:"
  log_info "        jq '.webhook_secret = \"<your-github-webhook-secret>\"' \\"
  log_info "          ~/.claude-secure/profiles/<name>/profile.json > /tmp/p.json \\"
  log_info "          && mv /tmp/p.json ~/.claude-secure/profiles/<name>/profile.json"
}

main() {
  parse_args "$@"
  echo "=== claude-secure installer ==="
  echo ""

  check_dependencies
  PLATFORM="$(detect_platform)"
  log_info "Detected platform: $PLATFORM"
  if [ "$PLATFORM" = "wsl2" ]; then
    # Preserved WSL2 warnings: Docker Desktop + iptables version log
    local os_info
    os_info=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo "unknown")
    if echo "$os_info" | grep -qi "docker desktop"; then
      log_warn "Docker Desktop detected. iptables may not work correctly."
      log_warn "Recommended: use Docker CE installed directly in WSL2."
    fi
    local ipt_version
    ipt_version=$(iptables -V 2>/dev/null || echo "not found")
    log_info "iptables version: $ipt_version"
  fi
  check_existing
  setup_directories
  setup_auth
  setup_workspace
  copy_app_files
  build_images
  install_cli

  install_git_hooks

  # Reclaim ownership of CONFIG_DIR for the invoking user (sudo creates as root).
  # install_cli + install_git_hooks + install_webhook_service deliberately leave
  # system paths (/usr/local/bin, /etc/systemd, /opt/claude-secure) as root.
  chown -R "$_invoking_user:$_invoking_user" "$CONFIG_DIR"
  chmod 777 "$CONFIG_DIR/logs"

  install_webhook_service

  echo ""
  log_info "Installation complete!"
  log_info "Run 'claude-secure --profile default' to start."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [ "${__INSTALL_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
