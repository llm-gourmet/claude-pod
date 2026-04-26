## Context

The codebase spans four languages (Bash, Node.js, Python, Dockerfile) across six top-level directories. No single document maps what every file does. Contributors — and Claude itself when working in the repo — currently rely on directory browsing or grep to orient themselves.

The `openspec/specs/index.md` already indexes the capability specs. This change adds a parallel `index.md` at the repo root for source files.

## Goals / Non-Goals

**Goals:**
- A single `index.md` at the repo root listing every source file with a one-line description and relative link
- Files grouped by architectural layer to match the four-layer security architecture described in CLAUDE.md
- Manually maintained alongside code changes

**Non-Goals:**
- Auto-generated index (no tooling, no CI step)
- Indexing config or data files (e.g., `profile.json`, `.openspec.yaml`)
- Indexing test fixtures or generated artifacts

## Decisions

**Location: repo root `index.md`**
Placing it at the root makes it the first thing a contributor sees alongside `README.md` and `CLAUDE.md`. Alternative (e.g., `docs/code-index.md`) would hide it — rejected.

**Grouping by architectural layer, not by directory**
The four-layer architecture (Docker isolation → hook validation → proxy redaction → iptables validator) is the mental model CLAUDE.md uses. Grouping files the same way lets readers map file → layer instantly. Grouping by directory would split conceptually related files (e.g., `claude/Dockerfile` and `proxy/Dockerfile` would be in separate sections instead of "Container Definitions"). Alternative: alphabetical — rejected as meaningless for navigation.

**One-line descriptions only**
Longer descriptions belong in the files themselves (or CLAUDE.md). The index is a navigation aid, not documentation. Each entry: relative link + one sentence.

**Manual maintenance**
This codebase is small enough that manual updates are cheaper than any generation tooling. A maintenance note at the top of the file sets the expectation.

## Risks / Trade-offs

- [Drift] Index falls out of date when files are added/renamed → Mitigation: maintenance note in the file header; code review checklist note in proposal/tasks
- [Scope creep] Authors add verbose descriptions → Mitigation: spec requires one-line entries only

## Migration Plan

No migration needed. This is a net-new file — no existing file is modified, renamed, or removed.
