## REMOVED Requirements

### Requirement: Listener fetches commit patch and filters TODO-only spawns
**Reason**: Diff-based filtering moves out of Python and into Claude Code's reasoning. The spawned session receives the full event JSON (including commit metadata) and a system prompt that describes filter criteria in natural language. `has_meaningful_todo_change()`, `fetch_commit_patch()`, and `todo_path_pattern` are removed from `listener.py`.
**Migration**: Add a system prompt to the connection's profile that replicates the filter intent. Example: "If the push does not add a new unchecked item (`- [ ]`) under `## Offene Fragen` in a `projects/*/ideas/idee.md` file, exit immediately without taking any action."

### Requirement: github_token stored in connections.json, never in container
**Reason**: The `github_token` field in `connections.json` was used exclusively by the diff filter to call the GitHub API. With the diff filter removed, the token is no longer needed by the listener. If Claude Code needs a GitHub token during a spawned session, it is provided via the profile's `.env` file (existing secret injection mechanism), not via `connections.json`.
**Migration**: Move any `github_token` value from `connections.json` to the profile's `.env` as `GITHUB_TOKEN=<value>`. Then remove the field from `connections.json`.
