## Why

Project documentation currently has no standardized structure, making it hard to find decisions, track ideas, and separate completed work from active tasks. A consistent scaffold with opinionated templates allows the TODO-scanner and other automation to locate and interpret project state reliably.

## What Changes

- Replace current documentation structure with a new folder layout under `projects/{project-name}/`
- Add top-level identity files: `VISION.md`, `GOALS.md`, `AGREEMENTS.md`
- Add `/decisions/` folder for dated Architecture Decision Records (ADRs)
- Add `/ideas/` folder for loose ideas (not yet committed)
- Add `/done/` folder for dated completed-work summaries
- Replace `todo.md` with `TODOS.md` (current open items) and `TASKS.md` (active in-progress tasks)
- Provide file templates for each document type
- Update bootstrap script to scaffold the new structure when initializing a new project

## Capabilities

### New Capabilities

- `docs-bootstrap`: Scaffold command / script that creates the new folder structure and seed templates under `projects/{project-name}/` for a new project

### Modified Capabilities

- `obsidian-todo-scanner`: Scanner path pattern changes from `projects/*/todo.md` to `projects/*/TODOS.md` — **BREAKING** requirement change

## Impact

- Bootstrap script (new or updated) that generates `projects/{project-name}/` folder tree with templated files
- `obsidian-todo-scanner` spec must be updated: file path pattern `projects/*/todo.md` → `projects/*/TODOS.md`
- Any existing `todo.md` files in `projects/` would need manual migration (out of scope for this change)
