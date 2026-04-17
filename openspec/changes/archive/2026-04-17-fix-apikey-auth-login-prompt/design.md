## Context

Claude Code reads `ANTHROPIC_API_KEY` from its environment to decide whether to use API-key auth or prompt for OAuth. In `docker-compose.yml`, the claude service sets this via two overlapping mechanisms:

1. `env_file: ${SECRETS_FILE}` — loads the profile `.env` file (the real key for API-key users)
2. `environment: ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}` — host-shell substitution, overrides `env_file`

Docker Compose rule: `environment` always wins over `env_file` for the same key.

When the host shell has `ANTHROPIC_API_KEY` exported (which happens when `bin/claude-secure` sources the `.env` with `set -a`), the override is benign — the real key is used. But the `:-dummy` fallback is a silent hazard: if the host env var is absent for any reason (e.g., sudo dropped exports, the .env was missing at load time, a future code path doesn't source the file), Claude Code receives `"dummy"`. Claude Code may reject `"dummy"` as a malformed key and fall back to the OAuth login prompt.

A secondary issue: the non-interactive install path (`ANTHROPIC_API_KEY` set in host env before running install.sh) short-circuits at line 352–356 and writes only `ANTHROPIC_API_KEY` to `.env`, silently dropping any `REAL_ANTHROPIC_BASE_URL` the user might have set. There is no non-interactive path to set a custom base URL.

## Goals / Non-Goals

**Goals:**
- Claude Code in the container receives `ANTHROPIC_API_KEY` from `env_file` without being overridden by a dummy fallback
- OAuth users are unaffected (they have `CLAUDE_CODE_OAUTH_TOKEN` in `env_file`; no API key)
- The non-interactive install path supports `REAL_ANTHROPIC_BASE_URL` via environment variable

**Non-Goals:**
- Changing the proxy architecture (`ANTHROPIC_BASE_URL` → proxy → `REAL_ANTHROPIC_BASE_URL` is correct and stays)
- Validating whether the custom base URL endpoint is actually Anthropic-compatible

## Decisions

### Decision 1: Remove `ANTHROPIC_API_KEY` from the claude service `environment` block

Remove the line `ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}` from the claude service `environment` block. Let `env_file` be the sole source.

**Why**: `env_file` already provides the key when the user chose API-key auth; the `environment` override only adds a failure mode (the "dummy" fallback). Removing it simplifies the precedence chain and eliminates the silent corruption.

**Why not "just fix the fallback to a valid-format dummy"**: A well-formatted dummy (e.g., `sk-ant-dummy`) would suppress the login prompt but would mean Claude Code always has a fake key set — a confusing and misleading state. Relying on `env_file` is cleaner: API-key users get the real key, OAuth users get nothing (they don't need it).

### Decision 2: Apply the same cleanup to `CLAUDE_CODE_OAUTH_TOKEN`

Remove `CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}` from `environment` for the same reason — `env_file` handles it.

**Why**: Consistency. Neither auth var needs an `environment` override since `env_file` is authoritative.

### Decision 3: Add `REAL_ANTHROPIC_BASE_URL` support to non-interactive install

When `ANTHROPIC_API_KEY` is set in the host environment, also check for `REAL_ANTHROPIC_BASE_URL` and write it to the `.env` if set.

**Why**: The interactive install path already handles this (line 391 in install.sh). The non-interactive path silently drops it, making custom base URL unusable in automated installs.

## Risks / Trade-offs

- **env_file-only delivery** means the env var is absent in the claude container if the `.env` file is missing or empty. This is acceptable: we validate profile completeness before launch, so a missing `.env` is caught earlier.
- **OAuth users getting no `ANTHROPIC_API_KEY`**: Claude Code may behave differently with the key fully absent vs. set to "dummy". If Claude Code still prompts for login when neither var is set, we'd need a different approach. This is unlikely given `CLAUDE_CODE_OAUTH_TOKEN` is the primary auth signal.

## Open Questions

- Does Claude Code in headless `-p` mode prompt for login interactively (requiring TTY) or exit with an error code? This determines whether the user sees a "login prompt" or just a silent failure. Worth verifying in a test container.
- Is there a minimum valid `ANTHROPIC_API_KEY` format that Claude Code accepts locally (e.g., `sk-ant-` prefix check) without making a network call?
