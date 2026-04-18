## ADDED Requirements

### Requirement: Bootstrap script creates standard project folder structure
A script `scripts/new-project.sh <project-name>` SHALL create the following folder tree under `projects/<project-name>/`:

```
projects/<project-name>/
  VISION.md
  GOALS.md
  AGREEMENTS.md
  decisions/
  ideas/
  done/
  TODOS.md
  TASKS.md
```

Each file SHALL be seeded from its corresponding template in `scripts/templates/`. The script SHALL exit with a non-zero status and print an error if `projects/<project-name>/` already exists.

#### Scenario: New project scaffolded successfully
- **WHEN** `scripts/new-project.sh my-project` is run and `projects/my-project/` does not exist
- **THEN** the directory `projects/my-project/` is created with all files and subdirectories listed above, each containing its seed template content

#### Scenario: Project already exists is rejected
- **WHEN** `scripts/new-project.sh my-project` is run and `projects/my-project/` already exists
- **THEN** the script exits with status 1 and prints `Error: projects/my-project already exists`

#### Scenario: Missing argument is rejected
- **WHEN** `scripts/new-project.sh` is run with no arguments
- **THEN** the script exits with status 1 and prints `Usage: new-project.sh <project-name>`

### Requirement: VISION.md seeded from template
The seeded `VISION.md` SHALL contain a `# Vision` heading, a blockquote `> Eine Zeile. Ein Bild. Kein Datum.`, a placeholder line `[Hier steht die Vision des Projekts.]`, and a footer note. The file is intended to change rarely; changes are significant.

#### Scenario: VISION.md seeded with correct template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/VISION.md` starts with `# Vision` and contains the blockquote `> Eine Zeile. Ein Bild. Kein Datum.`

### Requirement: GOALS.md seeded from template
The seeded `GOALS.md` SHALL contain a `# Goals` heading with two subsections: `## Strategisch` (table with columns: Ziel, Fällig, Status, Verantwortlich) and `## Taktisch` (table with columns: Ziel, Fällig, Status, Verknüpft mit). Status tags `[aktiv]` `[erreicht]` `[verworfen]` SHALL be documented. Entries are never deleted.

#### Scenario: GOALS.md seeded with correct template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/GOALS.md` contains `## Strategisch` and `## Taktisch` headings, each with a markdown table

### Requirement: AGREEMENTS.md seeded from template
The seeded `AGREEMENTS.md` SHALL contain a `# Agreements` heading with the description "Dinge, auf die wir uns geeinigt haben, sie nicht zu tun." Each entry SHALL use `**Entscheidung:**`, `**Begründung:**`, `**Datum:**` fields. The template includes one placeholder entry and one example entry.

#### Scenario: AGREEMENTS.md seeded with correct template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/AGREEMENTS.md` contains `# Agreements` heading and at least one entry block with `**Entscheidung:**` field

### Requirement: TODOS.md seeded from template
The seeded `TODOS.md` SHALL contain a `# Todos` heading with description "Kleine Aufgaben. Einzeiliger Kontext oder keiner." followed by placeholder `- [ ]` checklist items. This file is the target scanned by the obsidian-todo-scanner.

#### Scenario: TODOS.md seeded with correct template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/TODOS.md` starts with `# Todos` and contains at least one `- [ ]` line

### Requirement: TASKS.md seeded from template
The seeded `TASKS.md` SHALL contain a `# Tasks` heading with description "Größere Aufgaben. Kontext kommt aus der verlinkten Idee." Each task entry SHALL use `**Idee:**`, `**Status:**`, `**Fällig:**`, and `**Abhängigkeiten:**` fields. Status values: `[offen]` / `[in Arbeit]` / `[abgeschlossen]` / `[abgewiesen]`.

#### Scenario: TASKS.md seeded with correct template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/TASKS.md` contains `# Tasks` heading and at least one task block with `**Idee:**` and `**Status:**` fields

### Requirement: decisions/ contains a template file for new ADRs
The `decisions/` subdirectory SHALL contain `_template.md` seeded from the decisions template. ADR files are named `YYYY-MM-<slug>.md`. Each ADR SHALL contain `## Kontext`, `## Optionen`, `## Entscheidung`, `## Offene Fragen` sections, plus `**Datum:**`, `**Status:**`, `**Beteiligte:**` metadata. Revisions are appended, never overwritten.

#### Scenario: decisions/ created with template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/decisions/_template.md` exists and contains `## Kontext` and `## Entscheidung` headings

### Requirement: ideas/ contains a template file for new ideas
The `ideas/` subdirectory SHALL contain `_template.md` seeded from the ideas template. Idea files are named `idea-<slug>.md` (no date prefix). Each idea SHALL contain `## Kern`, `## Motivation`, `## Offene Fragen`, `## Notizen` sections, plus `**Erstellt:**` and `**Status:**` metadata. Status values: `[offen]` / `[in Umsetzung]` / `[umgesetzt]` / `[verworfen]`.

#### Scenario: ideas/ created with template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/ideas/_template.md` exists and contains `## Kern` and `## Motivation` headings

### Requirement: done/ contains a template file for completion summaries
The `done/` subdirectory SHALL contain `_template.md` seeded from the done template. Completion files are named `YYYY-MM-<slug>.md`. Each entry SHALL contain `## Was wurde gemacht / abgewiesen` and `## Kontext` sections, plus `**Abgeschlossen:**`, `**Status:**`, `**Verknüpfte Idee:**` metadata. Status values: `[umgesetzt]` / `[abgewiesen]`.

#### Scenario: done/ created with template
- **WHEN** `scripts/new-project.sh my-project` completes successfully
- **THEN** `projects/my-project/done/_template.md` exists and contains `## Was wurde gemacht / abgewiesen` heading
