# Phase 04: Installation & Platform - Context

**Gathered:** 2026-04-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Create an installer script that sets up claude-secure on a fresh Linux or WSL2 system: checks dependencies, collects auth credentials, configures workspace and config paths, builds Docker images, sets permissions, and creates a `claude-secure` CLI shortcut. Also verify that the full container topology works correctly on both native Linux and WSL2 with iptables/nftables backend detection.

This phase wraps the working three-container system (Phases 1-3) into an installable package.

</domain>

<decisions>
## Implementation Decisions

### Dependency Checking
- **D-01:** Installer checks for: `docker`, `docker compose` (v2 plugin), `curl`, `jq`, `uuidgen`. Each check uses `command -v`. Missing dependencies produce a clear error listing all missing tools with install hints (e.g., `apt install jq`).
- **D-02:** Docker Compose v2 detection: check `docker compose version` (not `docker-compose`). v1 is deprecated — fail with upgrade instructions if only v1 found.

### Auth Setup Flow
- **D-03:** Installer checks environment variables first (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`). If found, uses them without prompting. If not found, presents an interactive prompt: "Choose auth method: (1) OAuth token [recommended] (2) API key".
- **D-04:** OAuth is presented as the recommended option (per project constraint). For OAuth, user runs `claude setup-token` first and provides the token. For API key, user pastes the key directly.
- **D-05:** Auth credentials are stored in `~/.claude-secure/.env` file with `chmod 600`. The `.env` file is sourced by the CLI wrapper before `docker compose` commands, making credentials available as env vars to containers.

### CLI Wrapper Design
- **D-06:** `claude-secure` is a bash script installed to `/usr/local/bin/claude-secure` (or `~/.local/bin/` if no root access). The script sources `~/.claude-secure/.env` and runs docker compose commands.
- **D-07:** CLI subcommands:
  - `claude-secure` (no args) — `docker compose up -d && docker compose exec claude claude` (launch and attach)
  - `claude-secure stop` — `docker compose down`
  - `claude-secure status` — `docker compose ps`
  - `claude-secure update` — `git pull && docker compose build`
- **D-08:** The CLI wrapper sets `COMPOSE_FILE` to point to the project's `docker-compose.yml` and `WORKSPACE_PATH` from config, so it works from any directory.

### Workspace and Config Paths
- **D-09:** Host config directory: `~/.claude-secure/` containing:
  - `.env` — auth credentials (chmod 600)
  - `whitelist.json` — copy of or symlink to config/whitelist.json
  - `config.sh` — workspace path and other settings
- **D-10:** Workspace path prompted during install. Default: `~/claude-workspace/`. Stored in `~/.claude-secure/config.sh` as `WORKSPACE_PATH=/path/to/workspace`.
- **D-11:** Installer clones or copies the project repo to `~/.claude-secure/app/` (or uses the current directory if run from a cloned repo). Docker compose commands reference this location.

### Docker Image Building
- **D-12:** Installer runs `docker compose build` after configuration. No pre-built images — always build from local Dockerfiles (security tool should not pull pre-built images from registries).
- **D-13:** File permissions are set during Docker build (already in Dockerfiles). Installer verifies build success with `docker compose config --quiet`.

### WSL2 Detection and Platform Handling
- **D-14:** Detect WSL2 via `grep -qi microsoft /proc/version`. If detected, set `PLATFORM=wsl2`, otherwise `PLATFORM=linux`.
- **D-15:** WSL2-specific checks:
  - Verify Docker is Docker CE (not Docker Desktop) — `docker info` should show `Operating System: Ubuntu` not `Docker Desktop`
  - Warn if Docker Desktop detected (iptables may not work correctly)
  - Check iptables backend: `iptables -V` for `nf_tables` or `legacy`. Both should work but log which one is detected.
- **D-16:** Installer writes detected platform to `~/.claude-secure/config.sh` as `PLATFORM=linux|wsl2`.

### Secret Env Var Passthrough
- **D-17:** The installer generates the proxy service's environment section in docker-compose.yml (or an override file) dynamically from whitelist.json. For each `secrets[].env_var` in whitelist.json, add `- ENV_VAR=${ENV_VAR:-}` to the proxy service. This replaces the hardcoded entries from Phase 3.
- **D-18:** Alternative simpler approach for v1: document that users must manually add secret env vars to `.env` and proxy service. Dynamic generation deferred to v2. Claude's discretion on which approach — the simpler one is acceptable for MVP.

### Claude's Discretion
- Exact wording of prompts and error messages
- Whether to use colors/formatting in installer output
- Whether `claude-secure update` does `git pull` or a different update mechanism
- Order of dependency checks
- Whether to create a `.desktop` file or shell completion

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Architecture
- `.planning/PROJECT.md` — Core value, constraints, platform requirements (Linux + WSL2)
- `.planning/REQUIREMENTS.md` — INST-01 through INST-06, PLAT-01 through PLAT-03 acceptance criteria
- `CLAUDE.md` — Technology stack, dependency requirements, container image strategy

### Existing Container Infrastructure
- `docker-compose.yml` — Full service topology, env var passthrough, volume mounts, network config
- `claude/Dockerfile` — Claude container build: Node.js 22-slim, non-root user, hook/settings permissions
- `proxy/Dockerfile` — Proxy container build
- `validator/Dockerfile` — Validator container build with iptables
- `config/whitelist.json` — Secret-to-placeholder mapping schema

### Prior Phase Context
- `.planning/phases/02-call-validation/02-CONTEXT.md` — Shared network namespace, iptables enforcement decisions
- `.planning/phases/03-secret-redaction/03-CONTEXT.md` — Auth credential forwarding, env var passthrough

### Existing Test Patterns
- `tests/test-phase1.sh` — Integration test pattern (bash, pass/fail counter, colored output)
- `tests/test-phase2.sh` — Call validation tests
- `tests/test-phase3.sh` — Secret redaction tests

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `docker-compose.yml` — Already has `WORKSPACE_PATH` parameterized via env var with default `./workspace`
- `config/whitelist.json` — Default whitelist with 3 secret entries (GitHub, Stripe, OpenAI)
- `claude/settings.json` — Hook configuration already wired
- Existing test scripts — pattern for integration testing established

### Established Patterns
- Env vars pass host credentials to containers via `${VAR:-}` syntax in docker-compose.yml
- Root-owned chmod 555/444 for security-critical files (hooks, settings, whitelist)
- Claude Code runs as non-root user `claude` (mandatory — Claude Code refuses root)
- Internal network (`internal: true`) blocks direct internet from claude container

### Integration Points
- Installer must configure `WORKSPACE_PATH` for the workspace volume bind mount
- Installer must set `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` for proxy auth forwarding
- CLI wrapper must set `COMPOSE_FILE` to the project's docker-compose.yml location
- Secret env vars must be available to proxy container for redaction

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. The requirements (INST-01 through INST-06, PLAT-01 through PLAT-03) define what the installer must do clearly.

</specifics>

<deferred>
## Deferred Ideas

- Dynamic proxy env var generation from whitelist.json — may be simpler to document manual setup for v1
- Shell completion for `claude-secure` CLI — nice-to-have for v2
- `.desktop` file creation for Linux desktop environments — not needed for CLI tool
- Automatic Docker CE installation if missing — too platform-specific, just report missing dependency

</deferred>

---

*Phase: 04-installation-platform*
*Context gathered: 2026-04-09*
