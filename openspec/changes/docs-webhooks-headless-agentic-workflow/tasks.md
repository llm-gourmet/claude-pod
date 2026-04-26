## 1. Profile Directory Documentation

- [x] 1.1 Add directory-tree code block showing `~/.claude-pod/profiles/<name>/` structure with `profile.json`, `.env`, and `system_prompts/`
- [x] 1.2 Write prose description of `profile.json` fields: `workspace`, `secrets[]` (`env_var`, `redacted`, `domains`)
- [x] 1.3 Write prose description of `.env` (holds raw secret values referenced by `secrets[].env_var`)

## 2. System Prompt Resolution Documentation

- [x] 2.1 Document the three-step resolution chain: `system_prompts/<event_type>.md` → `system_prompts/default.md` → omit `--system-prompt`
- [x] 2.2 Clarify that omitting `--system-prompt` is not an error — spawn proceeds without it

## 3. Mermaid Webhook-to-Spawn Flow Diagram

- [x] 3.1 Draft Mermaid `flowchart TD` diagram covering: webhook receipt → HMAC verify (with failure exit) → connection lookup → skip-filter eval (with skip exit) → event file persist → `claude-pod spawn` → system prompt resolve → `claude -p` execution
- [x] 3.2 Verify the diagram renders correctly (no syntax errors in the Mermaid block)

## 4. Step-by-Step Prose for the Headless Pipeline

- [x] 4.1 Write numbered prose steps (minimum 6) describing each stage of the headless pipeline, keyed to the diagram nodes
- [x] 4.2 Include event payload injection: describe `---` separator, event-type label, fenced JSON block appended to the human-turn prompt
- [x] 4.3 Contrast with manual spawn (no event file → no payload block appended)

## 5. Section Assembly in architecture.md

- [x] 5.1 Add `---` horizontal rule and `## Agentic (Headless) Mode` heading after the existing "Call Chain Sequence" section
- [x] 5.2 Insert the profile directory structure subsection (tasks 1.1–1.3)
- [x] 5.3 Insert the system prompt resolution subsection (tasks 2.1–2.2)
- [x] 5.4 Insert the Mermaid diagram (task 3.1)
- [x] 5.5 Insert the numbered step-by-step prose (tasks 4.1–4.3)
- [x] 5.6 Add italicized source-file footer: list `webhook/listener.py`, `bin/claude-pod`, and `~/.claude-pod/profiles/` with update instruction

## 6. Verification

- [x] 6.1 Confirm all six spec scenarios are satisfied by reading through the completed section
- [x] 6.2 Check that document style (heading levels, horizontal rules, italicized footers) is consistent with the existing architecture.md
