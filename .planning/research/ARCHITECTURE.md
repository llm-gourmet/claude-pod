# Architecture Research

**Domain:** Headless agent mode integration for claude-secure
**Researched:** 2026-04-11
**Confidence:** HIGH

## System Overview

### Current Architecture (v1.0)

```
HOST
 |
 |  claude-secure --instance NAME
 |       |
 |       v
 |  docker compose up -d
 |  docker compose exec -it claude claude --dangerously-skip-permissions
 |       |
 |       v
 |  +=======================================================+
 |  |           claude-internal (internal: true)             |
 |  |                                                        |
 |  |  +----------+     +-----------+                        |
 |  |  | claude   |<--->| validator |                        |
 |  |  | (Ubuntu) |     | (Python)  |                        |
 |  |  | hooks    |     | iptables  |                        |
 |  |  +----+-----+     | SQLite   |                        |
 |  |       |            +-----------+                       |
 |  |       |          network_mode: service:claude          |
 |  |       v                                                |
 |  |  +----------+                                          |
 |  |  |  proxy   |----> claude-external ---> internet       |
 |  |  | (Node.js)|     (api.anthropic.com only)             |
 |  |  +----------+                                          |
 |  +=======================================================+
 |
 |  Config: ~/.claude-secure/instances/<name>/
 |    - .env (secrets + auth)
 |    - config.sh (WORKSPACE_PATH)
 |    - whitelist.json (domains + placeholders)
```

### v2.0 Target Architecture (Headless Agent Mode)

```
HOST
 |
 |  +----------------------------+
 |  | webhook-listener           |  <--- GitHub webhooks (port 9876)
 |  | (systemd user service)     |
 |  | Node.js http stdlib        |
 |  +--------+-------------------+
 |           |
 |           | event dispatch (child_process.execFile)
 |           v
 |  +----------------------------+
 |  | event-handler              |  Bash: map event -> profile + prompt
 |  | (per-profile templates)    |
 |  +--------+-------------------+
 |           |
 |           | claude-secure --profile <name> --headless "<prompt>"
 |           v
 |  +=======================================================+
 |  |    Ephemeral Docker Compose Instance                   |
 |  |    (COMPOSE_PROJECT_NAME=claude-hdls-<timestamp>)      |
 |  |                                                        |
 |  |  +----------+     +-----------+                        |
 |  |  | claude   |<--->| validator |                        |
 |  |  | -p mode  |     |           |                        |
 |  |  | -T exec  |     |           |                        |
 |  |  +----+-----+     +-----------+                        |
 |  |       |                                                |
 |  |  +----------+                                          |
 |  |  |  proxy   |----> api.anthropic.com                   |
 |  |  +----------+                                          |
 |  +=======================================================+
 |           |
 |           | JSON result (stdout capture)
 |           v
 |  +----------------------------+
 |  | report-writer              |  Parse JSON, format markdown,
 |  | (Bash: jq + git)           |  git commit+push to docs repo
 |  +----------------------------+
```

## New vs Modified Components

### Component Inventory

| Component | Status | Location | Runtime |
|-----------|--------|----------|---------|
| webhook-listener | **NEW** | `listener/server.js` | Node.js (host process, systemd) |
| profile-system | **NEW** | `~/.claude-secure/profiles/<name>/` | Config files (no runtime) |
| event-handler | **NEW** | `listener/handlers/dispatch.sh` | Bash |
| report-writer | **NEW** | `listener/report.sh` | Bash + jq + git |
| bin/claude-secure | **MODIFIED** | `bin/claude-secure` | Bash (add ~80 lines) |
| docker-compose.yml | **UNCHANGED** | `docker-compose.yml` | Already parameterized |
| proxy | **UNCHANGED** | `proxy/` | Node.js stdlib |
| validator | **UNCHANGED** | `validator/` | Python stdlib |
| pre-tool-use.sh | **UNCHANGED** | `claude/hooks/` | Bash |

### What Does NOT Change (and Why)

| Component | Why Unchanged |
|-----------|---------------|
| `docker-compose.yml` | Already fully parameterized via env vars (WHITELIST_PATH, SECRETS_FILE, WORKSPACE_PATH, LOG_DIR, LOG_PREFIX). Profiles produce the same env vars instances do. |
| `proxy/proxy.js` | Redacts based on whitelist.json content. Does not know or care whether the session is interactive or headless. |
| `validator/validator.py` | Validates call-IDs from hooks. Works identically regardless of Claude's session type. |
| `claude/hooks/pre-tool-use.sh` | Reads whitelist, registers with validator. Works in both interactive and `-p` mode since hooks fire on tool use regardless. |
| `claude/Dockerfile` | Claude Code CLI already installed. `-p` flag is a runtime argument, not a build-time concern. |

## Detailed Component Designs

### 1. Webhook Listener

**Location:** `listener/server.js`
**Runtime:** Node.js `http` + `crypto` (stdlib only, matching project's zero-dependency pattern)
**Deployment:** systemd user service

**Why Node.js over Bash:** HMAC-SHA256 signature validation for GitHub webhooks requires `crypto.createHmac`. Pure Bash would need `openssl dgst` piped through `xxd` which is fragile and hard to get right. Node.js `crypto` is reliable, fast, and already available (required for Claude Code).

**Why host-side, not containerized:** The listener must orchestrate Docker Compose instances (start, exec, stop). Running it inside Docker would require Docker-in-Docker or socket mounting, adding complexity and security risk. It also needs host-level access to profile configs and the docs repo for git push.

**Responsibility:**
1. Listen on configurable port (default 9876)
2. Validate GitHub webhook HMAC signature
3. Parse event type from `X-GitHub-Event` header
4. Parse action from payload
5. Route to event handler as subprocess
6. Enforce concurrency limit (default: 2 simultaneous headless runs)

**Key design: No framework needed.** The listener handles one route (`POST /webhook`) with HMAC validation. This is ~60 lines with `http.createServer`, matching the proxy's zero-dependency approach.

```javascript
// Sketch of core logic (not production code)
const http = require('http');
const crypto = require('crypto');
const { execFile } = require('child_process');

http.createServer((req, res) => {
  // Validate HMAC
  const sig = req.headers['x-hub-signature-256'];
  const body = Buffer.concat(chunks);
  const expected = 'sha256=' + crypto.createHmac('sha256', SECRET).update(body).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) {
    return res.writeHead(401).end();
  }
  // Dispatch
  const event = req.headers['x-github-event'];
  const payload = JSON.parse(body);
  execFile('./handlers/dispatch.sh', [event, payload.action], {
    env: { ...process.env, PAYLOAD_FILE: tmpFile }
  });
  res.writeHead(202).end('accepted');
}).listen(PORT);
```

### 2. Profile System

**Location:** `~/.claude-secure/profiles/<service-name>/`

**How profiles map to existing config files:**

Profiles contain exactly what instance directories contain today, plus headless-specific additions. The key insight: profiles and instances produce identical Docker Compose environment variables, so docker-compose.yml needs zero changes.

```
~/.claude-secure/profiles/
  my-api-service/
    whitelist.json        # Same format as instance whitelist.json
    .env                  # Same format: auth token + service secrets
    config.sh             # WORKSPACE_PATH + new headless vars:
                          #   DOCS_REPO_PATH="/path/to/docs-repo"
                          #   MAX_TURNS=50
                          #   MAX_BUDGET_USD=2.00
                          #   ALLOWED_TOOLS="Bash,Read,Write,Edit,Glob,Grep"
                          #   MODEL=sonnet
    prompt-templates/
      issue.md            # Template: "Analyze {{ISSUE_TITLE}}..."
      push.md             # Template: "Review changes in {{COMMITS}}..."
      ci-failure.md       # Template: "Diagnose CI failure: {{LOG_URL}}..."
```

**Profile-to-Docker-Compose mapping:**

| Profile File | Docker Compose Variable | Mount Point |
|-------------|------------------------|-------------|
| `whitelist.json` | `WHITELIST_PATH=~/.claude-secure/profiles/X/whitelist.json` | `/etc/claude-secure/whitelist.json:ro` |
| `.env` | `SECRETS_FILE=~/.claude-secure/profiles/X/.env` | `env_file` directive |
| `config.sh` (WORKSPACE_PATH) | `WORKSPACE_PATH=/path/to/repo` | `/workspace` bind mount |

**Profile vs Instance coexistence:** Profiles live in `~/.claude-secure/profiles/`, instances in `~/.claude-secure/instances/`. They do not interfere. The CLI flag `--profile <name>` loads from profiles instead of instances. This avoids breaking existing interactive workflows.

**Profile-to-repo lookup:** A config file maps repository names to profiles:
```json
// ~/.claude-secure/profiles/repo-map.json
{
  "myorg/my-api": "my-api-service",
  "myorg/my-frontend": "my-frontend",
  "myorg/*": "default-profile"
}
```

### 3. Headless CLI Path (bin/claude-secure modification)

The existing CLI wrapper needs a new code path triggered by `--headless` and `--profile` flags.

**Current interactive execution (line 342-348):**
```bash
mkdir -p "$LOG_DIR"
chmod 777 "$LOG_DIR"
cleanup_containers
docker compose up -d
docker compose exec -it claude claude --dangerously-skip-permissions
```

**New headless execution path:**
```bash
headless)
  if [ -z "$HEADLESS_PROMPT" ]; then
    echo "ERROR: --headless requires a prompt argument" >&2; exit 1
  fi

  # Generate ephemeral instance name
  INSTANCE="hdls-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
  export COMPOSE_PROJECT_NAME="claude-${INSTANCE}"

  mkdir -p "$LOG_DIR"
  chmod 777 "$LOG_DIR"

  # Start services
  docker compose up -d

  # Wait for proxy to be reachable
  docker compose exec -T claude sh -c \
    'for i in $(seq 1 30); do curl -sf http://proxy:8080/ >/dev/null 2>&1 && break; sleep 1; done'

  # Run Claude headless (capture output to temp file)
  RESULT_FILE=$(mktemp)
  EXIT_CODE=0
  docker compose exec -T claude claude -p "$HEADLESS_PROMPT" \
    --output-format json \
    --allowedTools "${ALLOWED_TOOLS:-Bash,Read,Write,Edit,Glob,Grep,WebSearch,WebFetch}" \
    --max-turns "${MAX_TURNS:-50}" \
    --max-budget-usd "${MAX_BUDGET_USD:-2.00}" \
    --dangerously-skip-permissions \
    --bare \
    --no-session-persistence \
    > "$RESULT_FILE" 2>"${RESULT_FILE}.err" || EXIT_CODE=$?

  # Teardown
  docker compose down --remove-orphans 2>/dev/null
  docker volume rm "${COMPOSE_PROJECT_NAME}_validator-db" 2>/dev/null || true

  # Output result
  cat "$RESULT_FILE"
  rm -f "$RESULT_FILE" "${RESULT_FILE}.err"
  exit $EXIT_CODE
  ;;
```

**Critical flags explained:**

| Flag | Why Required |
|------|-------------|
| `-T` on `docker compose exec` | No TTY in headless/systemd context. Without this, Docker fails with "input device is not a TTY". The current interactive path uses `-it` which MUST NOT be used headless. |
| `-p "prompt"` | Core non-interactive mode. Runs prompt and exits. |
| `--output-format json` | Returns structured JSON with `result`, `total_cost_usd`, `duration_ms`, `num_turns`, `session_id`, `is_error`. Essential for report generation and cost tracking. |
| `--allowedTools` | Security: restrict which tools headless Claude can use. Some profiles (review-only) may exclude Bash entirely. |
| `--max-turns N` | Prevents runaway sessions. Default 50 is generous for most webhook tasks. |
| `--max-budget-usd N` | Hard cost cap per invocation. Prevents accidental spending on a stuck agent. |
| `--dangerously-skip-permissions` | Required for non-interactive mode -- no human to approve tool calls. This is safe because claude-secure's hook still enforces domain whitelisting. |
| `--bare` | Skips auto-discovery of hooks, skills, MCP, CLAUDE.md from the filesystem. Faster startup, deterministic behavior. Note: claude-secure's hooks are mounted at a different path and configured via settings.json, so they still fire. |
| `--no-session-persistence` | Ephemeral container -- no point persisting sessions to disk. |

**Security note on --dangerously-skip-permissions + --allowedTools:**
Using `--dangerously-skip-permissions` alone would be reckless outside claude-secure. But inside the Docker container, all four security layers are active: network isolation prevents direct internet access, the hook validates every tool call against the whitelist, the proxy redacts secrets, and the validator enforces iptables rules. Adding `--allowedTools` provides defense-in-depth by restricting WHICH tools Claude can invoke, while the hook restricts WHERE those tools can connect.

### 4. Event Handler

**Location:** `listener/handlers/dispatch.sh`

**Event-to-action mapping:**

| GitHub Event | Action Filter | Profile Source | Prompt Template |
|-------------|---------------|----------------|-----------------|
| `issues` | `opened`, `labeled` (label=claude) | `repo.full_name` lookup | `prompt-templates/issue.md` |
| `push` | ref=`refs/heads/main` | `repo.full_name` lookup | `prompt-templates/push.md` |
| `check_suite` | `completed` + conclusion=`failure` | `repo.full_name` lookup | `prompt-templates/ci-failure.md` |

**Template substitution:** Prompt templates use shell-style variables that `envsubst` replaces from webhook payload fields:

```markdown
# prompt-templates/issue.md
You are analyzing a GitHub issue for the ${REPO_NAME} project.

## Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

${ISSUE_BODY}

## Task
1. Read the codebase to understand the relevant code
2. Analyze the issue and propose an approach
3. Write a detailed analysis report
```

### 5. Report Writer

**Location:** `listener/report.sh`

**Input:** JSON output from `claude -p --output-format json`

**Output JSON structure (from official docs, HIGH confidence):**
```json
{
  "type": "result",
  "subtype": "success",
  "result": "The full text response from Claude",
  "total_cost_usd": 0.42,
  "is_error": false,
  "duration_ms": 45000,
  "num_turns": 12,
  "session_id": "abc-123"
}
```

**Report format:**
```markdown
# [Event Type]: [Event Title]

**Date:** 2026-04-11T14:30:00Z
**Repository:** myorg/my-api
**Event:** issues.opened #42
**Cost:** $0.42 | **Turns:** 12 | **Duration:** 45s

---

[Claude's response text from result field]

---
*Generated by claude-secure headless agent*
```

**Commit to docs repo:**
```bash
DOCS_REPO_PATH="$HOME/docs-repo"  # from profile config.sh
REPORT_DIR="$DOCS_REPO_PATH/reports/$(date +%Y-%m)"
mkdir -p "$REPORT_DIR"
# Write report
echo "$REPORT_CONTENT" > "$REPORT_DIR/${TIMESTAMP}-${EVENT_TYPE}-${EVENT_ID}.md"
# Commit and push
cd "$DOCS_REPO_PATH"
git add .
git commit -m "report: ${EVENT_TYPE} ${REPO_NAME} #${EVENT_ID}"
git push origin main
```

## Data Flow

### Complete Webhook-to-Report Flow

```
GitHub
  |
  |  POST /webhook (X-GitHub-Event: issues, X-Hub-Signature-256: sha256=...)
  |
  v
webhook-listener (HOST, port 9876)
  |
  |  1. Validate HMAC-SHA256 signature
  |  2. Parse event type + action
  |  3. Check concurrency limit
  |  4. Return 202 Accepted (async processing)
  |
  v
dispatch.sh (HOST, subprocess)
  |
  |  5. Extract repo name from payload
  |  6. Look up profile from repo-map.json
  |  7. Load profile config.sh
  |  8. Render prompt template with payload data
  |
  v
claude-secure --profile my-api --headless "$PROMPT" (HOST, subprocess)
  |
  |  9. Export WHITELIST_PATH, SECRETS_FILE, WORKSPACE_PATH from profile
  | 10. Generate ephemeral COMPOSE_PROJECT_NAME
  | 11. docker compose up -d (starts claude, proxy, validator)
  | 12. docker compose exec -T claude claude -p "$PROMPT" --output-format json ...
  |
  v
DOCKER (claude-internal network)
  |
  | 13. Claude processes prompt using allowed tools
  | 14. Hook validates each tool call (whitelist, call-ID registration)
  | 15. Proxy redacts secrets in Anthropic API traffic
  | 16. Validator enforces iptables per registered call-ID
  | 17. Claude completes task, returns JSON result to stdout
  |
  v
claude-secure (HOST, continues)
  |
  | 18. Capture JSON output
  | 19. docker compose down --remove-orphans
  | 20. Delete ephemeral instance config
  |
  v
report.sh (HOST, subprocess)
  |
  | 21. Parse JSON result with jq
  | 22. Format markdown report with metadata
  | 23. Write to docs repo
  | 24. git commit + git push
```

### Profile Resolution Flow

```
Webhook payload { "repository": { "full_name": "myorg/my-api" } }
    |
    v
repo-map.json: "myorg/my-api" -> "my-api-service"
    |
    v
~/.claude-secure/profiles/my-api-service/
    |
    +-- whitelist.json    --> WHITELIST_PATH (mounted into proxy + claude)
    +-- .env              --> SECRETS_FILE (env_file in compose) + sourced for auth
    +-- config.sh         --> WORKSPACE_PATH, MAX_TURNS, MAX_BUDGET_USD, DOCS_REPO_PATH
    +-- prompt-templates/
         +-- issue.md     --> envsubst with ISSUE_TITLE, ISSUE_BODY, etc.
```

## Architectural Patterns

### Pattern 1: Profile-as-Config (No New Containers)

**What:** Profiles are purely a config-layer concept. They produce the same environment variables that instances produce today. No new Docker services, no docker-compose.yml changes.

**When to use:** Always for headless mode.

**Trade-offs:**
- Pro: Reuses entire existing Docker Compose stack exactly as-is
- Pro: Profile changes are immediate (no rebuild needed)
- Pro: Testable: use profiles for interactive sessions too (`--profile X` instead of `--instance Y`)
- Con: Profiles must be set up on the host before webhook events can be processed

### Pattern 2: Ephemeral Instance Lifecycle

**What:** Each headless invocation creates a unique COMPOSE_PROJECT_NAME, runs the task, captures output, tears down all containers, and removes ephemeral config. No state persists between runs.

**When to use:** Every webhook-triggered headless run.

**Trade-offs:**
- Pro: Clean isolation between runs, no state leakage, no resource accumulation
- Pro: Different runs can use different profiles with different secrets and whitelists
- Con: Cold start penalty (~10-15s for docker compose up + service health). Acceptable for webhook tasks.
- Con: Docker image layers are cached but container creation is not free

### Pattern 3: CLI Subprocess, Not SDK

**What:** The webhook listener spawns `claude-secure` as a subprocess, not via the Claude Agent SDK.

**When to use:** Always for this project.

**Why this is the only correct approach:** Using the Agent SDK (`claude-agent-sdk` package) directly from the host would run Claude on the host, completely bypassing all four security layers (Docker isolation, hooks, proxy redaction, iptables validation). The `-p` flag via `docker compose exec -T` is the correct integration point because Claude runs inside the security boundary.

**Trade-offs:**
- Pro: All security layers remain active. Identical security guarantees as interactive mode.
- Pro: No new dependencies (no `claude-agent-sdk` npm/pip package needed on host)
- Con: Subprocess output parsing via JSON stdout instead of native message objects
- Con: Error handling is exit-code-based rather than exception-based

### Pattern 4: Host-Side Orchestrator, Container-Side Agent

**What:** The webhook listener runs on the host (systemd), while Claude runs inside Docker containers.

**When to use:** Always -- this is the fundamental security boundary.

**Network boundary visualization:**
```
INTERNET <--[port 9876]--> webhook-listener (HOST)
                                |
                                | docker compose exec -T (Docker CLI)
                                v
                     Docker internal network (ISOLATED)
                        claude <-> proxy <-> api.anthropic.com (external only)
                        claude <-> validator (iptables enforcement)
```

The webhook listener communicates with Docker only through the Docker CLI. It never connects to any container over a network socket directly.

## Anti-Patterns

### Anti-Pattern 1: Running Claude Agent SDK Directly on Host

**What people do:** Import `claude-agent-sdk` in the webhook listener and call `query()` directly.
**Why it's wrong:** Completely bypasses Docker isolation, hooks, proxy redaction, and iptables validation. Claude runs on the host with full network access. Secrets are sent to Anthropic unredacted.
**Do this instead:** Always use `docker compose exec -T claude claude -p ...` to keep Claude inside the security boundary.

### Anti-Pattern 2: Persistent Headless Containers

**What people do:** Keep Docker Compose containers running between webhook events for faster response.
**Why it's wrong:** State leakage between tasks (workspace files, SQLite entries, env contamination). Different events may need different profiles.
**Do this instead:** Ephemeral instances. The ~10-15s startup cost is acceptable for webhook tasks that take 30-300 seconds anyway.

### Anti-Pattern 3: Webhook Listener Inside Docker

**What people do:** Add the listener as a Docker Compose service.
**Why it's wrong:** The listener needs to orchestrate Docker Compose (start/exec/stop other instances). Docker-in-Docker or socket mounting adds complexity and attack surface. The listener also needs host access to profile configs and docs repos.
**Do this instead:** Run the listener as a systemd user service on the host.

### Anti-Pattern 4: Using -it Flags for Headless Exec

**What people do:** Copy the interactive `docker compose exec -it claude claude ...` pattern for headless.
**Why it's wrong:** `-it` allocates a TTY and interactive stdin. In systemd/background context, there is no TTY, causing "input device is not a TTY" errors.
**Do this instead:** Use `docker compose exec -T` (no TTY, no stdin). This is critical and easy to miss.

### Anti-Pattern 5: --dangerously-skip-permissions Without --allowedTools

**What people do:** Use `--dangerously-skip-permissions` and rely solely on claude-secure's hook for security.
**Why it's wrong:** While the hook enforces domain whitelisting, defense-in-depth requires also restricting which tools are available. Some headless tasks (review, analysis) should not have Bash access at all.
**Do this instead:** Always pair with explicit `--allowedTools` per profile. Read-only tasks use `"Read,Glob,Grep"`. Full tasks use `"Bash,Read,Write,Edit,Glob,Grep,WebSearch,WebFetch"`.

## Recommended Project Structure (v2.0 additions)

```
claude-secure/
  (existing -- unchanged)
  bin/claude-secure              # MODIFIED: add --profile, --headless
  docker-compose.yml             # UNCHANGED
  proxy/                         # UNCHANGED
  validator/                     # UNCHANGED
  claude/                        # UNCHANGED
  config/                        # UNCHANGED
  tests/                         # UNCHANGED (add new test scripts)
  install.sh                     # MINOR: optionally install systemd service

  (new)
  listener/
    server.js                    # Webhook HTTP server (Node.js stdlib)
    handlers/
      dispatch.sh                # Event routing + profile lookup
    report.sh                    # JSON parse + report format + git push
    systemd/
      claude-webhook.service     # systemd user unit file
    config.example.json          # Example: port, webhook secret, concurrency

  profiles/
    example-service/             # Example profile (shipped in repo)
      whitelist.json
      env.example                # Example .env (no real secrets)
      config.sh
      prompt-templates/
        issue.md
        push.md
        ci-failure.md
    repo-map.example.json        # Example repo-to-profile mapping
```

## Suggested Build Order

Based on dependency analysis, build bottom-up:

| Order | Component | Depends On | Can Test With |
|-------|-----------|------------|---------------|
| 1 | Profile system | Nothing | Use profiles for interactive sessions |
| 2 | Headless CLI path | Profiles | `claude-secure --profile test --headless "echo hello"` |
| 3 | Report writer | Headless CLI output | Captured JSON from step 2 |
| 4 | Webhook listener | Nothing (independent) | `curl -X POST` with test payloads |
| 5 | Event handlers + templates | Profiles + listener | Webhook -> profile -> prompt (dry run) |
| 6 | Integration + lifecycle | All above | End-to-end: webhook -> headless -> report |

**Rationale:** Profiles first because everything else depends on them. Headless CLI second because it is the core integration point and can be tested manually. Listener can be developed in parallel with steps 2-3 since it is independent until integration. Report writer is simple (jq + git) but depends on knowing the JSON output format from step 2.

## Sources

- [Claude Code headless documentation](https://code.claude.com/docs/en/headless) -- HIGH confidence, official Anthropic docs. Confirms `-p`, `--output-format json`, `--bare`, `--allowedTools`, `--max-turns`, `--max-budget-usd`, `--no-session-persistence` flags.
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) -- HIGH confidence, official. Complete flag inventory including `--dangerously-skip-permissions`, `--append-system-prompt`, `--permission-mode`.
- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) -- HIGH confidence, official. Confirms SDK is for direct programmatic use (NOT appropriate for claude-secure's architecture where Docker isolation is required).
- [adnanh/webhook](https://github.com/adnanh/webhook) -- Reference for webhook server + systemd integration patterns.
- Existing claude-secure codebase (`docker-compose.yml`, `bin/claude-secure`, `pre-tool-use.sh`, `install.sh`) -- HIGH confidence, primary source for integration point analysis.

---
*Architecture research for: claude-secure v2.0 headless agent mode*
*Researched: 2026-04-11*
