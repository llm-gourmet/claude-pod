## Context

The webhook listener (`webhook/listener.py`) currently delegates all push-event intelligence to Claude: it spawns a container, Claude reads `{{COMMITS_JSON}}`, pattern-matches filenames, and outputs a one-line decision. This worked for the initial implementation but has two failure modes: (1) Haiku occasionally returns wrong answers on structured data tasks, and (2) every push costs ~$0.015 regardless of whether a TODOS.md was even touched.

The listener already has per-profile `webhook_event_filter` logic (`apply_event_filter`) that runs before spawn. Extending this to include a diff check is architecturally clean — no new process, no new service, same sync path.

GitHub's REST API (`GET /repos/{owner}/{repo}/commits/{sha}`) returns the full patch for each commit when called with `Accept: application/vnd.github.v3.diff`. This is a single HTTPS call per push event (not per file). The token can be a fine-grained PAT scoped to read-only contents on the obsidian repo.

## Goals / Non-Goals

**Goals:**
- Spawn only when `projects/*/TODOS.md` has a new unchecked item (`+- [ ]`) or an existing open item's text changed.
- Never spawn when the only change is checking off an item (`- [ ] x` → `- [x] x`).
- Keep the token host-only (in `webhook.json`); it never reaches the container.
- Add CLI parity with `bootstrap-docs`: configure listener settings, show status per instance.
- Remove all Report-Repo-Token references (dead code path).

**Non-Goals:**
- Supporting repos other than `llm-gourmet/obsidian` with this diff filter (the feature is profile-config-driven, but the test scope is the obsidian profile).
- Replacing the HMAC signature validation or any existing security layer.
- Streaming or async GitHub API calls (one blocking HTTP call per push is acceptable; pushes are infrequent).
- Pagination of commit patches (GitHub returns full patches for normal commits; large commits are an accepted edge case).

## Decisions

**D-01: Diff filter runs inside `apply_event_filter`, not in a new hook.**

`apply_event_filter` already sits between HMAC validation and persist/spawn. Adding the diff check here means: if the filter returns `(False, reason)`, the event is logged as filtered and no spawn occurs — exactly the right behavior. No new code path needed.

Alternative: a post-persist pre-spawn hook. Rejected: more complex, event file already written, harder to roll back.

**D-02: GitHub API call uses `urllib.request` (stdlib), not `requests`.**

The listener already uses only stdlib. Adding `requests` would be the first third-party dependency on a security-critical component. `urllib.request.urlopen` with a `Request` object handles headers and TLS fine for a single endpoint.

**D-03: `github_token` lives in `webhook.json` at the top level.**

It is not per-profile because (a) a single PAT can be scoped to multiple repos and (b) profile.json files are written by the CLI and readable by less-privileged processes. `webhook.json` is root-owned (mode 600).

Per-profile token was considered for multi-tenant scenarios, but this project is single-user; top-level is simpler.

**D-04: Diff filter is opt-in via a new per-profile `todo_path_pattern` field.**

If `todo_path_pattern` is absent (or no `github_token` in global config), the listener behaves exactly as today — no diff fetch, spawns on every push. This preserves backward compatibility for any profile that doesn't need the filter.

The obsidian `profile.json` will add:
```json
"todo_path_pattern": "projects/*/TODOS.md"
```

**D-05: Open-item change detection uses three rules on the unified diff.**

For each `+` line in the patch for matching files:
1. `+- [ ]` → new unchecked item added → spawn.
2. `+- [x]` only, paired with a `-` line that was `- [ ]` same text → item checked off → no spawn.
3. `+- [ ] <new text>` that has no corresponding `-` line → open item text changed → spawn.

Implementation: collect removed `- [ ]` lines and added `- [ ] / - [x]` lines; spawn if any net-new open lines exist after reconciliation.

**D-06: CLI subcommand is `claude-secure webhook-listener <subcommand>`.**

Pattern mirrors `bootstrap-docs`:
- `--set-token <pat>` — writes to a new `~/.claude-secure/webhook-listener.env` (mode 600).
- `--set-bind <addr>` / `--set-port <port>` — same env file.
- `status` — reads `webhook.json` for bind/port, calls `GET localhost:<port>/health` for each known instance, shows systemd unit status via `systemctl is-active`.

Multiple instances: the listener already supports arbitrary `bind`+`port` from `webhook.json`. The CLI `status` command reads a list of known config paths from `webhook-listener.env` (or a default single path `/etc/claude-secure/webhook.json`) and queries each.

**D-07: Report-Repo-Token removal is a clean delete.**

Search `bin/claude-secure`, `README.md`, and prompt templates for `REPORT_REPO_TOKEN`, `report_repo_token`, `publish_report`, and related strings. Delete dead code paths entirely — no deprecation shim, no comment.

## Risks / Trade-offs

- **GitHub API rate limit** → PATs have 5,000 req/hour; pushes to a personal vault are at most tens per day. Not a concern.
- **Network failure on diff fetch** → If the GitHub API call fails, fail open: log a warning and spawn anyway (same behavior as today). This is a conservative choice — a failed filter should not silently suppress a spawn.
- **Large patch truncation** → GitHub returns full patches up to ~1MB. Obsidian vault commits are tiny; this is not a concern.
- **False negatives on todo detection** → The three-rule heuristic (D-05) could miss an edge case (e.g., reordered lines). Acceptable: the worst outcome is a missed spawn, not a security issue.
- **`urllib.request` vs GitHub redirects** → GitHub API doesn't redirect on commit endpoints; no special redirect handling needed.

## Migration Plan

1. Deploy updated `listener.py` (new filter functions, `github_token` reading).
2. Add `github_token` to `/etc/claude-secure/webhook.json` on VPS via CLI: `claude-secure webhook-listener --set-token ghp_...` (or manual edit).
3. Add `todo_path_pattern` to obsidian `profile.json` via CLI or manual edit.
4. Restart `claude-secure-webhook.service`.
5. Push a test TODOS.md change; verify spawn fires.
6. Push a checkbox-only change; verify no spawn.
7. Delete obsidian `prompts/push.md` (or replace with minimal task prompt that assumes spawn was already pre-filtered).

Rollback: remove `todo_path_pattern` from profile.json → filter disabled, listener spawns on all pushes as before.
