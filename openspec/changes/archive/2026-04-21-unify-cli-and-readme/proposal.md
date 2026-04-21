## Why

The CLI mixes two syntaxes for the same concept: `--profile <name>` (flag) to create a profile and `profile <name> secret list` (subcommand) to manage one. This inconsistency forces users to remember which verb form applies to which operation and makes the help output misleading.

The README is also outdated — it contains migration guides for transitions that are complete and sections for features that no longer work that way.

## What Changes

- **BREAKING**: `claude-secure --profile <name>` removed; replaced by `claude-secure profile create <name>`
- `profile <name>` (bare, no subcommand) shows profile info instead of erroring
- Profile creation, secrets, and system-prompt management all live under the `profile` subcommand hierarchy
- README rewritten from scratch: covers installation, full CLI reference, profiles, webhooks, docs-bootstrap, auth variables, host file locations, and architecture
- All migration guides removed from README

## Capabilities

### New Capabilities
- `unified-cli`: The `profile` subcommand is the single entry point for all profile CRUD and config operations. `--profile` flag is removed.

### Modified Capabilities
- `cli-profile-create`: Creation moves from `--profile <name>` flag to `claude-secure profile create <name>` subcommand.

## Impact

- `bin/claude-secure`: remove `--profile` flag parsing and `--profile` create-and-exit block; route `profile create` to `create_profile`; update help text
- `README.md`: full rewrite
- Existing users relying on `--profile` flag will need to use `profile create` — this is intentional breaking cleanup
