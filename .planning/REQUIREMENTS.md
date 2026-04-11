# Requirements: claude-secure

**Defined:** 2026-04-11
**Core Value:** No secret ever leaves the isolated environment uncontrolled -- every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.

## v2.0 Requirements

Requirements for headless agent mode. Each maps to roadmap phases.

### Profiles

- [ ] **PROF-01**: User can create a profile with its own whitelist.json, .env, and workspace directory
- [ ] **PROF-02**: User can map a GitHub repository URL to a profile so events route correctly
- [ ] **PROF-03**: Profile resolution fails closed -- missing or invalid profile blocks execution, never falls back to default

### Headless Execution

- [ ] **HEAD-01**: User can spawn a non-interactive Claude Code session via `claude-secure spawn --profile <name> --event <payload>`
- [ ] **HEAD-02**: Headless session uses `-p` with `--output-format json` and captures structured result (result, cost, duration, session_id)
- [ ] **HEAD-03**: User can set per-profile `--max-turns` budget to limit execution scope
- [ ] **HEAD-04**: Spawned instance is ephemeral -- containers are created, execute, and tear down automatically
- [ ] **HEAD-05**: User can define prompt templates per profile with variable substitution (e.g. `{{ISSUE_TITLE}}`, `{{REPO_NAME}}`)

### Webhooks

- [ ] **HOOK-01**: Webhook listener runs as a host-side systemd service receiving GitHub webhooks
- [ ] **HOOK-02**: Every incoming webhook is verified via HMAC-SHA256 signature against raw payload body
- [ ] **HOOK-03**: Listener handles Issue events (opened, labeled) and dispatches to correct profile
- [ ] **HOOK-04**: Listener handles Push-to-Main events and dispatches to correct profile
- [ ] **HOOK-05**: Listener handles CI Failure events (workflow_run completed with failure) and dispatches to correct profile
- [ ] **HOOK-06**: Multiple simultaneous webhooks execute safely with unique compose project names and isolated workspaces
- [ ] **HOOK-07**: User can replay a stored webhook payload for debugging via CLI command

### Operations

- [ ] **OPS-01**: After execution, a structured markdown report is written and pushed to a separate documentation repo
- [ ] **OPS-02**: Each headless execution is logged to structured JSONL with event metadata (webhook ID, event type, commit SHA, cost)
- [ ] **OPS-03**: A container reaper cleans up orphaned containers from failed or timed-out executions

## Future Requirements

Deferred to future release. Tracked but not in current roadmap.

### Cost & Monitoring

- **COST-01**: Cost tracking per event aggregated by profile and time period
- **HEALTH-01**: Health monitoring with systemd watchdog integration
- **HEALTH-02**: Failure alerting via webhook to notification service (Slack/Discord)

### Security Hardening

- **SEC-01**: Per-profile --allowedTools scoping instead of blanket --dangerously-skip-permissions
- **SEC-02**: Prompt injection sanitization for GitHub event payloads injected into prompts

### CLI

- **CLI-01**: `claude-secure headless status` command showing listener state and recent events
- **CLI-02**: `claude-secure headless logs` command for querying execution history

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Auto-merge PRs created by agent | Security product must not auto-merge code. Humans review agent output. |
| Real-time streaming webhook responses | Massive complexity (SSE from container to GitHub API). Single summary on completion instead. |
| Dynamic prompt editing via GitHub comments | Turns one-shot into interactive session. Race conditions, prompt injection risk. |
| Multi-repo orchestration from single webhook | Explosion of concurrent containers, complex dependency ordering. One profile = one repo. |
| Agent-to-agent communication | Cross-container IPC is infrastructure engineering, not security tooling. Sequential chaining instead. |
| Persistent agent sessions (resume across events) | Defeats ephemeral isolation model. Fresh session per event with context in prompt. |
| Web UI dashboard | Massive scope expansion. CLI + structured JSONL is sufficient for solo dev. |
| Agent SDK integration | SDK runs Claude on host, bypassing all Docker security layers. Must use CLI `-p` via `docker compose exec`. |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROF-01 | Phase 12 | Pending |
| PROF-02 | Phase 12 | Pending |
| PROF-03 | Phase 12 | Pending |
| HEAD-01 | Phase 13 | Pending |
| HEAD-02 | Phase 13 | Pending |
| HEAD-03 | Phase 13 | Pending |
| HEAD-04 | Phase 13 | Pending |
| HEAD-05 | Phase 13 | Pending |
| HOOK-01 | Phase 14 | Pending |
| HOOK-02 | Phase 14 | Pending |
| HOOK-03 | Phase 15 | Pending |
| HOOK-04 | Phase 15 | Pending |
| HOOK-05 | Phase 15 | Pending |
| HOOK-06 | Phase 14 | Pending |
| HOOK-07 | Phase 15 | Pending |
| OPS-01 | Phase 16 | Pending |
| OPS-02 | Phase 16 | Pending |
| OPS-03 | Phase 17 | Pending |

**Coverage:**
- v2.0 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

---
*Requirements defined: 2026-04-11*
*Last updated: 2026-04-11 after roadmap creation*
