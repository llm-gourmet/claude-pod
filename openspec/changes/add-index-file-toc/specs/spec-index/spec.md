## ADDED Requirements

### Requirement: Index file exists at index.md
The repository SHALL contain a file at `index.md` that serves as a table of contents for all capability specs.

#### Scenario: File is present and readable
- **WHEN** a contributor navigates to `openspec/specs/`
- **THEN** `INDEX.md` SHALL be present and list every spec in the directory

### Requirement: Each spec has an entry with description and link
The index SHALL list every capability spec as a line containing the spec name, a one-line description, and a relative Markdown link to its `spec.md`.

#### Scenario: Spec entry format
- **WHEN** a spec named `foo-bar` exists at `openspec/specs/foo-bar/spec.md`
- **THEN** the index SHALL contain an entry of the form `- [foo-bar](foo-bar/spec.md): <description>`

### Requirement: Specs are grouped by functional area
The index SHALL organize specs under named section headers corresponding to functional areas (e.g., CLI & Spawn, Profiles, Webhooks, Documentation, Auth & Networking).

#### Scenario: Grouped rendering
- **WHEN** the index is rendered as Markdown
- **THEN** each functional area SHALL appear as a `##` section header with its specs listed below it

### Requirement: Index includes a maintenance note
The index SHALL include a note instructing contributors to update the file when adding or archiving a spec.

#### Scenario: Maintenance reminder present
- **WHEN** the index file is opened
- **THEN** a note SHALL be visible reminding contributors to keep the index up to date
