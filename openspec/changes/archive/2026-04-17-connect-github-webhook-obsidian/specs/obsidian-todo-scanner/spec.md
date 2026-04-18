## ADDED Requirements

### Requirement: obsidian profile routes push events from llm-gourmet/obsidian
A claude-secure profile named `obsidian` SHALL exist with `"repo": "llm-gourmet/obsidian"`, a `webhook_secret`, and a push event filter restricted to `["master", "main"]`. The webhook listener SHALL route all matching push events to this profile.

#### Scenario: Push to master triggers spawn
- **WHEN** GitHub sends a push event for `llm-gourmet/obsidian` on branch `master`
- **THEN** the webhook listener resolves the `obsidian` profile, verifies the HMAC signature, and calls `claude-secure spawn --profile obsidian --event-file <path>`

#### Scenario: Push to non-master branch is filtered
- **WHEN** GitHub sends a push event for `llm-gourmet/obsidian` on branch `feature/xyz`
- **THEN** the listener returns HTTP 202 with `{"status": "filtered", "reason": "branch_not_matched:feature/xyz"}` and no spawn is triggered

#### Scenario: Unknown repo rejected
- **WHEN** GitHub sends a push event for a repo other than `llm-gourmet/obsidian`
- **THEN** the listener returns HTTP 404 with `{"error": "unknown_repo"}`

### Requirement: TODO scanner detects projects/*/todo.md changes from event JSON
The obsidian profile's push prompt template SHALL instruct Claude to inspect `{{COMMITS_JSON}}` for file paths matching `projects/*/todo.md` (exactly: `projects/` + single path segment + `/todo.md`) across all commits' `added` and `modified` arrays. Claude SHALL NOT run shell commands or read files.

#### Scenario: Commit contains a new todo.md
- **WHEN** `{{COMMITS_JSON}}` contains a commit with `"added": ["projects/myproject/todo.md"]`
- **THEN** Claude outputs a line containing `TODO-Scanner: neue TODOs erkannt in: projects/myproject/todo.md`

#### Scenario: Commit modifies an existing todo.md
- **WHEN** `{{COMMITS_JSON}}` contains a commit with `"modified": ["projects/myproject/todo.md"]`
- **THEN** Claude outputs a line containing `TODO-Scanner: neue TODOs erkannt in: projects/myproject/todo.md`

#### Scenario: Commit touches no todo.md files
- **WHEN** no file path matching `projects/*/todo.md` appears in any commit's `added` or `modified` array
- **THEN** Claude outputs exactly `TODO-Scanner: keine Änderungen erkannt.` and stops

#### Scenario: Multiple todo.md files changed
- **WHEN** commits contain changes to `projects/alpha/todo.md` and `projects/beta/todo.md`
- **THEN** Claude outputs both file paths in the result line

### Requirement: Caddy exposes webhook listener to GitHub
Caddy SHALL be configured as a reverse proxy forwarding requests to `<public-host>/webhook` → `localhost:9000/webhook`. The GitHub webhook endpoint SHALL be reachable from GitHub's IP ranges.

#### Scenario: Webhook delivery reaches listener
- **WHEN** GitHub delivers a POST to `http(s)://<vps-host>/webhook`
- **THEN** Caddy forwards the request to `localhost:9000` preserving headers including `X-Hub-Signature-256` and `X-GitHub-Event`

#### Scenario: Health check accessible
- **WHEN** a GET request is sent to `localhost:9000/health`
- **THEN** the listener returns HTTP 200 with `{"status": "ok"}`

### Requirement: Spawn result captured in logs
The output of the Claude TODO-scanner session SHALL be captured in `~/.claude-secure/logs/spawns/<delivery_id>.log` and accessible without additional tooling.

#### Scenario: Scan result visible in spawn log
- **WHEN** a spawn completes (TODO found or not found)
- **THEN** `~/.claude-secure/logs/spawns/<delivery_id>.log` contains Claude's one-line output
