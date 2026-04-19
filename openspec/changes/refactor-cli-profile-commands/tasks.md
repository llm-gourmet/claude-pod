## 1. Argument Parsing Refactor

- [x] 1.1 Add `require_profile_arg` helper that reads `$1`, validates it as a profile name, and calls `load_profile_config`
- [x] 1.2 Strip session-start logic from `--profile` flag path: after `create_profile` or profile-exists check, print hint and exit 0
- [x] 1.3 Add `start <name>` top-level command block that replicates current `*)` interactive session logic using `require_profile_arg`

## 2. Spawn and Replay Commands

- [x] 2.1 Move `spawn` dispatch to top-level: `claude-secure spawn <name> [flags]` using `require_profile_arg`
- [x] 2.2 Move `replay` dispatch to top-level: `claude-secure replay <name> <delivery-id>` using `require_profile_arg`
- [x] 2.3 Remove old `--profile <name> spawn` and `--profile <name> replay` dispatch paths

## 3. Profile-Scoped Subcommands

- [x] 3.1 Update `status <name>` to use positional name via `require_profile_arg` (was `--profile <name> status`)
- [x] 3.2 Update `stop <name>` to use positional name (was `--profile <name> stop`)
- [x] 3.3 Update `remove <name>` to use positional name (was `--profile <name> remove`)
- [x] 3.4 Update `logs <name> [flags]` to use positional name (was `--profile <name> logs`)

## 4. Help Text and README

- [x] 4.1 Update built-in help output in `bin/claude-secure` to reflect new command shapes
- [x] 4.2 Update README.md usage examples and command reference table

## 5. Tests

- [x] 5.1 Update E2E test harness invocations that use `--profile <name>` for session start to use `start <name>`
- [x] 5.2 Add test: `--profile <name>` exits without starting containers
- [x] 5.3 Add test: `start <name>` with unknown profile prints correct error and exits non-zero
