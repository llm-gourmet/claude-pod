## 1. CLI: Remove --profile flag

- [x] 1.1 Remove the `--profile` / `--instance` flag parsing loop in `bin/claude-secure` (lines ~2467–2483)
- [x] 1.2 Remove the `--profile` create-and-exit block that follows (lines ~2491–2500)
- [x] 1.3 Add `--profile` to the arg parser as an unknown-option error with hint: "Did you mean: claude-secure profile create <name>?"
- [x] 1.4 Remove all `Run: claude-secure --profile <name>` references in error messages throughout the script; replace with `claude-secure profile create <name>`

## 2. CLI: Add `profile create` subcommand

- [x] 2.1 In the `cmd_profile` function, add `create` as the first subcommand that calls `create_profile "$prof_name"`
- [x] 2.2 Ensure `profile create <name>` exits 0 after creation with hint "Run 'claude-secure start <name>' to start a session"
- [x] 2.3 Ensure `profile create <name>` exits 0 with info message if profile already exists

## 3. CLI: Add `profile <name>` bare info display

- [x] 3.1 In `cmd_profile`, when no subcommand is given (only a name), print workspace path, secret count from `profile.json`, and running state via `docker ps`
- [x] 3.2 When profile does not exist, exit non-zero with "Profile '<name>' not found. Run 'claude-secure profile create <name>' to create it."

## 4. CLI: Update help text

- [x] 4.1 Replace `--profile <name>   Create a profile interactively, then exit` with `profile create <name>   Create a profile interactively, then exit` in the help output
- [x] 4.2 Verify all help sections are consistent with the new subcommand structure

## 5. README rewrite

- [x] 5.1 Write Installation section: prerequisites, clone + `sudo ./install.sh`, non-interactive install with `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`, custom base URL
- [x] 5.2 Write full CLI reference section with all commands grouped: profile lifecycle, profile management, headless/replay, system, bootstrap-docs, webhook-listener, log flags
- [x] 5.3 Write Profiles section: profile directory layout, `profile.json` schema table, `.env` file, secrets management commands, system-prompt commands
- [x] 5.4 Write Webhooks section: listener setup, connections, status, configuration, adding a repo
- [x] 5.5 Write Docs-Bootstrap section: connections, scaffold command, created structure
- [x] 5.6 Write Auth Variables section: the four variables table, naming note, example `.env`
- [x] 5.7 Write Host File Locations section: the two-tree table
- [x] 5.8 Write Architecture section with ASCII diagram and four subsections: Network isolation, Secret redaction, PreToolUse hook, Network enforcement
- [x] 5.9 Remove all migration guide content from README
