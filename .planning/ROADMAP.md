# Roadmap: claude-secure

## Milestones

- v1.0 MVP -- Phases 1-11 (shipped 2026-04-11)
- v2.0 Headless Agent Mode -- Phases 12-17 (shipped 2026-04-12)
- v3.0 macOS Support -- Phases 18-22 (in progress)
- v4.0 Agent Documentation Layer -- Phases 23-26 (shipped 2026-04-14)

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

<details>
<summary>v2.0 Headless Agent Mode (Phases 12-17) -- SHIPPED 2026-04-12</summary>

- [x] Phase 12: Profile System (2/2 plans) -- completed 2026-04-11
- [x] Phase 13: Headless CLI Path (3/3 plans) -- completed 2026-04-11
- [x] Phase 14: Webhook Listener (4/4 plans) -- completed 2026-04-12
- [x] Phase 15: Event Handlers (4/4 plans) -- completed 2026-04-12
- [x] Phase 16: Result Channel (4/4 plans) -- completed 2026-04-12
- [x] Phase 17: Operational Hardening (4/4 plans) -- completed 2026-04-12

</details>

<details>
<summary>v4.0 Agent Documentation Layer (Phases 23-26) -- SHIPPED 2026-04-14</summary>

- [x] Phase 23: Profile ↔ Doc Repo Binding (3/3 plans) -- completed 2026-04-13
- [x] Phase 24: Multi-File Publish Bundle (3/3 plans) -- completed 2026-04-14
- [x] Phase 25: Context Read & Read-Only Bind Mount (4/4 plans) -- completed 2026-04-14
- [x] Phase 26: Stop Hook & Mandatory Reporting (4/4 plans) -- completed 2026-04-14

See: .planning/milestones/v4.0-ROADMAP.md for full phase details.

</details>

### v3.0 macOS Support (In Progress)

- [x] **Phase 18: Platform Abstraction & Bash Portability** - Shared platform detection library and BSD/bash 3.2 portability fixes across all host scripts (completed 2026-04-13)
- [x] **Phase 19: Docker Desktop Compatibility** - Compose topology and validator image work correctly under Docker Desktop on macOS (completed 2026-04-13)
- [ ] **Phase 20: Network Enforcement on macOS** - Empirical spike resolves iptables-vs-pf, then implements network-level call enforcement
- [ ] **Phase 21: launchd Service Management** - Webhook listener and reaper run as LaunchDaemons; installer completes end-to-end on macOS
- [ ] **Phase 22: macOS Integration Tests** - TCP-level block tests and launchd lifecycle tests verify v3.0 against silent-failure modes

### Phase Details (v3.0 active phases)

#### Phase 18: Platform Abstraction & Bash Portability
**Goal**: Every host script can detect its platform and runs reliably on macOS without silent BSD/bash 3.2 misbehavior
**Requirements**: PLAT-02, PLAT-03, PLAT-04, PORT-01, PORT-02, PORT-03, PORT-04, TEST-01
**Plans**: 5/5 complete

#### Phase 19: Docker Desktop Compatibility
**Goal**: The existing Docker Compose stack boots and runs the four security layers correctly on Docker Desktop for Mac
**Requirements**: PLAT-05, COMPAT-01
**Plans**: 3/3 complete

#### Phase 20: Network Enforcement on macOS
**Goal**: Non-whitelisted outbound calls are blocked at the network layer on macOS via the enforcement strategy chosen by the empirical spike
**Depends on**: Phase 19
**Requirements**: ENFORCE-01, ENFORCE-02
**Plans**: TBD — requires real macOS hardware for empirical spike

#### Phase 21: launchd Service Management
**Goal**: The webhook listener and container reaper run as boot-persistent LaunchDaemons on macOS, and the installer completes the full claude-secure install path end-to-end
**Depends on**: Phase 20
**Requirements**: PLAT-01, SVC-01, SVC-02, SVC-03, SVC-04
**Plans**: TBD

#### Phase 22: macOS Integration Tests
**Goal**: Automated tests cover the macOS code paths so silent-failure modes are caught before users hit them
**Depends on**: Phase 21
**Requirements**: TEST-02, TEST-03
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-11. MVP phases | v1.0 | 21/21 | Complete | 2026-04-11 |
| 12-17. Headless Agent phases | v2.0 | 17/17 | Complete | 2026-04-12 |
| 18. Platform Abstraction | v3.0 | 5/5 | Complete | 2026-04-13 |
| 19. Docker Desktop Compat | v3.0 | 3/3 | Complete | 2026-04-13 |
| 20. Network Enforcement on macOS | v3.0 | 0/? | Not started | - |
| 21. launchd Service Management | v3.0 | 0/? | Not started | - |
| 22. macOS Integration Tests | v3.0 | 0/? | Not started | - |
| 23. Profile ↔ Doc Repo Binding | v4.0 | 3/3 | Complete | 2026-04-13 |
| 24. Multi-File Publish Bundle | v4.0 | 3/3 | Complete | 2026-04-14 |
| 25. Context Read & Bind Mount | v4.0 | 4/4 | Complete | 2026-04-14 |
| 26. Stop Hook & Mandatory Reporting | v4.0 | 4/4 | Complete | 2026-04-14 |
| 27-29. v2.0 Gap Closure | v2.0 gap | 6/6 | Complete | 2026-04-14 |
