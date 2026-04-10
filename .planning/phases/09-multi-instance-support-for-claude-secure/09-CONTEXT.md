# Phase 9: Multi-Instance Support for claude-secure - Context

**Gathered:** 2026-04-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Run multiple independent claude-secure environments simultaneously, each with its own workspace, secrets, whitelist, and container set. Users target instances via `--instance NAME` on all CLI commands.

</domain>

<decisions>
## Implementation Decisions

### Instance Naming
- **D-01:** Users specify instances with `--instance NAME` flag on all commands (e.g., `claude-secure --instance myproject`, `claude-secure stop --instance myproject`)
- **D-02:** Instance names are user-chosen, must be DNS-safe (lowercase, alphanumeric, hyphens)
- **D-03:** `--instance` is always required -- no default instance, no last-used tracking. Prevents accidental operations on wrong instance.
- **D-04:** Existing single-instance setups auto-migrate to an instance named `default` on first run after upgrade

### Isolation Boundaries
- **D-05:** Each instance gets its own Docker networks (e.g., `claude-internal-{name}`, `claude-external-{name}`) -- full network isolation between instances
- **D-06:** Each instance has its own whitelist.json and .env -- fully independent secrets and domain configuration
- **D-07:** Log files use shared directory `~/.claude-secure/logs/` with instance-name prefix (e.g., `myapp-hook.jsonl`, `myapp-anthropic.jsonl`)

### CLI Surface Changes
- **D-08:** Minimal new commands: existing commands gain `--instance` flag, plus new `claude-secure list` subcommand
- **D-09:** Instance auto-created on first use -- `claude-secure --instance foo` prompts for workspace path if instance doesn't exist, copies initial whitelist.json template and .env template
- **D-10:** `claude-secure list` shows table with instance name, running/stopped status, and workspace path

### Config Directory Layout
- **D-11:** `~/.claude-secure/instances/{name}/` subdirectory per instance containing config.sh, .env, whitelist.json
- **D-12:** Global config stays at `~/.claude-secure/config.sh` (APP_DIR, PLATFORM)
- **D-13:** Shared logs directory at `~/.claude-secure/logs/` with instance-prefixed filenames

### Claude's Discretion
- Docker Compose multi-instance strategy (COMPOSE_PROJECT_NAME vs templated compose files vs other approach)
- Container naming convention for multi-instance (remove hardcoded container_name or parameterize)
- Migration script implementation details for existing single-instance users
- Whether `claude-secure remove --instance X` is needed or just `stop` + manual cleanup

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose
- `docker-compose.yml` -- Current single-instance compose file with hardcoded container_name directives and fixed network names

### CLI and Installer
- `bin/claude-secure` -- Current CLI wrapper with hardcoded config paths and container names in cleanup_containers()
- `install.sh` -- Installer that creates ~/.claude-secure/ structure

### Configuration
- `config/whitelist.json` -- Template whitelist that each instance will get a copy of

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `bin/claude-secure`: CLI wrapper with log flag parsing, subcommand routing, docker compose orchestration -- needs refactoring but structure is reusable
- `install.sh`: Dependency checking, platform detection, auth setup -- can be extracted into shared functions
- `docker-compose.yml`: Service definitions are correct, just need container_name removal and parameterization

### Established Patterns
- Config loaded via `source "$CONFIG_DIR/config.sh"` and `source "$CONFIG_DIR/.env"` with `set -a` for auto-export
- Docker Compose env vars control behavior: `LOG_HOOK`, `LOG_ANTHROPIC`, `SECRETS_FILE`, `WORKSPACE_PATH`
- `cleanup_containers()` hardcodes three container names -- must be parameterized

### Integration Points
- `COMPOSE_FILE` env var already used to point docker compose at the right file
- `WORKSPACE_PATH` and `SECRETS_FILE` already externalized as env vars
- `LOG_DIR` already externalized -- just needs instance-prefixed filenames
- `network_mode: "service:claude"` on validator -- works with COMPOSE_PROJECT_NAME since service names stay the same

</code_context>

<specifics>
## Specific Ideas

No specific requirements -- open to standard approaches

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 09-multi-instance-support-for-claude-secure*
*Context gathered: 2026-04-10*
