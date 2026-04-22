# cli-profile-create Specification

## Purpose
TBD - created by archiving change refactor-cli-profile-commands. Update Purpose after archive.
## Requirements

<!-- REMOVED by change unify-cli-and-readme: Requirement "--profile flag only creates a profile and exits" was removed. The `--profile` flag is replaced by `claude-secure profile create <name>`. All profile operations now live under the `profile` subcommand. See unified-cli spec. -->

<!-- REMOVED by change profile-scaffold-event-tasks: Requirements "system-prompt set subcommand", "system-prompt get subcommand", and "system-prompt clear subcommand" were removed. System prompts moved to system_prompts/default.md file-based configuration. -->

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

### Requirement: profile create scaffolds task files with payload documentation
`create_profile()` SHALL scaffold `tasks/` stub files that document the event payload block available at runtime. Each stub SHALL include a comment explaining that the full webhook event JSON is appended automatically by spawn, and SHALL show the relevant event-type fields a task author would typically reference (e.g., `commits[]` for push, `issue` for issues events).

#### Scenario: push.md stub references commit payload
- **WHEN** a new profile is created
- **THEN** `tasks/push.md` contains a comment or example referencing `commits` from the appended event payload

#### Scenario: issues-opened.md stub references issue payload
- **WHEN** a new profile is created
- **THEN** `tasks/issues-opened.md` contains a comment or example referencing `issue.title` or `issue.body` from the appended event payload

#### Scenario: default.md stub explains payload availability
- **WHEN** a new profile is created
- **THEN** `tasks/default.md` explains that the full event JSON is appended to the prompt by spawn and can be used for any event type
