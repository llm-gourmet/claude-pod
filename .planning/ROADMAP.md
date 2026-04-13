# Roadmap: claude-secure

## Milestones

- v1.0 MVP -- Phases 1-11 (shipped 2026-04-11)
- v2.0 Headless Agent Mode -- Phases 12-17 (shipped 2026-04-12)
- v3.0 macOS Support -- Phases 18-22 (in progress)

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

### v3.0 macOS Support (In Progress)

- [ ] **Phase 18: Platform Abstraction & Bash Portability** - Shared platform detection library and BSD/bash 3.2 portability fixes across all host scripts
- [ ] **Phase 19: Docker Desktop Compatibility** - Compose topology and validator image work correctly under Docker Desktop on macOS
- [ ] **Phase 20: Network Enforcement on macOS** - Empirical spike resolves iptables-vs-pf, then implements network-level call enforcement
- [ ] **Phase 21: launchd Service Management** - Webhook listener and reaper run as LaunchDaemons; installer completes end-to-end on macOS
- [ ] **Phase 22: macOS Integration Tests** - TCP-level block tests and launchd lifecycle tests verify v3.0 against silent-failure modes

## Phase Details

### Phase 18: Platform Abstraction & Bash Portability
**Goal**: Every host script can detect its platform and runs reliably on macOS without silent BSD/bash 3.2 misbehavior
**Depends on**: Nothing (first v3.0 phase, foundation for all later phases)
**Requirements**: PLAT-02, PLAT-03, PLAT-04, PORT-01, PORT-02, PORT-03, PORT-04, TEST-01
**Success Criteria** (what must be TRUE):
  1. Any host script can source `lib/platform.sh` and call `detect_platform()` to receive `linux`, `wsl2`, or `macos`; `CLAUDE_SECURE_PLATFORM_OVERRIDE` forces a value for CI mocking
  2. Running the installer on macOS without Homebrew exits with an actionable message naming the missing tool and the exact `brew install` command to run
  3. Installer bootstraps GNU bash, coreutils, and jq via `brew install` before any other macOS step, and refuses to proceed if any are missing afterward
  4. Every host-side script runs cleanly on a fresh macOS shell: GNU coreutils are PATH-shimmed, bash 4+ syntax re-execs into brew bash 5, BSD `uuidgen` output is normalized to lowercase, and no `flock` calls remain
  5. Linux CI exercises the macOS code paths via `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` and the platform-detection unit tests pass on both real and mocked platforms
**Plans**: 5 plans
  - [ ] 18-01-PLAN.md — Wave 0: lib/platform.sh + Phase 18 test scaffolding + Phase 17 mkdir-lock test rewrite (PLAT-02, TEST-01)
  - [ ] 18-02-PLAN.md — Wave 1: install.sh macOS Homebrew bootstrap (PLAT-03, PLAT-04)
  - [ ] 18-03-PLAN.md — Wave 2: bin/claude-secure + run-tests.sh bash 4+ re-exec prologue (PORT-01, PORT-02)
  - [ ] 18-04-PLAN.md — Wave 3: flock removal + uuidgen lowercase normalization (PORT-03, PORT-04)
  - [ ] 18-05-PLAN.md — Wave 4: install.sh prologue + final TEST-01 macOS-override sub-suite

### Phase 19: Docker Desktop Compatibility
**Goal**: The existing Docker Compose stack boots and runs the four security layers correctly on Docker Desktop for Mac
**Depends on**: Phase 18
**Requirements**: PLAT-05, COMPAT-01
**Success Criteria** (what must be TRUE):
  1. Installer verifies Docker Desktop ≥ 4.44.3 is installed and running on macOS, and warns or blocks with a clear upgrade message if older
  2. Validator container builds from `python:3.11-slim-bookworm` on all platforms and starts cleanly under Docker Desktop without `iptables who?` errors
  3. A smoke test on macOS confirms the claude container boots, the proxy is reachable, the hook fires, and a call-ID is registered with the validator end-to-end
**Plans**: TBD

### Phase 20: Network Enforcement on macOS
**Goal**: Non-whitelisted outbound calls are blocked at the network layer on macOS via the enforcement strategy chosen by the empirical spike
**Depends on**: Phase 19
**Requirements**: ENFORCE-01, ENFORCE-02
**Success Criteria** (what must be TRUE):
  1. A 90-minute empirical spike on real macOS hardware tests iptables inside a Docker Desktop container with `NET_ADMIN` + bridge networking and produces a written decision (Option A: iptables stays in container, Option B: host-side pf, or Option C: proxy chokepoint)
  2. The chosen enforcement implementation is wired into the validator path and self-verifies on startup — a test rule is inserted and confirmed present, failing loudly if the kernel silently drops it
  3. A non-whitelisted domain reached from inside the claude container is rejected at the TCP layer (not just at HTTP), confirming enforcement is real and not a silent bypass
**Plans**: TBD

### Phase 21: launchd Service Management
**Goal**: The webhook listener and container reaper run as boot-persistent LaunchDaemons on macOS, and the installer completes the full claude-secure install path end-to-end
**Depends on**: Phase 20
**Requirements**: PLAT-01, SVC-01, SVC-02, SVC-03, SVC-04
**Success Criteria** (what must be TRUE):
  1. A user runs a single installer command on macOS and ends up with a working claude-secure: containers built, dependencies bootstrapped, daemons loaded, ready to spawn
  2. Webhook listener runs as `com.claude-secure.webhook` LaunchDaemon under `/Library/LaunchDaemons/`, root:wheel 0644, installed via `launchctl bootstrap system` and removed via `launchctl bootout system` (never deprecated `load`/`unload`)
  3. Container reaper runs as `com.claude-secure.reaper` LaunchDaemon and removes orphaned containers on its schedule, replacing the systemd timer used on Linux
  4. If the Phase 20 spike chose host-side pf enforcement, a one-shot `com.claude-secure.pf-loader` LaunchDaemon restores the pf anchor on boot; if pf was not chosen, this daemon is omitted from the install
**Plans**: TBD

### Phase 22: macOS Integration Tests
**Goal**: Automated tests cover the macOS code paths so silent-failure modes are caught before users hit them
**Depends on**: Phase 21
**Requirements**: TEST-02, TEST-03
**Success Criteria** (what must be TRUE):
  1. An integration test attempts a non-whitelisted call from inside the claude container on macOS and asserts the call is blocked at the network layer (TCP reject or HTTP 403, depending on the enforcement choice from Phase 20)
  2. An integration test installs the launchd daemons, verifies they survive a simulated reboot via `launchctl bootout`/`bootstrap` cycle, uninstalls cleanly, and confirms no zombie pf anchors remain on the host (when applicable)
  3. The full v3.0 test suite is added to the pre-push hook test selection so any change touching macOS code paths runs the tests automatically
**Plans**: TBD

## Progress

**Execution Order:**
v3.0 phases execute strictly in numeric order: 18 -> 19 -> 20 -> 21 -> 22
(Phase 20 is gated on Phase 19's Docker Desktop smoke test; Phase 21 cannot start until Phase 20 commits to an enforcement option.)

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
| 12. Profile System | v2.0 | 2/2 | Complete | 2026-04-11 |
| 13. Headless CLI Path | v2.0 | 3/3 | Complete | 2026-04-11 |
| 14. Webhook Listener | v2.0 | 4/4 | Complete | 2026-04-12 |
| 15. Event Handlers | v2.0 | 4/4 | Complete | 2026-04-12 |
| 16. Result Channel | v2.0 | 4/4 | Complete | 2026-04-12 |
| 17. Operational Hardening | v2.0 | 4/4 | Complete | 2026-04-12 |
| 18. Platform Abstraction & Bash Portability | v3.0 | 0/0 | Not started | - |
| 19. Docker Desktop Compatibility | v3.0 | 0/0 | Not started | - |
| 20. Network Enforcement on macOS | v3.0 | 0/0 | Not started | - |
| 21. launchd Service Management | v3.0 | 0/0 | Not started | - |
| 22. macOS Integration Tests | v3.0 | 0/0 | Not started | - |
