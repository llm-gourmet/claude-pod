## 1. Research existing specs

- [x] 1.1 List all directories under `openspec/specs/` and note each spec name
- [x] 1.2 Read each `spec.md` (or its title/first section) to write a one-line description per spec

## 2. Create the index file

- [x] 2.1 Create `index.md` with a top-level heading and maintenance note
- [x] 2.2 Add `## CLI & Spawn` section and list: cli-start-command, cli-spawn-positional, cli-profile-create, unified-cli, update-command, spawn-event-payload
- [x] 2.3 Add `## Profiles & System Prompts` section and list: profile-schema, profile-system-prompt-files, profile-system-prompt-scaffold, profile-event-task-scaffold, profile-task-files
- [x] 2.4 Add `## Webhooks` section and list: webhook-connections, webhook-listener-cli, webhook-diff-filter, webhook-spawn-always, gh-webhook-filter-cli, gh-webhook-filter-eval
- [x] 2.5 Add `## Documentation & Bootstrapping` section and list: docs-bootstrap, docs-bootstrap-connections, bootstrap-docs-command
- [x] 2.6 Add `## Auth & Networking` section and list: api-key-base-url, apikey-auth, commits-json-token, host-dep-auto-install, obsidian-todo-scanner

## 3. Verify

- [x] 3.1 Confirm every directory under `openspec/specs/` has an entry in the index (no orphans, no extras)
- [x] 3.2 Confirm all links resolve (each `spec.md` path exists)
- [x] 3.3 Confirm maintenance note is present in the file
