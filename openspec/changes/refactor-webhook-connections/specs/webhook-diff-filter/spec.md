## MODIFIED Requirements

### Requirement: github_token stored in connections.json, never in container
The `github_token` field in `~/.claude-secure/webhooks/connections.json` SHALL be the only place the PAT is stored. It SHALL NOT be injected into any container environment variable, prompt template, or event file.

#### Scenario: Token absent from spawn log
- **WHEN** a webhook event is processed after a diff-filter pass
- **THEN** the spawn log (`logs/spawns/<delivery_id>.log`) contains no occurrence of the PAT value

#### Scenario: Token absent from event file
- **WHEN** a push event is persisted to `events/`
- **THEN** the event JSON file contains no `github_token` field
