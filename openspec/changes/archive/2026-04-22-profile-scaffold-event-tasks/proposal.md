## Why

`profile create` currently scaffolds `tasks/default.md` and `system_prompts/default.md` with generic placeholder content, and retains three obsolete CLI subcommands (`profile <name> system-prompt set/get/clear`) that were superseded when system prompts moved to files. New users get no guidance on how the files work and no ready-to-use event-specific task templates.

## What Changes

- `profile create` writes a self-describing `system_prompts/default.md` that explains to Claude (and the operator) how to update the file on the host.
- `profile create` writes event-specific task files for common GitHub webhook event types (`push.md`, `issues-opened.md`, `issues-labeled.md`, `pull-request-opened.md`, `pull-request-merged.md`, `workflow-run-completed.md`) alongside the existing `tasks/default.md`.
- **BREAKING**: Remove `profile <name> system-prompt set`, `profile <name> system-prompt get`, and `profile <name> system-prompt clear` subcommands — these are dead code since the `profile-task-prompts` migration.

## Capabilities

### New Capabilities

- `profile-system-prompt-scaffold`: Default content for `system_prompts/default.md` that informs Claude it is a placeholder and tells the operator where to edit it.
- `profile-event-task-scaffold`: Event-specific task file templates created during `profile create` for the most common GitHub webhook event types.

### Modified Capabilities

- `cli-profile-create`: `profile create` gains event-task scaffold files and an improved system prompt scaffold. The `system-prompt` subcommand group is removed.

## Impact

- `bin/claude-secure`: update `create_profile()` scaffolding, remove `profile_system_prompt_set/get/clear` functions and their dispatch branches.
- `README.md`: remove `system-prompt set/get/clear` from CLI reference.
