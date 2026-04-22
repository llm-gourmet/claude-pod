#!/usr/bin/env bash
# bash 4+ re-exec guard (mirrors install.sh opening)
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

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

_invoking_user="${SUDO_USER:-$USER}"
if command -v getent >/dev/null 2>&1; then
  _invoking_home="$(getent passwd "$_invoking_user" | cut -d: -f6)"
elif command -v dscl >/dev/null 2>&1; then
  _invoking_home="$(dscl . -read "/Users/$_invoking_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
else
  eval "_invoking_home=~$_invoking_user"
fi
if [ -z "${_invoking_home:-}" ]; then
  echo "ERROR: Could not resolve home directory for user '$_invoking_user'" >&2
  exit 1
fi

CONFIG_DIR="$_invoking_home/.claude-secure"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

DRY_RUN=0
KEEP_DATA=0
REMOVE_IMAGES=0

_removed=()
_skipped=()
_manual=()

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)       DRY_RUN=1;       shift ;;
      --keep-data)     KEEP_DATA=1;     shift ;;
      --remove-images) REMOVE_IMAGES=1; shift ;;
      --help|-h)
        echo "Usage: $0 [--dry-run] [--keep-data] [--remove-images]"
        echo ""
        echo "  --dry-run        Preview removals without making changes"
        echo "  --keep-data      Preserve ~/.claude-secure/ while removing binaries and services"
        echo "  --remove-images  Also remove Docker images built by the installer"
        exit 0
        ;;
      *) log_warn "Unknown option: $1"; shift ;;
    esac
  done
}

# Wraps a removal command: prints intent in dry-run mode, otherwise executes.
# The last argument is used as the display path for dry-run output.
run_or_dry() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] would remove: ${*: -1}"
    return 0
  fi
  "$@"
}

load_config() {
  local cfg="$CONFIG_DIR/config.sh"
  if [ -f "$cfg" ]; then
    # shellcheck source=/dev/null
    source "$cfg"
    log_info "Loaded config from $cfg"
  else
    log_warn "Config not found at $cfg — using defaults"
  fi
}

remove_cli_binary() {
  local system_bin="/usr/local/bin/claude-secure"
  local user_bin="$_invoking_home/.local/bin/claude-secure"

  if [ -f "$system_bin" ]; then
    log_info "Removing CLI binary: $system_bin"
    if [ -w /usr/local/bin ]; then
      if run_or_dry rm -f "$system_bin"; then _removed+=("$system_bin")
      else log_warn "Failed to remove $system_bin"; _skipped+=("$system_bin (removal failed)"); fi
    else
      if run_or_dry sudo rm -f "$system_bin"; then _removed+=("$system_bin")
      else log_warn "Failed to remove $system_bin"; _skipped+=("$system_bin (removal failed)"); fi
    fi
  elif [ -f "$user_bin" ]; then
    log_info "Removing CLI binary: $user_bin"
    if run_or_dry rm -f "$user_bin"; then _removed+=("$user_bin")
    else log_warn "Failed to remove $user_bin"; _skipped+=("$user_bin (removal failed)"); fi
  else
    log_warn "CLI binary not found at $system_bin or $user_bin, skipping"
    _skipped+=("claude-secure binary (not found in known locations)")
  fi
}

remove_shared_templates() {
  local share_dir="/usr/local/share/claude-secure"

  if [ -d "$share_dir" ]; then
    log_info "Removing shared templates: $share_dir"
    if [ -w /usr/local/share ]; then
      if run_or_dry rm -rf "$share_dir"; then _removed+=("$share_dir")
      else log_warn "Failed to remove $share_dir"; _skipped+=("$share_dir (removal failed)"); fi
    else
      if run_or_dry sudo rm -rf "$share_dir"; then _removed+=("$share_dir")
      else log_warn "Failed to remove $share_dir"; _skipped+=("$share_dir (removal failed)"); fi
    fi
  else
    log_warn "Shared templates not found: $share_dir, skipping"
    _skipped+=("$share_dir (not found)")
  fi
}

remove_opt_dir() {
  local opt_dir="/opt/claude-secure"

  if [ -d "$opt_dir" ]; then
    log_info "Removing /opt directory: $opt_dir"
    if [ -w /opt ]; then
      if run_or_dry rm -rf "$opt_dir"; then _removed+=("$opt_dir")
      else log_warn "Failed to remove $opt_dir"; _skipped+=("$opt_dir (removal failed)"); fi
    else
      if run_or_dry sudo rm -rf "$opt_dir"; then _removed+=("$opt_dir")
      else log_warn "Failed to remove $opt_dir"; _skipped+=("$opt_dir (removal failed)"); fi
    fi
  else
    log_warn "/opt directory not found: $opt_dir, skipping"
    _skipped+=("$opt_dir (not found)")
  fi
}

remove_systemd_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not available — skipping service removal"
    log_warn "If services were installed, remove manually:"
    log_warn "  /etc/systemd/system/claude-secure-webhook.service"
    log_warn "  /etc/systemd/system/claude-secure-reaper.service"
    log_warn "  /etc/systemd/system/claude-secure-reaper.timer"
    _skipped+=("systemd services (systemctl not available)")
    return 0
  fi

  local -a unit_names=("claude-secure-webhook.service" "claude-secure-reaper.service" "claude-secure-reaper.timer")
  local daemon_reload_needed=0

  for unit in "${unit_names[@]}"; do
    local unit_file="/etc/systemd/system/$unit"
    if [ -f "$unit_file" ]; then
      log_info "Stopping and disabling: $unit"
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] would stop/disable: $unit"
        echo "[DRY-RUN] would remove: $unit_file"
        daemon_reload_needed=1
        _removed+=("$unit_file")
      else
        sudo systemctl stop "$unit" 2>/dev/null || true
        sudo systemctl disable "$unit" 2>/dev/null || true
        if sudo rm -f "$unit_file"; then
          daemon_reload_needed=1
          _removed+=("$unit_file")
        else
          log_warn "Failed to remove $unit_file"
          _skipped+=("$unit_file (removal failed)")
        fi
      fi
    else
      log_warn "Systemd unit not found: $unit_file, skipping"
      _skipped+=("$unit_file (not found)")
    fi
  done

  if [ "$daemon_reload_needed" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    sudo systemctl daemon-reload 2>/dev/null || log_warn "daemon-reload failed"
  fi
}

remove_docker_images() {
  if ! docker info >/dev/null 2>&1; then
    log_warn "Docker daemon not available — skipping image handling"
    _skipped+=("Docker images (docker unavailable)")
    return 0
  fi

  local images
  images="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^claude-secure' || true)"

  if [ -z "$images" ]; then
    _skipped+=("Docker images (none found)")
    return 0
  fi

  if [ "$REMOVE_IMAGES" -eq 0 ]; then
    log_warn "claude-secure Docker images found (pass --remove-images to delete):"
    while IFS= read -r img; do
      log_warn "  $img"
    done <<< "$images"
    local rmi_args
    rmi_args="$(echo "$images" | tr '\n' ' ')"
    _manual+=("docker rmi ${rmi_args% }")
    return 0
  fi

  while IFS= read -r img; do
    log_info "Removing Docker image: $img"
    if run_or_dry docker rmi "$img"; then _removed+=("docker image: $img")
    else log_warn "Failed to remove image $img"; _skipped+=("docker image: $img (removal failed)"); fi
  done <<< "$images"
}

remove_config_dir() {
  if [ "$KEEP_DATA" -eq 1 ]; then
    log_info "Preserving config dir (--keep-data): $CONFIG_DIR"
    _skipped+=("$CONFIG_DIR (--keep-data)")
    return 0
  fi

  if [ ! -d "$CONFIG_DIR" ]; then
    log_warn "Config directory not found: $CONFIG_DIR, skipping"
    _skipped+=("$CONFIG_DIR (not found)")
    return 0
  fi

  # Non-TTY: skip with printed manual command rather than aborting
  if [ ! -t 0 ]; then
    log_warn "Non-interactive stdin — skipping removal of $CONFIG_DIR"
    log_warn "To remove manually: rm -rf \"$CONFIG_DIR\""
    _skipped+=("$CONFIG_DIR (non-interactive, confirmation required)")
    _manual+=("rm -rf \"$CONFIG_DIR\"")
    return 0
  fi

  echo ""
  echo "  Config directory contains your API keys, profiles, and user data:"
  echo "  $CONFIG_DIR"
  read -rp "Remove it? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    log_info "Removing config directory: $CONFIG_DIR"
    if run_or_dry rm -rf "$CONFIG_DIR"; then _removed+=("$CONFIG_DIR")
    else log_warn "Failed to remove $CONFIG_DIR"; _skipped+=("$CONFIG_DIR (removal failed)"); fi
  else
    log_info "Preserved $CONFIG_DIR (user declined)"
    _skipped+=("$CONFIG_DIR (user declined)")
  fi
}

print_summary() {
  echo ""
  echo "=== Uninstall Summary ==="

  if [ "${#_removed[@]}" -gt 0 ]; then
    echo ""
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "Would remove:"
    else
      echo "Removed:"
    fi
    for item in "${_removed[@]}"; do
      echo "  [+] $item"
    done
  fi

  if [ "${#_skipped[@]}" -gt 0 ]; then
    echo ""
    echo "Skipped:"
    for item in "${_skipped[@]}"; do
      echo "  [-] $item"
    done
  fi

  if [ "${#_manual[@]}" -gt 0 ]; then
    echo ""
    echo "Manual follow-up:"
    for cmd in "${_manual[@]}"; do
      echo "  \$ $cmd"
    done
  fi

  echo ""
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Dry run complete — no changes were made."
  else
    log_info "Uninstall complete."
  fi
}

main() {
  parse_args "$@"

  echo "=== claude-secure uninstaller ==="
  echo ""

  [ "$DRY_RUN" -eq 1 ] && log_info "Dry-run mode — no changes will be made"

  load_config

  # Removal order: services → binary → shared → opt → images → config
  remove_systemd_services
  remove_cli_binary
  remove_shared_templates
  remove_opt_dir
  remove_docker_images
  remove_config_dir

  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
