## Why

Claude receives the task file but has no knowledge of the event that triggered the spawn — no commit messages, no issue title, no PR body, nothing. Without the payload, Claude must rely entirely on `git` commands or API calls to discover what happened, which is slow and impossible for events with no git footprint (issues, comments, labels).

## What Changes

- `bin/claude-secure` `do_spawn`: after loading the task file, the full event JSON is appended to the rendered prompt as a fenced code block, always, unconditionally
- `create_profile()` bootstrap stubs: the generated `tasks/*.md` files for new profiles are updated to reference the payload section and show concrete examples of how to use event fields

## Capabilities

### New Capabilities

- `spawn-event-payload`: spawn appends the complete webhook event JSON to the human-turn prompt before passing it to Claude, giving every task file access to the full payload without any template configuration

### Modified Capabilities

- `cli-profile-create`: stub task files created during `create_profile()` are updated to document the payload block and demonstrate usage patterns for common event types

## Impact

- `bin/claude-secure`: `do_spawn` function — append block after task file content
- `bin/claude-secure`: `create_profile()` function — updated task stub strings
- All existing spawns: Claude now always receives the payload (additive only, no breaking changes to task file format)
