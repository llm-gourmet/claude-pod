#!/usr/bin/env bash
set -euo pipefail

# Load CONFIG_DIR from installed config if available, fall back to default.
_config_sh="${HOME}/.claude-pod/config.sh"
if [ -f "$_config_sh" ]; then
  # shellcheck source=/dev/null
  source "$_config_sh"
fi
CONFIG_DIR="${CONFIG_DIR:-${HOME}/.claude-pod}"
TEMPLATES_DIR="${CONFIG_DIR}/docs-templates"
PROJECTS_DIR="$(pwd)/projects"

if [[ $# -eq 0 ]]; then
  echo "Usage: new-project.sh <project-name>" >&2
  exit 1
fi

if [[ ! -d "$TEMPLATES_DIR" ]] || [[ -z "$(find "$TEMPLATES_DIR" -maxdepth 3 -type f 2>/dev/null | head -1)" ]]; then
  echo "No templates found. Add your template files to: $TEMPLATES_DIR/" >&2
  exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
  echo "Error: projects/$PROJECT_NAME already exists" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR"
cp -r "$TEMPLATES_DIR/." "$PROJECT_DIR/"

echo "Created projects/$PROJECT_NAME"
