# Phase 13: Headless CLI Path - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 13-headless-cli-path
**Areas discussed:** Spawn invocation, Container lifecycle, Output capture, Prompt templates
**Mode:** Auto (--auto flag, all recommended defaults selected)

---

## Spawn Invocation

| Option | Description | Selected |
|--------|-------------|----------|
| New subcommand with JSON string | `spawn --profile X --event '<json>'` | ✓ |
| Pipe-based invocation | `echo payload | claude-secure spawn --profile X` | |
| Separate binary | `claude-secure-spawn` standalone script | |

**User's choice:** [auto] New subcommand with JSON string payload (recommended default)
**Notes:** Consistent with existing CLI pattern. Also adds --event-file for replay convenience.

---

## Container Lifecycle

| Option | Description | Selected |
|--------|-------------|----------|
| New compose project per spawn | `cs-<profile>-<uuid8>` unique per run | ✓ |
| Reuse existing stack | `docker compose exec` on running containers | |
| Docker run (no compose) | Direct `docker run` without compose orchestration | |

**User's choice:** [auto] New compose project per spawn (recommended default)
**Notes:** True isolation required for concurrent runs. Aligns with HOOK-06 (concurrent webhooks). Cleanup via trap on EXIT.

---

## Output Capture

| Option | Description | Selected |
|--------|-------------|----------|
| Stdout pipe with --output-format json | Direct stdout capture from exec -T | ✓ |
| Temp file written inside container | Container writes JSON, host reads after | |
| Docker log capture | Parse from docker compose logs | |

**User's choice:** [auto] Stdout pipe with --output-format json (recommended default)
**Notes:** Simplest approach. Claude Code's native --output-format json provides all needed fields.

---

## Prompt Templates

| Option | Description | Selected |
|--------|-------------|----------|
| Profile-directory .md files with {{VAR}} | `profiles/<name>/prompts/<event-type>.md` | ✓ |
| Inline prompt in profile.json | JSON string with ${VAR} substitution | |
| Central templates directory | Shared templates across profiles | |

**User's choice:** [auto] Profile-directory .md files with double-brace variables (recommended default)
**Notes:** .md files allow complex multi-paragraph prompts. Double-brace syntax avoids shell expansion. Per-profile for security isolation.

---

## Claude's Discretion

- Exact metadata envelope schema
- Error message formatting
- --dry-run flag (nice-to-have)
- Bug #7263 workaround strategy

## Deferred Ideas

None
