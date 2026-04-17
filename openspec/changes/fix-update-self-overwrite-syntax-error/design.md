## Context

`bin/claude-secure` is both the source and the installed binary (`/usr/local/bin/claude-secure`). The `update)` case does a `cp` of itself to the installed path mid-execution. Bash reads script files in blocks lazily — after executing the case body it reads forward to locate the next pattern or `esac`. At that point the file descriptor points into the new file, which may have different content at that byte offset.

## Goals / Non-Goals

**Goals:**
- `claude-secure update` exits cleanly with status 0 after printing "Update complete."
- No spurious output or syntax errors from the replaced script file

**Non-Goals:**
- Restructuring the update flow or using `exec` to restart
- Supporting partial update recovery or rollback

## Decisions

**Add `exit 0` before `;;` in the `update)` case.**

When bash executes `exit 0` it terminates immediately — no further file reads occur. This is the minimal, safest fix: one line, no behavior change for the user, no side effects.

Alternatives considered:
- `exec bash "$0" "$@"` after copy: would re-run the full script with `update` as the command, causing an infinite loop.
- Wrapping script in a function + single call at bottom: valid long-term pattern but a much larger change with no other benefit right now.
- Using a temp file and atomic rename: prevents the mid-execution read issue entirely but is heavy for what is a one-liner fix.

## Risks / Trade-offs

- `exit 0` suppresses any future code added after the echo in the `update)` case — a new developer might add post-update logic and wonder why it never runs. The exit is self-documenting in context.
