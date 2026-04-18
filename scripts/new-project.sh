#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
PROJECTS_DIR="$(pwd)/projects"

if [[ $# -eq 0 ]]; then
  echo "Usage: new-project.sh <project-name>" >&2
  exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
  echo "Error: projects/$PROJECT_NAME already exists" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/decisions" "$PROJECT_DIR/ideas" "$PROJECT_DIR/done"

cp "$TEMPLATES_DIR/VISION.md"      "$PROJECT_DIR/VISION.md"
cp "$TEMPLATES_DIR/GOALS.md"       "$PROJECT_DIR/GOALS.md"
cp "$TEMPLATES_DIR/AGREEMENTS.md"  "$PROJECT_DIR/AGREEMENTS.md"
cp "$TEMPLATES_DIR/TODOS.md"       "$PROJECT_DIR/TODOS.md"
cp "$TEMPLATES_DIR/TASKS.md"       "$PROJECT_DIR/TASKS.md"

cp "$TEMPLATES_DIR/decisions/_template.md" "$PROJECT_DIR/decisions/_template.md"
cp "$TEMPLATES_DIR/ideas/_template.md"     "$PROJECT_DIR/ideas/_template.md"
cp "$TEMPLATES_DIR/done/_template.md"      "$PROJECT_DIR/done/_template.md"

echo "Created projects/$PROJECT_NAME"
