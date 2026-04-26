## Why

`docs/architecture.md` currently only describes the four-layer security architecture for interactive sessions. The project is actively being extended with a webhook-driven agentic mode — where GitHub pushes trigger headless Claude instances via profiles and event-specific system prompts — and this mode is entirely absent from the architecture docs. Contributors reading the docs today would have no idea the system can operate as a fully automated agent.

## What Changes

- Extend `docs/architecture.md` with a new top-level section: **Agentic (Headless) Mode**
- Add a Mermaid flow diagram showing the end-to-end webhook → spawn → headless Claude pipeline
- Document the profile directory structure (`profile.json`, `.env`, `system_prompts/`)
- Explain how system prompts are resolved (event-specific → default → omitted)
- Document the webhook listener's role: HMAC verification, connection lookup, skip-filter evaluation, `claude-pod spawn` invocation
- Document how the event JSON payload is appended to the Claude prompt
- Add a section on the headless spawn contract (how `claude -p` is invoked, what flags are passed)

## Capabilities

### New Capabilities

- `agentic-workflow-architecture-docs`: Requirements for what `docs/architecture.md` must cover regarding the webhook-driven headless agentic workflow — webhook listener, profiles, system prompts, spawn mechanics, and event payload injection.

### Modified Capabilities

*(none — no existing spec-level requirements are changing)*

## Impact

- `docs/architecture.md` — primary file being modified
- No code changes; no API, dependency, or container changes
- Readers: contributors and users who want to understand how to configure claude-pod for automated agentic workflows
