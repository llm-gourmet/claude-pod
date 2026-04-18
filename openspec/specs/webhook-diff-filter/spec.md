## ADDED Requirements

### Requirement: Listener fetches commit patch and filters TODO-only spawns
When a push event matches a profile that has `todo_path_pattern` configured and a `github_token` is present in `webhook.json`, the listener SHALL fetch the commit patch from the GitHub API and evaluate whether the change contains a meaningful TODO modification before spawning.

#### Scenario: New open todo item triggers spawn
- **WHEN** a commit modifies `projects/JAD/TODOS.md` and the patch contains a line `+- [ ] some new task`
- **THEN** the listener permits the spawn and persists the event

#### Scenario: Checked-off item suppresses spawn
- **WHEN** a commit modifies `projects/JAD/TODOS.md` and the patch only contains `-  - [ ] done task` paired with `+- [x] done task`
- **THEN** the listener returns HTTP 202 with `{"status": "filtered", "reason": "todo_no_meaningful_change"}` and no spawn occurs

#### Scenario: Edited open item text triggers spawn
- **WHEN** a commit modifies `projects/JAD/TODOS.md` and the patch contains `-  - [ ] old wording` and `+- [ ] new wording`
- **THEN** the listener permits the spawn (a net-new open line exists after reconciliation)

#### Scenario: Non-TODOS.md push is unaffected
- **WHEN** a commit modifies only `projects/JAD/GOALS.md`
- **THEN** the diff filter is not invoked and the event proceeds through normal filter logic

#### Scenario: GitHub API failure fails open
- **WHEN** the GitHub API call to fetch the commit patch returns a non-200 status or raises a network error
- **THEN** the listener logs a warning and permits the spawn (fail-open to avoid silent suppression)

#### Scenario: Profile without todo_path_pattern is unaffected
- **WHEN** a profile has no `todo_path_pattern` field in `profile.json`
- **THEN** the diff filter is not invoked regardless of whether `github_token` is set

### Requirement: github_token stored in webhook.json, never in container
The `github_token` field in `/etc/claude-secure/webhook.json` SHALL be the only place the PAT is stored. It SHALL NOT be injected into any container environment variable, prompt template, or event file.

#### Scenario: Token absent from spawn log
- **WHEN** a spawn is triggered after a diff-filter pass
- **THEN** the spawn log (`logs/spawns/<delivery_id>.log`) contains no occurrence of the PAT value

#### Scenario: Token absent from event file
- **WHEN** a push event is persisted to `events/`
- **THEN** the event JSON file contains no `github_token` field
