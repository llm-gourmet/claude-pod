## ADDED Requirements

### Requirement: update command exits cleanly
The `claude-pod update` command SHALL exit with status 0 immediately after printing the completion message, without executing any further code from the script file.

#### Scenario: update completes successfully
- **WHEN** `claude-pod update` runs and rebuilds all profile images
- **THEN** the command prints "Update complete. N profile image(s) rebuilt." and exits with status 0
- **THEN** no additional output is produced after the completion message
