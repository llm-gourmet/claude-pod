---
phase: quick
plan: 260410-fjy
type: execute
wave: 1
depends_on: []
files_modified: [README.md]
autonomous: true
must_haves:
  truths:
    - "README documents the logging architecture with env-var toggles and JSONL format"
    - "README shows CLI log flags and logs subcommand usage"
    - "README includes update/upgrade instructions (already present in Usage but verify completeness)"
  artifacts:
    - path: "README.md"
      provides: "Updated documentation with logging section and verified update instructions"
---

<objective>
Update README.md to document the Phase 06 service logging features and verify update/upgrade instructions are adequate.

Purpose: Users need to know how to enable, configure, and view structured logs from all three services. The README already has `update` and `upgrade` commands in the Usage section -- verify they are sufficient or enhance them.

Output: Updated README.md with logging documentation section.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@README.md
@.planning/phases/06-service-logging/06-01-SUMMARY.md
@.planning/phases/06-service-logging/06-02-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add logging section and verify update instructions in README</name>
  <files>README.md</files>
  <action>
Add a new "## Logging" section to README.md, placed between "## Configuration" and "## Architecture Details". Include:

1. **Overview paragraph**: All three services (hook, proxy, validator) support structured JSONL logging, disabled by default, enabled via environment variable toggles.

2. **Enabling logs subsection**: Show the CLI log flags:
   - `claude-secure log:hook` -- enable hook logging
   - `claude-secure log:anthropic` -- enable proxy logging  
   - `claude-secure log:iptables` -- enable validator logging
   - `claude-secure log:all` -- enable all logging
   - Flags combine with commands: `claude-secure log:all` starts with all logging enabled

3. **Log format subsection**: Document the JSONL format with example entry:
   ```json
   {"ts":"2026-04-10T12:00:00.000Z","svc":"hook","level":"info","msg":"allow domain=github.com tool=Bash"}
   ```
   Note the four standard fields: ts, svc, level, msg.

4. **Viewing logs subsection**: Show the `logs` subcommand:
   - `claude-secure logs` -- tail all log files
   - `claude-secure logs hook` -- tail hook logs only
   - `claude-secure logs anthropic` -- tail proxy logs only
   - `claude-secure logs iptables` -- tail validator logs only
   - `claude-secure logs clear` -- delete all log files

5. **Log location**: Files are stored at `~/.claude-secure/logs/` as `hook.jsonl`, `anthropic.jsonl`, `iptables.jsonl`.

6. **Security note**: Proxy logs never include request/response bodies (which may contain secrets pre-redaction). Only metadata (method, path, status, duration, redaction count) is logged.

Also review the existing "## Usage" section -- it already lists `update` and `upgrade` commands. Verify the descriptions are clear. They currently say:
- `claude-secure update` -- Pull latest source, rebuild images, and update CLI wrapper
- `claude-secure upgrade` -- Rebuild claude image with latest Claude Code from npm (--no-cache)

These are adequate. No changes needed to update/upgrade docs unless you spot something unclear.
  </action>
  <verify>
    <automated>grep -c "## Logging" README.md && grep -c "log:all" README.md && grep -c "hook.jsonl" README.md && grep -c "claude-secure update" README.md</automated>
  </verify>
  <done>README.md contains a Logging section documenting env-var toggles, JSONL format, CLI log flags, logs subcommand, log file locations, and security note. Update/upgrade instructions verified present.</done>
</task>

</tasks>

<verification>
- README contains "## Logging" section
- Log flag examples (log:hook, log:anthropic, log:iptables, log:all) documented
- JSONL format with example shown
- logs subcommand documented
- Security note about no body logging present
- Update/upgrade commands still documented in Usage section
</verification>

<success_criteria>
README.md fully documents the logging feature so a new user can enable, view, and understand structured logs without reading source code. Update/upgrade instructions are present and clear.
</success_criteria>

<output>
After completion, create `.planning/quick/260410-fjy-update-readme-with-logging-features-and-/260410-fjy-SUMMARY.md`
</output>
