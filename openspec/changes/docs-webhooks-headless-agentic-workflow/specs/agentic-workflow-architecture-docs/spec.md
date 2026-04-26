## ADDED Requirements

### Requirement: architecture.md documents the agentic headless mode section
`docs/architecture.md` SHALL contain a top-level section titled "Agentic (Headless) Mode" that describes how claude-pod operates as a fully automated agent triggered by GitHub webhooks. The section SHALL appear after the existing interactive architecture sections.

#### Scenario: Section exists in the document
- **WHEN** `docs/architecture.md` is read
- **THEN** the file contains a section headed "Agentic (Headless) Mode"

#### Scenario: Section appears after security and call-chain sections
- **WHEN** the document structure is examined
- **THEN** "Agentic (Headless) Mode" is positioned after "Call Chain Sequence"

### Requirement: architecture.md includes a Mermaid diagram for the webhook-to-spawn pipeline
The agentic mode section SHALL include a Mermaid flowchart diagram that traces the full path from an incoming GitHub webhook through to the running headless Claude instance. The diagram SHALL include: webhook arrival, HMAC verification (with failure exit), connection lookup, skip-filter evaluation (with skip exit), event file persistence, `claude-pod spawn` invocation, system prompt resolution, and `claude -p` execution.

#### Scenario: Diagram is a Mermaid flowchart
- **WHEN** the "Agentic (Headless) Mode" section is read
- **THEN** it contains a fenced ```mermaid block with a `flowchart` directive

#### Scenario: Diagram shows HMAC failure path
- **WHEN** the diagram is examined
- **THEN** there is an explicit branch for HMAC verification failure that exits with a non-spawn outcome

#### Scenario: Diagram shows skip-filter branch
- **WHEN** the diagram is examined
- **THEN** there is an explicit branch for when a skip-filter matches (no spawn)

#### Scenario: Diagram shows spawn and headless Claude node
- **WHEN** the diagram is examined
- **THEN** nodes for `claude-pod spawn` and `claude -p` (headless) are present

### Requirement: architecture.md documents the profile directory structure
The agentic mode section SHALL describe the profile directory layout at `~/.claude-pod/profiles/<name>/` including the three components: `profile.json` (workspace path and secrets), `.env` (secret values), and `system_prompts/` (system prompt files). The description SHALL use a directory-tree code block.

#### Scenario: Directory tree code block is present
- **WHEN** the agentic section is read
- **THEN** it contains a code block showing the `~/.claude-pod/profiles/<name>/` tree with `profile.json`, `.env`, and `system_prompts/`

#### Scenario: profile.json fields are described
- **WHEN** the profile directory description is read
- **THEN** `workspace`, `secrets`, `env_var`, `redacted`, and `domains` fields are mentioned

### Requirement: architecture.md documents system prompt resolution order
The agentic mode section SHALL document the three-step system prompt resolution chain: (1) event-specific file `system_prompts/<event_type>.md`, (2) fallback to `system_prompts/default.md`, (3) omit `--system-prompt` if neither exists.

#### Scenario: All three resolution steps are described
- **WHEN** the system prompt resolution description is read
- **THEN** the document describes the event-specific lookup, the default fallback, and the no-prompt case

#### Scenario: Omit-on-missing behavior is documented
- **WHEN** the system prompt section is read
- **THEN** it states that `--system-prompt` is omitted (not an error) when no file exists

### Requirement: architecture.md documents event payload injection into the Claude prompt
The agentic mode section SHALL describe how the full GitHub event JSON is appended to the human-turn prompt sent to `claude -p`. It SHALL mention the `---` separator, the event-type label, and the fenced JSON block format.

#### Scenario: Event payload injection is described
- **WHEN** the spawn mechanics are described
- **THEN** the document explains that the event JSON is appended after a `---` separator in a fenced JSON block

#### Scenario: Manual spawn without event is contrasted
- **WHEN** the event payload section is read
- **THEN** it notes that `--system-prompt` is omitted and no payload block is appended for manual spawns without an event

### Requirement: architecture.md includes numbered step-by-step prose for the headless pipeline
The agentic mode section SHALL include numbered prose steps (matching the style of the existing "Call Chain Sequence" step-by-step) that walk through the headless pipeline: webhook receipt → HMAC verify → connection lookup → filter evaluation → event persist → spawn → system prompt resolve → `claude -p` invocation → completion.

#### Scenario: Numbered steps are present
- **WHEN** the agentic mode section prose is read
- **THEN** it contains a numbered list of at least six steps describing the pipeline

#### Scenario: Steps reference diagram nodes
- **WHEN** the prose steps and diagram are compared
- **THEN** every major diagram branch or node has a corresponding prose description

### Requirement: architecture.md agentic section ends with a source-file reference footer
The agentic mode section SHALL end with an italicized note listing the source files it describes (matching the style of the existing footer: `*These diagrams describe...*`). The note SHALL reference `webhook/listener.py`, `bin/claude-pod` (spawn/profile logic), and `~/.claude-pod/profiles/`.

#### Scenario: Footer note is present
- **WHEN** the end of the agentic section is read
- **THEN** an italicized sentence lists the source files the section describes and instructs authors to update the section when those files change
