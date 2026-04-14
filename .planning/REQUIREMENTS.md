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

- [x] **HEAD-01**: User can spawn a non-interactive Claude Code session via `claude-secure spawn --profile <name> --event <payload>`
- [x] **HEAD-02**: Headless session uses `-p` with `--output-format json` and captures structured result (result, cost, duration, session_id)
- [x] **HEAD-03**: User can set per-profile `--max-turns` budget to limit execution scope
- [x] **HEAD-04**: Spawned instance is ephemeral -- containers are created, execute, and tear down automatically
- [x] **HEAD-05**: User can define prompt templates per profile with variable substitution (e.g. `{{ISSUE_TITLE}}`, `{{REPO_NAME}}`)

### Webhooks

- [x] **HOOK-01**: Webhook listener runs as a host-side systemd service receiving GitHub webhooks
- [x] **HOOK-02**: Every incoming webhook is verified via HMAC-SHA256 signature against raw payload body
- [x] **HOOK-03**: Listener handles Issue events (opened, labeled) and dispatches to correct profile
- [x] **HOOK-04**: Listener handles Push-to-Main events and dispatches to correct profile
- [x] **HOOK-05**: Listener handles CI Failure events (workflow_run completed with failure) and dispatches to correct profile
- [x] **HOOK-06**: Multiple simultaneous webhooks execute safely with unique compose project names and isolated workspaces
- [x] **HOOK-07**: User can replay a stored webhook payload for debugging via CLI command

### Operations

- [x] **OPS-01**: After execution, a structured markdown report is written and pushed to a separate documentation repo
- [x] **OPS-02**: Each headless execution is logged to structured JSONL with event metadata (webhook ID, event type, commit SHA, cost)
- [x] **OPS-03**: A container reaper cleans up orphaned containers from failed or timed-out executions

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
| PROF-01 | Phase 12 → Phase 27 (verif backfill) | Pending |
| PROF-02 | Phase 12 → Phase 29 (UX fix) | Pending |
| PROF-03 | Phase 12 → Phase 27 (verif backfill) | Pending |
| HEAD-01 | Phase 13 | Complete |
| HEAD-02 | Phase 13 | Complete |
| HEAD-03 | Phase 13 | Complete |
| HEAD-04 | Phase 13 | Complete |
| HEAD-05 | Phase 13 | Complete |
| HOOK-01 | Phase 14 | Complete |
| HOOK-02 | Phase 14 | Complete |
| HOOK-03 | Phase 15 | Complete |
| HOOK-04 | Phase 15 | Complete |
| HOOK-05 | Phase 15 | Complete |
| HOOK-06 | Phase 14 | Complete |
| HOOK-07 | Phase 15 | Complete |
| OPS-01 | Phase 16 → Phase 27 (verif) + Phase 28 (docs_repo fix) | Pending |
| OPS-02 | Phase 16 → Phase 27 (verif backfill) | Pending |
| OPS-03 | Phase 17 | Complete |

**Coverage:**
- v2.0 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

## v3.0 Requirements

Requirements for macOS platform support. Each maps to roadmap phases.

### Platform Detection & Installer (PLAT)

- [ ] **PLAT-01**: User can install claude-secure on macOS via a single installer command
- [x] **PLAT-02**: Installer detects platform (linux/wsl2/macos) via shared `lib/platform.sh` with `detect_platform()` — all scripts use it, `CLAUDE_SECURE_PLATFORM_OVERRIDE` available for CI mocking
- [x] **PLAT-03**: Installer verifies Homebrew is present on macOS and prints actionable install instructions if missing (does not auto-install)
- [x] **PLAT-04**: Installer bootstraps GNU tools on macOS (`brew install bash coreutils jq`) before any other steps
- [x] **PLAT-05**: Installer verifies Docker Desktop ≥ 4.44.3 is installed and running on macOS, and warns/blocks if older

### Container Compatibility (COMPAT)

- [x] **COMPAT-01**: Validator container uses `python:3.11-slim-bookworm` base image on all platforms (replaces Alpine — fixes iptables-nft mismatch with Docker Desktop Mac's kernel)

### Bash/BSD Portability (PORT)

- [x] **PORT-01**: All host-side scripts prepend GNU coreutils to PATH via `$(brew --prefix)/libexec/gnubin` on macOS (fixes `date`, `sed`, `readlink`, `stat`, `base64`, `xargs`, `grep -P` silently)
- [x] **PORT-02**: Host scripts using bash 4+ features (`declare -A`, `mapfile`, `${var,,}`) re-exec into brew bash 5 on macOS
- [x] **PORT-03**: All host-side scripts audited for `flock` usage; replaced with `mkdir`-based atomic locking where found
- [x] **PORT-04**: Hook call-ID generation normalizes `uuidgen` output to lowercase on macOS (BSD uuidgen outputs uppercase)

### Network Enforcement (ENFORCE)

- [ ] **ENFORCE-01**: Empirical spike on macOS hardware verifies whether iptables works inside Docker Desktop containers with `NET_ADMIN` + shared network namespace
- [ ] **ENFORCE-02**: Network-level call enforcement is functional on macOS (implementation determined by spike: iptables-in-container / host-side pf anchor / proxy chokepoint)

### Service Management — launchd (SVC)

- [ ] **SVC-01**: Webhook listener runs as a LaunchDaemon on macOS (`com.claude-secure.webhook.plist`), replacing the systemd unit
- [ ] **SVC-02**: Installer installs/uninstalls webhook LaunchDaemon using `launchctl bootstrap`/`bootout` (not deprecated `load`/`unload`)
- [ ] **SVC-03**: Container reaper runs as a LaunchDaemon on macOS (`com.claude-secure.reaper.plist`), replacing the systemd timer
- [ ] **SVC-04**: pf anchor rules are restored on macOS boot via a one-shot LaunchDaemon *(conditional: only required if ENFORCE-01 spike chooses host-side pf enforcement)*

### Testing (TEST)

- [x] **TEST-01**: `CLAUDE_SECURE_PLATFORM_OVERRIDE` env var allows Linux CI to mock and exercise macOS code paths without a Mac runner
- [ ] **TEST-02**: Integration tests verify non-whitelisted calls are blocked on macOS (TCP reject or HTTP 403 depending on enforcement choice)
- [ ] **TEST-03**: Integration tests verify launchd lifecycle: install, start, survive reboot, uninstall cleanly including pf zombie anchor cleanup

## v3.0 Traceability

Which phases cover which v3.0 requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PLAT-01 | Phase 21 | Pending |
| PLAT-02 | Phase 18 | Complete |
| PLAT-03 | Phase 18 | Complete |
| PLAT-04 | Phase 18 | Complete |
| PLAT-05 | Phase 19 | Complete |
| COMPAT-01 | Phase 19 | Complete |
| PORT-01 | Phase 18 | Complete |
| PORT-02 | Phase 18 | Complete |
| PORT-03 | Phase 18 | Complete |
| PORT-04 | Phase 18 | Complete |
| ENFORCE-01 | Phase 20 | Pending |
| ENFORCE-02 | Phase 20 | Pending |
| SVC-01 | Phase 21 | Pending |
| SVC-02 | Phase 21 | Pending |
| SVC-03 | Phase 21 | Pending |
| SVC-04 | Phase 21 | Pending (conditional on Phase 20 spike) |
| TEST-01 | Phase 18 | Complete |
| TEST-02 | Phase 22 | Pending |
| TEST-03 | Phase 22 | Pending |

**Coverage:**
- v3.0 requirements: 19 total
- Mapped to phases: 19
- Unmapped: 0

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

### macOS Enhancements (Post-v3.0)

- **MAC-01**: Homebrew tap for installer distribution (`brew install claude-secure`)
- **MAC-02**: Keychain-backed OAuth token storage on macOS (native `security` CLI)
- **MAC-03**: Apple Silicon + Intel multi-arch container images (`linux/arm64` + `linux/amd64`)
- **MAC-04**: Logs to `~/Library/Logs/claude-secure/` for Console.app integration

### Agent Documentation Layer (Post-v4.0)

- **HOOK-INBOX-01**: Webhook listener routes doc-repo push/issues events to profiles via `resolve_profile_by_docs_repo` (deferred to v4.1)
- **TEST-V4-01**: Roundtrip integration tests for v4.0 — parallel-push race, Stop-hook DNS-failure, back-compat with Phase 16 profiles (deferred to v4.1)

## v4.0 Requirements

Requirements for the agent documentation layer. Each maps to roadmap phases.

### Profile ↔ Doc Repo Binding (BIND)

- [ ] **BIND-01**: User can configure a doc repo URL, branch, project directory slug, and access token per profile (`docs_repo`, `docs_branch`, `docs_project_dir`, `DOCS_REPO_TOKEN` in profile.json / .env)
- [ ] **BIND-02**: `DOCS_REPO_TOKEN` is stored in the host-only profile `.env` and is never mounted into the Claude container
- [ ] **BIND-03**: Profiles with legacy `report_repo` / `REPORT_REPO_TOKEN` (Phase 16) continue to work without migration — new fields are aliases

### Doc Repo Structure (DOCS)

- [x] **DOCS-01**: User can initialize a per-project directory in the doc repo via `claude-secure profile init-docs --profile <name>`, creating `projects/<slug>/todo.md`, `architecture.md`, `vision.md`, `ideas.md`, and `specs/`
- [x] **DOCS-02**: Agent reports are written to `projects/<slug>/reports/YYYY/MM/<date>-<session-id>.md` — one file per execution, never overwriting
- [x] **DOCS-03**: `projects/<slug>/reports/INDEX.md` receives a one-line summary entry per report for human scanning

### Outbound Reporting (RPT)

- [x] **RPT-01**: Every agent execution produces a report using the standardized template: Goal, Where Worked, What Changed (thematic), What Failed, How to Test, Future Findings
- [x] **RPT-02**: Report and INDEX.md update are committed as a single atomic git commit — never a partial push
- [x] **RPT-03**: Every file staged for commit passes through the existing secret redaction pipeline before push
- [x] **RPT-04**: Every file staged for commit is sanitized to strip external image references, HTML comments, and raw HTML before commit (prevents markdown exfil beacons)
- [x] **RPT-05**: Push uses `git push` over HTTPS, never force-push, with 3-attempt jittered retry on non-fast-forward

### Mandatory Enforcement (SPOOL)

- [ ] **SPOOL-01**: A Stop hook verifies a local report spool file was written before Claude exits — if missing, re-prompts Claude once to produce it
- [ ] **SPOOL-02**: The Stop hook makes no network calls — it only checks for the local spool file (doc repo outage cannot block Claude exit)
- [ ] **SPOOL-03**: A host-side async shipper reads the spool after Claude exits and pushes to the doc repo with jittered backoff — failure is logged to audit JSONL and never blocks the next spawn

### Context Read (CTX)

- [x] **CTX-01**: At spawn time, `bin/claude-secure` performs a sparse shallow clone of the doc repo and bind-mounts it read-only into the Claude container at `/agent-docs/`
- [x] **CTX-02**: Agent can read any project-level doc (`/agent-docs/projects/<slug>/todo.md`, `architecture.md`, `vision.md`, `ideas.md`, `specs/`) when it needs context — no auto-injection into prompt
- [x] **CTX-03**: If the profile has no doc repo configured, context read is skipped silently — spawn is never blocked
- [x] **CTX-04**: The bind-mounted clone never includes `.git/` — agents cannot push from inside the container

## v4.0 Traceability

Which phases cover which v4.0 requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BIND-01 | Phase 23 | Pending |
| BIND-02 | Phase 23 | Pending |
| BIND-03 | Phase 23 | Pending |
| DOCS-01 | Phase 23 | Complete |
| DOCS-02 | Phase 24 | Complete |
| DOCS-03 | Phase 24 | Complete |
| RPT-01 | Phase 24 | Complete |
| RPT-02 | Phase 24 | Complete |
| RPT-03 | Phase 24 | Complete |
| RPT-04 | Phase 24 | Complete |
| RPT-05 | Phase 24 | Complete |
| SPOOL-01 | Phase 26 | Pending |
| SPOOL-02 | Phase 26 | Pending |
| SPOOL-03 | Phase 26 | Pending |
| CTX-01 | Phase 25 | Complete |
| CTX-02 | Phase 25 | Complete |
| CTX-03 | Phase 25 | Complete |
| CTX-04 | Phase 25 | Complete |

**Coverage:**
- v4.0 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

---
*Requirements defined: 2026-04-11*
*Last updated: 2026-04-14 — phases 27-29 added (v2.0 gap closure from audit)*
