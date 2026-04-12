---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: Headless Agent Mode
status: executing
stopped_at: Completed 17-02-PLAN.md
last_updated: "2026-04-12T14:12:32.667Z"
last_activity: 2026-04-12
progress:
  total_phases: 6
  completed_phases: 5
  total_plans: 21
  completed_plans: 19
  percent: 88
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-11)

**Core value:** No secret ever leaves the isolated environment uncontrolled -- every outbound call is validated, every secret in LLM context is redacted, and Claude Code cannot bypass the security layers.
**Current focus:** Phase 17 — operational-hardening

## Current Position

Phase: 17 (operational-hardening) — EXECUTING
Plan: 3 of 4
Status: Ready to execute
Last activity: 2026-04-12

Progress: [█████████░] 88% (15/17 plans)

## Performance Metrics

**Velocity:**

- Total plans completed: 2 (v2.0)
- Average duration: ~3.5min
- Total execution time: ~7 minutes

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| Phase 12 P01 | 5min | 2 tasks | 2 files |
| Phase 12 P02 | 2min | 2 tasks | 2 files |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 13 P01 | 5min | 2 tasks | 3 files |
| Phase 13 P02 | 4min | 1 tasks | 1 files |
| Phase 13 P03 | 1min | 1 tasks | 1 files |
| Phase 14 P01 | 6min | 3 tasks | 4 files |
| Phase 14 P03 | 3min | 1 tasks | 1 files |
| Phase 14-webhook-listener P02 | 35min | 2 tasks | 2 files |
| Phase 14 P04 | 8min | 1 tasks | 1 files |
| Phase 15-event-handlers P01 | 8min | 3 tasks | 11 files |
| Phase 15-event-handlers P02 | 7min | 2 tasks | 6 files |
| Phase 15 P03 | 35min | 3 tasks | 5 files |
| Phase 15 P04 | 3min | 1 tasks | 1 files |
| Phase 16-result-channel P02 | 12min | 2 tasks | 3 files |
| Phase 16-result-channel P03 | 180 | 3 tasks | 2 files |
| Phase 16-result-channel P04 | 12m | 2 tasks | 3 files |
| Phase 17 P01 | 9min | 3 tasks | 10 files |
| Phase 17 P02 | 18min | 3 tasks | 6 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap v2.0]: Six phases following dependency chain: Profile System -> Headless CLI + Webhook Listener (parallel) -> Event Handlers -> Result Channel -> Hardening
- [Roadmap v2.0]: Phase 13 and 14 can proceed in parallel since both depend only on Phase 12
- [Research]: Claude Code `-p` flag via `docker compose exec -T` is the only correct headless integration point (SDK bypasses security layers)
- [Research]: Profile resolution must fail closed -- no fallback to default profile
- [Research]: Known bug #7263 (empty output with large stdin) needs verification at Phase 13
- [Phase 12]: Used jq to generate profile.json instead of bash config.sh for per-profile workspace config
- [Phase 13]: Type guards in tests must come AFTER sourcing bin/claude-secure
- [Phase 13]: do_spawn() wraps spawn logic as function for local variables and testability
- [Phase 13]: bare flag omitted from spawn to preserve PreToolUse security hooks
- [Phase 13]: resolve_template uses PROFILE+CONFIG_DIR globals matching test contract
- [Phase 14]: Wave 0 test scaffold created: 16 named test functions, stub claude-secure binary on PATH, gen_sig uses printf '%s' to avoid trailing-newline HMAC mismatch
- [Phase 14]: Hardening directives (NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet) deliberately omitted from webhook unit file — each breaks docker compose subprocess; Phase 17 may revisit
- [Phase 14-webhook-listener]: Plan 14-02: HMAC-SHA256 verified on raw body bytes (never re-serialized); ThreadingHTTPServer + Semaphore(3) for bounded async dispatch; SIGTERM dispatches shutdown() on worker thread to avoid 90s hang
- [Phase 14]: install.sh --with-webhook added: parse_args() + install_webhook_service() with WSL2 warn-don't-block gate, idempotent listener.py refresh, never-overwrite webhook.json
- [Phase 15-event-handlers]: [Phase 15-01]: Wave 0 test scaffold — 28 named test functions + 9 fixtures encoding Pitfalls 1/4/7, LISTENER_PORT=19015, inline harness helpers
- [Phase 15-event-handlers]: [Phase 15-02]: Expanded resolve_profile_by_repo to return webhook_event_filter + webhook_bot_users so apply_event_filter runs with zero I/O (Pitfall 3)
- [Phase 15-event-handlers]: [Phase 15-02]: Listener emits BOTH event=routed (D-23) and event=received (Phase 14 compat) for accepted events
- [Phase 15]: render_template rewritten with 18 D-16 variables using awk file-based substitution (Pitfall 1 fix)
- [Phase 15]: UTF-8 safe truncation via python3 env-var transport (Pitfall 4 fix)
- [Phase 15]: BRANCH/COMMIT_SHA use gated [ -s ] fallback pattern (not post-hoc grep)
- [Phase 15]: replay subcommand uses exec recursion with CLAUDE_SECURE_EXEC escape hatch for test harness
- [Phase 15]: Dev-checkout fallback: APP_DIR derived from script location when config.sh absent
- [Phase 15]: [Phase 15-04]: install.sh install_webhook_service now copies webhook/templates/*.md to /opt/claude-secure/webhook/templates/ with D-12 always-refresh (cp overwrite, never rm -rf)
- [Phase 16-result-channel]: Parameterized _resolve_default_templates_dir(subdir) instead of duplicating — single resolver serves both prompt and report templates, preserving Phase 15 backward compat
- [Phase 16-result-channel]: [Phase 16-03]: Pattern E wrapper writes audit AFTER publish so report_url is in the same JSONL line (avoids O_APPEND-breaking reconciliation)
- [Phase 16-result-channel]: [Phase 16-03]: D-18 exit semantics — publish failures audit-log only; only claude_exit \!= 0 flips spawn exit
- [Phase 16-result-channel]: [Phase 16-03]: delivery_id_short = last 8 chars of STRIPPED id (after replay-/manual- prefix removal) so all three id types produce the same slug format
- [Phase 16-result-channel]: [Phase 16-03]: CLAUDE_SECURE_FAKE_CLAUDE_STDOUT test escape hatch added (Rule 3 deviation) — production docker compose path unchanged
- [Phase 16-result-channel]: Plan 16-04: install.sh step 5c clones step 5b structurally with templates→report-templates substitution and explicit chmod 755 on the directory; D-12 always-refresh preserves operator-added custom templates
- [Phase 16-result-channel]: Plan 16-04: README Phase 16 section placed between Logging and Testing as the operator observability anchor; uses natural prose with no leaked decision IDs and copy-pasteable jq/profile.json examples
- [Phase 17]: [Phase 17-01]: Wave 0 failing-test scaffold with mock docker (Pattern B) + mock flock PATH shims; 31 unit tests (26 fail as NOT IMPLEMENTED sentinels, 5 scaffold passes); E2E harness with check_budget gate between scenarios + REAPER_ORPHAN_AGE_SECS=0 cleanup trap
- [Phase 17]: [Phase 17-01]: profile-e2e .env force-added (gitignored by default) -- test-only placeholder, no real secret. Fixture rewrites loader-facing .env path that Phase 15/16 contracts require verbatim
- [Phase 17]: Phase 17-02: dual ISO8601 timestamp handling (case-statement fractional-second strip) to tolerate both .nnnZ and plain Z inputs from docker inspect
- [Phase 17]: Phase 17-02: atomic D-11 hardening commit (Pattern G) applies 10 safe-subset directives to BOTH webhook.service and reaper.service in a single commit to prevent half-hardened listener state
- [Phase 17]: Phase 17-02: mem_limit: 1g short-form on claude service (Pitfall 5) -- deploy.resources is Swarm-only and silently ignored by docker compose up

### Pending Todos

- **iptables packet-level logging**: Add iptables `-j LOG` rules for DROP/ACCEPT and poll `dmesg`/`/proc/kmsg` from validator background thread to capture actual packet allow/block events into `iptables.jsonl`.

### Blockers/Concerns

- [Research]: systemd in WSL2 requires `[boot] systemd=true` in `/etc/wsl.conf` -- installer should detect this (affects Phase 14)
- [Research]: `--allowedTools` prefix match syntax needs empirical verification (affects Phase 13)
- [Research]: Docker Compose `deploy.resources.limits` vs `mem_limit` -- verify with `docker inspect` (affects Phase 13)

## Session Continuity

Last session: 2026-04-12T14:12:24.125Z
Stopped at: Completed 17-02-PLAN.md
Resume file: None
