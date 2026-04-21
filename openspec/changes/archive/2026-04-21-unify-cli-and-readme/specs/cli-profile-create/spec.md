## REMOVED Requirements

### Requirement: --profile flag only creates a profile and exits
**Reason**: The `--profile` flag is replaced by `claude-secure profile create <name>`. Mixing flag and subcommand syntax for the same noun is confusing. All profile operations now live under the `profile` subcommand.
**Migration**: Replace `claude-secure --profile <name>` with `claude-secure profile create <name>`.
