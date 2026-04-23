## Requirements

### Requirement: Default system prompt scaffold content
When `profile create` writes `system_prompts/default.md`, the file SHALL contain text that:
1. Informs Claude that this is the default system prompt and it is a placeholder.
2. Instructs Claude to tell the user on the first response that the system prompt is a placeholder and can be updated on the host at `~/.claude-pod/profiles/<profile-name>/system_prompts/`.

The profile name SHALL be substituted into the path at scaffold time (not at runtime).

#### Scenario: File content addresses Claude on first interaction
- **WHEN** `profile create myproj` is run
- **THEN** `~/.claude-pod/profiles/myproj/system_prompts/default.md` exists
- **AND** the file contains the literal text `~/.claude-pod/profiles/myproj/system_prompts/`
- **AND** the file instructs Claude to mention this is a default/placeholder on first response

#### Scenario: File is non-empty
- **WHEN** `profile create` completes
- **THEN** `system_prompts/default.md` is non-empty (more than a comment line)
