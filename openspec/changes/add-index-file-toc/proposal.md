## Why

The `openspec/specs/` directory has grown to 25+ capability specs with no central index, making it hard to discover what capabilities exist or understand how they relate. A table-of-contents index file gives contributors a single entry point to navigate the spec library.

## What Changes

- Add `index.md` — a structured table of contents listing every spec with a one-line description and a link to its `spec.md`
- The index is organized by functional area (networking, CLI, webhooks, profiles, docs, etc.)
- Index is manually maintained (updated whenever a spec is added or archived)

## Capabilities

### New Capabilities

- `spec-index`: A human-readable index file at `index.md` that lists all capability specs grouped by functional area, each with a brief description and relative link.

### Modified Capabilities

## Impact

- Documentation only — no code, no runtime behavior changes
- Future contributors adding a new spec should also update `index.md`
