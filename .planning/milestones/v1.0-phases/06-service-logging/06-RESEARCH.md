# Phase 6: Service Logging - Research

**Researched:** 2026-04-10
**Domain:** Structured logging for Docker containerized services, CLI flag-based log routing
**Confidence:** HIGH

## Summary

Phase 6 adds observability to claude-secure by letting users enable per-service logging via CLI flags (`log:hook`, `log:anthropic`, `log:iptables`). The three services (hook script, proxy, validator) already produce log output -- the hook writes to `/var/log/claude-secure/hook.log`, the proxy uses `console.log`/`console.error` to stdout/stderr, and the validator uses Python `logging` to stderr. The work is primarily: (1) making each service write structured JSON logs to a known file path, (2) mounting a shared host directory into all containers for unified log access, (3) adding CLI flags to enable/disable logging per service via environment variables, and (4) optionally tailing logs in real-time.

No external libraries are needed. The hook already logs to a file. The proxy needs a file-logging wrapper around its console calls. The validator already uses Python `logging` and just needs a file handler added. All three services can check an environment variable to decide whether to write to the log file.

**Primary recommendation:** Use environment variables (`LOG_HOOK=1`, `LOG_ANTHROPIC=1`, `LOG_IPTABLES=1`) passed through docker-compose to toggle file-based structured JSON logging in each service. Mount a shared host directory (`~/.claude-secure/logs/`) into all containers at `/var/log/claude-secure/`. The CLI parses `log:*` flags and sets the corresponding env vars before `docker compose up`.

<phase_requirements>
## Phase Requirements

Since no requirement IDs are formally mapped yet, the following are the requirements this phase must address, derived from the ROADMAP goal and the existing OBSV requirements in REQUIREMENTS.md:

| ID | Description | Research Support |
|----|-------------|------------------|
| LOG-01 | CLI supports `log:hook` flag to enable hook script logging to host file | CLI flag parsing, env var passthrough, hook already has `log()` function |
| LOG-02 | CLI supports `log:anthropic` flag to enable proxy logging to host file | CLI flag parsing, env var passthrough, proxy needs file logger |
| LOG-03 | CLI supports `log:iptables` flag to enable validator/iptables logging to host file | CLI flag parsing, env var passthrough, validator already uses Python logging |
| LOG-04 | All enabled logs write to a unified directory on the host filesystem | Docker volume mount of host `~/.claude-secure/logs/` to `/var/log/claude-secure/` |
| LOG-05 | Log entries use structured JSON format with timestamp, service, level, and message fields | JSON formatting in each service's log writer |
| LOG-06 | Logging is disabled by default (no performance impact when not requested) | Environment variable check at service startup / per-write |
| LOG-07 | `claude-secure logs` command tails the unified log directory | CLI subcommand reading from known host path |
</phase_requirements>

## Standard Stack

### Core

No new libraries needed. All logging uses stdlib/builtins already present in each container.

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Bash `log()` function | -- | Hook script logging | Already exists in `pre-tool-use.sh`, writes to `/var/log/claude-secure/hook.log` |
| Node.js `fs.appendFileSync` | stdlib | Proxy file logging | Zero-dependency, synchronous append is fine for a buffered proxy handling tens of requests per minute |
| Python `logging.FileHandler` | stdlib | Validator file logging | Validator already uses Python `logging` module; adding a FileHandler is one line |
| Docker bind mount | -- | Host log directory access | Same pattern used for `whitelist.json` mount; bind mount gives host read access to container logs |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| File-per-service logs | Docker `json-file` log driver + `docker compose logs` | Would capture stdout but cannot be toggled per-service at runtime, no structured JSON control, and `docker compose logs` mixes all services |
| Synchronous file writes | Async buffered writes | Unnecessary complexity for tens-of-requests-per-minute volume; sync writes add < 1ms per call |
| JSON log format | Plain text | JSON is greppable, parseable with `jq`, and aligns with OBSV-01 requirement for structured audit logging |

## Architecture Patterns

### Log File Layout

```
~/.claude-secure/logs/           # Host directory (created by CLI or installer)
  hook.jsonl                     # Hook decisions (allow/deny/register)
  anthropic.jsonl                # Proxy requests/responses (redacted bodies)
  iptables.jsonl                 # Validator registrations, validations, iptables changes
```

Using `.jsonl` (JSON Lines) format -- one JSON object per line, appendable, trivially parseable with `jq`.

### Pattern 1: Environment Variable Toggle

**What:** Each service checks an environment variable to decide whether to write log entries to the file.
**When to use:** Always -- this is the core mechanism.
**Example:**

```bash
# In pre-tool-use.sh
log() {
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    printf '{"ts":"%s","svc":"hook","msg":"%s"}\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}
```

```javascript
// In proxy.js
const LOG_FILE = process.env.LOG_ANTHROPIC === '1'
  ? '/var/log/claude-secure/anthropic.jsonl' : null;

function logEntry(level, msg, extra) {
  if (!LOG_FILE) return;
  const entry = JSON.stringify({
    ts: new Date().toISOString(),
    svc: 'anthropic',
    level,
    msg,
    ...extra
  });
  fs.appendFileSync(LOG_FILE, entry + '\n');
}
```

```python
# In validator.py -- add file handler conditionally
if os.environ.get("LOG_IPTABLES") == "1":
    fh = logging.FileHandler("/var/log/claude-secure/iptables.jsonl")
    fh.setFormatter(logging.Formatter('%(message)s'))  # JSON formatted in custom handler
    logger.addHandler(fh)
```

### Pattern 2: CLI Flag Parsing

**What:** The `claude-secure` CLI parses `log:hook`, `log:anthropic`, `log:iptables` from arguments and sets environment variables.
**When to use:** Every invocation of the CLI.
**Example:**

```bash
# In bin/claude-secure, before docker compose up
LOG_HOOK=0
LOG_ANTHROPIC=0
LOG_IPTABLES=0

for arg in "$@"; do
  case "$arg" in
    log:hook)       LOG_HOOK=1 ;;
    log:anthropic)  LOG_ANTHROPIC=1 ;;
    log:iptables)   LOG_IPTABLES=1 ;;
    log:all)        LOG_HOOK=1; LOG_ANTHROPIC=1; LOG_IPTABLES=1 ;;
  esac
done

export LOG_HOOK LOG_ANTHROPIC LOG_IPTABLES
```

### Pattern 3: Docker Compose Volume Mount

**What:** A bind mount from host `~/.claude-secure/logs/` into each container at `/var/log/claude-secure/`.
**When to use:** Added to docker-compose.yml for all three services.
**Example:**

```yaml
# docker-compose.yml additions
services:
  claude:
    environment:
      - LOG_HOOK=${LOG_HOOK:-0}
    volumes:
      - ${LOG_DIR:-./logs}:/var/log/claude-secure

  proxy:
    environment:
      - LOG_ANTHROPIC=${LOG_ANTHROPIC:-0}
    volumes:
      - ${LOG_DIR:-./logs}:/var/log/claude-secure

  # validator shares network namespace with claude, so it inherits claude's mounts?
  # NO -- network_mode: service:claude shares network, NOT filesystem.
  # Validator needs its own volume mount.
  validator:
    environment:
      - LOG_IPTABLES=${LOG_IPTABLES:-0}
    volumes:
      - ${LOG_DIR:-./logs}:/var/log/claude-secure
```

### Pattern 4: Log Entry Structure

**What:** Consistent JSON schema across all services.

```json
{"ts":"2026-04-10T12:00:00Z","svc":"hook","level":"info","action":"allow","tool":"Bash","domain":"github.com","reason":"read-only request"}
{"ts":"2026-04-10T12:00:01Z","svc":"anthropic","level":"info","action":"forward","method":"POST","path":"/v1/messages","redacted_count":2,"status":200}
{"ts":"2026-04-10T12:00:01Z","svc":"iptables","level":"info","action":"register","call_id":"abc-123","domain":"api.github.com","ip":"140.82.121.6","expires":"2026-04-10T12:00:11Z"}
```

### Anti-Patterns to Avoid

- **Logging secret values:** The proxy MUST NOT log request/response bodies (they contain secrets pre-redaction). Log only metadata: method, path, status code, redaction count, timing.
- **Logging to stdout then capturing with Docker:** This loses per-service toggle control and mixes container lifecycle logs with application audit logs.
- **Using a log rotation library:** For a local dev tool with manual start/stop, log rotation is unnecessary. Files are ephemeral per session (or accumulate trivially). If needed later, the host can use `logrotate`.
- **Blocking on log writes:** The hook runs synchronously in Claude Code's critical path. Log writes must be fire-and-forget (append with `|| true` to suppress errors).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON serialization in bash | Custom string escaping | `jq -nc` with `--arg` | Properly escapes special characters in log messages |
| Log file rotation | Custom rotation logic | Nothing (out of scope) or host `logrotate` | Solo dev tool, logs are small and ephemeral |
| Log aggregation | Custom log merger | `jq -s 'sort_by(.ts)' ~/.claude-secure/logs/*.jsonl` | One-liner covers the "unified view" need |
| Real-time log tailing | Custom watcher | `tail -f ~/.claude-secure/logs/*.jsonl` | Standard Unix tool, works perfectly |

## Common Pitfalls

### Pitfall 1: Hook Log File Permissions in Docker

**What goes wrong:** The hook runs as user `claude` (non-root) inside the claude container. The log directory bind mount may be owned by the host user's UID, which may not match the container's `claude` UID.
**Why it happens:** Docker bind mounts preserve host UID/GID. The container `claude` user (created by `useradd`) gets a different UID than the host user.
**How to avoid:** The claude Dockerfile already creates `/var/log/claude-secure` with `chown claude:claude`. For bind mounts, either: (a) create the host directory with world-writable permissions (`chmod 777`), or (b) use a named volume, or (c) ensure the container `claude` user UID matches the host user UID. Option (a) is simplest for a local dev tool. The existing Dockerfile already does `mkdir -p /var/log/claude-secure && chown claude:claude /var/log/claude-secure` which handles the non-bind-mount case.
**Warning signs:** "Permission denied" errors in hook log writes (currently silenced by `|| true`).

### Pitfall 2: Validator Shares Network but Not Filesystem

**What goes wrong:** Assuming `network_mode: service:claude` means the validator can write to claude's `/var/log/claude-secure` directory.
**Why it happens:** `network_mode: service:X` shares the network namespace only, not the filesystem. The validator container has its own filesystem.
**How to avoid:** Add an explicit volume mount to the validator service in docker-compose.yml.
**Warning signs:** Validator log file missing from host directory.

### Pitfall 3: Proxy Logging Secret Values

**What goes wrong:** Logging request/response bodies that contain secret values before redaction.
**Why it happens:** Developer adds verbose logging without considering the data flow: secrets exist in plaintext in the request body BEFORE the `applyReplacements` call.
**How to avoid:** Only log metadata (method, path, content-length, status code, number of redactions applied). Never log body content.
**Warning signs:** `grep -r` on log files revealing actual API keys.

### Pitfall 4: JSON Escaping in Bash

**What goes wrong:** Log messages containing quotes, backslashes, or special characters break the JSON format.
**Why it happens:** Using string interpolation (`printf '{"msg":"%s"}'`) with unescaped user input.
**How to avoid:** Use `jq -nc --arg msg "$message" '{msg: $msg}'` for proper escaping. The slight performance cost (forking jq per log line) is negligible at this volume.
**Warning signs:** Broken JSON lines when parsing with `jq` -- lines that fail `jq .`.

### Pitfall 5: Log Directory Not Existing on First Run

**What goes wrong:** Docker bind mount fails or creates the directory as root-owned if the host directory doesn't exist.
**Why it happens:** Docker creates missing bind-mount source directories as root.
**How to avoid:** The CLI wrapper must `mkdir -p` the log directory before running `docker compose up`. The installer should also create it.
**Warning signs:** Docker compose error or root-owned log directory that containers can't write to.

## Code Examples

### CLI Flag Parsing (bin/claude-secure)

```bash
# Parse log flags from arguments
parse_log_flags() {
  LOG_HOOK=0
  LOG_ANTHROPIC=0
  LOG_IPTABLES=0
  local remaining=()

  for arg in "$@"; do
    case "$arg" in
      log:hook)       LOG_HOOK=1 ;;
      log:anthropic)  LOG_ANTHROPIC=1 ;;
      log:iptables)   LOG_IPTABLES=1 ;;
      log:all)        LOG_HOOK=1; LOG_ANTHROPIC=1; LOG_IPTABLES=1 ;;
      *)              remaining+=("$arg") ;;
    esac
  done

  export LOG_HOOK LOG_ANTHROPIC LOG_IPTABLES
  REMAINING_ARGS=("${remaining[@]}")
}
```

### Proxy Structured Logger (proxy.js)

```javascript
const LOG_PATH = '/var/log/claude-secure/anthropic.jsonl';
const LOG_ENABLED = process.env.LOG_ANTHROPIC === '1';

function logJson(level, action, extra) {
  if (!LOG_ENABLED) return;
  try {
    const entry = JSON.stringify({
      ts: new Date().toISOString(),
      svc: 'anthropic',
      level,
      action,
      ...extra
    }) + '\n';
    fs.appendFileSync(LOG_PATH, entry);
  } catch (e) {
    // Silently ignore log write failures
  }
}

// Usage in request handler:
logJson('info', 'forward', {
  method: req.method,
  path: url.pathname,
  redacted: redactMap.length,
  status: upstreamRes.statusCode,
  duration_ms: Date.now() - startTime
});
```

### Hook JSON Logging (pre-tool-use.sh)

```bash
log_json() {
  local level="$1" action="$2" msg="$3"
  shift 3
  if [ "${LOG_HOOK:-0}" = "1" ]; then
    jq -nc \
      --arg ts "$(date -Iseconds)" \
      --arg svc "hook" \
      --arg level "$level" \
      --arg action "$action" \
      --arg msg "$msg" \
      --arg tool "${TOOL_NAME:-}" \
      --arg domain "${DOMAIN:-}" \
      '{ts: $ts, svc: $svc, level: $level, action: $action, msg: $msg, tool: $tool, domain: $domain}' \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
}
```

### Validator File Handler (validator.py)

```python
class JsonFileHandler(logging.Handler):
    """Writes JSON-formatted log entries to a file."""

    def __init__(self, filepath):
        super().__init__()
        self.filepath = filepath

    def emit(self, record):
        try:
            entry = json.dumps({
                "ts": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                "svc": "iptables",
                "level": record.levelname.lower(),
                "msg": record.getMessage(),
            })
            with open(self.filepath, "a") as f:
                f.write(entry + "\n")
        except Exception:
            pass

# In __main__:
if os.environ.get("LOG_IPTABLES") == "1":
    logger.addHandler(JsonFileHandler("/var/log/claude-secure/iptables.jsonl"))
```

### Docker Compose Additions

```yaml
services:
  claude:
    environment:
      - LOG_HOOK=${LOG_HOOK:-0}
    volumes:
      - ${LOG_DIR}:/var/log/claude-secure

  proxy:
    environment:
      - LOG_ANTHROPIC=${LOG_ANTHROPIC:-0}
    volumes:
      - ${LOG_DIR}:/var/log/claude-secure

  validator:
    environment:
      - LOG_IPTABLES=${LOG_IPTABLES:-0}
    volumes:
      - ${LOG_DIR}:/var/log/claude-secure
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `console.log` to stdout | Structured JSON to file | This phase | Enables queryable audit trail |
| No per-service toggle | Env-var-based per-service toggle | This phase | Zero overhead when logging disabled |

## Open Questions

1. **Log retention / rotation policy**
   - What we know: Solo dev tool, logs accumulate across sessions
   - What's unclear: Should logs be cleared on each `claude-secure` start, or accumulate?
   - Recommendation: Accumulate by default. Add `claude-secure logs clear` subcommand for manual cleanup. Date-prefix each session start with a separator line.

2. **Proxy body logging for debugging**
   - What we know: Bodies contain secrets pre-redaction, so logging them is dangerous
   - What's unclear: Should there be a "debug" mode that logs redacted bodies?
   - Recommendation: Phase 6 should NOT log bodies. If needed later, add a separate `log:anthropic:verbose` flag that logs bodies post-redaction only.

3. **`claude-secure logs` command output format**
   - What we know: Users want to see recent activity
   - What's unclear: Should it tail all files merged, or per-service?
   - Recommendation: `claude-secure logs` tails all files. `claude-secure logs hook` tails one service. Both use `tail -f` under the hood.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash + curl + jq (integration tests, consistent with existing test-phase*.sh) |
| Config file | None needed -- shell scripts |
| Quick run command | `bash tests/test-phase6.sh` |
| Full suite command | `bash tests/test-phase6.sh` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| LOG-01 | Hook writes JSON log when LOG_HOOK=1 | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-02 | Proxy writes JSON log when LOG_ANTHROPIC=1 | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-03 | Validator writes JSON log when LOG_IPTABLES=1 | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-04 | All logs appear in host directory | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-05 | Log entries are valid JSONL with required fields | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-06 | No log files created when flags are not set | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |
| LOG-07 | `claude-secure logs` command works | integration | `bash tests/test-phase6.sh` | No -- Wave 0 |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase6.sh`
- **Per wave merge:** Full test suite including phases 1-4 tests
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/test-phase6.sh` -- covers LOG-01 through LOG-07
- [ ] Test requires running Docker containers (same as existing phase tests)

## Project Constraints (from CLAUDE.md)

- **Platform**: Linux (native) and WSL2 only
- **Dependencies**: No new dependencies allowed -- use Docker, bash, jq, Node.js stdlib, Python stdlib only
- **Security**: Log files must NOT contain secret values. Hook scripts must remain root-owned and immutable. Logging must not create a side channel for secret exfiltration.
- **Architecture**: Proxy uses buffered request/response (logging fits naturally at buffer boundaries)
- **No npm packages**: Proxy uses Node.js stdlib only (no winston, pino, etc.)
- **No pip packages**: Validator uses Python stdlib only

## Sources

### Primary (HIGH confidence)

- Direct codebase analysis of `proxy/proxy.js`, `validator/validator.py`, `claude/hooks/pre-tool-use.sh`, `docker-compose.yml`, `bin/claude-secure`, `install.sh`
- Docker Compose documentation on bind mounts and `network_mode` -- well-known stable features
- Node.js `fs.appendFileSync` -- stable stdlib API
- Python `logging` module -- stable stdlib API

### Secondary (MEDIUM confidence)

- JSONL format convention (newline-delimited JSON) -- widely adopted community standard

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All stdlib, no external dependencies, existing patterns in codebase
- Architecture: HIGH - Straightforward env-var toggle + file logging + bind mount pattern
- Pitfalls: HIGH - Based on direct analysis of existing docker-compose.yml and file permission model

**Research date:** 2026-04-10
**Valid until:** 2026-05-10 (stable domain, no fast-moving dependencies)
