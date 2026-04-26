## Context

`docs/architecture.md` currently covers only the four-layer security architecture for an interactive claude-pod session. The project has grown a second mode of operation — headless (agentic) mode — where a GitHub webhook triggers a `claude-pod spawn` call, which starts a non-interactive `claude -p` instance inside the same four-layer-secured container. This mode depends on three subsystems that are not documented anywhere: the webhook listener, profiles, and system prompts. The gap means contributors cannot understand the agentic workflow from the docs alone.

All spec-level requirements already exist in `openspec/specs/`: `webhook-connections`, `webhook-listener-cli`, `webhook-spawn-always`, `spawn-event-payload`, `profile-schema`, `profile-system-prompt-files`, `profile-system-prompt-scaffold`. This design is purely additive documentation work.

## Goals / Non-Goals

**Goals:**
- Add an "Agentic (Headless) Mode" section to `docs/architecture.md`
- Include a Mermaid flow diagram tracing: GitHub push → webhook listener → HMAC verify → skip-filter eval → `claude-pod spawn` → headless `claude -p`
- Document the profile directory layout (`profile.json`, `.env`, `system_prompts/`)
- Explain system prompt resolution order (event-specific → default → omitted)
- Document how the event JSON payload is appended to the human-turn prompt
- Remain consistent with the existing doc's style (Mermaid, step-by-step prose, reference pointers)

**Non-Goals:**
- Code changes of any kind
- Documenting security internals already covered by the existing section
- Documenting the `claude-pod` CLI UX (that belongs in a separate user guide)
- Adding examples or tutorials

## Decisions

**Single file, new section** — Extend `docs/architecture.md` with a new H2 section rather than creating a separate doc. The existing doc is 95 lines and is reader-complete on its own; a second doc would fragment the picture. A new section keeps the full system visible in one place.

**Mermaid flowchart for the webhook pipeline** — The interactive session already uses a sequence diagram; the headless pipeline maps better to a flowchart (decision nodes for HMAC failure, filter match, no profile). Using a different diagram type also visually distinguishes the two modes.

**Profile structure as a directory tree** — A code-block directory tree (`~/.claude-pod/profiles/<name>/`) is clearer than prose for showing `profile.json`, `.env`, and `system_prompts/`. Matches what developers expect from docs.

**Step-by-step prose mirrors the existing call-chain section** — The interactive sequence diagram has 9 numbered steps in prose. The headless section will follow the same pattern: numbered steps keyed to the diagram.

## Risks / Trade-offs

[Drift risk] Architecture doc falls out of sync as the agentic subsystem evolves → Mitigation: add a reference footer note (matching the existing one) that lists the source files the section describes, so authors know what to update when those files change.

[Scope creep] Temptation to document CLI flags or user-facing commands → Mitigation: spec requirement explicitly limits the section to architectural description only.

## Open Questions

*(none — all subsystems are spec-complete and already implemented)*
