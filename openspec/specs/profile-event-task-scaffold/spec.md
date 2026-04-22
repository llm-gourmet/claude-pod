## Requirements

### Requirement: Event-specific task files created on profile create
`profile create` SHALL create the following task files under `tasks/` alongside `tasks/default.md`:

- `push.md`
- `issues-opened.md`
- `issues-labeled.md`
- `pull-request-opened.md`
- `pull-request-merged.md`
- `workflow-run-completed.md`

Each file SHALL contain a single-line stub comment instructing the operator to describe what Claude should do for that event type (e.g. `# TODO: describe what Claude should do when a push event arrives`).

#### Scenario: All event files are created
- **WHEN** `profile create myproj` is run
- **THEN** `tasks/push.md`, `tasks/issues-opened.md`, `tasks/issues-labeled.md`, `tasks/pull-request-opened.md`, `tasks/pull-request-merged.md`, and `tasks/workflow-run-completed.md` all exist under the new profile directory

#### Scenario: spawn resolves event-specific file without default fallback
- **WHEN** a `push` event triggers spawn for the new profile
- **THEN** `resolve_task_file` returns `tasks/push.md` (not `tasks/default.md`)

#### Scenario: spawn --dry-run succeeds immediately after profile create
- **WHEN** `claude-pod spawn <name> --event '{"event_type":"push",...}' --dry-run` is run on a freshly created profile
- **THEN** exit code is 0 and `task_file:` line names `tasks/push.md`
