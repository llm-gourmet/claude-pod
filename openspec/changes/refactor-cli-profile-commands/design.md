## Context

`bin/claude-secure` is a ~2500-line bash script with a single argument-parsing block that dispatches on `$1` after stripping `--profile <name>`. The current flow:

1. If `--profile <name>` is present → load or create profile, then fall through to command dispatch
2. The default case (`*`) starts containers and runs an interactive session

This means profile creation and session start share the same code path, making it impossible to create a profile without starting containers.

## Goals / Non-Goals

**Goals:**
- `--profile <name>` creates the profile and exits (no containers)
- `claude-secure start <name>` is the new entry point for interactive sessions
- `claude-secure spawn <name>` replaces `--profile <name> spawn`
- All other subcommands (`status`, `stop`, `remove`, `logs`, `list`, `replay`, etc.) accept profile name as a positional arg

**Non-Goals:**
- Changing profile storage format or `.env` structure
- Superuser mode (no `--profile`) — behavior unchanged
- Changing how containers are built or started (only when)

## Decisions

### D-1: `--profile` becomes create-only; `start` is a new top-level command

**Decision**: Repurpose `--profile <name>` to mean "create profile if absent, then exit". Add `start <name>` as a top-level command that calls `load_profile_config` + container start + `docker compose exec`.

**Alternative considered**: Keep `--profile` for both create and start, add `--no-start` flag. Rejected — opt-out flags are worse UX than explicit commands.

### D-2: Positional profile name for all subcommands

**Decision**: Commands become `claude-secure <cmd> <name>` (e.g., `status myapp`, `stop myapp`, `logs myapp`). The `--profile` flag is removed from non-create paths.

**Alternative considered**: Keep `--profile` as optional for all commands for backwards compat. Rejected — the whole point is to remove the ambiguity. Breaking change is acceptable since this is a single-user local tool.

### D-3: `spawn` and `replay` move to top-level with positional name

**Decision**: `spawn <name> [flags]` and `replay <name> <delivery-id>` become top-level commands. Internal dispatch logic is unchanged; only the argument parsing changes.

## Risks / Trade-offs

- **Breaking change** for any scripts using `--profile <name>` to start sessions → Mitigation: clear error message redirecting to `start <name>`
- Bash argument parsing grows slightly more complex as profile name shifts from a flag to a positional arg in more places → Mitigation: extract a `require_profile_arg` helper that reads `$1` and validates it, used by `start`, `stop`, `status`, `remove`, `logs`, `spawn`, `replay`

## Migration Plan

1. Update argument parsing to split `--profile` (create-only) from `start <name>`
2. Add `start` command block that mirrors current `*)` default case
3. Refactor `spawn` and `replay` dispatch to use positional name
4. Update `status`, `stop`, `remove`, `logs` to accept positional name
5. Update help text and README
6. Old `--profile <name>` (non-create) path removed; no shim needed
