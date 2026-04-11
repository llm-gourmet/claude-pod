# Project Research Summary

**Project:** claude-secure v2.0
**Domain:** Webhook-triggered ephemeral agent mode for a security-isolated Claude Code wrapper
**Researched:** 2026-04-11
**Confidence:** HIGH

## Executive Summary

claude-secure v2.0 adds headless/ephemeral agent execution to an existing four-layer security wrapper. The v1.0 foundation (Docker Compose network isolation, Node.js buffered proxy with secret redaction, Python+iptables call validator, PreToolUse hook scripts) remains entirely unchanged — v2.0 layers event-driven orchestration on top without modifying any existing component. The core insight from research is that Claude Code's `-p` (non-interactive) flag run via `docker compose exec -T` is the only correct integration point: running Claude on the host via the Agent SDK would bypass all four security layers entirely, defeating the product's purpose.

The recommended architecture introduces three host-level components: a Node.js webhook listener (systemd user service) that receives GitHub events, a Bash event dispatcher that maps events to profiles and prompt templates, and a report writer that formats and pushes results to a documentation repo. A new profile system — a config-layer concept producing identical Docker Compose environment variables to the existing instance system — provides per-service isolation of secrets, whitelists, and workspaces. No new container types are needed; ephemeral runs use the existing compose stack with a unique COMPOSE_PROJECT_NAME per event and are torn down after each run.

The primary risks fall into two categories: security correctness and operational reliability. On security: profile misconfiguration that routes an event to the wrong profile can leak secrets to Anthropic via the proxy (wrong whitelist = wrong redaction set), and using the `--bare` flag disables the very security hooks that make headless mode safe. On reliability: without a concurrency cap and container reaper, event bursts can exhaust host resources within minutes. Both risk categories must be addressed before any real webhook connections are established.

## Key Findings

### Recommended Stack

v2.0 adds zero new container technologies and zero npm/pip dependencies. The webhook listener uses Node.js stdlib (`http`, `crypto`, `child_process`) consistent with the project's zero-dependency security philosophy. The profile system is a JSON/Bash config layer. Report delivery uses `git` CLI already present in the claude container. Process supervision uses systemd user services, already available on all target platforms.

**Core technologies (new for v2.0):**
- Claude Code CLI `-p` flag: headless execution — already in claude container, no new deps; `--output-format json` returns structured result/cost/turns metadata
- Node.js stdlib `http`+`crypto`: webhook listener — HMAC-SHA256 signature validation and event dispatch in ~60 lines
- Node.js `child_process.spawn`: Docker orchestration — non-blocking container lifecycle management from the host
- Bash + `jq`: event handlers and report writer — consistent with existing hook scripts; extracts JSON fields and performs git operations
- systemd user service: listener process supervision — `Restart=always`, `WatchdogSec=30`, journal logging; already on all target platforms
- JSON profile files: per-service config — same format as existing `whitelist.json`; no new config schema needed

**Explicitly rejected (with rationale):**
- `@anthropic-ai/claude-agent-sdk`: runs Claude on host, bypasses all security layers, requires API key not OAuth
- `--bare` flag: documented as "recommended for scripted calls" but disables claude-secure's PreToolUse hooks
- `@octokit/webhooks` npm package: 5-line `crypto.createHmac` replaces it with no supply-chain risk
- `--dangerously-skip-permissions` without `--allowedTools`: maximum blast radius from prompt injection

### Expected Features

**Must have (table stakes — v2.0 launch):**
- Profile system (isolated whitelist, .env, workspace, prompt templates per service) — foundation for all other features
- Webhook listener as systemd service with HMAC-SHA256 signature verification — entry point and first security gate
- Event routing for three event types (issues.opened, push to main, workflow_run failure) — the stated scope
- Headless spawn with `-p`, `--output-format json`, `--allowedTools`, `--max-turns`, `--max-budget-usd` — core execution
- Ephemeral lifecycle (fresh workspace clone per run, `docker compose up`, execute, `docker compose down -v`) — clean state isolation
- Result reporting (JSON parse -> markdown format -> git commit+push to docs repo) — the output channel
- Execution audit logging with event metadata (webhook ID, event type, repo, cost, duration) — accountability

**Should have (add after validation — v2.x):**
- Cost tracking aggregation per profile and event type
- Webhook replay / manual trigger (`claude-secure headless replay <event-id>`)
- Prompt templates with `envsubst` variable substitution (replaces inline prompt construction)
- Health monitoring with systemd watchdog and failure alerting
- `claude-secure headless status` CLI command

**Defer (v3+):**
- Multi-event chaining (output of one feeds next)
- PR creation for code changes (requires careful security review)
- Notification integrations (Slack/Discord on failure)
- Web UI dashboard (contradicts solo-dev deployment model)
- Auto-merge of agent-created PRs (industry consensus: never)

**Competitive positioning:** The differentiator is not webhook handling (commodity) but running headless Claude Code with the same four-layer security isolation as interactive mode. No other solution (GitHub Actions, Copilot, Buildkite) redacts secrets from LLM context in headless/CI scenarios.

### Architecture Approach

v2.0 is a host-level orchestration layer around an unchanged Docker stack. The fundamental security boundary — Claude runs inside Docker, orchestration runs on the host via Docker CLI — is never crossed. The webhook listener receives events, validates signatures, dispatches to Bash handlers, which invoke `claude-secure --profile <name> --headless "<prompt>"`. That wrapper exports profile env vars, generates a unique COMPOSE_PROJECT_NAME, runs `docker compose up -d`, executes `docker compose exec -T claude claude -p ...`, captures JSON output, runs `docker compose down -v`, and passes results to the report writer.

**Major components (new for v2.0):**
1. **Webhook Listener** (`listener/server.js`) — Node.js stdlib HTTP server; validates HMAC-SHA256; enforces concurrency limit (default 2-3); returns 202 immediately, dispatches asynchronously
2. **Profile System** (`~/.claude-secure/profiles/<name>/`) — config directory containing `whitelist.json`, `.env`, `config.sh` (WORKSPACE_PATH, MAX_TURNS, MAX_BUDGET_USD, DOCS_REPO_PATH), `prompt-templates/`; plus `repo-map.json` for repo-to-profile routing
3. **Event Dispatcher** (`listener/handlers/dispatch.sh`) — maps GitHub event type + action to profile + prompt template; performs `envsubst` substitution; invokes headless CLI path
4. **Headless CLI Path** (addition to `bin/claude-secure`) — ~80 new lines; generates ephemeral COMPOSE_PROJECT_NAME; runs `docker compose exec -T` with correct flags; handles all exit scenarios
5. **Report Writer** (`listener/report.sh`) — parses `--output-format json` output with `jq`; formats markdown with metadata; git commit+push to docs repo from outside Claude container

**Build order (from dependency analysis):** Profile system -> Headless CLI path -> Report writer -> Webhook listener (can develop in parallel with steps 2-3) -> Event handlers -> Integration + lifecycle

### Critical Pitfalls

1. **Profile misconfiguration leaks secrets across services** — Profile resolution must fail closed: no match = reject event entirely, never fall back to a default profile. Validate at load time that whitelist.json, .env, and workspace are distinct files (different inodes). Root-own profile directories.

2. **Webhook HMAC validation errors** — Validate `X-Hub-Signature-256` against raw body Buffer BEFORE JSON parsing. Use `crypto.timingSafeEqual`. Strip `sha256=` prefix. Store webhook secret separately from profile secrets. Return 401 silently on failure. Handle `ping` event with 200.

3. **Orphaned containers from failed spawns** — Every instance needs a unique COMPOSE_PROJECT_NAME (profile+event-id+timestamp). Two-layer cleanup: inline trap handler runs `docker compose down -v` after every run regardless of exit code; systemd timer reaper runs every 5 minutes to force-remove containers with `claude-secure.ephemeral=true` label older than max lifetime. Ship spawn and reaper together — never one without the other.

4. **`--bare` flag disabling security hooks** — Do NOT use `--bare` in claude-secure. The PreToolUse hooks are the security layer. Accept the 2-3s startup cost. Verify hook log entries exist after every ephemeral run.

5. **Concurrent event flood exhausting host resources** — Implement semaphore in webhook listener (default max 2-3). Always return 202 before spawning. Set `mem_limit`/`cpus` at service level (not `deploy:` section, which may be silently ignored on some versions). Verify enforcement with `docker stats --no-stream`.

6. **Git credential leakage via report repo** — Report push must happen outside the Claude container. Host-side report.sh does git operations using a fine-grained PAT scoped to the report repo only. If the token must enter the container, it must be in profile's `whitelist.json`. Never use classic PATs with `repo` scope.

7. **Prompt injection via event payloads** — Issue titles, commit messages, and CI logs are attacker-controlled. Sanitize and truncate all fields (issue body max 5000 chars). Wrap in clear delimiters. Scope `--allowedTools` narrowly per event type (read-only analysis: `Read,Glob,Grep`; never Bash for issue triage).

## Implications for Roadmap

### Phase 1: Profile System
**Rationale:** Everything else depends on correct profile isolation. Profiles must exist and be verified secure before any webhook connection is made. Build order confirmed by both ARCHITECTURE.md and PITFALLS.md independently.
**Delivers:** Profile directory structure, repo-map.json routing, config.sh schema with headless-specific vars (MAX_TURNS, MAX_BUDGET_USD, DOCS_REPO_PATH, ALLOWED_TOOLS), validation logic (fail-closed resolution, inode checks, path sanitization), non-interactive profile creation script.
**Addresses:** Profile system (P1), concurrent execution safety (via COMPOSE_PROJECT_NAME isolation)
**Avoids:** Pitfall 1 (profile misconfiguration -> secret cross-contamination)
**Research flag:** Standard pattern (mirrors existing instance system exactly). Skip `/gsd:research-phase`.

### Phase 2: Headless CLI Path
**Rationale:** Core integration point. All subsequent phases build on the exact invocation flags and output JSON schema. Must be manually testable (`claude-secure --profile test --headless "echo hello"`) before event handlers are built.
**Delivers:** `--profile` and `--headless` flags in `bin/claude-secure`; `docker compose exec -T` invocation with correct flags; all exit-code handling (empty result = retry once then fail; max-turns reached = flag incomplete); ephemeral lifecycle (up, execute, `down -v`); resource limits at service level verified by `docker inspect`.
**Uses:** Claude Code `-p` flag, `--output-format json` schema, `--allowedTools` syntax
**Implements:** Headless CLI path component
**Avoids:** Pitfall 3 (orphaned containers), Pitfall 4 (`--bare` flag), resource limits silently ignored
**Research flag:** Needs validation — known bug #7263 (empty output with large stdin >7000 chars) must be reproduced and worked around. Test `--allowedTools` prefix syntax (`Bash(git *)` with space before `*`).

### Phase 3: Webhook Listener
**Rationale:** Independent of event handlers and report writer — can be developed in parallel with Phase 2. Must be correct before any real webhook is connected. Listener without concurrency control is a resource bomb.
**Delivers:** `listener/server.js` (Node.js stdlib, single route POST /webhook); HMAC-SHA256 validation on raw body before JSON parsing; `crypto.timingSafeEqual`; `ping` event handling; 202 Accepted before async dispatch; concurrency semaphore (default: 2); `GET /health` endpoint; systemd unit file with `Restart=always`, `WatchdogSec=30`, `MemoryMax=512M`, `User=`; `X-GitHub-Delivery` deduplication log.
**Addresses:** Webhook listener (P1), GitHub signature verification (P1), concurrent execution safety
**Avoids:** Pitfall 2 (HMAC validation errors), Pitfall 4 (event flood), Pitfall 9 (listener dies silently)
**Research flag:** Standard pattern (Node.js crypto HMAC + systemd are well-documented). Skip `/gsd:research-phase`.

### Phase 4: Event Handlers and Prompt Templates
**Rationale:** Requires both profile system (Phase 1) and headless CLI path (Phase 2) to be working. Webhook listener (Phase 3) can be connected here for first end-to-end test.
**Delivers:** `listener/handlers/dispatch.sh`; handler scripts for three event types (issues.opened, push to refs/heads/main, check_suite.completed+failure); prompt template files with `envsubst` substitution; payload field sanitization and truncation; per-event-type `--allowedTools` config in profile.
**Addresses:** Event routing (P1), all three GitHub event types
**Avoids:** Pitfall 7 (race conditions for same repo), Pitfall 8 (prompt injection)
**Research flag:** Prompt injection sanitization patterns for LLM context may need research — effective delimiter strategies lack a single authoritative source. Consider `/gsd:research-phase`.

### Phase 5: Result Channel (Report Writing)
**Rationale:** Final link in the chain. Requires structured output from Phase 2 and profile config (DOCS_REPO_PATH) from Phase 1.
**Delivers:** `listener/report.sh` (jq JSON parsing, markdown formatting with metadata header, per-event unique file path `reports/{profile}/{YYYY-MM}/{timestamp}-{event-type}-{event-id}.md`); git operations outside Claude container using fine-grained PAT; conflict-free write strategy via unique paths; token not present in any ephemeral container environment.
**Addresses:** Result reporting (P1)
**Avoids:** Pitfall 5 (git credential leakage), Pitfall 7 (report repo merge conflicts)
**Research flag:** Standard git operations. Fine-grained PAT scoping is well-documented. Skip `/gsd:research-phase`.

### Phase 6: Operational Hardening and Integration Testing
**Rationale:** Security product requires verification that "looks done but isn't" items are actually done. Ten specific checklist items from PITFALLS.md require dedicated integration tests.
**Delivers:** Container reaper (systemd timer, 5-minute interval, removes containers with `claude-secure.ephemeral=true` label older than max lifetime + corresponding volumes, networks, temp dirs); full integration test suite (end-to-end webhook-to-report, HMAC rejection, concurrent flood, orphan cleanup, resource limit verification, hook log verification per run, git token absence from container env); installer additions for systemd service and profile setup; example profile documentation.
**Addresses:** Execution audit logging (P1), concurrent execution safety verification
**Avoids:** All pitfalls via test verification (reaper addresses Pitfall 3; load test verifies Pitfall 4; `docker stats` verifies resource limits)
**Research flag:** Standard integration testing. Skip `/gsd:research-phase`.

### Phase Ordering Rationale

- Profile system first because it is a direct dependency of every other phase — no headless spawn, event handler, or report writer can be correctly implemented without the profile contract.
- Headless CLI path second because it is the core integration point; all subsequent phases build on knowing the exact invocation flags and output JSON schema.
- Webhook listener third because it is independent of event handlers and can be tested with `curl` payloads before handlers exist.
- Event handlers fourth because they require both profile system and headless path to be stable.
- Result channel fifth because it requires known JSON output format (Phase 2) and profile DOCS_REPO_PATH (Phase 1).
- Hardening last because it can only verify what exists — and the reaper must ship before production use.

### Research Flags

Phases likely needing `/gsd:research-phase` during planning:
- **Phase 4 (Event Handlers):** Prompt injection sanitization patterns for LLM context — effective delimiter strategies are nuanced without a single authoritative source.

Phases with standard patterns (skip `/gsd:research-phase`):
- **Phase 1 (Profile System):** Mirrors existing instance system exactly. Config files + Bash + JSON.
- **Phase 2 (Headless CLI Path):** Official Claude Code docs verified all flags. Prioritize testing bug #7263 workaround at implementation.
- **Phase 3 (Webhook Listener):** Node.js crypto HMAC + systemd unit files are exceptionally well-documented.
- **Phase 5 (Result Channel):** Standard git operations + GitHub fine-grained PAT docs are authoritative.
- **Phase 6 (Hardening):** Integration testing patterns are project-specific; research adds little value.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Official Anthropic docs verified all Claude Code CLI flags. Node.js stdlib APIs stable for years. systemd unit file patterns mature and well-documented. |
| Features | HIGH | Feature set derived from official Claude Code headless docs, GitHub webhook docs, and competitive analysis of GitHub Actions/Copilot patterns. MVP scope is conservative and validated against existing v1.0 capabilities. |
| Architecture | HIGH | Validated against existing codebase (docker-compose.yml, bin/claude-secure). All unchanged components verified as unchanged by analyzing responsibilities. Build order validated by two independent research files agreeing. |
| Pitfalls | HIGH | Sourced from official GitHub docs (HMAC validation), official Claude Code docs (--bare behavior), known bug tracker (issue #7263), Docker docs (deploy.resources.limits), and direct codebase analysis. Ten "looks done but isn't" verification criteria provided. |

**Overall confidence:** HIGH

### Gaps to Address

- **Known bug #7263 (empty output with large stdin):** Research documents the bug and workaround (write context to file, use `--append-system-prompt-file`) but does not confirm fix status. Verify at Phase 2 implementation whether the bug affects expected webhook event prompt sizes.
- **`--allowedTools` prefix match syntax:** Research notes `Bash(git *)` requires a space before `*`. Needs empirical verification during Phase 2 — subtle syntax errors are silent.
- **Docker Compose `deploy.resources.limits` vs `mem_limit`:** The safe choice (top-level `mem_limit`/`cpus`) is documented but the exact Docker Compose version threshold where `deploy:` syntax works reliably is unclear. Verify with `docker inspect` at Phase 2.
- **systemd in WSL2:** Requires systemd enabled via `/etc/wsl.conf` (`[boot] systemd=true`). Installer should detect this and configure or provide clear instructions. First-run UX risk.
- **Report push handoff pattern:** Research recommends keeping git token out of Claude container (host-side report.sh). The exact mechanism for passing report content from container stdout to host-side script needs confirmation at Phase 5 — `--output-format json` stdout capture is the handoff point.

## Sources

### Primary (HIGH confidence)
- [Claude Code headless mode docs](https://code.claude.com/docs/en/headless) — `-p`, `--bare`, `--output-format json`, `--max-turns`, `--allowedTools`, `--max-budget-usd`, `--no-session-persistence` flags; output JSON schema
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) — complete flag inventory
- [Claude Code permission modes](https://code.claude.com/docs/en/permission-modes) — `--allowedTools` prefix match syntax, `--dangerously-skip-permissions` risks
- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) — confirmed SDK spawns CLI internally; API key requirement (no OAuth)
- [GitHub: Validating webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) — HMAC-SHA256 validation, raw body requirement, timing-safe comparison
- [GitHub: Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) — fine-grained vs classic PATs
- [Docker: Resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) — memory and CPU limits
- [Docker Compose Deploy Specification](https://docs.docker.com/reference/compose-file/deploy/) — deploy.resources.limits behavior in non-Swarm mode
- claude-secure v1.0 codebase — docker-compose.yml, bin/claude-secure, pre-tool-use.sh; primary source for integration point analysis

### Secondary (MEDIUM confidence)
- [Anthropic Auto Mode Engineering Blog](https://www.anthropic.com/engineering/claude-code-auto-mode) — headless invocation patterns
- [GitHub Agentic Workflows Technical Preview](https://github.blog/changelog/2026-02-13-github-agentic-workflows-are-now-in-technical-preview/) — industry patterns for webhook-triggered agents
- [Claude Code Bug #7263](https://github.com/anthropics/claude-code/issues/7263) — empty output with large stdin (>7000 chars)
- [adnanh/webhook](https://github.com/adnanh/webhook) — webhook server + systemd integration reference patterns
- [GitHub: Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) — secondary rate limits, abuse detection

### Tertiary (LOW confidence)
- [@octokit/webhooks npm v13.x](https://www.npmjs.com/package/@octokit/webhooks) — version noted from Dec 2025 publish date; referenced only to document rejection rationale

---
*Research completed: 2026-04-11*
*Ready for roadmap: yes*
