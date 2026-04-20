## Context

`bin/claude-secure` is a ~2800-line Bash script. Profile creation is triggered by the `--profile` flag parsed in a pre-loop before command dispatch. All other profile management (`secret`, `system-prompt`) goes through a `profile` subcommand dispatched in the main `case` block. This creates two separate code paths for the same concept.

The README was written incrementally across many changes and contains stale migration guides and inconsistent examples.

## Goals / Non-Goals

**Goals:**
- Single verb for all profile operations: `claude-secure profile <name> <subcommand>`
- `profile create <name>` replaces `--profile <name>`
- `profile <name>` (bare) shows profile info (workspace, secrets count, running state)
- README is accurate, complete, and migration-free

**Non-Goals:**
- Restructuring the CLI into separate files or adding a framework
- Changing any non-profile commands (`start`, `stop`, `spawn`, `webhook-listener`, etc.)
- Changing `profile.json` or `.env` schema

## Decisions

**Drop `--profile` entirely, not alias it.**
An alias would keep the inconsistency alive and clutter the help text. This is a clean break — the flag only ever created profiles, so removing it is safe. Anyone scripting against `--profile` is on an internal tool and can update one line.

**`profile create <name>` is the canonical create command.**
`profile <name>` (bare, no action) shows a summary instead. This mirrors git-style subcommand UX: `git remote` lists, `git remote add` creates.

**No changes to dispatch for `start`, `stop`, `list`, `status`, `remove`, `logs`.**
These are profile lifecycle commands that already work correctly at the top level. Moving them under `profile` would be a larger breaking change with no clarity benefit — `claude-secure start myapp` is already readable.

**README written to match implemented state, not aspirational state.**
Sections describe what exists. No "planned" or "coming soon" language.

## Risks / Trade-offs

`--profile` removal is breaking for any existing scripts → Mitigation: the tool is a personal security wrapper for solo devs; no public API contract. Change is intentional.

`profile <name>` (bare) showing info rather than creating may surprise users who learned the old flag → Mitigation: `profile create` is explicit and the help text is updated.
