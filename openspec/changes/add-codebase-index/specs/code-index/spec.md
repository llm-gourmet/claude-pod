## ADDED Requirements

### Requirement: Code index file at repo root
The system SHALL include a file named `index.md` at the repository root that lists every source file in the project with a one-line description and a relative link to that file.

#### Scenario: File exists at root
- **WHEN** a contributor looks at the repo root
- **THEN** `index.md` is present alongside `README.md` and `CLAUDE.md`

### Requirement: Files grouped by architectural layer
`index.md` SHALL organize entries into sections matching the project's four-layer architecture: orchestration scripts, CLI, container definitions, security services, hooks, utility scripts, and tests.

#### Scenario: Reader can locate a file by layer
- **WHEN** a contributor wants to find the proxy service code
- **THEN** they look under the "Security Services" section and find `proxy/proxy.js` with its description and link

### Requirement: Relative links to source files
Each entry in `index.md` SHALL use a relative Markdown link pointing to the actual source file.

#### Scenario: Links are navigable
- **WHEN** a contributor clicks a link in `index.md` on GitHub or in an editor
- **THEN** they are taken directly to the referenced source file

### Requirement: One-line entry per file
Each source file entry SHALL consist of exactly one line: a relative Markdown link followed by an em-dash (`—`) and a single-sentence description of what the file does.

#### Scenario: Description is concise
- **WHEN** an entry is written
- **THEN** the description fits on a single line and does not exceed one sentence

### Requirement: Maintenance note in file header
`index.md` SHALL include a note at the top instructing contributors to update it whenever a source file is added, renamed, or removed.

#### Scenario: Maintenance expectation is visible
- **WHEN** a contributor opens `index.md`
- **THEN** the first visible content after the title is a maintenance instruction

### Requirement: Tests section lists all test scripts
`index.md` SHALL include a dedicated section for the `tests/` directory that lists every test script file.

#### Scenario: All test scripts are indexed
- **WHEN** the index is complete
- **THEN** every file under `tests/` with a `.sh` extension appears in the Tests section
