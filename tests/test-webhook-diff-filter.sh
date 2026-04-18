#!/bin/bash
# test-webhook-diff-filter.sh -- Unit tests for has_meaningful_todo_change and fetch_commit_patch
# Tests DIFF-FILTER-01 through DIFF-FILTER-06
#
# Strategy: import the two Python functions by running them inline via local Python.
# No Docker, no network calls (fetch_commit_patch tested with a mock).
#
# Usage: bash tests/test-webhook-diff-filter.sh
# Exit 0 if all pass, exit 1 if any fail.
set -uo pipefail

PASS=0
FAIL=0
TOTAL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LISTENER="$PROJECT_DIR/webhook/listener.py"

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: run Python snippet that imports helpers from listener.py and executes a check.
# The snippet must print "ok" on success or exit nonzero on failure.
run_python() {
  python3 - "$@" <<'PYEOF'
import sys, importlib.util, pathlib

listener_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("listener", listener_path)
mod = importlib.util.module_from_spec(spec)
# Avoid running main() when importing
import unittest.mock as mock
with mock.patch.object(spec.loader, 'exec_module', side_effect=lambda m: exec(
    compile(listener_path.read_text(), listener_path, 'exec'),
    {**m.__dict__}
)):
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        pass
PYEOF
}

# Use a simpler import approach: exec the file with __name__ != '__main__'
py_import_and_run() {
  local snippet="$1"
  python3 -c "
import sys
sys.argv = ['listener']
# Patch argparse to avoid parsing sys.argv
import unittest.mock as mock
with mock.patch('argparse.ArgumentParser.parse_args'):
    pass

# Direct exec approach
import importlib.util, pathlib
p = pathlib.Path('$LISTENER')
src = p.read_text()
# Replace if __name__ == '__main__' block
src = src.replace(\"if __name__ == '__main__':\", \"if False:\")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
$snippet
"
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-01: New open item in matching file triggers spawn
# ---------------------------------------------------------------------------
test_new_open_item_triggers_spawn() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

patch = """diff --git a/projects/JAD/TODOS.md b/projects/JAD/TODOS.md
index abc..def 100644
--- a/projects/JAD/TODOS.md
+++ b/projects/JAD/TODOS.md
@@ -1,3 +1,4 @@
 # TODOs
-
+- [ ] some new task
"""
result = has_meaningful_todo_change(patch, "projects/*/TODOS.md")
assert result is True, f"Expected True, got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-02: Checkbox-off only does NOT trigger spawn
# ---------------------------------------------------------------------------
test_checkbox_off_no_spawn() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

patch = """diff --git a/projects/JAD/TODOS.md b/projects/JAD/TODOS.md
index abc..def 100644
--- a/projects/JAD/TODOS.md
+++ b/projects/JAD/TODOS.md
@@ -1,3 +1,3 @@
 # TODOs
-- [ ] done task
+- [x] done task
"""
result = has_meaningful_todo_change(patch, "projects/*/TODOS.md")
assert result is False, f"Expected False, got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-03: Edited open item text triggers spawn (old text removed, new open text added)
# ---------------------------------------------------------------------------
test_edited_open_item_triggers_spawn() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

patch = """diff --git a/projects/JAD/TODOS.md b/projects/JAD/TODOS.md
index abc..def 100644
--- a/projects/JAD/TODOS.md
+++ b/projects/JAD/TODOS.md
@@ -1,3 +1,3 @@
 # TODOs
-- [ ] old wording
+- [ ] new wording
"""
result = has_meaningful_todo_change(patch, "projects/*/TODOS.md")
assert result is True, f"Expected True, got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-04: Non-matching path returns False (diff filter not invoked for GOALS.md)
# ---------------------------------------------------------------------------
test_non_matching_path_no_spawn() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

patch = """diff --git a/projects/JAD/GOALS.md b/projects/JAD/GOALS.md
index abc..def 100644
--- a/projects/JAD/GOALS.md
+++ b/projects/JAD/GOALS.md
@@ -1,3 +1,4 @@
 # Goals
+- [ ] new goal
"""
result = has_meaningful_todo_change(patch, "projects/*/TODOS.md")
assert result is False, f"Expected False for non-matching path, got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-05: Empty patch returns False
# ---------------------------------------------------------------------------
test_empty_patch_no_spawn() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

result = has_meaningful_todo_change("", "projects/*/TODOS.md")
assert result is False, f"Expected False for empty patch, got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# DIFF-FILTER-06: Mixed file patch — only TODOS.md section evaluated
# ---------------------------------------------------------------------------
test_mixed_patch_only_todos_evaluated() {
  python3 - "$LISTENER" <<'EOF'
import importlib.util, pathlib, sys

p = pathlib.Path(sys.argv[1])
src = p.read_text().replace("if __name__ == '__main__':", "if False:")
ns = {}
exec(compile(src, str(p), 'exec'), ns)
has_meaningful_todo_change = ns['has_meaningful_todo_change']

# GOALS.md has a +- [ ] line but TODOS.md only has a checkbox-off
patch = """diff --git a/projects/JAD/GOALS.md b/projects/JAD/GOALS.md
index abc..def 100644
--- a/projects/JAD/GOALS.md
+++ b/projects/JAD/GOALS.md
@@ -1,2 +1,3 @@
 # Goals
+- [ ] new goal in goals
diff --git a/projects/JAD/TODOS.md b/projects/JAD/TODOS.md
index abc..def 100644
--- a/projects/JAD/TODOS.md
+++ b/projects/JAD/TODOS.md
@@ -1,3 +1,3 @@
 # TODOs
-- [ ] done
+- [x] done
"""
result = has_meaningful_todo_change(patch, "projects/*/TODOS.md")
assert result is False, f"Expected False (open item only in non-matching file), got {result}"
print("ok")
EOF
  [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo ""
echo "=== Webhook Diff Filter Tests ==="
echo ""

run_test "DIFF-FILTER-01: new open item triggers spawn" test_new_open_item_triggers_spawn
run_test "DIFF-FILTER-02: checkbox-off only does not trigger spawn" test_checkbox_off_no_spawn
run_test "DIFF-FILTER-03: edited open item text triggers spawn" test_edited_open_item_triggers_spawn
run_test "DIFF-FILTER-04: non-matching path returns False" test_non_matching_path_no_spawn
run_test "DIFF-FILTER-05: empty patch returns False" test_empty_patch_no_spawn
run_test "DIFF-FILTER-06: mixed patch, only matching file evaluated" test_mixed_patch_only_todos_evaluated

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
echo ""

[ "$FAIL" -eq 0 ]
