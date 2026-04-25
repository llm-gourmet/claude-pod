## 1. Create architecture documentation file

- [x] 1.1 Create `docs/architecture.md` with an intro paragraph describing the four-layer security model
- [x] 1.2 Add Mermaid `flowchart TD` diagram showing containers (claude, proxy, validator) and Docker networks (internal, external) with labeled edges
- [x] 1.3 Add explanatory prose below the topology diagram describing each component and network segment

## 2. Add call chain sequence diagram

- [x] 2.1 Add Mermaid `sequenceDiagram` to `docs/architecture.md` covering the full call chain: Claude Code tool invocation → PreToolUse hook → validator `/register` → proxy redaction → Anthropic API → proxy secret restore → response to Claude Code
- [x] 2.2 Add explanatory prose below the sequence diagram describing each step

## 3. Link from README

- [x] 3.1 Add an "Architecture" section to `README.md` with a brief description and a link to `docs/architecture.md`

## 4. Verify diagrams render

- [x] 4.1 Verify both diagrams render correctly in a local Mermaid renderer or GitHub preview (no syntax errors, all nodes visible)
