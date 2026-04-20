## Why

The current CLI conflates profile creation with session start: `claude-secure --profile <name>` creates a profile and immediately launches Docker containers, which surprises users who only want to set up a profile. Separating these concerns makes intent explicit and prevents unwanted container builds during profile setup.

## What Changes

- `claude-secure --profile <name>` now **only** creates the profile (interactive setup) and exits — no containers started
- **BREAKING**: Interactive session start moves to `claude-secure start <name>`
- **BREAKING**: Headless session moves to `claude-secure spawn <name>` (was `claude-secure --profile <name> spawn`)
- Other subcommands (`status`, `stop`, `remove`, `logs`, `list`, `update`, `upgrade`, `reap`, `webhook-listener`, `bootstrap-docs`) adopt positional profile name: `claude-secure <command> <name>`

## Capabilities

### New Capabilities

- `cli-profile-create`: `--profile <name>` creates a profile and exits without starting containers
- `cli-start-command`: `claude-secure start <name>` launches an interactive Claude Code session for a profile
- `cli-spawn-positional`: `claude-secure spawn <name>` replaces `claude-secure --profile <name> spawn` for headless sessions

### Modified Capabilities

- `profile-schema`: CLI invocation pattern changes; profile storage and schema are unchanged
- `webhook-listener-cli`: `webhook-listener` subcommand adopts positional profile name

## Impact

- `bin/claude-secure`: argument parsing, command dispatch, help text
- All existing users of `claude-secure --profile <name>` (interactive) must switch to `claude-secure start <name>`
- Documented usage in README.md
