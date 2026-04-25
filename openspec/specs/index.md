# Capability Specs Index

> **Maintenance note:** Update this file whenever a spec is added or archived. Each entry should include a one-line description and a relative link to the spec's `spec.md`.

## CLI & Spawn

- [cli-start-command](cli-start-command/spec.md): `claude-pod start <name>` launches an interactive Claude Code session for a named profile, replacing the old `--profile` flag
- [cli-spawn-positional](cli-spawn-positional/spec.md): `claude-pod spawn <name>` runs a headless Claude Code session using a positional profile name, replacing `--profile <name> spawn`
- [cli-profile-create](cli-profile-create/spec.md): `claude-pod profile create <name>` scaffolds the full profile directory with task files and a system prompt placeholder
- [unified-cli](unified-cli/spec.md): Defines the unified CLI surface — all profile operations consolidated under the `profile` subcommand; legacy `--profile` flag removed
- [update-command](update-command/spec.md): Ensures `claude-pod update` exits with status 0 immediately after printing its completion message
- [spawn-event-payload](spawn-event-payload/spec.md): Appends the full event JSON payload to Claude's task prompt during spawn, separated by a `---` block labeled with the event type

## Profiles & System Prompts

- [profile-schema](profile-schema/spec.md): Defines `profile.json` as the single profile config file; removes per-profile `whitelist.json`
- [profile-system-prompt-files](profile-system-prompt-files/spec.md): Defines the event-specific → default resolution chain for system prompt files used during spawn
- [profile-system-prompt-scaffold](profile-system-prompt-scaffold/spec.md): Sets the default placeholder content for `system_prompts/default.md` created by `profile create`
- [profile-event-task-scaffold](profile-event-task-scaffold/spec.md): Defines event-specific task files (`push.md`, `issues-opened.md`, etc.) created alongside `tasks/default.md` on `profile create`
- [profile-task-files](profile-task-files/spec.md): Defines the event-specific → default resolution chain for task prompt files used during spawn

## Webhooks

- [webhook-connections](webhook-connections/spec.md): Defines the schema and storage location for webhook connection config at `~/.claude-pod/webhooks/connections.json`
- [webhook-listener-cli](webhook-listener-cli/spec.md): CLI for managing webhook connections, including writing a GitHub PAT via `gh-webhook-listener --set-token`
- [webhook-diff-filter](webhook-diff-filter/spec.md): Removes diff-based TODO filtering from the listener; delegates filter logic to Claude via system prompt instead
- [webhook-spawn-always](webhook-spawn-always/spec.md): Listener spawns after HMAC verification and skip_filters evaluation only — no branch filtering or diff gating
- [gh-webhook-filter-cli](gh-webhook-filter-cli/spec.md): CLI commands to add `skip_filters` to a webhook connection for suppressing known-irrelevant events
- [gh-webhook-filter-eval](gh-webhook-filter-eval/spec.md): Listener evaluates `skip_filters` against the event payload before spawning and returns HTTP 200 on a match without calling spawn

## Documentation & Bootstrapping

- [docs-bootstrap](docs-bootstrap/spec.md): Defines `scripts/new-project.sh` which creates a standard project folder structure under `projects/<name>/`
- [docs-bootstrap-connections](docs-bootstrap-connections/spec.md): Defines the schema and storage for `bootstrap-docs` connection config at `~/.claude-pod/docs-bootstrap/connections.json`
- [bootstrap-docs-command](bootstrap-docs-command/spec.md): Defines `claude-pod bootstrap-docs --connection <name> <path>` for scaffolding a path in a remote docs repo

## Auth & Networking

- [api-key-base-url](api-key-base-url/spec.md): Prompts for an optional custom base URL when setting up API key authentication
- [apikey-auth](apikey-auth/spec.md): Ensures `ANTHROPIC_API_KEY` is delivered to the Claude container exclusively via `env_file`, not the `environment` block
- [commits-json-token](commits-json-token/spec.md): Makes `{{COMMITS_JSON}}` available as a template token substituted with the push event's `commits` array
- [host-dep-auto-install](host-dep-auto-install/spec.md): Detects and auto-installs missing host dependencies (`curl`, `jq`, `uuidgen`, `python3`) when a supported package manager is present
- [obsidian-todo-scanner](obsidian-todo-scanner/spec.md): Defines an `obsidian` profile that routes push events from `llm-gourmet/obsidian` to Claude
