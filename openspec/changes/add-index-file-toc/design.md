## Context

`openspec/specs/` contains 25 capability specs across diverse functional areas (networking, CLI, webhooks, profiles, docs). There is no index — discovering what exists requires listing the directory and reading individual files. This is a pure documentation change with no runtime components.

## Goals / Non-Goals

**Goals:**
- Single `INDEX.md` file at `index.md`
- All 25 existing specs listed with a one-line description and relative link
- Specs grouped by functional area for easier scanning

**Non-Goals:**
- Auto-generation tooling (manually maintained is sufficient at this scale)
- Embedding spec content (links only)
- Modifying any existing spec files

## Decisions

**File location: `index.md`**
Placing the index inside `openspec/specs/` keeps it co-located with what it describes. Alternatives considered: `openspec/INDEX.md` (one level up) — rejected because the index is specifically about the specs directory, not all of openspec.

**Format: Markdown table vs. grouped list**
Grouped list chosen over a table. Tables require column alignment and become unwieldy when descriptions vary in length. A grouped list with `- [name](path/spec.md): description` is readable as plain text and renders cleanly on GitHub.

**Grouping scheme:**
Five functional areas derived from existing specs:
- CLI & Spawn (cli-start-command, cli-spawn-positional, cli-profile-create, unified-cli, update-command, spawn-event-payload)
- Profiles & System Prompts (profile-schema, profile-system-prompt-files, profile-system-prompt-scaffold, profile-event-task-scaffold, profile-task-files)
- Webhooks (webhook-connections, webhook-listener-cli, webhook-diff-filter, webhook-spawn-always, gh-webhook-filter-cli, gh-webhook-filter-eval)
- Documentation & Bootstrapping (docs-bootstrap, docs-bootstrap-connections, bootstrap-docs-command)
- Auth & Networking (api-key-base-url, apikey-auth, commits-json-token, host-dep-auto-install, obsidian-todo-scanner)

## Risks / Trade-offs

**Index drift** → The index is manually maintained and can fall out of sync as specs are added or archived. Mitigation: add a note in the file itself reminding contributors to update it when adding specs.

**Grouping subjectivity** → Reasonable people may categorize a spec differently. Mitigation: keep the grouping simple and flat; avoid deep hierarchies that are hard to maintain.
