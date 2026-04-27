#!/bin/bash
# tests/test-payload-filter.sh -- Unit and integration tests for webhook payload filter
# PAY-01: filter_payload returns None for unknown event types
# PAY-02: push subset strips url/stat/flag fields, keeps ref/commits/repo/pusher
# PAY-03: issues subset strips url/id/stat fields, keeps action/issue/repo/sender
# PAY-04: pull_request subset keeps action/pr fields/repo/sender
# PAY-05: issue_comment subset includes issue.state; pull_request_review_comment does not
# PAY-06: workflow_run subset keeps action/workflow_run/workflow/repo/sender
# PAY-07: helper _pick_commits extracts id/message/added/modified/removed/author
# PAY-08: integration — persisted event file is filtered (no url/id/stat fields)
# PAY-09: integration — unknown event type returns 200 skipped, no event file, no spawn
# PAY-10: _meta and event_type are always present in persisted filtered file
#
# Usage:
#   bash tests/test-payload-filter.sh             # full suite
#   bash tests/test-payload-filter.sh test_push_subset  # single test

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
STUB_LOG="$TEST_TMPDIR/stub-invocations.log"
LISTENER_PID=""
LISTENER_PORT=19067  # unique port for this test suite

cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

run_test() {
  local name="$1"; shift
  TOTAL=$((TOTAL+1))
  if "$@"; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL+1))
  fi
}

# =========================================================================
# Stub + listener setup
# =========================================================================
install_stub() {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/claude-pod" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:-/tmp/stub.log}"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/claude-pod"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export STUB_LOG
}

setup_test_profile() {
  local home_dir="$TEST_TMPDIR/home"
  local webhooks_dir="$home_dir/.claude-pod/webhooks"
  mkdir -p "$home_dir/.claude-pod/profiles/test-profile" \
    "$webhooks_dir" \
    "$home_dir/.claude-pod/events" \
    "$home_dir/.claude-pod/logs"
  cat > "$home_dir/.claude-pod/profiles/test-profile/profile.json" <<JSON
{
  "workspace": "$TEST_TMPDIR/workspace",
  "secrets": []
}
JSON
  cat > "$webhooks_dir/connections.json" <<JSON
[
  {
    "name": "test-profile",
    "repo": "test-org/test-repo",
    "webhook_secret": "test-secret-pay67"
  }
]
JSON
  chmod 600 "$webhooks_dir/connections.json"
  mkdir -p "$TEST_TMPDIR/workspace"
  cat > "$TEST_TMPDIR/webhook.json" <<JSON
{
  "bind": "127.0.0.1",
  "port": $LISTENER_PORT,
  "max_concurrent_spawns": 3,
  "profiles_dir": "$home_dir/.claude-pod/profiles",
  "webhooks_dir": "$webhooks_dir",
  "events_dir": "$home_dir/.claude-pod/events",
  "logs_dir": "$home_dir/.claude-pod/logs",
  "claude_pod_bin": "$TEST_TMPDIR/bin/claude-pod"
}
JSON
}

start_listener() {
  [ -f "$PROJECT_DIR/webhook/listener.py" ] || return 1
  python3 "$PROJECT_DIR/webhook/listener.py" --config "$TEST_TMPDIR/webhook.json" \
    >"$TEST_TMPDIR/listener.stdout" 2>"$TEST_TMPDIR/listener.stderr" &
  LISTENER_PID=$!
  local i=0
  while [ $i -lt 20 ]; do
    curl -sSf "http://127.0.0.1:$LISTENER_PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

gen_sig() {
  local hex
  hex=$(printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.* //')
  printf 'sha256=%s' "$hex"
}

post_webhook() {
  local event="$1" body="$2" prefix="$3"
  local sig delivery_id
  sig=$(gen_sig "test-secret-pay67" "$body")
  delivery_id="${prefix}-$(uuidgen)"
  curl -sS -o "$TEST_TMPDIR/resp.json" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$LISTENER_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: $event" \
    -H "X-GitHub-Delivery: $delivery_id" \
    -H "X-Hub-Signature-256: $sig" \
    --data-binary "$body"
}

# =========================================================================
# PAY-01..PAY-07: Python unit tests against filter_payload and helpers
# =========================================================================

# PAY-01: unknown event type returns None
test_unknown_event_type_returns_none() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

cases = ["ping", "create", "delete", "deployment", "fork", "watch", "star"]
for base in cases:
    result = filter_payload(base, {"repository": {"full_name": "a/b"}, "sender": {"login": "u"}})
    if result is not None:
        print(f"FAIL: filter_payload({base!r}) should return None, got {result!r}", file=sys.stderr)
        sys.exit(1)
print("OK: all unknown event types return None")
sys.exit(0)
PYEOF
}

# PAY-02: push subset strips url/stat/flag fields, keeps required fields
test_push_subset() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

payload = {
  "ref": "refs/heads/main",
  "before": "aaaa",
  "after": "bbbb",
  "forced": False,
  "repository": {
    "id": 1,
    "node_id": "R_abc",
    "full_name": "org/repo",
    "default_branch": "main",
    "html_url": "https://github.com/org/repo",
    "forks_count": 5,
    "stargazers_count": 10,
    "has_issues": True,
    "ssh_url": "git@github.com:org/repo.git",
    "clone_url": "https://github.com/org/repo.git",
  },
  "pusher": {"name": "alice", "email": "alice@example.com"},
  "commits": [
    {
      "id": "abc123",
      "message": "Fix bug",
      "timestamp": "2024-01-01T00:00:00Z",
      "added": ["new.py"],
      "modified": ["old.py"],
      "removed": [],
      "author": {"name": "alice", "username": "alice_gh", "email": "alice@example.com"},
      "html_url": "https://github.com/org/repo/commit/abc123",
    }
  ],
  "head_commit": {"id": "abc123"},
}

result = filter_payload("push", payload)
assert result is not None, "push should not return None"

# Required fields kept
assert result.get("ref") == "refs/heads/main", f"ref missing: {result}"
assert result.get("before") == "aaaa", f"before missing: {result}"
assert result.get("after") == "bbbb", f"after missing: {result}"
assert result.get("forced") is False, f"forced missing: {result}"
assert result.get("repository", {}).get("full_name") == "org/repo", f"repo.full_name missing: {result}"
assert result.get("repository", {}).get("default_branch") == "main", f"repo.default_branch missing: {result}"
assert result.get("pusher", {}).get("name") == "alice", f"pusher.name missing: {result}"

# Commits subset
commits = result.get("commits", [])
assert len(commits) == 1, f"expected 1 commit, got {len(commits)}"
c = commits[0]
assert c.get("id") == "abc123", f"commit.id missing: {c}"
assert c.get("message") == "Fix bug", f"commit.message missing: {c}"
assert c.get("timestamp") == "2024-01-01T00:00:00Z", f"commit.timestamp missing: {c}"
assert c.get("added") == ["new.py"], f"commit.added missing: {c}"
assert c.get("modified") == ["old.py"], f"commit.modified missing: {c}"
assert c.get("removed") == [], f"commit.removed missing: {c}"
assert c.get("author", {}).get("name") == "alice", f"commit.author.name missing: {c}"
assert c.get("author", {}).get("username") == "alice_gh", f"commit.author.username missing: {c}"

# Excluded fields
assert "html_url" not in (result.get("repository") or {}), f"repo.html_url should be stripped"
assert "forks_count" not in (result.get("repository") or {}), f"repo.forks_count should be stripped"
assert "stargazers_count" not in (result.get("repository") or {}), f"repo.stargazers_count should be stripped"
assert "has_issues" not in (result.get("repository") or {}), f"repo.has_issues should be stripped"
assert "ssh_url" not in (result.get("repository") or {}), f"repo.ssh_url should be stripped"
assert "node_id" not in (result.get("repository") or {}), f"repo.node_id should be stripped"
assert "email" not in (result.get("pusher") or {}), f"pusher.email should be stripped"
assert "html_url" not in commits[0], f"commit.html_url should be stripped"
assert "email" not in (commits[0].get("author") or {}), f"commit.author.email should be stripped"
assert "head_commit" not in result, f"head_commit should be stripped"
assert "id" not in result.get("repository", {}), f"repo.id should be stripped"

print("OK: push subset correct")
sys.exit(0)
PYEOF
}

# PAY-03: issues subset keeps action/issue/repo/sender, strips url/id/stat fields
test_issues_subset() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

payload = {
  "action": "opened",
  "issue": {
    "number": 42,
    "title": "Bug report",
    "body": "Description here",
    "state": "open",
    "html_url": "https://github.com/org/repo/issues/42",
    "node_id": "I_abc",
    "id": 99999,
    "user": {"login": "reporter", "id": 1, "node_id": "U_abc", "avatar_url": "https://avatars.github.com/u/1"},
    "labels": [
      {"id": 1, "node_id": "L_abc", "name": "bug", "color": "d73a4a", "url": "https://..."},
    ],
    "assignees": [{"login": "maintainer", "id": 2, "node_id": "U_xyz"}],
    "milestone": {"title": "v2.0", "id": 5, "node_id": "M_abc"},
  },
  "repository": {
    "id": 1,
    "node_id": "R_abc",
    "full_name": "org/repo",
    "html_url": "https://github.com/org/repo",
    "forks_count": 5,
    "has_issues": True,
  },
  "sender": {"login": "reporter", "id": 1, "node_id": "U_abc", "avatar_url": "https://..."},
}

result = filter_payload("issues", payload)
assert result is not None, "issues should not return None"

# Required fields
assert result.get("action") == "opened"
issue = result.get("issue", {})
assert issue.get("number") == 42
assert issue.get("title") == "Bug report"
assert issue.get("body") == "Description here"
assert issue.get("state") == "open"
assert issue.get("user", {}).get("login") == "reporter"
assert issue.get("labels") == [{"name": "bug"}]
assert issue.get("assignees") == [{"login": "maintainer"}]
assert issue.get("milestone", {}).get("title") == "v2.0"
assert result.get("repository", {}).get("full_name") == "org/repo"
assert result.get("sender", {}).get("login") == "reporter"

# Excluded fields
assert "html_url" not in issue, f"issue.html_url should be stripped: {issue}"
assert "node_id" not in issue, f"issue.node_id should be stripped: {issue}"
assert "id" not in issue, f"issue.id should be stripped: {issue}"
assert "id" not in (result.get("repository") or {}), f"repo.id should be stripped"
assert "forks_count" not in (result.get("repository") or {}), f"repo.forks_count should be stripped"
assert "node_id" not in (result.get("sender") or {}), f"sender.node_id should be stripped"
assert "avatar_url" not in (result.get("sender") or {}), f"sender.avatar_url should be stripped"
# Label color and url should be stripped
lbl = issue.get("labels", [{}])[0]
assert "color" not in lbl, f"label.color should be stripped: {lbl}"
assert "url" not in lbl, f"label.url should be stripped: {lbl}"

print("OK: issues subset correct")
sys.exit(0)
PYEOF
}

# PAY-04: pull_request subset
test_pull_request_subset() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

payload = {
  "action": "opened",
  "pull_request": {
    "number": 7,
    "title": "Add feature",
    "body": "PR body",
    "state": "open",
    "merged": False,
    "html_url": "https://github.com/org/repo/pull/7",
    "node_id": "PR_abc",
    "id": 888,
    "head": {"ref": "feature/x", "sha": "sha1", "label": "org:feature/x"},
    "base": {"ref": "main", "sha": "sha0", "label": "org:main"},
    "user": {"login": "dev", "id": 5, "node_id": "U_dev"},
    "labels": [{"id": 2, "name": "enhancement", "color": "blue"}],
    "requested_reviewers": [{"login": "reviewer", "id": 3, "node_id": "U_rev"}],
    "diff_url": "https://github.com/org/repo/pull/7.diff",
  },
  "repository": {
    "id": 1,
    "full_name": "org/repo",
    "forks_count": 3,
    "ssh_url": "git@github.com:org/repo.git",
  },
  "sender": {"login": "dev", "id": 5, "node_id": "U_dev"},
}

result = filter_payload("pull_request", payload)
assert result is not None

assert result.get("action") == "opened"
pr = result.get("pull_request", {})
assert pr.get("number") == 7
assert pr.get("title") == "Add feature"
assert pr.get("state") == "open"
assert pr.get("merged") is False
assert pr.get("head", {}).get("ref") == "feature/x"
assert pr.get("head", {}).get("sha") == "sha1"
assert pr.get("base", {}).get("ref") == "main"
assert pr.get("base", {}).get("sha") == "sha0"
assert pr.get("user", {}).get("login") == "dev"
assert pr.get("labels") == [{"name": "enhancement"}]
assert pr.get("requested_reviewers") == [{"login": "reviewer"}]
assert result.get("repository", {}).get("full_name") == "org/repo"
assert result.get("sender", {}).get("login") == "dev"

# Excluded
assert "html_url" not in pr, f"pr.html_url should be stripped"
assert "node_id" not in pr, f"pr.node_id should be stripped"
assert "id" not in pr, f"pr.id should be stripped"
assert "diff_url" not in pr, f"pr.diff_url should be stripped"
assert "label" not in (pr.get("head") or {}), f"head.label should be stripped"
assert "ssh_url" not in (result.get("repository") or {}), f"repo.ssh_url should be stripped"

print("OK: pull_request subset correct")
sys.exit(0)
PYEOF
}

# PAY-05: issue_comment includes issue.state; pull_request_review_comment does not
test_comment_issue_state_rules() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

comment_payload = {
  "action": "created",
  "comment": {
    "id": 111,
    "body": "LGTM",
    "html_url": "https://github.com/org/repo/issues/1#issuecomment-111",
    "user": {"login": "reviewer", "id": 3, "node_id": "U_rev", "avatar_url": "https://..."},
  },
  "issue": {"number": 1, "title": "Issue title", "state": "open", "id": 42, "node_id": "I_abc"},
  "repository": {"id": 1, "full_name": "org/repo", "html_url": "https://github.com/org/repo"},
  "sender": {"login": "reviewer", "id": 3},
}

# issue_comment: should include issue.state
ic = filter_payload("issue_comment", comment_payload)
assert ic is not None
assert ic.get("action") == "created"
issue = ic.get("issue", {})
assert issue.get("number") == 1
assert issue.get("title") == "Issue title"
assert issue.get("state") == "open", f"issue_comment must include issue.state, got: {issue}"
# Stripped
assert "id" not in issue, f"issue.id should be stripped"
assert "node_id" not in issue, f"issue.node_id should be stripped"
assert "html_url" not in (ic.get("comment") or {}), f"comment.html_url should be stripped"
assert "id" not in (ic.get("comment") or {}), f"comment.id should be stripped"

# pull_request_review_comment: must NOT include issue.state
prc = filter_payload("pull_request_review_comment", comment_payload)
assert prc is not None
pr_issue = prc.get("issue", {})
assert pr_issue.get("number") == 1
assert "state" not in pr_issue, \
  f"pull_request_review_comment must NOT include issue.state, got: {pr_issue}"

print("OK: issue.state rules correct for issue_comment and pull_request_review_comment")
sys.exit(0)
PYEOF
}

# PAY-06: workflow_run subset
test_workflow_run_subset() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import filter_payload

payload = {
  "action": "completed",
  "workflow_run": {
    "id": 123456,
    "name": "CI",
    "head_branch": "main",
    "head_sha": "abc123",
    "status": "completed",
    "conclusion": "failure",
    "event": "push",
    "workflow_id": 99,
    "html_url": "https://github.com/org/repo/actions/runs/123456",
    "node_id": "WR_abc",
  },
  "workflow": {
    "id": 99,
    "name": "CI",
    "path": ".github/workflows/ci.yml",
    "html_url": "https://github.com/org/repo/actions/workflows/ci.yml",
    "node_id": "W_abc",
  },
  "repository": {
    "id": 1,
    "full_name": "org/repo",
    "forks_count": 0,
    "ssh_url": "git@github.com:org/repo.git",
  },
  "sender": {"login": "github-actions[bot]", "id": 41898282, "node_id": "U_bot"},
}

result = filter_payload("workflow_run", payload)
assert result is not None

assert result.get("action") == "completed"
wr = result.get("workflow_run", {})
assert wr.get("id") == 123456
assert wr.get("name") == "CI"
assert wr.get("head_branch") == "main"
assert wr.get("head_sha") == "abc123"
assert wr.get("status") == "completed"
assert wr.get("conclusion") == "failure"
assert wr.get("event") == "push"
assert wr.get("workflow_id") == 99
wf = result.get("workflow", {})
assert wf.get("id") == 99
assert wf.get("name") == "CI"
assert wf.get("path") == ".github/workflows/ci.yml"
assert result.get("repository", {}).get("full_name") == "org/repo"
assert result.get("sender", {}).get("login") == "github-actions[bot]"

# Excluded
assert "html_url" not in wr, f"workflow_run.html_url should be stripped"
assert "node_id" not in wr, f"workflow_run.node_id should be stripped"
assert "html_url" not in wf, f"workflow.html_url should be stripped"
assert "node_id" not in wf, f"workflow.node_id should be stripped"
assert "ssh_url" not in (result.get("repository") or {}), f"repo.ssh_url should be stripped"
assert "forks_count" not in (result.get("repository") or {}), f"repo.forks_count should be stripped"

print("OK: workflow_run subset correct")
sys.exit(0)
PYEOF
}

# PAY-07: _pick_commits helper
test_pick_commits_helper() {
  python3 - <<PYEOF
import sys
sys.path.insert(0, "$PROJECT_DIR/webhook")
from listener import _pick_commits

commits = [
  {
    "id": "abc",
    "message": "Fix",
    "timestamp": "2024-01-01T00:00:00Z",
    "added": ["a.py"],
    "modified": ["b.py"],
    "removed": ["c.py"],
    "author": {"name": "Alice", "username": "alice_gh", "email": "alice@example.com"},
    "html_url": "https://github.com/...",
    "url": "https://api.github.com/...",
  },
  "not_a_dict",  # should be skipped
]

result = _pick_commits(commits)
assert len(result) == 1, f"expected 1 commit (non-dict skipped), got {len(result)}"
c = result[0]
assert c.get("id") == "abc"
assert c.get("message") == "Fix"
assert c.get("timestamp") == "2024-01-01T00:00:00Z"
assert c.get("added") == ["a.py"]
assert c.get("modified") == ["b.py"]
assert c.get("removed") == ["c.py"]
assert c.get("author", {}).get("name") == "Alice"
assert c.get("author", {}).get("username") == "alice_gh"
assert "email" not in c.get("author", {}), "author.email should be stripped"
assert "html_url" not in c, "commit.html_url should be stripped"
assert "url" not in c, "commit.url should be stripped"

# Empty / None input
assert _pick_commits(None) == []
assert _pick_commits([]) == []

print("OK: _pick_commits helper correct")
sys.exit(0)
PYEOF
}

# PAY-08: integration — persisted event file is filtered
test_integration_persisted_file_is_filtered() {
  # Build a rich push payload with fields that should be stripped
  local body status ev_file
  body=$(cat <<'JSON'
{
  "ref": "refs/heads/main",
  "before": "0000000000000000000000000000000000000000",
  "after": "abc123def456abc123def456abc123def456abcd",
  "repository": {
    "id": 1000001,
    "node_id": "R_kgXX",
    "name": "test-repo",
    "full_name": "test-org/test-repo",
    "html_url": "https://github.com/test-org/test-repo",
    "ssh_url": "git@github.com:test-org/test-repo.git",
    "clone_url": "https://github.com/test-org/test-repo.git",
    "default_branch": "main",
    "forks_count": 3,
    "stargazers_count": 12,
    "has_issues": true,
    "archived": false,
    "owner": { "login": "test-org" }
  },
  "pusher": { "name": "test-user", "email": "test@example.com" },
  "commits": [
    {
      "id": "abc123def456abc123def456abc123def456abcd",
      "message": "Test commit",
      "timestamp": "2024-01-01T00:00:00Z",
      "added": [],
      "modified": ["README.md"],
      "removed": [],
      "author": { "name": "Test User", "email": "test@example.com", "username": "test-user" },
      "html_url": "https://github.com/test-org/test-repo/commit/abc123"
    }
  ],
  "head_commit": { "id": "abc123" }
}
JSON
)
  status=$(post_webhook push "$body" "pay08")
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3

  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-pod/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || { echo "no event file found" >&2; return 1; }

  # Required fields present
  jq -e '.ref == "refs/heads/main"' "$ev_file" >/dev/null || { echo "ref missing" >&2; return 1; }
  jq -e '.repository.full_name == "test-org/test-repo"' "$ev_file" >/dev/null || { echo "repo.full_name missing" >&2; return 1; }
  jq -e '.repository.default_branch == "main"' "$ev_file" >/dev/null || { echo "repo.default_branch missing" >&2; return 1; }
  jq -e '.pusher.name == "test-user"' "$ev_file" >/dev/null || { echo "pusher.name missing" >&2; return 1; }
  jq -e '.commits[0].id == "abc123def456abc123def456abc123def456abcd"' "$ev_file" >/dev/null || { echo "commit.id missing" >&2; return 1; }
  jq -e '.commits[0].author.username == "test-user"' "$ev_file" >/dev/null || { echo "commit.author.username missing" >&2; return 1; }

  # Stripped fields absent
  jq -e '.repository.html_url == null' "$ev_file" >/dev/null || { echo "repo.html_url should be absent" >&2; cat "$ev_file" >&2; return 1; }
  jq -e '.repository.ssh_url == null' "$ev_file" >/dev/null || { echo "repo.ssh_url should be absent" >&2; return 1; }
  jq -e '.repository.node_id == null' "$ev_file" >/dev/null || { echo "repo.node_id should be absent" >&2; return 1; }
  jq -e '.repository.forks_count == null' "$ev_file" >/dev/null || { echo "repo.forks_count should be absent" >&2; return 1; }
  jq -e '.repository.has_issues == null' "$ev_file" >/dev/null || { echo "repo.has_issues should be absent" >&2; return 1; }
  jq -e '.repository.id == null' "$ev_file" >/dev/null || { echo "repo.id should be absent" >&2; return 1; }
  jq -e '.pusher.email == null' "$ev_file" >/dev/null || { echo "pusher.email should be absent" >&2; return 1; }
  jq -e '.commits[0].html_url == null' "$ev_file" >/dev/null || { echo "commit.html_url should be absent" >&2; return 1; }
  jq -e '.commits[0].author.email == null' "$ev_file" >/dev/null || { echo "commit.author.email should be absent" >&2; return 1; }
  jq -e '.head_commit == null' "$ev_file" >/dev/null || { echo "head_commit should be absent" >&2; return 1; }

  return 0
}

# PAY-09: integration — unknown event type returns 200 skipped, no spawn, no event file
test_integration_unknown_event_type_skipped() {
  local ev_count_before ev_count_after spawn_before spawn_after status body

  body='{"zen":"Non-blocking is better","hook_id":1,"repository":{"id":1000001,"name":"test-repo","full_name":"test-org/test-repo"},"sender":{"login":"test-user"}}'
  ev_count_before=$(ls "$TEST_TMPDIR/home/.claude-pod/events"/*.json 2>/dev/null | wc -l)
  spawn_before=$(grep -c '"spawn_start"' "$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl" 2>/dev/null || echo 0)

  status=$(post_webhook ping "$body" "pay09")
  [ "$status" = "200" ] || { echo "expected 200 (skipped) for unknown event type, got $status" >&2; return 1; }

  resp=$(cat "$TEST_TMPDIR/resp.json" 2>/dev/null)
  echo "$resp" | grep -q '"unknown_event_type"' || { echo "response should mention unknown_event_type: $resp" >&2; return 1; }

  sleep 0.3
  ev_count_after=$(ls "$TEST_TMPDIR/home/.claude-pod/events"/*.json 2>/dev/null | wc -l)
  [ "$ev_count_after" -eq "$ev_count_before" ] || { echo "no new event file should be created for unknown type" >&2; return 1; }

  spawn_after=$(grep -c '"spawn_start"' "$TEST_TMPDIR/home/.claude-pod/logs/webhook.jsonl" 2>/dev/null || echo 0)
  [ "$spawn_after" -eq "$spawn_before" ] || { echo "spawn_start must not be logged for unknown event type" >&2; return 1; }

  return 0
}

# PAY-10: integration — persisted file always has _meta and event_type
test_integration_meta_and_event_type_always_present() {
  local body status ev_file
  body=$(cat "$PROJECT_DIR/tests/fixtures/github-issues-opened.json")
  status=$(post_webhook issues "$body" "pay10")
  [ "$status" = "202" ] || { echo "expected 202, got $status" >&2; return 1; }
  sleep 0.3

  ev_file=$(ls -t "$TEST_TMPDIR/home/.claude-pod/events"/*.json 2>/dev/null | head -n1)
  [ -n "$ev_file" ] || { echo "no event file found" >&2; return 1; }

  jq -e '.event_type == "issues-opened"' "$ev_file" >/dev/null || { echo ".event_type missing" >&2; return 1; }
  jq -e '._meta.event_type == "issues-opened"' "$ev_file" >/dev/null || { echo "._meta.event_type missing" >&2; return 1; }
  jq -e '._meta.profile == "test-profile"' "$ev_file" >/dev/null || { echo "._meta.profile missing" >&2; return 1; }
  jq -e '._meta.received_at | . != null and . != ""' "$ev_file" >/dev/null || { echo "._meta.received_at missing" >&2; return 1; }

  return 0
}

# =========================================================================
# Main dispatcher
# =========================================================================
main() {
  install_stub
  setup_test_profile

  echo "========================================"
  echo "  Payload Filter Tests (PAY-01..PAY-10)"
  echo "========================================"
  echo ""

  echo "--- Unit tests (no listener required) ---"
  run_test "PAY-01: unknown event type returns None"           test_unknown_event_type_returns_none
  run_test "PAY-02: push subset correct"                       test_push_subset
  run_test "PAY-03: issues subset correct"                     test_issues_subset
  run_test "PAY-04: pull_request subset correct"               test_pull_request_subset
  run_test "PAY-05: comment issue.state rules"                 test_comment_issue_state_rules
  run_test "PAY-06: workflow_run subset correct"               test_workflow_run_subset
  run_test "PAY-07: _pick_commits helper correct"              test_pick_commits_helper
  echo ""

  echo "--- Integration tests (listener required) ---"
  if ! start_listener; then
    echo "  SKIP: listener failed to start"
    for t in test_integration_persisted_file_is_filtered \
              test_integration_unknown_event_type_skipped \
              test_integration_meta_and_event_type_always_present; do
      TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "  FAIL: $t (listener not running)"
    done
  else
    run_test "PAY-08: persisted file is filtered"              test_integration_persisted_file_is_filtered
    run_test "PAY-09: unknown event type skipped"              test_integration_unknown_event_type_skipped
    run_test "PAY-10: _meta and event_type always present"     test_integration_meta_and_event_type_always_present
  fi

  echo ""
  echo "========================================"
  echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
  echo "========================================"
  [ "$FAIL" -eq 0 ]
}

if [ $# -gt 0 ]; then
  install_stub
  setup_test_profile
  start_listener || true
  "$@"
  exit $?
fi

main "$@"
