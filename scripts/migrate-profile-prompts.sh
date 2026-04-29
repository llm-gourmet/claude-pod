#!/usr/bin/env bash
# migrate-profile-prompts.sh -- One-shot migration to the file-based
# system-prompt layout.
#
# For each profile directory under $CONFIG_DIR/profiles/:
#   1. If profile.json has `system_prompt`, write it to
#      system_prompts/default.md (only if that file does not already exist),
#      then strip the field from profile.json.
#   2. If profile has a legacy prompts/ directory, remove it (tasks/ are no
#      longer used; spawn uses a hardcoded fallback prompt instead).
#   3. If profile has a tasks/ directory, remove it (no longer used).
#
# Idempotent: re-running on already-migrated profiles is a no-op.
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-$HOME/.claude-pod}"
PROFILES_DIR="$CONFIG_DIR/profiles"

if [ ! -d "$PROFILES_DIR" ]; then
  exit 0
fi

migrated=0
for pdir in "$PROFILES_DIR"/*/; do
  [ -d "$pdir" ] || continue
  pjson="${pdir}profile.json"
  [ -f "$pjson" ] || continue
  pname=$(basename "$pdir")
  touched=0

  # 1. system_prompt field -> system_prompts/default.md
  sp_value=$(jq -r '.system_prompt // empty' "$pjson" 2>/dev/null || true)
  if [ -n "$sp_value" ]; then
    mkdir -p "${pdir}system_prompts"
    target="${pdir}system_prompts/default.md"
    if [ ! -f "$target" ]; then
      printf '%s\n' "$sp_value" > "$target"
      echo "  [$pname] wrote system_prompts/default.md from system_prompt field"
    else
      echo "  [$pname] system_prompts/default.md already exists — leaving file unchanged"
    fi
    tmp=$(mktemp)
    jq 'del(.system_prompt)' "$pjson" > "$tmp"
    mv "$tmp" "$pjson"
    touched=1
  elif jq -e 'has("system_prompt")' "$pjson" >/dev/null 2>&1; then
    # Empty-string system_prompt field: strip, nothing to write.
    tmp=$(mktemp)
    jq 'del(.system_prompt)' "$pjson" > "$tmp"
    mv "$tmp" "$pjson"
    echo "  [$pname] removed empty system_prompt field"
    touched=1
  fi

  # 2. Remove legacy prompts/ directory (tasks/ are no longer used).
  if [ -d "${pdir}prompts" ]; then
    rm -rf "${pdir}prompts"
    echo "  [$pname] removed legacy prompts/ directory"
    touched=1
  fi

  # 3. Remove tasks/ directory (spawn now uses a hardcoded fallback prompt).
  if [ -d "${pdir}tasks" ]; then
    rm -rf "${pdir}tasks"
    echo "  [$pname] removed tasks/ directory (spawn uses hardcoded fallback)"
    touched=1
  fi

  if [ "$touched" -eq 1 ]; then
    migrated=$((migrated + 1))
  fi
done

echo "migrate-profile-prompts: $migrated profile(s) migrated."
