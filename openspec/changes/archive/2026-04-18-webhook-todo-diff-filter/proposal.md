## Why

The obsidian TODO scanner runs a Claude session for every push event just to check if `TODOS.md` was touched — a string-matching problem that costs ~$0.015 per push and fails silently when the model returns the wrong answer (as observed: Haiku returning "keine Änderungen erkannt" despite a clear match). Pure code is faster, cheaper, and deterministic.

## What Changes

- **Replace LLM TODO scanner** with a Python diff filter inside the webhook listener: fetch the commit patch via GitHub API, check for `+- [ ]` additions or open-item line edits in `projects/*/TODOS.md`, spawn only on match.
- **Add `github_token`** field to `webhook.json` (host-only, root-owned) for GitHub API access; token never enters the container.
- **Remove Report-Repo-Token** references from README, bin/claude-secure, and any docs — this pattern is no longer in use.
- **Add `webhook-listener` CLI subcommands** to `bin/claude-secure` (similar to `bootstrap-docs`): configure token/bind/port, show status of all active listener instances.
- **Update tests**: delete old LLM-scanner tests (test-phase9 obsidian prompt tests), add new tests for diff filter logic and CLI subcommands.
- **Remove obsidian push prompt** (`profiles/obsidian/prompts/push.md`) — the listener now decides whether to spawn; the spawn prompt becomes a simple task prompt (no scanner logic).

## Capabilities

### New Capabilities

- `webhook-diff-filter`: Listener-side Python logic that fetches a commit's patch from the GitHub API and detects meaningful TODO changes (new open items or edits to open items) in `projects/*/TODOS.md` files before deciding to spawn.
- `webhook-listener-cli`: `claude-secure webhook-listener` subcommand family — `--set-token`, `--set-bind`, `--set-port`, `status` — mirroring the `bootstrap-docs` pattern, supporting multiple named listener instances.

### Modified Capabilities

- `obsidian-todo-scanner`: Requirements replaced — detection moves from Claude prompt to listener Python code; LLM is no longer in the decision path; spawn only happens after a confirmed meaningful TODO change.

## Impact

- `webhook/listener.py`: new `fetch_commit_patch()` + `has_meaningful_todo_change()` functions; `apply_event_filter` extended to call diff filter when `github_token` is configured and a `todo_path_pattern` is set in profile.
- `webhook/config.example.json`: add `github_token` field.
- `bin/claude-secure`: add `cmd_webhook_listener()` + helpers; dispatch routing; remove Report-Repo-Token references.
- `install.sh`: no new steps needed (token is user-configured post-install).
- `profiles/obsidian/prompts/push.md`: delete or simplify (scanner logic removed).
- `tests/`: delete scanner-specific test cases; add diff-filter unit tests (pure Python, no Docker) and CLI tests.
- `README.md`: update webhook section; remove Report-Repo-Token section.
