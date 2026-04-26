## ADDED Requirements

### Requirement: Architecture topology diagram
The project SHALL include a Mermaid `flowchart TD` diagram in `docs/architecture.md` that shows all three containers (claude, proxy, validator), both Docker Compose networks (internal and external), and the labeled edges between them.

#### Scenario: Topology diagram renders on GitHub
- **WHEN** a user views `docs/architecture.md` on GitHub
- **THEN** the flowchart diagram renders without errors, showing all containers and network boundaries as labeled subgraphs

#### Scenario: Topology diagram covers all containers
- **WHEN** the diagram is reviewed
- **THEN** it MUST include nodes for `claude`, `proxy`, and `validator` containers, and subgraphs for the `internal` and `external` Docker networks

### Requirement: Call chain sequence diagram
The project SHALL include a Mermaid `sequenceDiagram` in `docs/architecture.md` that traces the full lifecycle of a tool invocation from Claude Code through the PreToolUse hook, validator registration, proxy secret redaction, Anthropic API call, response restoration, and final return to Claude Code.

#### Scenario: Sequence diagram renders on GitHub
- **WHEN** a user views `docs/architecture.md` on GitHub
- **THEN** the sequence diagram renders without errors, with participants labeled by service name

#### Scenario: Sequence diagram covers the full call chain
- **WHEN** the diagram is reviewed
- **THEN** it MUST show all of the following steps in order: Claude Code tool invocation → PreToolUse hook → validator `/register` → proxy receives request → proxy redacts secrets → Anthropic API call → proxy restores secrets → response returned to Claude Code

### Requirement: Architecture doc linked from README
The `README.md` SHALL contain a link to `docs/architecture.md` under a dedicated "Architecture" section so users can navigate to the diagrams from the project root.

#### Scenario: README links to architecture doc
- **WHEN** a user reads the README on GitHub
- **THEN** they can find and follow a link to `docs/architecture.md` within an "Architecture" section
