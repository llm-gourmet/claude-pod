## Context

`profile create` already scaffolds `tasks/default.md` and `system_prompts/default.md` via a `create_profile()` function in `bin/claude-secure`. The content is currently a generic placeholder. Three subcommands (`profile <name> system-prompt set/get/clear`) parse and dispatch but have been dead code since the `profile-task-prompts` change moved system prompts to files; they can be deleted safely.

## Goals / Non-Goals

**Goals:**
- `system_prompts/default.md` scaffold tells Claude it is a placeholder and tells the operator the host path to edit.
- `tasks/` scaffold includes a `default.md` fallback and six event-specific files covering the most common GitHub webhook event types.
- Remove three dead CLI subcommands.

**Non-Goals:**
- Generating substantive task content (that is operator responsibility).
- Adding new event-type routing logic.
- Changing migration script behavior for existing profiles.

## Decisions

**D-01: Hardcode six event-type task files.** Rather than making the set configurable, ship a fixed list that covers the event types the webhook listener already routes: `push`, `issues-opened`, `issues-labeled`, `pull-request-opened`, `pull-request-merged`, `workflow-run-completed`. These match the old `webhook/templates/` filenames we removed. An operator who doesn't need a particular event type can leave the placeholder content or delete the file — `default.md` catches everything else.

**D-02: Task file content is a prompted stub, not empty.** Each event-specific file gets a one-line task stub (e.g. `# TODO: describe what Claude should do when a push event arrives`). This is enough for `spawn --dry-run` to succeed out of the box and makes the operator's job obvious, without prescribing content.

**D-03: system_prompts/default.md content addresses Claude, not the operator.** The file is read verbatim as Claude's system prompt. The instructional text ("this is a placeholder; edit at path X on the host") is addressed to Claude so Claude can relay it to the user on first interaction. This matches the user's requirement.

**D-04: Remove system-prompt subcommands without deprecation period.** They have been dead since the last merge — no migration needed.

## Risks / Trade-offs

- [Existing profiles are unaffected] → migration script already handled them; new scaffold only applies to `profile create`.
- [Hardcoded event list may miss niche event types] → `default.md` fallback ensures spawn never fails for unlisted events.
