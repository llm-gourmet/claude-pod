## REMOVED Requirements

### Requirement: system-prompt set subcommand
**Reason**: System prompts moved to `system_prompts/default.md` in the `profile-task-prompts` change. The subcommand has been dead code since that merge.
**Migration**: Edit `~/.claude-secure/profiles/<name>/system_prompts/default.md` directly on the host.

### Requirement: system-prompt get subcommand
**Reason**: System prompts moved to files. `cat ~/.claude-secure/profiles/<name>/system_prompts/default.md` replaces this command.
**Migration**: Use `cat ~/.claude-secure/profiles/<name>/system_prompts/default.md`.

### Requirement: system-prompt clear subcommand
**Reason**: System prompts moved to files. Deleting or emptying `system_prompts/default.md` replaces this command.
**Migration**: Delete or empty `~/.claude-secure/profiles/<name>/system_prompts/default.md`.

## MODIFIED Requirements

### Requirement: profile create scaffolds profile directory
`claude-secure profile create <name>` SHALL create the following structure:

```
~/.claude-secure/profiles/<name>/
  profile.json
  .env
  tasks/
    default.md          ← generic fallback stub
    push.md
    issues-opened.md
    issues-labeled.md
    pull-request-opened.md
    pull-request-merged.md
    workflow-run-completed.md
  system_prompts/
    default.md          ← self-describing placeholder addressed to Claude
```

#### Scenario: Full directory structure is created
- **WHEN** `claude-secure profile create myproj` completes
- **THEN** all files listed above exist under `~/.claude-secure/profiles/myproj/`

#### Scenario: system-prompt subcommand is gone
- **WHEN** `claude-secure profile myproj system-prompt set "hello"` is run
- **THEN** exit code is non-zero and an "unknown subcommand" error is printed
