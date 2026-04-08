# Phase 03: Secret Redaction - Context

**Gathered:** 2026-04-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Buffered proxy that redacts known secret values from Claude-to-Anthropic API traffic (replacing with placeholders) and restores placeholders to real values in Anthropic responses, so secrets never reach Anthropic in cleartext. Proxy reads config fresh on each request and forwards auth credentials correctly.

This phase transforms the stub proxy (`proxy/proxy.js`) into a functioning secret redaction layer.

</domain>

<decisions>
## Implementation Decisions

### Secret Value Sourcing
- **D-01:** Proxy reads `whitelist.json` on each request (SECR-04 hot-reload). For each `secrets[]` entry, reads the real secret value from the environment variable named in `env_var`. Env vars are passed to the proxy container via `docker-compose.yml` environment section.
- **D-02:** If an env var is unset or empty, that secret entry is skipped (no redaction for missing secrets). Log a warning on first encounter.

### Outbound Redaction (Request Path)
- **D-03:** Scan the entire request body as a string. Replace every occurrence of each secret's real value with its `placeholder`. Simple string replacement, case-sensitive, exact match.
- **D-04:** Redaction applies to the request body only — not headers or URL path. Auth headers (API key, OAuth token) are the proxy's own credentials forwarded to Anthropic, not Claude's secrets.
- **D-05:** No encoding-variant detection (base64, URL-encoded) for v1. ESEC-02 covers this in v2.

### Inbound Restoration (Response Path)
- **D-06:** Scan the entire response body as a string. Replace every occurrence of each placeholder with its real secret value. This restores secrets so Claude can use them in subsequent tool calls.
- **D-07:** Restoration is NOT scoped to specific contexts for v1. The covert channel risk (Anthropic crafting responses with embedded placeholders to exfiltrate secrets) is accepted as a known limitation — the threat model trusts the Anthropic API response path. If needed, scoping can be added as a v2 hardening measure.

### Auth Credential Forwarding
- **D-08:** Proxy forwards authentication to Anthropic using its own environment variables: `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`. The claude container's auth headers are stripped and replaced with the proxy's credentials.
- **D-09:** OAuth token takes precedence over API key when both are set (per project constraint: OAuth is primary).

### Content-Length Handling
- **D-10:** After redaction changes the body, recalculate `Content-Length` header before forwarding (secret values and placeholders may differ in length).

### Claude's Discretion
- Error response format when upstream fails or whitelist is unreadable
- Log format and verbosity level
- Whether to add a request counter or timing metrics

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project Architecture
- `.planning/PROJECT.md` — Core value, constraints, four-layer architecture description
- `.planning/REQUIREMENTS.md` — SECR-01 through SECR-05 acceptance criteria
- `CLAUDE.md` — Technology stack (Node.js stdlib only), container image strategy, stack patterns

### Existing Proxy Code (to be modified)
- `proxy/proxy.js` — Stub proxy: buffers request/response, forwards to api.anthropic.com. Add redaction logic here.
- `proxy/Dockerfile` — Node.js 22-slim base, no dependencies needed
- `docker-compose.yml` — Proxy on both internal + external networks, env vars, whitelist mount

### Whitelist Schema
- `config/whitelist.json` — Secret-to-placeholder mapping with `env_var`, `placeholder`, `allowed_domains`

### Prior Phase Context
- `.planning/phases/02-call-validation/02-CONTEXT.md` — Hook/validator architecture, shared network namespace decisions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `proxy/proxy.js` — Working buffered proxy (44 lines). Already handles: request buffering, upstream HTTPS forwarding, response buffering, error handling. Add redaction as transform step between buffer and forward.
- `config/whitelist.json` — Schema with `secrets[].placeholder`, `secrets[].env_var`, `secrets[].allowed_domains`. Proxy only needs `placeholder` and `env_var` fields.

### Established Patterns
- Node.js stdlib only — `http`, `https`, `fs` modules. No npm dependencies (security constraint).
- Config read from `WHITELIST_PATH` env var (already set in docker-compose.yml to `/etc/claude-secure/whitelist.json`).
- Proxy listens on port 8080, claude container connects via `ANTHROPIC_BASE_URL=http://proxy:8080`.

### Integration Points
- Claude container sends API requests to `http://proxy:8080` — proxy is transparent to Claude Code
- Proxy forwards to `REAL_ANTHROPIC_BASE_URL` (default `https://api.anthropic.com`) via external network
- Auth env vars (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`) need to be added to proxy service in docker-compose.yml
- Content-Length must be recalculated after body transformation

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. The requirements (SECR-01 through SECR-05) and existing proxy stub define the implementation clearly.

</specifics>

<deferred>
## Deferred Ideas

- Scoped placeholder restoration (only in auth/tool_use contexts) — v2 hardening against covert channel
- Encoding-variant redaction (base64, URL-encoded secrets) — v2, ESEC-02
- Streaming SSE support — v2, STRM-01/STRM-02

</deferred>

---

*Phase: 03-secret-redaction*
*Context gathered: 2026-04-09*
