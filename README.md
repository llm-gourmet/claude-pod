# claude-secure

A security wrapper for Claude Code that prevents API key and secret exfiltration by running it in a fully network-isolated Docker environment.

## Problem

Claude Code has unrestricted network access. It reads `.env` files and other configuration, pulling secrets into the LLM context. Those secrets are then sent to Anthropic's API as part of every conversation turn. Additionally, tool calls like `Bash(curl ...)` or `WebFetch` can exfiltrate data to arbitrary external URLs. There is no built-in mechanism to prevent this.

claude-secure solves this with a four-layer defense-in-depth architecture that ensures no secret ever leaves the isolated environment uncontrolled.

## How It Works

Four independent security layers work together so that any single layer failing does not compromise the system:

**Layer 1: Docker Network Isolation** -- The Claude container runs on a Docker network marked `internal: true`, which blocks all direct external access at the network level.

**Layer 2: PreToolUse Hook** -- A shell hook intercepts every `Bash`, `WebFetch`, and `WebSearch` tool call before execution. It extracts the target domain, checks it against a configurable whitelist, blocks payloads to non-whitelisted domains, and detects shell obfuscation attempts (variable expansion, `eval`, base64 encoding in curl commands).

**Layer 3: Anthropic Proxy** -- All traffic from Claude Code to the Anthropic API passes through a buffered proxy. The proxy scans each request body for secret values and replaces them with placeholders before forwarding. On the response, it restores placeholders to real values so Claude Code functions normally -- but Anthropic never sees the actual secrets.

**Layer 4: Call Validator** -- The hook registers a single-use, time-limited (10-second TTL) call-ID with the validator before allowing any outbound payload request. The validator manages iptables rules to enforce that only registered calls can reach external services. Call-IDs are stored in SQLite and expire automatically.

### Architecture Diagram

```
                        +---------------------------+
                        |     claude-external       |
                        |       (network)           |
                        +---------------------------+
                              |              |
                              |         api.anthropic.com
                              |
                  +-----------+-----------+
                  |       proxy           |
                  |  (Node.js)            |
                  |  - HTTP :8080         |
                  |  - HTTPS :443         |
                  |  - secret redaction   |
                  |  - buffered req/res   |
                  |  - DNS alias:         |
                  |    api.anthropic.com  |
                  +-----------+-----------+
                              |
                  +-----------+-----------+
                  |   claude-internal     |
                  |   (network,           |
                  |    internal: true)    |
                  +-----------+-----------+
                              |
          +-------------------+-------------------+
          |                                       |
+---------+---------+               +-------------+---------+
|      claude       |               |       validator       |
| (Ubuntu, Claude   |               | (Python, SQLite,      |
|  Code CLI)        | <- shared ->  |  iptables)            |
| - PreToolUse hook |   network     | - call-ID registry    |
| - workspace mount |   namespace   | - iptables rules      |
+-------------------+               +-------------+---------+
```

The proxy container bridges both networks. The validator shares the claude container's network namespace (`network_mode: service:claude`) so it can manage iptables rules for Claude's outbound traffic directly.

## Prerequisites

- Docker Engine 24+
- Docker Compose v2 (the `docker compose` plugin, not standalone `docker-compose` v1)
- curl
- jq
- uuidgen (`uuid-runtime` package on Debian/Ubuntu)
- Linux (native) or WSL2 -- no macOS support

## Installation

```bash
git clone <repo-url>
cd claude-secure
sudo ./install.sh

# Optional: also install webhook listener (systemd service) and reaper timer
sudo ./install.sh --with-webhook
```

The installer:

1. Checks that all host dependencies are present
2. Detects platform (native Linux or WSL2) and warns about Docker Desktop iptables issues
3. Prompts for authentication -- OAuth token (recommended, via `claude setup-token`) or API key as fallback
4. Prompts for a workspace path (default: `~/claude-workspace`)
5. Copies project files to `~/.claude-secure/app/`
6. Copies the default `whitelist.json` to `~/.claude-secure/whitelist.json` and symlinks it back so config edits persist across updates
7. Builds Docker images
8. Installs the `claude-secure` CLI to `/usr/local/bin` (or `~/.local/bin` as fallback)
9. Requires `sudo` to install the CLI to `/usr/local/bin/` and write hook configs to `/etc/claude-secure/` (root-owned, immutable to the Claude process). If `sudo` is unavailable, the CLI falls back to `~/.local/bin` but security hooks will not be root-owned.
10. When `--with-webhook` is passed: installs `webhook/listener.py` to `/opt/claude-secure/webhook/`, writes a default config to `/etc/claude-secure/webhook.json` (never overwrites an existing file), and installs `claude-secure-listener.service` plus `claude-secure-reaper.timer` systemd units.

## Usage

```bash
# Start containers and launch Claude Code interactively
claude-secure

# Stop all containers
claude-secure stop

# Show container status and Claude Code version
claude-secure status

# Pull latest source, rebuild images, and update CLI wrapper
claude-secure update

# Rebuild claude image with latest Claude Code from npm (--no-cache)
claude-secure upgrade

# Show all available commands
claude-secure help
```

```bash
# Scope any command to a specific profile
claude-secure --profile <name>

# Without --profile: superuser mode (merged access to all profiles)
claude-secure

# Run headless Claude Code session triggered by a GitHub event
claude-secure --profile <name> spawn --event '<json>'
claude-secure --profile <name> spawn --event-file <path/to/event.json>

# Replay a previous webhook delivery by delivery-ID substring
claude-secure --profile <name> replay <delivery-id>

# Clean up orphaned spawn containers and stale event files
claude-secure reap

# List all profiles and their running status
claude-secure list
```

## Configuration

The whitelist controls which domains can receive outbound data and which secrets are redacted by the proxy. The configuration file lives at `~/.claude-secure/whitelist.json` (symlinked into the Docker build context by the installer).

The whitelist is re-read on every request -- no container restart is needed after editing.

### Default Structure

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    },
    {
      "placeholder": "PLACEHOLDER_STRIPE",
      "env_var": "STRIPE_KEY",
      "allowed_domains": ["stripe.com", "api.stripe.com"]
    },
    {
      "placeholder": "PLACEHOLDER_OPENAI",
      "env_var": "OPENAI_API_KEY",
      "allowed_domains": ["api.openai.com"]
    }
  ],
  "readonly_domains": [
    "google.com",
    "stackoverflow.com",
    "docs.anthropic.com"
  ]
}
```

**`secrets`** -- Each entry defines:
- `placeholder`: The string that replaces the secret value in LLM context sent to Anthropic
- `env_var`: The environment variable holding the real secret value
- `allowed_domains`: Domains to which this secret may be sent in outbound payload requests

**`readonly_domains`** -- Domains allowed for read-only (GET) requests without call-ID registration. These are typically documentation and reference sites.

To add a new secret, add an entry to the `secrets` array with a unique placeholder, the environment variable name, and the domains that need it. Set the environment variable in `~/.claude-secure/.env`.

## Profiles

Profiles isolate each project's workspace, secrets, and whitelist into a named
directory under `~/.claude-secure/profiles/<name>/`.

### Profile directory layout

```
~/.claude-secure/profiles/<name>/
  profile.json      # Profile configuration
  .env              # Auth credentials + project secrets (chmod 600)
  whitelist.json    # Per-profile domain whitelist
  prompts/          # Optional: custom prompt templates
  report-templates/ # Optional: custom report templates
```

### Creating a profile

Pass `--profile <name>` to any `claude-secure` command. If the profile does not
exist, the CLI prompts interactively for workspace path and auth credentials:

```bash
claude-secure --profile myproject
```

Profile names must be DNS-safe: lowercase alphanumeric and hyphens, starting with
a letter or digit, max 63 characters.

### profile.json fields

| Field | Required | Description |
|-------|----------|-------------|
| `workspace` | Yes | Absolute path to the project workspace directory |
| `repo` | No | Full repo name (`owner/repo`) -- used by webhook listener for profile routing |
| `webhook_secret` | No | HMAC-SHA256 secret for GitHub webhook verification |
| `report_repo` | No | Full HTTPS URL of the docs repo for report push (e.g. `https://github.com/you/docs.git`) |
| `report_branch` | No | Target branch for report push (default: `main`) |
| `report_path_prefix` | No | Directory inside report repo where reports land (default: `reports`) |
| `max_turns` | No | Maximum Claude turns per headless spawn (default: unlimited) |
| `webhook_event_filter` | No | Per-event-type filter config (see Webhook Listener section) |
| `webhook_bot_users` | No | GitHub usernames ignored for loop prevention on push events |

The `REPORT_REPO_TOKEN` PAT for report push belongs in the profile `.env`, not
the global `.env`:

```bash
# ~/.claude-secure/profiles/<name>/.env
REPORT_REPO_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

## Logging

All three services (hook, proxy, validator) support structured JSONL logging. Logging is disabled by default and enabled via environment variable toggles, so there is zero overhead unless you opt in.

### Enabling Logs

Append log flags to any `claude-secure` command:

```bash
# Enable specific service logging
claude-secure log:hook         # Enable hook script logging
claude-secure log:anthropic    # Enable proxy logging (metadata only)
claude-secure log:bodies       # Enable proxy logging with full request/response bodies
claude-secure log:iptables     # Enable validator/iptables logging

# Enable all logging at once
claude-secure log:all          # Enable all metadata logging (no bodies)

# Flags combine with commands
claude-secure log:hook log:anthropic  # Enable hook + proxy only
```

### Log Format

Each service writes structured JSONL (one JSON object per line) with four standard fields:

```json
{"ts":"2026-04-10T12:00:00.000Z","svc":"hook","level":"info","msg":"allow domain=github.com tool=Bash"}
```

| Field   | Description                                  |
|---------|----------------------------------------------|
| `ts`    | ISO 8601 timestamp (UTC)                     |
| `svc`   | Service name: `hook`, `anthropic`, `iptables`|
| `level` | Log level: `info`, `warning`, `error`        |
| `msg`   | Human-readable event description             |

### Viewing Logs

Use the `logs` subcommand to tail log files in real time:

```bash
claude-secure logs              # Tail all log files
claude-secure logs hook         # Tail hook logs only
claude-secure logs anthropic    # Tail proxy logs only
claude-secure logs iptables     # Tail validator logs only
claude-secure logs clear        # Delete all log files
```

### Log Location

Log files are stored at `~/.claude-secure/logs/`:

- `hook.jsonl` -- PreToolUse hook decisions (allow, deny, register)
- `anthropic.jsonl` -- Proxy request metadata (method, path, status, duration, redaction count)
- `iptables.jsonl` -- Validator call-ID registration and iptables rule events

### Body Logging

The `log:bodies` flag enables full request/response body logging for traffic to `api.anthropic.com`. Bodies are logged **after redaction**, so secrets appear as placeholders (e.g., `REDACTED_GITHUB_TOKEN`), not real values. This lets you inspect exactly what Anthropic receives.

```bash
# Start with body logging
claude-secure log:bodies

# Tail and pretty-print the payloads
tail -f ~/.claude-secure/logs/anthropic.jsonl | jq .

# Extract just the last message sent to Anthropic
tail -f ~/.claude-secure/logs/anthropic.jsonl | jq 'select(.request_body) | {path, request_body: (.request_body | fromjson | .messages[-1])}'
```

Body logs can be large. Use `log:bodies` only for targeted debugging or security audits, not in regular sessions. The `log:all` flag intentionally excludes bodies.

### Security Note

By default, proxy logs never include request or response bodies -- only metadata (HTTP method, path, status code, duration, and redaction count). The `log:bodies` flag opts in to body logging, which is safe because bodies are captured after the redaction layer has replaced all secrets with placeholders.

## Phase 16 -- Result Channel (Report Push + Audit Log)

Every headless execution of `claude-secure spawn` (whether triggered by the webhook listener or invoked manually) produces two durable artifacts:

1. A **structured markdown report** pushed to a dedicated documentation repo on GitHub
2. A **JSONL audit line** appended to `$LOG_DIR/executions.jsonl` on the host

The audit log is always written. The report push is best-effort -- push failures are non-fatal and are recorded in the audit line.

### One-time setup: documentation repo + PAT

1. Create a new, empty GitHub repo for reports (e.g. `you/claude-reports`). Initialize it with a `main` branch and an initial commit (an empty README is fine -- a clone of an empty repo has no branch to check out).

2. Create a fine-grained GitHub Personal Access Token with the minimum scope: `contents: write` on the report repo ONLY. Do NOT grant scope on any source repo. The token is used exclusively to push report commits.

3. Add the PAT to the **profile** `.env` file (never the global `.env`). The profile `.env` is loaded only when that profile is active, and its values are auto-redacted from committed reports.

   ```bash
   # ~/.claude-secure/profiles/<name>/.env
   REPORT_REPO_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
   ```

4. Configure the profile JSON with the report repo fields:

   ```bash
   jq '.report_repo = "https://github.com/you/claude-reports.git"
       | .report_branch = "main"
       | .report_path_prefix = "reports"' \
     ~/.claude-secure/profiles/<name>/profile.json > /tmp/p.json \
     && mv /tmp/p.json ~/.claude-secure/profiles/<name>/profile.json
   ```

   Fields:
   - `report_repo` -- full HTTPS URL of the documentation repo. Leave unset or empty to skip report push entirely (audit log is still written).
   - `report_branch` -- target branch (default `main`).
   - `report_path_prefix` -- directory inside the repo where reports land (default `reports`). Reports are placed at `<prefix>/<YYYY>/<MM>/<event_type>-<delivery_id_short>.md`.

### Audit log

Every spawn appends one JSONL line to `$LOG_DIR/<LOG_PREFIX>executions.jsonl`. For the default instance the path is `~/.claude-secure/logs/executions.jsonl`; multi-instance deployments (e.g. the test instance) get their own prefixed file.

Each line is a single JSON object with mandatory keys: `ts`, `delivery_id`, `webhook_id`, `event_type`, `profile`, `repo`, `commit_sha`, `branch`, `cost_usd`, `duration_ms`, `session_id`, `status`, `report_url`.

```bash
# tail successful spawns
tail -f ~/.claude-secure/logs/executions.jsonl | jq 'select(.status == "success")'

# find push failures
jq 'select(.status == "report_push_failed")' ~/.claude-secure/logs/executions.jsonl

# total cost per profile
jq -s 'group_by(.profile)
       | map({profile: .[0].profile,
              total_cost: (map(.cost_usd // 0) | add)})' \
  ~/.claude-secure/logs/executions.jsonl
```

The `status` field takes one of four values:

- `success` -- Claude ran, the report pushed cleanly (or no `report_repo` was configured).
- `report_push_failed` -- Claude ran successfully but the push failed. Spawn still exits 0 -- push is observability, not the source of truth.
- `claude_error` -- Claude itself failed (nonzero exit). Spawn exits nonzero.
- `spawn_error` -- A pre-Claude error (profile load, config, cleanup failure) aborted the spawn.

### Customizing report templates

Report templates are resolved through a fallback chain (first match wins):

1. `~/.claude-secure/profiles/<name>/report-templates/<event>.md` -- profile override (per-profile customization)
2. `$WEBHOOK_REPORT_TEMPLATES_DIR/<event>.md` -- env override (primarily for tests)
3. `<repo-checkout>/webhook/report-templates/<event>.md` -- dev fallback (when running from a git checkout)
4. `/opt/claude-secure/webhook/report-templates/<event>.md` -- production default (shipped by `install.sh`)

Default templates live in `webhook/report-templates/` in this repo and are copied to `/opt/claude-secure/webhook/report-templates/` on every `install.sh` run. The installer copies individual files but never `rm -rf`s the directory, so any extra templates you add alongside the defaults (e.g. `pull_request-opened.md`) survive reinstalls.

To customize a default, drop a file of the same name in your profile's `report-templates/` directory -- it takes precedence. Templates use `{{VARIABLE}}` substitution with all Phase 15 variables (`{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{REPO_FULL_NAME}}`, `{{COMMIT_SHA}}`, etc.) plus Phase 16 extensions:

- `{{RESULT_TEXT}}` -- Claude's final message body (truncated at 16KB with a `... [truncated N more bytes]` marker)
- `{{ERROR_MESSAGE}}` -- non-empty on failures
- `{{COST_USD}}`, `{{DURATION_MS}}`, `{{SESSION_ID}}` -- from the Claude output envelope
- `{{TIMESTAMP}}` -- ISO-8601 UTC timestamp of the spawn
- `{{STATUS}}` -- one of `success` / `claude_error` / `spawn_error` / `report_push_failed`

### Skipping publish (local-only runs)

Pass `--skip-report` on the command line or set `CLAUDE_SECURE_SKIP_REPORT=1` in the environment. The audit log line is still written, but no clone or push is attempted. Useful for debugging, offline work, and test harnesses.

```bash
claude-secure spawn --skip-report --profile <name> --event <path-to-event.json>
# or
CLAUDE_SECURE_SKIP_REPORT=1 claude-secure spawn --profile <name> --event ...
```

### Security notes

- **PAT is never placed in the remote URL or argv.** Git is invoked with a `GIT_ASKPASS` helper script that reads the PAT from an environment variable passed only to the `git` child process. The token never appears in `ps` output, command history, or the remote URL.
- **Profile `.env` values are auto-redacted from committed reports.** Before `git add`, the rendered report body passes through a redaction pass that replaces every occurrence of each profile `.env` value with `<REDACTED:KEY>`. If Claude's output accidentally echoes `REPORT_REPO_TOKEN`, the committed markdown contains `<REDACTED:REPORT_REPO_TOKEN>` instead. Empty values are skipped (so `EMPTY_VAR=` does not mangle whitespace).
- **No force-push, ever.** Force-push is never used by the report publisher. If a concurrent writer pushes to the same branch first, the spawn rebases with `git pull --rebase` and retries exactly once. A second failure is recorded in the audit log with `status=report_push_failed`; the doc repo history is never rewritten.
- **Result text is bounded at 16KB.** Larger Claude outputs are truncated UTF-8-safely with a `... [truncated N more bytes]` suffix so that long sessions cannot produce multi-megabyte commits.
- **Audit lines are append-only.** Per-instance JSONL files respect the `LOG_PREFIX` multi-instance convention, so two instances on the same host write to distinct files and cannot race each other. Within one instance, POSIX `O_APPEND` guarantees atomic writes because each line stays under 4KB (`PIPE_BUF`).

## Phase 17 -- Operational Hardening (Container Reaper)

A systemd timer periodically cleans up orphaned spawn containers (from crashed or timed-out executions) and stale event files. The reaper is installed automatically by `install.sh --with-webhook`; no configuration is required for default behavior.

### How it runs

- **Timer:** `claude-secure-reaper.timer` fires 2 minutes after boot, then every 5 minutes thereafter.
- **Service:** Each firing invokes `claude-secure reap` as a one-shot systemd service. No long-running daemon.
- **Locking:** A `flock` guard prevents concurrent cycles. If a manual invocation and a timer firing collide, the second one exits silently.
- **Logging:** All reaper activity goes to the systemd journal only -- no separate log file.

### Tailing activity

```bash
# Live tail of the reaper journal (what the timer is doing right now)
journalctl -u claude-secure-reaper -f

# Timer status and next scheduled firing
systemctl list-timers claude-secure-reaper.timer

# One-shot view of recent cycles
journalctl -u claude-secure-reaper --since '1 hour ago'
```

### Manual invocation

```bash
# Preview what would be reaped without touching anything
claude-secure reap --dry-run

# Run a normal reap cycle (same as the timer does)
claude-secure reap

# Aggressive cleanup: reap every matching container regardless of age
REAPER_ORPHAN_AGE_SECS=0 claude-secure reap
```

### Tuning via environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `REAPER_ORPHAN_AGE_SECS` | `600` (10 min) | Minimum container age before the reaper will tear it down. The default is twice the timer interval, so a healthy spawn always exits well before the reaper would consider it. |
| `REAPER_EVENT_AGE_SECS` | `86400` (24 h) | Minimum age before event files under `~/.claude-secure/events/` are deleted. The 24-hour default is well above any normal spawn lifetime. |

The reaper never touches images, named volumes, bind-mounted workspaces, or containers outside your configured instance prefix. Multi-instance deployments (e.g. a `test` instance alongside `default`) are isolated by label -- each instance's timer only reaps its own orphans.

### Listener hardening

The webhook listener unit file and the reaper service both ship with a conservative set of systemd hardening directives (read-only kernel tunables, no namespace creation, no write-execute memory, native syscall ABI only). These are docker-compose-compatible. Six additional directives (`NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`, `CapabilityBoundingSet`, `ProtectHome`, `PrivateDevices`) are deliberately excluded because each one breaks docker compose subprocess access to the docker socket or `/tmp`. The exclusion list is documented inline in each unit file; re-enabling any of those directives without re-running the end-to-end tests will break the listener.

### Upgrading from Phase 16

If you installed a prior version with `install.sh --with-webhook`, re-run the installer to pick up both the reaper timer and the updated listener hardening. Your existing webhook secrets, profiles, and report repos are preserved -- only the unit files and `/opt/claude-secure/webhook/` contents are refreshed.

```bash
sudo ./install.sh --with-webhook
```

## Testing

### Quick Start

Requires Docker running. All tests use an isolated `claude-test` Docker Compose instance that does not interfere with any running `claude-secure` session.

```bash
# Run all integration tests
./run-tests.sh

# Run specific test suites
./run-tests.sh test-phase1.sh test-phase3.sh
```

### Available Test Suites

| Script | Covers |
|--------|--------|
| test-phase1.sh | Container infrastructure, networking, health checks |
| test-phase2.sh | Call validation, hook enforcement, iptables rules |
| test-phase3.sh | Secret redaction in proxy |
| test-phase4.sh | Installer script |
| test-phase6.sh | Phase 6 features |
| test-phase7.sh | Environment file and secret loading |
| test-phase9.sh | CLI wrapper (bin/claude-secure) |

### Smart Pre-Push Hook

The pre-push hook (`git-hooks/pre-push`) automatically runs relevant tests before each push:

- **Smart selection** -- Determines which test suites to run based on changed files using `tests/test-map.json`. For example, editing files under `proxy/` triggers `test-phase1.sh` and `test-phase3.sh`.
- **Doc-only skip** -- Changes limited to `*.md`, `.planning/`, or `.claude/` skip tests entirely.
- **Fallback** -- If changed files have no mapping in test-map.json, all tests run as a safety net.
- **Isolated instance** -- Tests run in a dedicated `claude-test` Docker Compose project, separate from any running session.
- **Skip**: `git push --no-verify`
- **Force all tests**: `RUN_ALL_TESTS=1 git push`

### test-map.json Structure

The file `tests/test-map.json` controls smart test selection with two keys:

- **`mappings`** -- Array of `{paths: [...], tests: [...]}` objects. Each entry maps file path prefixes to the test suites that cover them.
- **`always_skip`** -- Array of patterns (globs like `*.md`, directory prefixes like `.planning/`) that never trigger tests.

Example from the actual file:

```json
{
  "mappings": [
    { "paths": ["proxy/"], "tests": ["test-phase1.sh", "test-phase3.sh"] },
    { "paths": ["install.sh"], "tests": ["test-phase4.sh"] }
  ],
  "always_skip": [".planning/", ".claude/", ".git/", "*.md"]
}
```

## Architecture Details

### claude Container

- Base image: Node.js 22 Slim
- Runs the Claude Code CLI
- All Linux capabilities dropped (`cap_drop: ALL`), `no-new-privileges` enforced
- Workspace directory bind-mounted as a Docker volume
- `ANTHROPIC_BASE_URL` points to the proxy (`http://proxy:8080`), so all API traffic routes through the redaction layer
- `HTTP_PROXY` and `HTTPS_PROXY` set to `http://proxy:8080`, routing all outbound HTTP/HTTPS tool calls (curl, wget, WebFetch) through the proxy for domain validation and CONNECT tunneling
- `NODE_TLS_REJECT_UNAUTHORIZED=0` set to accept the proxy's self-signed certificate for intercepted HTTPS calls
- Telemetry, auto-updater, and error reporting disabled to prevent non-essential external connections
- Onboarding flag pre-set (`hasCompletedOnboarding`) to skip startup checks that bypass `ANTHROPIC_BASE_URL`
- PreToolUse hook installed at `/etc/claude-secure/` (root-owned, read-only)
- Connected only to the `claude-internal` network (no external access)

### proxy Container

- Base image: Node.js 22 Slim
- Zero npm dependencies -- uses only Node.js stdlib (`http`, `https`, `net`, `dns`, `fs`)
- Listens on HTTP port 8080 (for `ANTHROPIC_BASE_URL` traffic) and HTTPS port 443 with a self-signed certificate (for intercepted hardcoded calls)
- Registered as a Docker network alias for `api.anthropic.com`, `statsig.anthropic.com`, and `sentry.anthropic.com` on the internal network -- Claude Code's hardcoded external calls resolve to the proxy instead of failing
- Acts as a forward proxy for the claude container (`HTTP_PROXY`/`HTTPS_PROXY`), enabling outbound HTTPS connections to whitelisted domains via CONNECT tunneling
- Validates CONNECT targets against the whitelist -- non-whitelisted domains are rejected with 403
- Uses external DNS (8.8.8.8, 1.1.1.1) for upstream resolution to bypass Docker network aliases that would otherwise cause a DNS loop
- Buffers entire request body, performs longest-first secret replacement, forwards to `api.anthropic.com`
- Buffers entire response, restores placeholders to real values, returns to Claude
- Strips `Accept-Encoding` to prevent compressed responses that cannot be scanned
- Connected to both `claude-internal` and `claude-external` networks

### validator Container

- Base image: Python 3.11 Alpine
- Zero pip dependencies -- uses only Python stdlib (`http.server`, `sqlite3`, `subprocess`, `json`, `threading`)
- SQLite database in WAL mode for concurrent read/write access
- `POST /register` -- accepts call-ID + domain, stores with 10-second TTL
- `GET /validate?call_id=X` -- checks if call-ID is valid and not expired
- Background thread sweeps expired entries periodically
- Shares network namespace with claude container (`network_mode: service:claude`) for direct iptables rule management
- Allows DNS queries to Docker embedded DNS (127.0.0.11) for domain resolution during call-ID registration
- Requires `NET_ADMIN` capability for iptables access

## Security Model

**Secrets are redacted before reaching Anthropic.** The proxy replaces every secret value in the request body with a placeholder. Anthropic's API only ever sees `PLACEHOLDER_GITHUB`, never the actual token.

**Outbound payload requests require whitelisted domain + registered call-ID.** The PreToolUse hook checks that the target domain appears in `whitelist.json` and registers a single-use call-ID with the validator before allowing the call to proceed.

**Read-only (GET) requests are allowed without registration.** Fetching documentation, searching the web, and reading public APIs do not require call-ID registration.

**Shell obfuscation is detected and blocked.** The hook scans curl/wget commands for variable expansion (`$VAR`, `${VAR}`), backtick substitution, `eval`, and `base64` encoding. Any detected obfuscation results in an immediate deny.

**Hook scripts and config are root-owned and read-only.** Inside the container, the Claude process cannot modify the security layer.

**Zero external dependencies in security-critical paths.** The proxy uses only Node.js stdlib. The validator uses only Python stdlib. No npm packages, no pip packages -- eliminating supply-chain attack surface.

## Limitations

- **Buffered proxy (no streaming)** -- All API responses are buffered for redaction before returning. This adds latency compared to streaming.
- **No `@file` content scanning** -- When Claude Code references files via `@file`, the file contents enter LLM context but are not scanned by the proxy (they are part of the user-side message, not a secret environment variable).
- **No macOS support** -- Docker Desktop on macOS does not support the network isolation and iptables patterns this project requires.
- **No automatic OAuth token refresh** -- If the OAuth token expires, you must re-run the auth setup manually.

## Platform Support

- **Linux (native)** -- Fully supported. Any modern distribution with Docker Engine 24+ and kernel 4.x+.
- **WSL2** -- Supported. The installer detects WSL2 automatically and validates the iptables backend.

Docker Desktop on WSL2 may have iptables compatibility issues. Docker CE installed directly in the WSL2 distribution is recommended.

## License

[TBD]
