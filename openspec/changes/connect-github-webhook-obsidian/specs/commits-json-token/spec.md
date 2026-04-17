## ADDED Requirements

### Requirement: commits-json token available in push templates
The `render_template` function in `bin/claude-secure` SHALL substitute the token `{{COMMITS_JSON}}` with the compact JSON representation of the `commits` array from the GitHub push event payload. If the `commits` key is absent, the token SHALL be replaced with the empty JSON array `[]`.

#### Scenario: Push event with changed files
- **WHEN** a push event payload contains `"commits": [{"id": "abc", "added": ["projects/foo/todo.md"], "modified": [], "removed": []}]`
- **THEN** `{{COMMITS_JSON}}` in the rendered template is replaced with `[{"id":"abc","added":["projects/foo/todo.md"],"modified":[],"removed":[]}]`

#### Scenario: Push event with no commits key
- **WHEN** the event JSON does not contain a `commits` key
- **THEN** `{{COMMITS_JSON}}` is replaced with `[]`

#### Scenario: Existing templates unaffected
- **WHEN** a template does not contain the `{{COMMITS_JSON}}` token
- **THEN** `render_template` output is identical to before this change

#### Scenario: Token available across all event types
- **WHEN** `render_template` is called for any event type (push, issues, workflow_run)
- **THEN** `{{COMMITS_JSON}}` substitution is applied; for non-push events it resolves to `[]`
