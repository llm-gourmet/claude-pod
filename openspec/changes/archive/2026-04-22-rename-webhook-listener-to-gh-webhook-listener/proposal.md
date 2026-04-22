## Why

The `webhook-listener` CLI subcommand and its references in code and tests do not reflect that the implementation is GitHub-specific. Renaming to `gh-webhook-listener` makes the GitHub-only scope explicit and sets a naming convention for future platform-specific listeners.

## What Changes

- CLI subcommand renamed: `claude-secure webhook-listener` → `claude-secure gh-webhook-listener`
- All flags under the subcommand updated (e.g., `--add-connection`, `--remove-connection`, `--list-connections`, `--set-token`, `--set-profile`, `--set-bind`, `--set-port`, `status`)
- Help text and inline code comments updated to use `gh-webhook-listener`
- Test file descriptions and command invocations updated in `tests/test-webhook-listener-cli.sh` and `tests/test-webhook-spawn.sh`
- README sections referencing `webhook-listener` updated
- File names (`listener.py`, `claude-secure-webhook.service`, `Caddyfile.example`) unchanged

## Capabilities

### New Capabilities

_(none — this is a rename only)_

### Modified Capabilities

- `webhook-listener-cli`: CLI command name changes from `webhook-listener` to `gh-webhook-listener`; all flag names and help text updated accordingly. **BREAKING** for any existing scripts invoking `claude-secure webhook-listener`.

## Impact

- `bin/claude-secure`: command routing, flag handling, help text
- `tests/test-webhook-listener-cli.sh`: all command invocations
- `tests/test-webhook-spawn.sh`: any references to the command name
- `webhook/listener.py`: inline comments
- `README.md` (if present): usage examples
- Any user scripts calling `claude-secure webhook-listener` must be updated
