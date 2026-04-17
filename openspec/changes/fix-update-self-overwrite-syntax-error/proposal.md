## Why

`claude-secure update` overwrites the running script mid-execution. Bash reads scripts lazily in blocks, so after the copy completes, bash reads the next chunk from the new file at the old byte offset — landing in arbitrary code and producing a syntax error. The fix is trivial but must ship so the update command is reliable.

## What Changes

- Add `exit 0` at the end of the `update)` case in `bin/claude-secure`, before the `;;`, so bash exits cleanly without reading any further from the (now-replaced) file.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

_(none — implementation-only fix, no spec-level behavior changes)_

## Impact

- `bin/claude-secure`: one-line change inside the `update)` case
- No API, config, or dependency changes
