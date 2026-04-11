# Roadmap: claude-secure

## Milestones

- v1.0 MVP -- Phases 1-11 (shipped 2026-04-11)
- v2.0 Headless Agent Mode -- Phases 12-17 (in progress)

## Phases

<details>
<summary>v1.0 MVP (Phases 1-11) -- SHIPPED 2026-04-11</summary>

- [x] Phase 1: Docker Infrastructure (2/2 plans) -- completed 2026-04-08
- [x] Phase 2: Call Validation (3/3 plans) -- completed 2026-04-08
- [x] Phase 3: Secret Redaction (2/2 plans) -- completed 2026-04-08
- [x] Phase 4: Installation & Platform (2/2 plans) -- completed 2026-04-08
- [x] Phase 5: Integration Testing (absorbed into per-phase test suites)
- [x] Phase 6: Service Logging (3/3 plans) -- completed 2026-04-09
- [x] Phase 7: Env-file Strategy (2/2 plans) -- completed 2026-04-09
- [x] Phase 8: Container Tooling (1/1 plan) -- completed 2026-04-09
- [x] Phase 9: Multi-Instance Support (3/3 plans) -- completed 2026-04-10
- [x] Phase 10: Automate Pre-push Tests (2/2 plans) -- completed 2026-04-10
- [x] Phase 11: Milestone Cleanup (1/1 plan) -- completed 2026-04-11

</details>

### v2.0 Headless Agent Mode (In Progress)

- [ ] **Phase 12: Profile System** - Per-service security context with isolated whitelist, secrets, workspace, and repo routing
- [ ] **Phase 13: Headless CLI Path** - Non-interactive Claude Code execution with ephemeral container lifecycle
- [ ] **Phase 14: Webhook Listener** - Systemd service receiving and validating GitHub webhooks
- [ ] **Phase 15: Event Handlers** - Event-type dispatch with prompt templates and payload sanitization
- [ ] **Phase 16: Result Channel** - Structured reporting and execution audit logging
- [ ] **Phase 17: Operational Hardening** - Container reaper and end-to-end integration verification

## Phase Details

### Phase 12: Profile System
**Goal**: Users can define per-service security contexts so each project gets its own whitelist, secrets, and workspace
**Depends on**: Nothing (first v2.0 phase, builds on v1.0 instance system)
**Requirements**: PROF-01, PROF-02, PROF-03
**Success Criteria** (what must be TRUE):
  1. User can create a profile directory with its own whitelist.json, .env, and workspace path, and spawn a claude-secure instance that uses that profile's config
  2. User can map a GitHub repository URL to a profile, and the system resolves the correct profile from a repo URL
  3. When a profile is missing or invalid (no whitelist.json, no .env, bad workspace path), execution is blocked with a clear error -- never falls back to a default profile
**Plans**: TBD

Plans:
- [ ] 12-01: TBD
- [ ] 12-02: TBD

### Phase 13: Headless CLI Path
**Goal**: Users can run Claude Code non-interactively through claude-secure with full security isolation and automatic cleanup
**Depends on**: Phase 12
**Requirements**: HEAD-01, HEAD-02, HEAD-03, HEAD-04, HEAD-05
**Success Criteria** (what must be TRUE):
  1. User can run `claude-secure spawn --profile <name> --event <payload>` and get a non-interactive Claude Code session that executes inside the Docker security stack
  2. Headless session returns structured JSON output containing result text, cost, duration, and session_id
  3. User can set per-profile max-turns budget, and execution stops when the limit is reached
  4. After execution completes (success or failure), all containers, volumes, and networks for that run are automatically torn down
  5. User can define prompt templates with variable substitution (e.g. `{{ISSUE_TITLE}}`) in the profile directory, and the headless spawn fills them from event data
**Plans**: TBD

Plans:
- [ ] 13-01: TBD
- [ ] 13-02: TBD

### Phase 14: Webhook Listener
**Goal**: A persistent host-side service receives GitHub webhooks, validates their authenticity, and safely handles concurrent events
**Depends on**: Phase 12
**Requirements**: HOOK-01, HOOK-02, HOOK-06
**Success Criteria** (what must be TRUE):
  1. A systemd service runs on the host listening for GitHub webhook POST requests and survives restarts
  2. Every incoming webhook is verified via HMAC-SHA256 signature against the raw payload body -- invalid signatures are rejected with 401
  3. Multiple simultaneous webhooks execute safely, each with a unique compose project name and isolated workspace -- no cross-contamination between concurrent runs
**Plans**: TBD

Plans:
- [ ] 14-01: TBD
- [ ] 14-02: TBD

### Phase 15: Event Handlers
**Goal**: Incoming GitHub events are routed to the correct profile and dispatched with appropriate prompts
**Depends on**: Phase 13, Phase 14
**Requirements**: HOOK-03, HOOK-04, HOOK-05, HOOK-07
**Success Criteria** (what must be TRUE):
  1. When a GitHub Issue event (opened/labeled) arrives, the listener routes it to the correct profile and spawns a headless session with issue context in the prompt
  2. When a push-to-main event arrives, the listener routes it to the correct profile and spawns a headless session with commit context in the prompt
  3. When a CI failure event (workflow_run completed with failure) arrives, the listener routes it to the correct profile and spawns a headless session with failure context in the prompt
  4. User can replay a stored webhook payload via CLI command for debugging
**Plans**: TBD

Plans:
- [ ] 15-01: TBD
- [ ] 15-02: TBD

### Phase 16: Result Channel
**Goal**: Every headless execution produces a structured report pushed to a documentation repo and an audit log entry
**Depends on**: Phase 13
**Requirements**: OPS-01, OPS-02
**Success Criteria** (what must be TRUE):
  1. After a headless execution completes, a structured markdown report (with event metadata, result summary, and cost) is committed and pushed to a separate documentation repo
  2. Every headless execution is logged to a structured JSONL file with webhook ID, event type, commit SHA, cost, and duration
**Plans**: TBD

Plans:
- [ ] 16-01: TBD

### Phase 17: Operational Hardening
**Goal**: Orphaned containers from failed runs are automatically cleaned up and the full system is verified end-to-end
**Depends on**: Phase 15, Phase 16
**Requirements**: OPS-03
**Success Criteria** (what must be TRUE):
  1. A container reaper (systemd timer) automatically removes orphaned containers from failed or timed-out executions within a bounded time window
  2. End-to-end integration tests verify the complete webhook-to-report pipeline including HMAC rejection, concurrent execution, orphan cleanup, and resource limit enforcement
**Plans**: TBD

Plans:
- [ ] 17-01: TBD
- [ ] 17-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 12 -> 13 -> 14 -> 15 -> 16 -> 17
(Note: Phase 14 can proceed in parallel with Phase 13 as both depend only on Phase 12)

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Docker Infrastructure | v1.0 | 2/2 | Complete | 2026-04-08 |
| 2. Call Validation | v1.0 | 3/3 | Complete | 2026-04-08 |
| 3. Secret Redaction | v1.0 | 2/2 | Complete | 2026-04-08 |
| 4. Installation & Platform | v1.0 | 2/2 | Complete | 2026-04-08 |
| 5. Integration Testing | v1.0 | 0/0 | Complete (per-phase) | 2026-04-08 |
| 6. Service Logging | v1.0 | 3/3 | Complete | 2026-04-09 |
| 7. Env-file Strategy | v1.0 | 2/2 | Complete | 2026-04-09 |
| 8. Container Tooling | v1.0 | 1/1 | Complete | 2026-04-09 |
| 9. Multi-Instance Support | v1.0 | 3/3 | Complete | 2026-04-10 |
| 10. Automate Pre-push Tests | v1.0 | 2/2 | Complete | 2026-04-10 |
| 11. Milestone Cleanup | v1.0 | 1/1 | Complete | 2026-04-11 |
| 12. Profile System | v2.0 | 0/? | Not started | - |
| 13. Headless CLI Path | v2.0 | 0/? | Not started | - |
| 14. Webhook Listener | v2.0 | 0/? | Not started | - |
| 15. Event Handlers | v2.0 | 0/? | Not started | - |
| 16. Result Channel | v2.0 | 0/? | Not started | - |
| 17. Operational Hardening | v2.0 | 0/? | Not started | - |
