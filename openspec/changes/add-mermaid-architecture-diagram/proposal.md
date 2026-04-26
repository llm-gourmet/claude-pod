## Why

claude-pod's four-layer security architecture (Docker isolation, PreToolUse hooks, Anthropic proxy, iptables validator) is non-trivial to understand from code alone. A Mermaid diagram embedded in the docs makes the architecture, component dependencies, and call chain immediately visible to new contributors and users evaluating the tool.

## What Changes

- Add a Mermaid architecture diagram showing containers, networks, and inter-service relationships
- Add a Mermaid sequence diagram showing the full call chain from Claude Code tool invocation through hook validation, proxy secret redaction, and iptables enforcement
- Embed both diagrams in the project README (or a dedicated `docs/architecture.md`)

## Capabilities

### New Capabilities
- `mermaid-architecture-diagram`: Static Mermaid diagram files and their embedding location in project documentation, covering the container topology (claude, proxy, validator), network segments (internal/external), and the end-to-end call chain from hook to iptables

### Modified Capabilities
<!-- none -->

## Impact

- `README.md` or new `docs/architecture.md`: diagram embedding
- No code changes — documentation only
- No new runtime dependencies
