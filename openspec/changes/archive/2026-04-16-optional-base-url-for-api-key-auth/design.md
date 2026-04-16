## Context

The proxy container reads `REAL_ANTHROPIC_BASE_URL` from its environment to determine where to forward API requests (`proxy.js:7`). This is currently hardcoded in `docker-compose.yml` under the `environment:` key, which takes precedence over `env_file:` — so values in the profile `.env` are silently ignored.

The launcher (`bin/claude-secure:load_profile_config`) already does `set -a; source "$pdir/.env"; set +a`, which exports all `.env` vars into the host shell before `docker compose` runs. Docker Compose interpolates `${VAR}` references from the host environment at startup time. This means writing `REAL_ANTHROPIC_BASE_URL` to the profile `.env` and switching the compose entry to variable substitution is sufficient — no launcher changes needed.

## Goals / Non-Goals

**Goals:**
- Allow API-key users to specify a custom upstream base URL at install/profile-create time
- Store the URL in the profile `.env` so it persists across sessions
- Make the proxy use it without code changes to `proxy.js`
- Support the `install.sh` interactive path and `claude-secure profile create` interactive path equally

**Non-Goals:**
- Validating the URL format or reachability at install time
- Supporting OAuth profiles with a custom base URL (OAuth always talks to Anthropic)
- Env-var passthrough (`sudo -E REAL_ANTHROPIC_BASE_URL=...`) — user edits `.env` directly for that case

## Decisions

**D1: Store as `REAL_ANTHROPIC_BASE_URL` in `.env`**

Using the same variable name that `proxy.js` already reads keeps the chain simple. Alternative: introduce a new `CUSTOM_BASE_URL` var and map it — unnecessary indirection.

**D2: docker-compose uses `${REAL_ANTHROPIC_BASE_URL:-https://api.anthropic.com}`**

Variable substitution at compose-parse time reads from the host environment (already populated by `set -a; source .env`). The `:-` default means existing installs with no value in `.env` continue to work unchanged. Alternative: remove the `environment:` entry and rely solely on `env_file:` — this would work but removes the explicit default and makes the fallback implicit.

**D3: Prompt only for API key auth, not OAuth**

Custom base URLs are only meaningful when using an API key against a non-Anthropic endpoint. OAuth tokens are Anthropic-issued and only valid against `api.anthropic.com`.

**D4: `write_env_file()` extended to accept optional second variable**

The function currently writes exactly one key-value pair. Extend it to accept an optional `(name, value)` pair for `REAL_ANTHROPIC_BASE_URL`. If the user skips the prompt (empty input), the line is omitted and the compose default applies. Alternative: append to `.env` after initial write — more fragile, breaks the atomic write guarantee.

## Risks / Trade-offs

- [Risk] User enters a URL without `https://` → proxy forwards insecure → Mitigation: show example with `https://` in the prompt hint; no enforcement needed (user's choice)
- [Risk] `write_env_file()` change adds complexity to a security-critical path → Mitigation: keep the change minimal — one optional extra `printf` line inside the same grouped redirection

## Migration Plan

Existing installs: no action needed. `REAL_ANTHROPIC_BASE_URL` absent from `.env` → compose default `https://api.anthropic.com` applies as before.

New installs with API key: user is prompted, presses Enter to skip → same default behavior.
