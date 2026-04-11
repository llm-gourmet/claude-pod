# Phase 9: Multi-Instance Support for claude-secure - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-10
**Phase:** 09-multi-instance-support-for-claude-secure
**Areas discussed:** Instance naming, Isolation boundaries, CLI surface changes, Config directory layout

---

## Instance Naming

| Option | Description | Selected |
|--------|-------------|----------|
| Named flag: --instance NAME | Explicit flag, verbose but clear | ✓ |
| Positional: claude-secure start myproject | Instance name as subcommand argument | |
| Env var: CLAUDE_SECURE_INSTANCE=myproject | Set once per shell session | |

**User's choice:** Named flag: --instance NAME
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| User-chosen names | DNS-safe names picked at creation | ✓ |
| Auto-generated from workspace path | Derive from directory basename | |
| You decide | Claude picks | |

**User's choice:** User-chosen names
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| Yes -- 'default' instance | Omitting flag targets 'default' | |
| Yes -- last-used instance | Track and target last used | |
| No -- always require --instance | Explicit every time | ✓ |

**User's choice:** No -- always require --instance
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| Auto-migrate to 'default' instance | Move existing config into named instance | ✓ |
| Manual migration required | User re-runs installer | |
| You decide | Claude picks | |

**User's choice:** Auto-migrate to 'default' instance
**Notes:** None

---

## Isolation Boundaries

| Option | Description | Selected |
|--------|-------------|----------|
| Separate networks per instance | Own claude-internal-{name} and claude-external-{name} | ✓ |
| Shared internal network | All instances share claude-internal | |
| You decide | Claude picks | |

**User's choice:** Separate networks per instance
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| Each instance has its own | Fully independent whitelist and secrets | ✓ |
| Shared whitelist, separate secrets | One whitelist, per-instance .env | |
| Shared by default, overridable | Global defaults with per-instance overrides | |

**User's choice:** Each instance has its own
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| Separate log dirs per instance | ~/.claude-secure/instances/{name}/logs/ | |
| Shared log dir with instance prefix | ~/.claude-secure/logs/{instance}-hook.jsonl | ✓ |
| You decide | Claude picks | |

**User's choice:** Shared log dir with instance prefix
**Notes:** None

---

## CLI Surface Changes

| Option | Description | Selected |
|--------|-------------|----------|
| create/list/stop/remove | Full lifecycle management | |
| create/list/remove only | Fewer new commands | |
| Minimal: just --instance on existing commands | No new subcommands except list | ✓ |

**User's choice:** Minimal -- `--instance` on existing commands plus `list`
**Notes:** User specified: `claude-secure --instance X` starts, `claude-secure stop --instance X` stops, `claude-secure list`

| Option | Description | Selected |
|--------|-------------|----------|
| Prompt for workspace path only | Quick setup, copy templates | ✓ |
| Prompt workspace + auth method | Full mini-installer per instance | |
| Require explicit create first | Fail if not created | |

**User's choice:** Prompt for workspace path only
**Notes:** User confirmed: just ask workspace path

| Option | Description | Selected |
|--------|-------------|----------|
| Name + status + workspace | Clean table | ✓ |
| Name + status + workspace + uptime | Same plus container uptime | |
| You decide | Claude picks | |

**User's choice:** Name + status + workspace
**Notes:** None

---

## Config Directory Layout

| Option | Description | Selected |
|--------|-------------|----------|
| instances/ subdirectory | Per-instance dirs under ~/.claude-secure/instances/ | ✓ |
| Flat with name prefix | {name}.config.sh, {name}.env at root level | |

**User's choice:** instances/ subdirectory
**Notes:** Selected after viewing preview of directory structure

| Option | Description | Selected |
|--------|-------------|----------|
| COMPOSE_PROJECT_NAME per instance | Auto-prefix via env var | |
| Template docker-compose per instance | Generate compose file per instance | |
| You decide | Claude picks best approach | ✓ |

**User's choice:** You decide
**Notes:** Claude has discretion on Docker Compose multi-instance strategy

---

## Claude's Discretion

- Docker Compose multi-instance strategy
- Container naming convention
- Migration script implementation details
- Whether `remove` subcommand is needed

## Deferred Ideas

None -- discussion stayed within phase scope
