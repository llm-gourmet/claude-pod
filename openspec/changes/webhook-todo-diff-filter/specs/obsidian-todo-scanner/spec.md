## MODIFIED Requirements

### Requirement: TODO detection moves from Claude prompt to listener diff filter
The obsidian profile SHALL no longer use a Claude prompt to detect TODO changes. Instead, the webhook listener SHALL evaluate commit patches directly (via `webhook-diff-filter`) before deciding to spawn. The `prompts/push.md` template for the obsidian profile SHALL be replaced with a simple task prompt that assumes the spawn was already pre-filtered.

#### Scenario: Spawn only fires on meaningful TODO change
- **WHEN** GitHub sends a push event for `llm-gourmet/obsidian` containing a commit that adds a new `- [ ]` line in `projects/*/TODOS.md`
- **THEN** the listener spawns a Claude session

#### Scenario: No spawn on checkbox-only change
- **WHEN** GitHub sends a push event where the only change in any `projects/*/TODOS.md` is converting `- [ ]` to `- [x]`
- **THEN** the listener returns HTTP 202 with `{"status": "filtered", "reason": "todo_no_meaningful_change"}` and no spawn occurs

#### Scenario: No spawn when TODOS.md not touched
- **WHEN** GitHub sends a push event where no `projects/*/TODOS.md` file appears in any commit's `added` or `modified` array
- **THEN** no spawn occurs (existing branch/path filter behavior unchanged)

## REMOVED Requirements

### Requirement: TODO scanner detects projects/*/TODOS.md changes from event JSON
**Reason**: Detection moved to listener Python code (webhook-diff-filter). LLM is no longer in the decision path; this eliminates model reliability issues and per-push API costs.
**Migration**: Remove `prompts/push.md` scanner prompt from obsidian profile. Add `todo_path_pattern: "projects/*/TODOS.md"` to obsidian `profile.json`. Ensure `github_token` is set in `webhook.json`.
