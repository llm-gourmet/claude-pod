## Context

`README.md` is the sole user-facing documentation for claude-secure. It currently opens with a one-sentence description and jumps straight into the full Installation section, followed by ~500 lines of reference material. First-time users have no obvious path to "running Claude Code in five minutes" — they must parse the entire document to understand the sequence.

The change is additive: one new Markdown section inserted before Installation. No configuration files, no code, no install artifacts are affected.

## Goals / Non-Goals

**Goals:**
- Give new users a single read-through path from prerequisites to first session
- Keep all commands copy-paste ready with no placeholders that require decisions
- Link to existing deep-reference sections rather than duplicating content

**Non-Goals:**
- Rewriting or restructuring existing sections
- Adding screenshots, GIFs, or external hosting
- Covering webhook setup, docs bootstrap, or headless spawn in the quickstart

## Decisions

**Placement: after the intro sentence, before Installation**
The quickstart must appear before any reference content so a user who reads top-to-bottom encounters it first. The existing Installation section becomes the reference readers are linked to when they want flags and options.

**Five-step flow, no branching**
The quickstart picks one path (OAuth token auth, no extra secrets) and stays linear. Branches (API key vs OAuth, corporate base URL, adding secrets) belong in the reference sections that are already present. A decision tree in a quickstart defeats the purpose.

**Step 5 optional: adding a secret**
Included as an optional step because it's the first thing most real users need after a working session, and the command is short. Marked clearly as optional so users who don't need it skip past.

## Risks / Trade-offs

- **Quickstart drift** — CLI flags and command names evolve; the quickstart is a second place to update. Mitigation: keep the section minimal (5 commands), so the surface to maintain is small. The existing CLI reference section is canonical — quickstart links to it.
- **OAuth-only path may not fit all users** — API key users will see "OAuth token" and need to adapt. Mitigation: a one-line note after the auth step pointing to the Installation section for API key setup.
