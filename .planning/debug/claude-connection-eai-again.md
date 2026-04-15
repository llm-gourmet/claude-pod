---
status: awaiting_human_verify
trigger: "Claude Code inside docker fails with EAI_AGAIN trying to reach api.anthropic.com"
created: 2026-04-09T00:00:00Z
updated: 2026-04-09T00:00:00Z
---

## Current Focus

hypothesis: REVISED -- hasCompletedOnboarding fix was necessary but insufficient. Claude Code interactive mode makes MULTIPLE direct calls to api.anthropic.com that bypass ANTHROPIC_BASE_URL: (1) telemetry to statsig.anthropic.com/sentry, (2) auth/org checks. GitHub #36998 confirms interactive mode ignores ANTHROPIC_BASE_URL for startup calls. GitHub #2481 confirms telemetry failure causes misleading EAI_AGAIN error.
test: Rebuild and run with DISABLE_TELEMETRY=1, DISABLE_AUTOUPDATER=1, DISABLE_ERROR_REPORTING=1, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 plus existing hasCompletedOnboarding fix
expecting: All non-API external calls suppressed, Claude Code connects through proxy successfully
next_action: User rebuilds and tests -- docker compose build claude && claude-secure

## Symptoms

expected: Claude Code starts and connects to Anthropic API through the local proxy container at http://proxy:8080
actual: "Unable to connect to Anthropic services - Failed to connect to api.anthropic.com: EAI_AGAIN"
errors: EAI_AGAIN (DNS resolution failure for api.anthropic.com)
reproduction: Run `claude-secure` command -- containers start, but Claude Code can't connect
started: First run after installation

## Eliminated

- hypothesis: hasCompletedOnboarding alone fixes EAI_AGAIN
  evidence: User rebuilt with hasCompletedOnboarding=true in ~/.claude.json, same EAI_AGAIN error persists. The onboarding bypass is necessary but not sufficient -- Claude Code interactive mode makes other direct calls to api.anthropic.com (telemetry, auth/org checks) that also bypass ANTHROPIC_BASE_URL (confirmed by GitHub #36998, #2481).
  timestamp: 2026-04-09

## Evidence

- timestamp: 2026-04-09T00:01:00Z
  checked: docker-compose.yml environment variables
  found: ANTHROPIC_BASE_URL=http://proxy:8080 is set on claude container; proxy is on same internal network
  implication: The env var IS set, so either Claude Code doesn't use it for all connections, the var name is wrong, or OAuth has a separate endpoint

- timestamp: 2026-04-09T00:02:00Z
  checked: Network topology in docker-compose.yml
  found: claude container on claude-internal only (internal: true); proxy on claude-internal + claude-external; DNS name "proxy" should resolve on internal network
  implication: Network topology is correct; proxy should be reachable by name; but claude container cannot reach external DNS (api.anthropic.com) -- which is by design

- timestamp: 2026-04-09T00:03:00Z
  checked: Error message specifics
  found: Error says "api.anthropic.com" not "proxy" -- Claude Code is attempting to reach the real Anthropic API, not the proxy
  implication: ANTHROPIC_BASE_URL is not being used for this particular connection, OR Claude Code has a separate auth/connection check that uses a hardcoded URL

- timestamp: 2026-04-09T00:04:00Z
  checked: Claude Code documentation and GitHub issues for ANTHROPIC_BASE_URL bypass behavior
  found: Known issue (GitHub #26935) -- Claude Code's onboarding flow calls api.anthropic.com directly when hasCompletedOnboarding is not set in ~/.claude.json, ignoring ANTHROPIC_BASE_URL entirely
  implication: ROOT CAUSE CONFIRMED -- the container is a fresh environment with no ~/.claude.json, so Claude Code runs onboarding check that bypasses the proxy and hits api.anthropic.com directly, which fails because the container has no external DNS

- timestamp: 2026-04-09
  checked: GitHub issues for Claude Code ANTHROPIC_BASE_URL bypass behavior
  found: Issue #36998 (March 2026) confirms interactive mode ignores ANTHROPIC_BASE_URL for startup/auth/telemetry calls, connecting directly to api.anthropic.com. Print mode (claude -p) respects it. Issue #2481 confirms telemetry failure (statsig.anthropic.com TLS) causes misleading "Unable to connect to Anthropic services" error, resolved by DISABLE_TELEMETRY=1.
  implication: Multiple direct-to-api.anthropic.com calls exist in interactive startup. Fix requires disabling telemetry AND potentially other startup checks. ANTHROPIC_BASE_URL alone is not enough for interactive mode in a network-isolated container.

- timestamp: 2026-04-09
  checked: How other Docker isolation projects handle this (shaharia.com, claudebox, RchGrav/claudebox)
  found: Most projects use a Squid/filtering proxy approach that ALLOWS Claude Code to reach api.anthropic.com but through a controlled proxy, rather than using ANTHROPIC_BASE_URL to redirect. This confirms that ANTHROPIC_BASE_URL redirection in interactive mode is unreliable.
  implication: Two fix paths: (A) disable all non-API external calls via env vars and hope ANTHROPIC_BASE_URL works for the remaining API calls, or (B) switch architecture to a filtering proxy model that allows controlled external access.

## Resolution

root_cause: Claude Code interactive mode makes MULTIPLE startup calls directly to api.anthropic.com that bypass ANTHROPIC_BASE_URL (confirmed GitHub #36998, #2481, #15274). These include: (1) telemetry to statsig.anthropic.com, (2) error reporting to sentry, (3) auto-updater checks, (4) onboarding check (already fixed), (5) auth/org validation. In the network-isolated Docker container (internal network, no external DNS), ALL of these fail with EAI_AGAIN. The hasCompletedOnboarding fix only addressed item (4). The fix must suppress ALL non-API external calls via environment variables: DISABLE_TELEMETRY=1, DISABLE_AUTOUPDATER=1, plus keep hasCompletedOnboarding.
fix: Added four environment variables to suppress ALL non-API external connections that bypass ANTHROPIC_BASE_URL -- DISABLE_TELEMETRY=1, DISABLE_AUTOUPDATER=1, DISABLE_ERROR_REPORTING=1, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1. Set in both docker-compose.yml (runtime) and Dockerfile (build-time fallback). Combined with existing hasCompletedOnboarding fix, this should eliminate all direct-to-api.anthropic.com calls except the actual API calls which respect ANTHROPIC_BASE_URL.
verification: Pending user rebuild and test
files_changed: [docker-compose.yml, claude/Dockerfile]
