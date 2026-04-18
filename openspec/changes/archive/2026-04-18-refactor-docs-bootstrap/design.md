## Context

Projects under `projects/` in the Obsidian vault currently have no enforced structure. Each project accumulates files organically. The only file the automation depends on is `todo.md`. A standardized layout enables consistent automation, makes project state discoverable, and separates concerns (vision vs. active tasks vs. completed work vs. decisions).

The bootstrap is a shell script (or equivalent) invoked with a project name. It creates the folder tree and seeds each file from a template.

## Goals / Non-Goals

**Goals:**
- Define the canonical folder structure for a project under `projects/{name}/`
- Provide a bootstrap script that scaffolds the structure with seed templates
- Update the TODO-scanner path pattern to match the new `TODOS.md` filename
- Document the purpose and expected content of each file/folder

**Non-Goals:**
- Migrating existing projects (manual process, out of scope)
- Enforcing structure at runtime (no validation of existing projects)
- Version-controlling the templates separately from the bootstrap script

## Decisions

### File naming: uppercase vs lowercase

Chose uppercase (`TODOS.md`, `TASKS.md`, `VISION.md`, etc.) for top-level documents.

**Rationale**: Uppercase signals "project-level, canonical file" — same convention as `README.md`, `CHANGELOG.md`. Lowercase is used for dated entries in subdirectories where the date prefix already provides hierarchy.

**Alternative considered**: All lowercase (consistent with `todo.md`). Rejected because it loses the visual distinction between canonical project files and dated log entries.

### `/decisions/` date prefix format: `YYYY-MM-`

Entries are named `YYYY-MM-<slug>.md` (e.g., `2026-04-auth-strategy.md`).

**Rationale**: Month granularity is sufficient for decisions; day precision is rarely needed and adds noise. Alphabetical sort equals chronological sort.

### `/ideas/` naming: `idea-<slug>.md`

No date prefix on ideas.

**Rationale**: Ideas are undated by design — they represent possibilities, not events. Adding a date implies a commitment or timeline that doesn't exist yet.

### `/done/` date prefix format: `YYYY-MM-<slug>.md`

Same format as `/decisions/`.

**Rationale**: Completed work is an event in time; the date anchors it to a release or sprint.

### Bootstrap implementation: shell script

A single Bash script `scripts/new-project.sh <project-name>` creates the tree and seeds files.

**Rationale**: Consistent with existing tooling in this project. No new runtime dependencies.

## Risks / Trade-offs

- **BREAKING path change**: `obsidian-todo-scanner` currently looks for `projects/*/todo.md`. Changing to `TODOS.md` silently stops scanning existing projects until they rename the file. → Mitigation: document migration step; existing projects are manually renamed.
- **Template drift**: Templates live in the bootstrap script. If the desired structure changes, old projects bootstrapped earlier won't auto-update. → Mitigation: treat the bootstrap as a one-time scaffold; document templates in the spec.
- **No validation**: Nothing enforces that projects conform to the structure after bootstrap. → Accepted trade-off for now; automation only depends on `TODOS.md`.
