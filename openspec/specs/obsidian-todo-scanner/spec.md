## ADDED Requirements

### Requirement: obsidian profile routes push events from llm-gourmet/obsidian
A claude-pod profile named `obsidian` SHALL exist with `"repo": "llm-gourmet/obsidian"`, a `webhook_secret`, and a push event filter restricted to `["master", "main"]`. The webhook listener SHALL route all matching push events to this profile.

#### Scenario: Push to master triggers spawn
- **WHEN** GitHub sends a push event for `llm-gourmet/obsidian` on branch `master`
- **THEN** the webhook listener resolves the `obsidian` profile, verifies the HMAC signature, and calls `claude-pod spawn --profile obsidian --event-file <path>`

#### Scenario: Push to non-master branch is filtered
- **WHEN** GitHub sends a push event for `llm-gourmet/obsidian` on branch `feature/xyz`
- **THEN** the listener returns HTTP 202 with `{"status": "filtered", "reason": "branch_not_matched:feature/xyz"}` and no spawn is triggered

#### Scenario: Unknown repo rejected
- **WHEN** GitHub sends a push event for a repo other than `llm-gourmet/obsidian`
- **THEN** the listener returns HTTP 404 with `{"error": "unknown_repo"}`

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

### Requirement: Caddy exposes webhook listener to GitHub
Caddy SHALL be configured as a reverse proxy forwarding requests to `<public-host>/webhook` → `localhost:9000/webhook`. The GitHub webhook endpoint SHALL be reachable from GitHub's IP ranges.

#### Scenario: Webhook delivery reaches listener
- **WHEN** GitHub delivers a POST to `http(s)://<vps-host>/webhook`
- **THEN** Caddy forwards the request to `localhost:9000` preserving headers including `X-Hub-Signature-256` and `X-GitHub-Event`

#### Scenario: Health check accessible
- **WHEN** a GET request is sent to `localhost:9000/health`
- **THEN** the listener returns HTTP 200 with `{"status": "ok"}`

### Requirement: Spawn result captured in logs
The output of the Claude TODO-scanner session SHALL be captured in `~/.claude-pod/logs/spawns/<delivery_id>.log` and accessible without additional tooling.

#### Scenario: Scan result visible in spawn log
- **WHEN** a spawn completes (TODO found or not found)
- **THEN** `~/.claude-pod/logs/spawns/<delivery_id>.log` contains Claude's one-line output
