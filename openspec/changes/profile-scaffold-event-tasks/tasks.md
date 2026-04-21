## 1. Profile Create Scaffolding

- [x] 1.1 Update `create_profile()` in `bin/claude-secure` — write `system_prompts/default.md` with self-describing content that addresses Claude and includes the literal host path `~/.claude-secure/profiles/<name>/system_prompts/`
- [x] 1.2 Update `create_profile()` — write `tasks/default.md` with a generic fallback stub comment
- [x] 1.3 Update `create_profile()` — write `tasks/push.md` with a push-event stub comment
- [x] 1.4 Update `create_profile()` — write `tasks/issues-opened.md` with an issues-opened stub comment
- [x] 1.5 Update `create_profile()` — write `tasks/issues-labeled.md` with an issues-labeled stub comment
- [x] 1.6 Update `create_profile()` — write `tasks/pull-request-opened.md` with a PR-opened stub comment
- [x] 1.7 Update `create_profile()` — write `tasks/pull-request-merged.md` with a PR-merged stub comment
- [x] 1.8 Update `create_profile()` — write `tasks/workflow-run-completed.md` with a workflow-run stub comment

## 2. Remove Obsolete Subcommands

- [x] 2.1 Remove `profile_system_prompt_set()`, `profile_system_prompt_get()`, `profile_system_prompt_clear()` functions from `bin/claude-secure`
- [x] 2.2 Remove the `system-prompt` dispatch branch from the `profile` subcommand handler in `bin/claude-secure`
- [x] 2.3 Remove `system-prompt set/get/clear` entries from `bin/claude-secure` help text and README

## 3. Tests

- [x] 3.1 Test: `profile create` produces all eight scaffold files (`tasks/default.md` + 6 event files + `system_prompts/default.md`)
- [x] 3.2 Test: `system_prompts/default.md` contains the profile name in the host path
- [x] 3.3 Test: `spawn --dry-run` on a fresh profile resolves `tasks/push.md` for a push event
- [x] 3.4 Test: `profile <name> system-prompt set` exits non-zero with unknown-subcommand error
