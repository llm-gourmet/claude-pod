## Context

claude-pod consists of three containers (claude, proxy, validator) connected across two Docker Compose networks (internal-only and external-capable). The security model depends on specific inter-service call flows: every outbound request from Claude Code is intercepted by a PreToolUse hook, registered with the validator, forwarded through the proxy for secret redaction, and gated by iptables rules. This call chain is invisible from the README alone.

Mermaid is supported natively by GitHub and by most markdown renderers, requiring no build step or external tooling. The diagrams live as fenced code blocks in a markdown file.

## Goals / Non-Goals

**Goals:**
- Produce a container/network topology diagram (C4-style, using Mermaid `graph` or `flowchart`)
- Produce a call-chain sequence diagram (`sequenceDiagram`) covering hook → validator register → proxy redact → Anthropic API → proxy restore → Claude Code response
- Embed both diagrams in `docs/architecture.md` (new file) with explanatory prose
- Link `docs/architecture.md` from `README.md`

**Non-Goals:**
- Interactive diagrams or SVG exports
- Automated diagram generation from code
- Diagrams for installation flow or CI pipeline

## Decisions

**Single dedicated file (`docs/architecture.md`) over inline README embedding**
Embedding large diagrams in `README.md` makes it unwieldy. A dedicated file keeps the README focused on installation and quick-start while making the architecture linkable independently.
*Alternative considered*: Inline in README — rejected because diagram source gets long and disrupts the README reading flow.

**Mermaid `flowchart TD` for topology, `sequenceDiagram` for call chain**
`flowchart` handles nodes, subgraphs (for Docker networks), and labeled edges cleanly. `sequenceDiagram` is the natural fit for time-ordered request/response flows.
*Alternative considered*: `graph LR` — rejected because top-down better reflects the network stack layers.

**No external diagram tooling (draw.io, PlantUML, Miro)**
Mermaid is zero-dependency for viewers (rendered by GitHub) and zero-dependency for editors (just text). All other options require either a build step or external service access, which conflicts with the project's minimal-dependency philosophy.

## Risks / Trade-offs

- [Mermaid syntax support varies by renderer] → Diagrams are tested against GitHub's renderer (the primary target). Complex subgraph nesting can break in some renderers — keep nesting shallow.
- [Diagrams drift from code] → Diagrams are documentation, not generated code. A note in `docs/architecture.md` will reference the source files they describe so future maintainers know what to update.

## Migration Plan

1. Create `docs/architecture.md` with both diagrams
2. Add a link in `README.md` under an "Architecture" section
3. No rollback needed — pure documentation addition
