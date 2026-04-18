## MODIFIED Requirements

### Requirement: TODO scanner detects projects/*/TODOS.md changes from event JSON
The obsidian profile's push prompt template SHALL instruct Claude to inspect `{{COMMITS_JSON}}` for file paths matching `projects/*/TODOS.md` (exactly: `projects/` + single path segment + `/TODOS.md`) across all commits' `added` and `modified` arrays. Claude SHALL NOT run shell commands or read files.

#### Scenario: Commit contains a new TODOS.md
- **WHEN** `{{COMMITS_JSON}}` contains a commit with `"added": ["projects/myproject/TODOS.md"]`
- **THEN** Claude outputs a line containing `TODO-Scanner: neue TODOs erkannt in: projects/myproject/TODOS.md`

#### Scenario: Commit modifies an existing TODOS.md
- **WHEN** `{{COMMITS_JSON}}` contains a commit with `"modified": ["projects/myproject/TODOS.md"]`
- **THEN** Claude outputs a line containing `TODO-Scanner: neue TODOs erkannt in: projects/myproject/TODOS.md`

#### Scenario: Commit touches no TODOS.md files
- **WHEN** no file path matching `projects/*/TODOS.md` appears in any commit's `added` or `modified` array
- **THEN** Claude outputs exactly `TODO-Scanner: keine Änderungen erkannt.` and stops

#### Scenario: Multiple TODOS.md files changed
- **WHEN** commits contain changes to `projects/alpha/TODOS.md` and `projects/beta/TODOS.md`
- **THEN** Claude outputs both file paths in the result line

#### Scenario: Old todo.md path is not matched
- **WHEN** `{{COMMITS_JSON}}` contains a commit with `"modified": ["projects/myproject/todo.md"]`
- **THEN** Claude outputs exactly `TODO-Scanner: keine Änderungen erkannt.` and stops
