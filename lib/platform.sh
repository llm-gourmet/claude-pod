#!/bin/bash
# lib/platform.sh — platform detection and PATH bootstrapping for claude-pod
#
# MUST remain bash 3.2-safe: no associative arrays, no array-from-stdin
# builtins, no lowercase-conversion parameter expansion, no other bash-4+
# syntax. See Plan 03 for the caller-side re-exec guard.
# Top-level code is parsed by Apple's /bin/bash before re-exec can occur.
#
# Public API (consumed by Phase 18+ scripts):
#   detect_platform                     -> echo "linux" | "wsl2" | "macos"; rc 0/1
#   claude_pod_brew_prefix           -> echo brew prefix or empty; rc 0/1
#   claude_pod_uuid_lower            -> echo a lowercase UUID
#   claude_pod_bootstrap_path        -> idempotent, sets PATH on macOS
#
# Environment overrides (for testing / CI):
#   CLAUDE_SECURE_PLATFORM_OVERRIDE     = linux | wsl2 | macos (forces detect)
#   CLAUDE_SECURE_BREW_PREFIX_OVERRIDE  = path (forces brew prefix; CI mock)
#
# NO `set -e` here — it would leak into the caller and break unrelated logic.

# Guard: idempotent sourcing.
if [ -n "${__CLAUDE_SECURE_PLATFORM_LOADED:-}" ]; then
  return 0
fi
__CLAUDE_SECURE_PLATFORM_LOADED=1

detect_platform() {
  if [ -n "${CLAUDE_SECURE_PLATFORM_OVERRIDE:-}" ]; then
    case "$CLAUDE_SECURE_PLATFORM_OVERRIDE" in
      linux|wsl2|macos)
        echo "$CLAUDE_SECURE_PLATFORM_OVERRIDE"
        return 0
        ;;
      *)
        echo "ERROR: CLAUDE_SECURE_PLATFORM_OVERRIDE must be one of: linux, wsl2, macos (got: $CLAUDE_SECURE_PLATFORM_OVERRIDE)" >&2
        return 1
        ;;
    esac
  fi
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Darwin)
      echo "macos"
      return 0
      ;;
    Linux)
      if [ -r /proc/version ] && grep -qi microsoft /proc/version; then
        echo "wsl2"
      else
        echo "linux"
      fi
      return 0
      ;;
    *)
      echo "unknown"
      return 1
      ;;
  esac
}

# Print the Homebrew prefix, or empty string if brew is unavailable.
# Honors CLAUDE_SECURE_BREW_PREFIX_OVERRIDE for CI mocking.
claude_pod_brew_prefix() {
  if [ -n "${CLAUDE_SECURE_BREW_PREFIX_OVERRIDE:-}" ]; then
    echo "$CLAUDE_SECURE_BREW_PREFIX_OVERRIDE"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    brew --prefix 2>/dev/null
    return 0
  fi
  echo ""
  return 1
}

# Normalize a UUID to lowercase. Safe on both BSD and GNU uuidgen.
claude_pod_uuid_lower() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

# Bootstrap PATH for macOS. Idempotent. Call this as the very first action
# in the calling script after sourcing this file.
#
# NOTE: the bash 4+ re-exec guard does NOT live here. By the time control
# enters this function, bash has already PARSED the caller's body — if it
# contained any bash-4+ syntax under apple bash 3.2, we would have crashed
# at parse time. The re-exec must therefore live in the caller's prologue
# (added in Plan 03). This function only verifies the brew bash binary
# exists so the caller's prologue can re-exec into it.
claude_pod_bootstrap_path() {
  if [ -n "${__CLAUDE_SECURE_BOOTSTRAPPED:-}" ]; then
    return 0
  fi
  __CLAUDE_SECURE_BOOTSTRAPPED=1
  export __CLAUDE_SECURE_BOOTSTRAPPED

  local plat
  plat="$(detect_platform)" || return 1
  if [ "$plat" != "macos" ]; then
    return 0
  fi

  local brew_prefix
  brew_prefix="$(claude_pod_brew_prefix)"
  if [ -z "$brew_prefix" ]; then
    echo "ERROR: Homebrew is required on macOS." >&2
    echo "Install Homebrew, then re-run this command:" >&2
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" >&2
    return 1
  fi

  # Prepend GNU coreutils so plain `date`, `stat`, `readlink`, `sed`, `grep`
  # behave like Linux.
  local gnubin="$brew_prefix/opt/coreutils/libexec/gnubin"
  if [ -d "$gnubin" ]; then
    PATH="$gnubin:$PATH"
    export PATH
  else
    echo "ERROR: GNU coreutils not installed. Run: brew install coreutils" >&2
    return 1
  fi

  # Verify brew bash is reachable (caller prologue will re-exec into it).
  if ! [ -x "$brew_prefix/bin/bash" ]; then
    echo "ERROR: brew bash not installed. Run: brew install bash" >&2
    return 1
  fi

  # Verify jq (PLAT-04 completeness).
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not installed. Run: brew install jq" >&2
    return 1
  fi

  return 0
}
