# Phase 3: Secret Redaction - Research

**Researched:** 2026-04-09
**Domain:** Node.js HTTP proxy with string-level secret redaction/restoration
**Confidence:** HIGH

## Summary

Phase 3 transforms the existing stub proxy (`proxy/proxy.js`, 44 lines) into a secret redaction layer. The proxy already buffers full request and response bodies -- the work is adding: (1) config loading from `whitelist.json` on each request, (2) secret value lookup from environment variables, (3) string replacement of secret values with placeholders in outbound requests, (4) reverse replacement of placeholders with real values in inbound responses, and (5) auth credential forwarding.

The implementation is straightforward Node.js stdlib work. The existing proxy handles the hard parts (buffering, HTTPS forwarding, error handling). The redaction logic is pure string manipulation with no edge cases beyond ordering (longer secrets must be replaced first to avoid partial matches) and Content-Length recalculation.

**Primary recommendation:** Modify `proxy/proxy.js` to load whitelist + env vars, build a replacement map, apply `String.prototype.replaceAll()` for each secret on the request body (value->placeholder) and response body (placeholder->value), recalculate Content-Length, and forward auth credentials from proxy env vars.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- D-01: Proxy reads whitelist.json on each request. Secret values come from env vars named in env_var field.
- D-02: Missing/empty env vars skip that secret entry. Log warning on first encounter.
- D-03: Entire request body scanned as string. Simple case-sensitive exact string replacement.
- D-04: Redaction applies to request body only, not headers or URL.
- D-05: No encoding-variant detection (base64, URL-encoded) for v1.
- D-06: Entire response body scanned. Placeholders replaced with real values.
- D-07: Restoration is NOT scoped to specific contexts for v1 (accepted risk).
- D-08: Proxy uses its own env vars for auth, strips claude container's auth headers.
- D-09: OAuth token takes precedence over API key when both set.
- D-10: Content-Length recalculated after body transformation.

### Claude's Discretion
- Error response format when upstream fails or whitelist is unreadable
- Log format and verbosity level
- Whether to add a request counter or timing metrics

### Deferred Ideas (OUT OF SCOPE)
- Scoped placeholder restoration (v2 hardening)
- Encoding-variant redaction (base64, URL-encoded) -- v2, ESEC-02
- Streaming SSE support -- v2, STRM-01/STRM-02
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SECR-01 | Proxy intercepts all Claude-to-Anthropic API traffic via ANTHROPIC_BASE_URL override | Already working in stub proxy. Claude container sets `ANTHROPIC_BASE_URL=http://proxy:8080`. No changes needed. |
| SECR-02 | Proxy replaces known secret values in outbound request bodies with configured placeholders | Config loading + `String.prototype.replaceAll()` with longest-first ordering. See Architecture Patterns. |
| SECR-03 | Proxy restores placeholders to real secret values in Anthropic response bodies | Reverse replacement map applied to response body before sending to Claude. See Architecture Patterns. |
| SECR-04 | Proxy reads secret mappings fresh from whitelist config on each request (hot-reload) | `fs.readFileSync()` on each request. No caching, no file watcher needed. See Code Examples. |
| SECR-05 | Proxy forwards authentication credentials correctly to Anthropic | Auth header construction from proxy's own env vars. OAuth preferred over API key. See Code Examples. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Node.js `http` (stdlib) | 22 LTS | HTTP server | Already used in stub proxy. No changes. |
| Node.js `https` (stdlib) | 22 LTS | HTTPS client for upstream | Already used in stub proxy. No changes. |
| Node.js `fs` (stdlib) | 22 LTS | Read whitelist.json on each request | `readFileSync` is appropriate -- blocking is fine since proxy is already fully buffered. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `JSON.parse` (builtin) | -- | Parse whitelist.json | Every request, wrapped in try/catch for error resilience |
| `Buffer.byteLength` (builtin) | -- | Recalculate Content-Length after redaction | After every body transformation |
| `String.prototype.replaceAll` (builtin) | ES2021+ (Node 15+) | String replacement | Available in Node 22. Simpler than regex for literal string replacement. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `replaceAll()` per secret | Single regex with alternation | Regex would need escaping of secret values (secrets may contain regex-special chars like `$`, `.`, `+`). Sequential `replaceAll()` is safer and clearer. |
| `readFileSync` per request | `fs.watch` + cached config | Adds complexity (race conditions, watcher reliability). Reading a small JSON file per request is negligible overhead at proxy's throughput (tens of requests/minute). D-01 explicitly requires fresh read. |

**Installation:**
```bash
# No installation needed -- all stdlib
```

## Architecture Patterns

### Recommended Proxy Structure
```
proxy/
  proxy.js        # All logic in single file (~120 lines)
  Dockerfile      # Unchanged from Phase 1
```

No need for multiple files. The proxy is a single-purpose buffered transform. Splitting into modules would be overengineering for ~80 lines of added logic.

### Pattern 1: Request Lifecycle with Redaction
**What:** Each request goes through: buffer -> load config -> build maps -> redact -> set auth -> forward -> buffer response -> restore -> respond
**When to use:** Every request through the proxy

```javascript
// Lifecycle pseudocode
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    // 1. Load config fresh
    const config = loadWhitelist();
    // 2. Build replacement maps from config + env vars
    const { redactMap, restoreMap } = buildMaps(config);
    // 3. Redact secrets in request body
    const redactedBody = applyReplacements(body, redactMap);
    // 4. Build auth headers
    const authHeaders = buildAuthHeaders();
    // 5. Forward with recalculated Content-Length
    // 6. Buffer response, apply restoreMap, respond
  });
});
```

### Pattern 2: Replacement Map Construction
**What:** Build ordered arrays of [search, replace] pairs from config. Sort by value length descending to prevent partial matches.
**When to use:** On every request, after config load.

**Critical detail -- longest-first ordering:** If secret A is `ghp_abc123` and secret B is `ghp_abc123_extended`, replacing A first would corrupt B. Sorting replacements by search-string length (longest first) prevents this.

```javascript
function buildMaps(config) {
  const redactMap = [];   // [realValue, placeholder] pairs
  const restoreMap = [];  // [placeholder, realValue] pairs

  for (const entry of config.secrets || []) {
    const realValue = process.env[entry.env_var];
    if (!realValue) {
      // D-02: skip missing env vars, warn once
      continue;
    }
    redactMap.push([realValue, entry.placeholder]);
    restoreMap.push([entry.placeholder, realValue]);
  }

  // Sort by search string length, longest first
  redactMap.sort((a, b) => b[0].length - a[0].length);
  restoreMap.sort((a, b) => b[0].length - a[0].length);

  return { redactMap, restoreMap };
}
```

### Pattern 3: Auth Header Construction (D-08, D-09)
**What:** Strip Claude container's auth headers, replace with proxy's own credentials.
**When to use:** On every forwarded request.

```javascript
function buildAuthHeaders() {
  const token = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  const apiKey = process.env.ANTHROPIC_API_KEY;

  if (token) {
    // D-09: OAuth takes precedence
    return { 'authorization': `Bearer ${token}` };
  } else if (apiKey) {
    return { 'x-api-key': apiKey };
  }
  return {};
}
```

### Anti-Patterns to Avoid
- **Caching whitelist.json:** D-01 explicitly requires fresh read per request. Do not add a cache or file watcher.
- **Regex-based replacement:** Secret values may contain regex metacharacters (`$`, `.`, `*`, `+`, etc.). Using `replaceAll()` with literal strings avoids escaping issues entirely.
- **Streaming the proxy:** Phase 1 constraint is buffered proxy. Streaming breaks the ability to redact secrets that span chunk boundaries. Deferred to v2 (STRM-01/02).
- **Modifying headers for redaction:** D-04 says body only. Do not scan or modify request headers (other than auth replacement and Content-Length recalculation).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| String replacement | Regex engine with escaping | `String.prototype.replaceAll()` | Built-in, handles literal strings, no escaping needed |
| JSON parsing | Custom parser | `JSON.parse()` | Stdlib, handles all edge cases |
| Byte length calculation | `string.length` | `Buffer.byteLength(str, 'utf8')` | String length !== byte length for non-ASCII. Content-Length must be in bytes. |

**Key insight:** This phase is pure string manipulation on buffered bodies. There are no libraries to pull in -- Node.js stdlib has everything needed. The complexity is in getting the ordering right and handling edge cases (missing env vars, malformed config, empty bodies).

## Common Pitfalls

### Pitfall 1: Content-Length Mismatch
**What goes wrong:** After redaction, the body length changes but Content-Length header still reflects the original size. Anthropic rejects the request or truncates it.
**Why it happens:** Secret values and placeholders have different lengths (e.g., `ghp_abc123def456` vs `PLACEHOLDER_GITHUB`).
**How to avoid:** Always recalculate Content-Length using `Buffer.byteLength(redactedBody)` after applying all replacements. Remove any `transfer-encoding: chunked` header and set explicit Content-Length.
**Warning signs:** Anthropic returns 400 errors, truncated JSON in requests.

### Pitfall 2: Partial Match Corruption
**What goes wrong:** A shorter secret value is a substring of a longer one. Replacing the shorter one first corrupts the longer one.
**Why it happens:** Unsorted replacement order.
**How to avoid:** Sort replacement pairs by search-string length, longest first, before applying.
**Warning signs:** Garbled secrets, partial placeholders in output.

### Pitfall 3: Placeholder Collision in Request Body
**What goes wrong:** Claude legitimately uses a string that matches a placeholder name (e.g., `PLACEHOLDER_GITHUB` appears in code the user is writing). The proxy incorrectly restores it to a real secret in the response path.
**Why it happens:** Placeholder names are simple strings, not namespaced.
**How to avoid:** Use distinctive placeholder format unlikely to appear in normal code. The existing format `PLACEHOLDER_GITHUB` is reasonable but consider adding a prefix like `__REDACTED_GITHUB__` or `<<PLACEHOLDER_GITHUB>>`. This is a Claude's Discretion area -- the planner should decide.
**Warning signs:** Secrets appearing in unexpected places in responses.

### Pitfall 4: Auth Header Passthrough
**What goes wrong:** Claude container's `ANTHROPIC_API_KEY` or `Authorization` header passes through to Anthropic alongside the proxy's credentials, causing auth confusion or leaking the claude container's dummy token.
**Why it happens:** Spreading `req.headers` into upstream request without filtering.
**How to avoid:** Explicitly delete `x-api-key`, `authorization`, and `anthropic-api-key` from the forwarded headers before adding the proxy's own auth headers.
**Warning signs:** 401 errors from Anthropic, or the dummy key appearing in logs.

### Pitfall 5: readFileSync Error Crashes Proxy
**What goes wrong:** If whitelist.json is malformed or temporarily unavailable (during a Docker volume remount), `readFileSync` or `JSON.parse` throws, crashing the proxy process.
**Why it happens:** No error handling around config read.
**How to avoid:** Wrap in try/catch. On failure, return 500 to the claude container with a descriptive error. Do NOT forward the request unredacted -- failing open would defeat the security model.
**Warning signs:** Proxy container restarts, intermittent 502s from claude.

### Pitfall 6: Empty Body Requests
**What goes wrong:** Some requests (health checks, GET requests) have empty bodies. Applying redaction to empty string is wasteful but harmless -- however, setting Content-Length to 0 when the original had no Content-Length can confuse some HTTP stacks.
**How to avoid:** Only apply redaction logic when body is non-empty. For empty bodies, pass through unchanged.

## Code Examples

### Config Loading (SECR-04)
```javascript
const fs = require('fs');

const WHITELIST_PATH = process.env.WHITELIST_PATH || '/etc/claude-secure/whitelist.json';
const warnedEnvVars = new Set(); // Track warned env vars (D-02)

function loadWhitelist() {
  try {
    const raw = fs.readFileSync(WHITELIST_PATH, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    console.error(`Failed to load whitelist: ${err.message}`);
    return null; // Caller must handle null -> return 500
  }
}
```

### Replacement Application
```javascript
function applyReplacements(text, pairs) {
  if (!text) return text;
  let result = text;
  for (const [search, replace] of pairs) {
    result = result.replaceAll(search, replace);
  }
  return result;
}
```

### Auth Header Stripping and Replacement
```javascript
function prepareHeaders(incomingHeaders, redactedBodyLength) {
  const headers = { ...incomingHeaders };

  // Remove Claude container's auth (D-08)
  delete headers['x-api-key'];
  delete headers['authorization'];
  delete headers['anthropic-api-key'];

  // Set proxy's own auth (D-09: OAuth preferred)
  const oauthToken = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (oauthToken) {
    headers['authorization'] = `Bearer ${oauthToken}`;
  } else if (apiKey) {
    headers['x-api-key'] = apiKey;
  }

  // Fix host and content-length (D-10)
  headers['content-length'] = redactedBodyLength;

  return headers;
}
```

### Full Request Handler Skeleton
```javascript
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    // Load config fresh (SECR-04)
    const config = loadWhitelist();
    if (!config) {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Proxy configuration error' }));
      return;
    }

    // Build replacement maps
    const { redactMap, restoreMap } = buildMaps(config);

    // Redact outbound (SECR-02)
    const redactedBody = applyReplacements(body, redactMap);

    // Prepare headers with auth (SECR-05) and new Content-Length (D-10)
    const url = new URL(req.url, UPSTREAM);
    const headers = prepareHeaders(req.headers, Buffer.byteLength(redactedBody));
    headers['host'] = url.host;

    // Forward to Anthropic
    const upstreamReq = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname + url.search,
      method: req.method,
      headers
    }, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        // Restore placeholders in response (SECR-03)
        const restoredBody = applyReplacements(responseBody, restoreMap);

        // Recalculate response Content-Length
        const resHeaders = { ...upstreamRes.headers };
        resHeaders['content-length'] = Buffer.byteLength(restoredBody);
        delete resHeaders['transfer-encoding']; // Remove chunked if present

        res.writeHead(upstreamRes.statusCode, resHeaders);
        res.end(restoredBody);
      });
    });

    upstreamReq.on('error', err => {
      console.error('Upstream error:', err.message);
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Bad Gateway', detail: err.message }));
    });

    upstreamReq.write(redactedBody);
    upstreamReq.end();
  });
});
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `String.prototype.replace()` (first match only) | `String.prototype.replaceAll()` | ES2021 / Node 15+ | Must use `replaceAll` -- a secret value may appear multiple times in a single request body |
| `http.request` callback API | Same (stable) | Always | No change needed. The callback API is simpler for buffered proxying than async/await with fetch. |

**Deprecated/outdated:**
- None relevant. Node.js `http`/`https` stdlib is extremely stable.

## Open Questions

1. **Placeholder format distinctiveness**
   - What we know: Current format is `PLACEHOLDER_GITHUB`, `PLACEHOLDER_STRIPE`, etc.
   - What's unclear: Whether this is distinctive enough to avoid false positive matches in code that Claude might write or discuss.
   - Recommendation: Planner can decide whether to wrap in delimiters (e.g., `__REDACTED_GITHUB__`). This is a Claude's Discretion area per CONTEXT.md.

2. **Response Content-Encoding (gzip/br)**
   - What we know: Anthropic API may return compressed responses. The current stub proxy reads response as string chunks, which only works for uncompressed responses.
   - What's unclear: Whether Anthropic returns compressed responses when the client doesn't send `Accept-Encoding: gzip`.
   - Recommendation: Strip `Accept-Encoding` from forwarded request headers to ensure Anthropic returns uncompressed responses. This sidesteps decompression complexity entirely.

3. **Proxy's own auth credentials in env vars**
   - What we know: `docker-compose.yml` passes `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` to the claude container but NOT to the proxy container currently.
   - What's unclear: Nothing -- this is a known gap.
   - Recommendation: Add these env vars to the proxy service in `docker-compose.yml`. This is a required docker-compose change.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + curl + jq (shell-based integration tests) |
| Config file | None (shell scripts in `tests/`) |
| Quick run command | `bash tests/test-phase3.sh` |
| Full suite command | `bash tests/test-phase1.sh && bash tests/test-phase2.sh && bash tests/test-phase3.sh` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SECR-01 | Proxy intercepts Claude-to-Anthropic traffic | integration | `docker compose exec claude curl -s http://proxy:8080/` | Covered by Phase 1 tests |
| SECR-02 | Secret values replaced with placeholders in outbound requests | integration | Send request containing secret value, verify proxy logs/forwards placeholder | Wave 0 |
| SECR-03 | Placeholders restored to real values in responses | integration | Mock upstream returns placeholder, verify claude receives real value | Wave 0 |
| SECR-04 | Config re-read on each request without restart | integration | Modify whitelist.json, send request, verify new config takes effect | Wave 0 |
| SECR-05 | Auth credentials forwarded correctly | integration | Send request, verify upstream receives correct auth header | Wave 0 |

### Sampling Rate
- **Per task commit:** Manual verification via `docker compose exec` curl commands
- **Per wave merge:** `bash tests/test-phase3.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test-phase3.sh` -- covers SECR-01 through SECR-05
- [ ] Test approach: Tests need a mock upstream or inspection mechanism. Options: (a) Use `docker compose exec proxy` to check proxy logs, (b) Add a test endpoint to proxy that echoes the redacted body, (c) Use a simple test HTTP server as mock upstream. The planner should decide the test approach.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | Container runtime | Yes | 29.3.1 | -- |
| Docker Compose | Orchestration | Yes | v5.1.1 | -- |
| Node.js (host) | Local testing | Yes | 22.22.2 | Test only inside container |

**Missing dependencies with no fallback:** None.

## Sources

### Primary (HIGH confidence)
- Existing codebase: `proxy/proxy.js`, `config/whitelist.json`, `docker-compose.yml` -- direct inspection
- Node.js 22 LTS stdlib (`http`, `https`, `fs`, `Buffer`) -- stable APIs, unchanged for years
- `String.prototype.replaceAll()` -- ES2021, available since Node 15, well-documented

### Secondary (MEDIUM confidence)
- Training data on Anthropic API request/response format (headers, auth patterns)
- Training data on `Accept-Encoding` behavior for HTTP APIs

### Tertiary (LOW confidence)
- None -- this phase is entirely Node.js stdlib work with no external dependencies to verify

## Project Constraints (from CLAUDE.md)

- **Node.js stdlib only** -- no npm packages for proxy (security constraint)
- **Node.js 22 LTS** -- base image is `node:22-slim`
- **Buffered proxy** -- no streaming for Phase 1
- **Auth**: OAuth primary, API key fallback
- **Config mount**: whitelist.json at `/etc/claude-secure/whitelist.json` (read-only)
- **Proxy on both networks**: `claude-internal` + `claude-external`
- **GSD Workflow**: Must use GSD commands for changes

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all stdlib, no version ambiguity
- Architecture: HIGH -- modifying a 44-line working proxy with well-defined transform logic
- Pitfalls: HIGH -- common HTTP proxy pitfalls, well-understood

**Research date:** 2026-04-09
**Valid until:** 2026-05-09 (stable domain, no fast-moving dependencies)
