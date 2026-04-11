# Feature Research

**Domain:** Headless/ephemeral CI agent mode for a security-isolated Claude Code wrapper
**Researched:** 2026-04-11
**Confidence:** MEDIUM-HIGH

## Feature Landscape

### Table Stakes (Users Expect These)

Features that any headless agent mode must have. Missing these = the feature is broken or unusable.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Profile-based configuration (whitelist, .env, workspace per service) | Users managing multiple repos/services need isolated security contexts. Without this, a single whitelist leaks one service's secrets to another. | MEDIUM | Extends existing multi-instance pattern (`$CONFIG_DIR/instances/`). Each profile = directory with whitelist.json, .env, config.sh. Leverage existing `COMPOSE_PROJECT_NAME` isolation. |
| Headless spawn with `-p` flag and `--dangerously-skip-permissions` | Claude Code's official headless mode. This is the documented way to run non-interactive tasks. Anything else would be fighting the tool. | LOW | Already used in existing CLI (`docker compose exec -it claude claude --dangerously-skip-permissions`). Change to `-p "prompt" --dangerously-skip-permissions --output-format json`. Drop `-it` for non-interactive. |
| Ephemeral lifecycle (spawn, execute, teardown) | Headless agents that leave containers running waste resources and risk stale state. GitHub Actions, Copilot cloud agents, and every CI system uses ephemeral environments. | MEDIUM | `docker compose up -d && docker compose exec claude claude -p "..." && docker compose down`. Key: capture exit code and output before teardown. |
| GitHub webhook signature verification (HMAC-SHA256) | Security product accepting unverified webhooks is a contradiction. GitHub sends `X-Hub-Signature-256` header with every delivery. All webhook receivers verify this. | LOW | `openssl dgst -sha256 -hmac "$WEBHOOK_SECRET"` against raw payload body, constant-time compare. Well-documented pattern in GitHub docs. |
| Webhook event routing (Issue, Push, CI Failure) | Users expect different events to trigger different agent behaviors. A push-to-main handler should not run the same prompt as an issue handler. | MEDIUM | Parse `X-GitHub-Event` header + payload `action` field. Route to handler scripts: `handlers/issues.sh`, `handlers/push.sh`, `handlers/workflow_run.sh`. Each handler constructs the appropriate `-p` prompt. |
| Structured output capture (JSON) | Headless mode output must be machine-parseable to extract results for reporting. Claude Code `--output-format json` returns `result`, `cost_usd`, `duration_ms`, `num_turns`, `session_id`. | LOW | Already supported by Claude Code. Use `--output-format json` and pipe through `jq`. |
| Result reporting to documentation repo | The whole point of headless agents is producing output. Users need results written somewhere persistent and reviewable. A docs repo is the stated target. | MEDIUM | `git clone docs-repo`, write markdown report, `git add && git commit && git push`. Must handle: repo auth (deploy key or PAT in profile .env), conflict resolution (pull before push), and structured report format. |
| Execution logging and audit trail | Security product must log what the agent did, what it cost, and whether it succeeded. Extends existing structured logging. | LOW | Existing `LOG_DIR` and JSONL logging infrastructure. Add event metadata (webhook ID, GitHub event type, commit SHA) to log entries. |
| Concurrent execution safety | Multiple webhooks can arrive simultaneously. Two agents touching the same workspace = corruption. | MEDIUM | Each headless spawn gets a unique `COMPOSE_PROJECT_NAME` (e.g., `claude-headless-{event-id}`). Ephemeral workspace cloned fresh per run. No shared mutable state between runs. |

### Differentiators (Competitive Advantage)

Features that distinguish claude-secure's headless mode from "just run `claude -p` in a GitHub Action."

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Security-isolated headless execution | The entire point of claude-secure. GitHub Actions runs Claude Code on a shared runner with full network access. claude-secure runs it in a network-isolated container where secrets are redacted from LLM context. No other headless Claude Code setup provides this. | LOW (already built) | The four-layer security architecture (Docker isolation, hook validation, proxy redaction, iptables enforcement) applies identically to headless mode. This is the core differentiator and it is already implemented. |
| Per-profile security boundaries | Each service gets its own whitelist of allowed domains, its own secrets, its own workspace. Profile A's GitHub token cannot be seen by profile B's agent. | MEDIUM | Directory-based: `profiles/service-a/whitelist.json`, `profiles/service-a/.env`. Maps 1:1 to existing instance config pattern. The webhook listener routes events to the correct profile based on repo. |
| Cost tracking per event | Claude Code returns `cost_usd` in JSON output. Aggregate by profile, event type, time period. Solo devs care about API costs. | LOW | Parse `cost_usd` from `--output-format json` output. Append to a costs.jsonl file per profile. Simple `jq` aggregation for reporting. |
| Webhook replay / manual trigger | Re-run a failed event without waiting for GitHub to re-deliver. Useful for debugging handler prompts. | LOW | Store raw webhook payloads in `$LOG_DIR/webhooks/`. Add `claude-secure headless replay <event-id>` command. Feeds stored payload back through the handler. |
| Prompt templates with variable substitution | Handler scripts construct prompts from templates with GitHub event data injected. Enables non-developer customization of agent behavior. | LOW | Template files in `profiles/service-a/prompts/issue.md` with `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{REPO_NAME}}` placeholders. `envsubst` or simple `sed` replacement. |
| Health monitoring and failure alerting | Webhook listener uptime, agent failure rate, last successful run. Solo dev needs to know if the system stopped working. | MEDIUM | systemd watchdog integration (`WatchdogSec=`), failure count tracking in SQLite or flat file, optional webhook to a notification service (Slack/Discord/email). |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Auto-merge PRs created by agent | "Let the agent handle everything end-to-end" | Security product should never auto-merge code changes. Humans must review agent output. GitHub Copilot coding agent explicitly does not auto-merge. Industry-wide consensus for AI-generated code. | Write results to docs repo (read-only output). For code changes, create PRs that require human review. |
| Real-time streaming webhook responses | "Show agent progress in GitHub issue comments as it works" | Streaming adds massive complexity (SSE/WebSocket from container to webhook listener to GitHub API). Claude Code's `stream-json` format exists but parsing it in real-time from Docker exec is fragile. Progress updates require GitHub API calls mid-execution. | Post a single summary comment when the agent completes. Include duration and cost. If users need progress, they can tail logs. |
| Dynamic prompt editing via GitHub comments | "Let users refine the agent's task by commenting on the issue" | Turns a one-shot headless execution into an interactive conversation managed via webhook polling. Race conditions, state management, and security implications (any commenter can inject prompts). | One-shot execution with well-crafted prompt templates. If the result is wrong, fix the template and replay. |
| Multi-repo orchestration from single webhook | "One event triggers agents across multiple repos" | Explosion of concurrent containers, complex dependency ordering, partial failure handling. Way beyond MVP scope. | One profile = one repo. If repos are related, use separate webhook subscriptions with separate profiles. |
| Agent-to-agent communication | "Have the code review agent talk to the docs agent" | Claude Code's subagent/teammate model is designed for within-session delegation, not cross-container IPC. Building a message bus between ephemeral containers is infrastructure engineering, not security tooling. | Sequential execution: first agent writes output, second agent reads it as input. Chain via handler scripts. |
| Persistent agent sessions (resume across events) | "Continue the conversation from the last push event" | Ephemeral is the point. Persistent sessions accumulate context window bloat, stale assumptions, and make security boundaries fuzzy. Claude Code's `--resume` exists but defeats the isolation model. | Fresh session per event. Include relevant context in the prompt (last commit messages, changed files). |
| Web UI dashboard | "I want to see all events and results in a browser" | Massive scope expansion. Web framework, auth, frontend, hosting. Contradicts the solo-dev-on-a-server deployment model. | CLI commands (`claude-secure headless status`, `claude-secure headless logs`) and structured JSONL that tools like `jq` can query. |

## Feature Dependencies

```
[Profile System]
    |
    +--requires--> [Existing Multi-Instance Infrastructure]
    |                   (already built: COMPOSE_PROJECT_NAME, instance dirs)
    |
    +--enables--> [Webhook Event Routing]
    |                 (routes events to correct profile based on repo)
    |
    +--enables--> [Headless Spawn]
                      |
                      +--requires--> [Existing Docker/Security Layers]
                      |                   (already built: proxy, validator, hooks)
                      |
                      +--enables--> [Ephemeral Lifecycle]
                      |                 (spawn + execute + teardown)
                      |
                      +--enables--> [Result Reporting]
                                        |
                                        +--requires--> [Structured Output Capture]
                                        |                   (--output-format json)
                                        |
                                        +--writes-to--> [Documentation Repo]

[Webhook Listener]
    |
    +--requires--> [GitHub Signature Verification]
    |
    +--requires--> [Profile System]
    |                   (to know which profile handles which repo)
    |
    +--triggers--> [Event Handlers]
                       |
                       +--constructs--> [Headless Spawn]
```

### Dependency Notes

- **Profile System requires Multi-Instance Infrastructure:** The existing `$CONFIG_DIR/instances/` pattern with per-instance whitelist.json, .env, and config.sh is the exact same pattern needed for profiles. Profiles are essentially "instances designed for headless use" with additional metadata (repo URL, event types to handle).
- **Webhook Listener requires Profile System:** The listener must know which profile to activate when a webhook arrives for a specific repository. Profile config includes the repo-to-profile mapping.
- **Headless Spawn requires existing security layers:** The proxy, validator, hooks, and Docker network isolation all work unchanged. Headless mode just changes how Claude Code is invoked inside the container (interactive to `-p` flag).
- **Result Reporting requires Structured Output Capture:** The JSON output from Claude Code (`result`, `cost_usd`, `session_id`) is the raw material for the report written to the docs repo.
- **Ephemeral Lifecycle enables concurrent execution:** Because each run creates and destroys its own container set, multiple events can execute in parallel without workspace conflicts.

## MVP Definition

### Launch With (v2.0)

Minimum viable headless agent mode -- what is needed to validate the concept works.

- [ ] Profile system (profile directory with whitelist.json, .env, config.sh, handler configs) -- foundation for all other features
- [ ] Webhook listener as systemd service (receive GitHub webhooks, verify HMAC-SHA256 signature) -- entry point for all automation
- [ ] Event routing to handler scripts (Issues opened, Push to main, CI workflow_run failure) -- the three stated event types
- [ ] Headless spawn (construct prompt from event data, run `claude -p` in security-isolated container) -- core execution
- [ ] Ephemeral lifecycle (fresh workspace clone, execute, capture output, teardown containers) -- clean state per run
- [ ] Result reporting (write markdown report to documentation repo, git push) -- output channel
- [ ] Execution audit logging (event metadata, duration, cost, success/failure in JSONL) -- accountability

### Add After Validation (v2.x)

Features to add once core headless mode is working and proven useful.

- [ ] Cost tracking aggregation (per-profile, per-event-type summaries) -- trigger: after running for a week and wanting to understand costs
- [ ] Webhook replay / manual trigger -- trigger: first time a handler prompt needs debugging
- [ ] Prompt templates with variable substitution -- trigger: when handler scripts become unwieldy with inline prompts
- [ ] Health monitoring with systemd watchdog -- trigger: first time the webhook listener silently dies
- [ ] `claude-secure headless status` CLI command -- trigger: needing to check system state without SSH

### Future Consideration (v3+)

- [ ] Multi-event chaining (output of one event feeds into next) -- defer: need to validate single-event model first
- [ ] PR creation for code change events (not just docs reporting) -- defer: requires careful security review of agent writing to source repos
- [ ] Notification integrations (Slack/Discord on failure) -- defer: not needed for solo dev initially

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | Depends On |
|---------|------------|---------------------|----------|------------|
| Profile system | HIGH | MEDIUM | P1 | Existing multi-instance |
| Webhook listener (systemd) | HIGH | MEDIUM | P1 | None (host process) |
| GitHub signature verification | HIGH | LOW | P1 | Webhook listener |
| Event routing (3 event types) | HIGH | MEDIUM | P1 | Webhook listener, profiles |
| Headless spawn (`-p` flag) | HIGH | LOW | P1 | Profile system, existing security layers |
| Ephemeral lifecycle | HIGH | MEDIUM | P1 | Headless spawn |
| Structured output capture | HIGH | LOW | P1 | Headless spawn |
| Result reporting to docs repo | HIGH | MEDIUM | P1 | Structured output capture |
| Execution audit logging | MEDIUM | LOW | P1 | Existing logging infra |
| Concurrent execution safety | HIGH | MEDIUM | P1 | Ephemeral lifecycle |
| Cost tracking | MEDIUM | LOW | P2 | Structured output capture |
| Webhook replay | MEDIUM | LOW | P2 | Webhook listener, logging |
| Prompt templates | MEDIUM | LOW | P2 | Event handlers |
| Health monitoring | MEDIUM | MEDIUM | P2 | Webhook listener |
| CLI status command | LOW | LOW | P3 | Logging, profiles |

**Priority key:**
- P1: Must have for v2.0 launch
- P2: Should have, add in v2.x when triggered by real usage
- P3: Nice to have, future consideration

## Competitor Feature Analysis

| Feature | GitHub Actions + Claude Code | GitHub Copilot Coding Agent | Buildkite + Claude Code | claude-secure Headless |
|---------|------------------------------|----------------------------|-------------------------|------------------------|
| Network isolation | None (shared runner) | None (GitHub-managed) | None (pipeline runner) | Full (Docker internal network, iptables, proxy redaction) |
| Secret protection from LLM | None (secrets in env, visible to Claude) | Unknown (GitHub-managed) | None (secrets in env) | Proxy-level redaction of all secrets from LLM context |
| Webhook trigger | Native (workflow dispatch) | Native (issue assignment) | Native (pipeline trigger) | Custom listener (systemd service) |
| Per-repo config | workflow YAML per repo | AGENTS.md per repo | Pipeline YAML per repo | Profile directory per service (whitelist, secrets, workspace) |
| Ephemeral environment | Yes (runner lifecycle) | Yes (GitHub-managed VM) | Yes (pipeline step) | Yes (Docker Compose up/down per event) |
| Result output | GitHub Actions artifacts, PR comments | PR with changes | Pipeline artifacts | Markdown report to docs repo |
| Cost visibility | GitHub billing (no per-run breakdown) | Included in Copilot subscription | Buildkite billing | Per-event cost from Claude Code JSON output |
| Self-hosted | Possible (self-hosted runners) | No | Yes | Yes (designed for it) |

**Key insight:** The competitive advantage is not in the webhook/event handling (that is commodity infrastructure). The advantage is running headless Claude Code with the same four-layer security isolation that interactive mode provides. No other solution redacts secrets from the LLM context in headless/CI scenarios.

## Implementation Notes for Existing Infrastructure

### What can be reused from v1.0

| v1.0 Component | Reuse in v2.0 | Adaptation Needed |
|----------------|---------------|-------------------|
| `docker-compose.yml` | Directly | Add override file or env vars for headless command instead of `sleep infinity` + interactive exec |
| Proxy (Node.js) | As-is | None -- buffered redaction works identically for headless requests |
| Validator (Python + iptables) | As-is | None -- call-ID registration works identically |
| PreToolUse hooks | As-is | None -- hook intercepts tool calls regardless of interactive/headless mode |
| `bin/claude-secure` CLI | Extended | Add `headless` subcommand family alongside existing commands |
| Multi-instance infra | Pattern reused | Profiles build on same directory structure, add repo mapping + handler config |
| Structured logging | Extended | Add event metadata fields (webhook ID, event type, repo) |
| Instance auto-creation | Pattern reused | Profiles need non-interactive creation (no `read -rp` prompts) |

### What must be built new

| Component | Location | Purpose |
|-----------|----------|---------|
| Webhook listener | `webhook/` or host-level script | systemd service receiving HTTP POST from GitHub |
| Event handlers | `handlers/issues.sh`, `handlers/push.sh`, `handlers/ci-failure.sh` | Parse event payload, construct prompt, invoke headless spawn |
| Profile config schema | `profiles/*/` directories | Extended instance config with repo URL, event types, handler selection |
| Headless spawn script | `bin/claude-secure-headless` or subcommand | Non-interactive: clone workspace, `docker compose up`, `claude -p`, capture output, teardown |
| Result reporter | `lib/report.sh` | Clone docs repo, write report, commit and push |
| Installer additions | `install.sh` | Webhook listener systemd unit installation, profile setup |

## Sources

- [Claude Code Headless Mode - Official Docs](https://code.claude.com/docs/en/headless) -- HIGH confidence, official Anthropic documentation
- [Claude Code Permission Modes](https://code.claude.com/docs/en/permission-modes) -- HIGH confidence, official docs
- [Anthropic Auto Mode Engineering Blog](https://www.anthropic.com/engineering/claude-code-auto-mode) -- HIGH confidence, official blog
- [GitHub Agentic Workflows Technical Preview](https://github.blog/changelog/2026-02-13-github-agentic-workflows-are-now-in-technical-preview/) -- HIGH confidence, official GitHub
- [GitHub Copilot Coding Agent](https://docs.github.com/copilot/concepts/agents/coding-agent/about-coding-agent) -- HIGH confidence, official GitHub docs
- [GitHub Webhook Signature Verification](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) -- HIGH confidence, official GitHub docs
- [adnanh/webhook - lightweight webhook server](https://github.com/adnanh/webhook) -- HIGH confidence, widely-used open source tool
- [Buildkite Claude Code Review Bot](https://github.com/buildkite-agentic-examples/github-code-review-bot) -- MEDIUM confidence, community example
- [GitLab Copilot Coding Agent pattern](https://github.com/satomic/gitlab-copilot-coding-agent) -- MEDIUM confidence, community example

---
*Feature research for: claude-secure v2.0 headless agent mode*
*Researched: 2026-04-11*
