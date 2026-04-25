## Why

The codebase has grown to span multiple languages and components (Bash scripts, Node.js proxy, Python validator/webhook, Docker config) with no single entry point for navigating source files. A code index gives contributors and Claude itself a fast orientation map — what every file does, organized by layer — without having to grep or explore the tree from scratch.

## What Changes

- Add `index.md` at the repo root — a structured table of contents listing every source file with a one-line description of its purpose
- Files are grouped by architectural layer (orchestration scripts, CLI, containers/services, hooks, tests)
- Index is manually maintained: updated whenever a source file is added, removed, or renamed

## Capabilities

### New Capabilities

- `code-index`: A human-readable `index.md` at the repo root that maps every source file to its role, organized by architectural layer, with relative links.

### Modified Capabilities

## Impact

- Documentation only — no code, no runtime behavior changes
- Future contributors adding or renaming a source file should also update `index.md`
