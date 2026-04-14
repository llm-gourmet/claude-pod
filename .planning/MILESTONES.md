# Milestones

## v4.0 Agent Documentation Layer (Shipped: 2026-04-14)

**Phases completed:** 15 phases, 49 plans, 79 tasks

**Key accomplishments:**

- Complete rewrite of bin/claude-secure from instance system to profile system with JSON config, fail-closed validation, superuser merge mode, and 19 passing tests
- Updated install.sh to create profiles/default/ with JSON config and routed test-map.json to test-phase12.sh
- spawn subcommand with --event/--event-file/--prompt-template/--dry-run parsing, cs-profile-uuid8 ephemeral naming, and 16-test scaffold for HEAD-01 through HEAD-05
- Headless Claude Code execution via docker compose exec -T with JSON output envelope, max-turns forwarding, dry-run mode, and documented --bare exclusion for security
- resolve_template + render_template functions with 6-variable substitution from event JSON, multiline ISSUE_BODY via awk, wired into spawn flow
- One-liner:
- One-liner:
- Standalone systemd unit file for the claude-secure webhook listener with D-25 directives locked verbatim and hardening omissions justified inline
- `install.sh --with-webhook` installs the webhook listener as a root systemd service idempotently, with sentinel path substitution and a WSL2 warn-don't-block gate.
- 28-test Nyquist self-healing harness with 9 regression fixtures encoding Pitfalls 1/4/7, establishing the red-green contract for Phase 15 event handlers
- 1. [Rule 3 - Blocking] Expand resolve_profile_by_repo return fields
- bin/claude-secure gains D-16 variable rendering via awk, a default-template fallback chain, UTF-8-safe payload extraction, and a `replay <delivery-id>` subcommand — eliminating the latent Pitfall 1/4/6/7 regressions and unblocking 15 of the 16 new Phase 15 tests.
- One-liner:
- Scaffold invariants (3 — MUST PASS in Wave 0):
- RED
- 1. [Rule 3 - Blocking] Added `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` escape
    hatch

- 1. [Rule 2 - Critical correctness] Added explicit `chmod 755` on the report-templates directory
- Nyquist failing-test scaffold for Phase 17: 26 reaper+hardening unit sentinels, 4 E2E scenario sentinels, budget gate, and the profile-e2e fixture tree -- all ready for Waves 1a/1b/2 to flip green.
- Container reaper (OPS-03) implemented: `claude-secure reap` runs a flock-guarded single-flight cycle that label-scopes orphan spawn projects by instance prefix, ages them via docker inspect, tears them down with `docker compose down -v --remove-orphans --timeout 10`, sweeps stale event files under `$CONFIG_DIR/events/`, and logs three lines to the systemd journal per cycle. The same commit wave adds the reaper.service + reaper.timer systemd units and atomically extends BOTH webhook.service and reaper.service with the 10 D-11 safe-subset hardening directives.
- Four D-14 E2E scenarios flipped from Wave 0 sentinels to live executions driving the real Phase 14 listener subprocess + FAKE_CLAUDE_STDOUT stub + file:// bare report repo, completing in 15 seconds vs the 90-second budget — and uncovered two production bugs in Phase 16/17 code that would have bitten real concurrent operator workloads.
- install.sh now ships the Phase 17 reaper systemd units and timer alongside the webhook listener (subject to the same WSL2 systemd gate), and prints the D-18 post-install hint for journal tailing. README.md gains a natural-prose operator section between Phase 16 and Testing covering reaper behavior, tuning knobs, manual invocation, and the upgrade path from Phase 16. Three installer-static unit tests flipped from red to green; the Phase 17 unit suite is now 31/31. Phase 17 is complete.
- Wave 0 ships lib/platform.sh (bash 3.2-safe platform detection + PATH bootstrap) and tests/test-phase18.sh harness with 10 real assertions and 6 stubs for downstream plans, plus retires the Phase 17 flock binary mock in favor of mkdir-lock contention assertions.
- bin/claude-secure and run-tests.sh now re-exec into brew bash 5 on Apple bash 3.2 hosts before any bash 4+ syntax parses, and source lib/platform.sh so plain `date`/`stat`/`readlink`/`realpath`/`sed`/`grep` resolve to GNU coreutils on macOS.
- do_reap in bin/claude-secure now uses an mkdir-based atomic lock with a PID-file stale-reclaim path (replacing util-linux flock), and the claude container hook pipes uuidgen through tr to lowercase the call-id defensively — retiring the two macOS-incompatible primitives identified by the Phase 18 research audit.
- 1. [Rule 3 - Blocker] Rewrote bash 3.2 safety comment to remove literal `[[`
- One-liner:
- Pinned validator base to python:3.11-slim-bookworm and added iptables_probe() startup diagnostic that logs OK/FAIL before setup_default_iptables, replacing two test stub functions with real grep assertions
- macOS Docker Desktop >= 4.44.3 version gate added to install.sh with three fixture-driven unit tests replacing PLAT-05 stubs
- Wave 0 Nyquist test scaffold with 17 test functions (2 green baseline + 15 RED stubs), two fixture profiles (new docs schema + legacy alias schema), and test-map.json registration for all four Phase 23 requirements.
- BIND-01/02/03 implemented: validate_docs_binding (URL/token validation), project_env_for_containers (host-only token projection filtering DOCS_REPO_TOKEN from docker-compose env_file), and resolve_docs_alias (legacy report_repo/REPORT_REPO_TOKEN backcompat with rate-limited deprecation warning)
- 1. [Rule 1 - Bug] validate_profile rejects file:// URLs used in DOCS-01 tests
- Wave 0 Nyquist self-healing scaffold for Phase 24 publishing: 13-test harness (2 GREEN + 11 RED sentinels), 4 attack-vector bundle fixtures, profile-24-bundle .env with DOCS_REPO_TOKEN and SEEDED_SECRET, canonical 6-section bundle.md template, and 7 new RPT/DOCS requirement entries in test-map.json.
- Two reusable library helpers in bin/claude-secure: verify_bundle_sections() anchors-checks the 6 mandatory H2 sections of a rendered report body, and sanitize_markdown_file() strips 4 exfiltration vectors (HTML comments, raw HTML tags, external inline images, external reference-style image defs) while preserving local image refs.
- One-liner:
- Host-side sparse+shallow+partial clone of doc-repo project subtree with PAT scrubbing, realpath normalization, and structural .git/ exclusion by mount-source subdirectory targeting.
- Two add-only insertions in `bin/claude-secure` complete the Phase 25 context-read bind-mount pipeline: do_spawn fails closed, interactive path warns and continues, full 15-test Phase 25 suite green.
- Container-ready poll loop and exec-health guard in test-phase25.sh close WSL2 false-negative and false-positive races in docker-gated integration tests
- stop-hook.sh (56 lines): local-only spool verification with recursion guard, 6-H2 re-prompt JSON, and zero network calls; registered in settings.json under Stop event
- 1. [Rule 1 - Bug] Fixed jq `select()` in object context
- Backfill VERIFICATION.md files for Phase 12 (3/3 PROF requirements) and Phase 13 (5/5 HEAD requirements) using SUMMARY.md commit evidence — closing the v2.0 verification gap for both phases
- Updated frontmatter flags in 6 VALIDATION.md files (phases 12-17) from draft/false to complete/true, and fixed 5 stale traceability entries in REQUIREMENTS.md (PROF-01/03 checkboxes, OPS-01/02/PROF-01/03 Pending→Complete)
- 1. [Rule 3 - Blocking] Seed `projects/test-alias/` into bare remote before invoking do_spawn
- Commit:
- Commit:

---

## v1.0 MVP (Shipped: 2026-04-11)

**Phases completed:** 10 phases, 21 plans, 39 tasks

**Key accomplishments:**

- Dual-network Docker topology with 3 container stubs, DNS exfiltration blocking, capability dropping, and root-owned immutable security configuration
- 10-test bash integration suite verifying Docker network isolation, DNS blocking, capability dropping, file permissions, and whitelist configuration
- SQLite-backed call validator with iptables OUTPUT DROP policy enforced via shared Docker network namespace
- Full PreToolUse hook with domain extraction from curl/wget/WebFetch, whitelist enforcement, obfuscation detection, and call-ID registration via validator
- 13-test integration suite verifying hook interception, domain blocking, call-ID registration/single-use/expiry, and iptables enforcement in live Docker topology
- Buffered proxy with per-request whitelist reload, secret-to-placeholder redaction in outbound bodies, placeholder-to-secret restoration in inbound bodies, and OAuth/API-key auth forwarding
- 8-test integration suite proving secret redaction, placeholder restoration, config hot-reload, and auth forwarding via mock upstream in Docker
- Bash installer with dependency preflight, WSL2/Docker Desktop detection, OAuth/API key auth, and CLI wrapper with four subcommands
- 12 integration tests covering installer dependency checking, platform detection, auth setup, directory permissions, Docker builds, CLI wrapper validation, and container topology verification
- Integration test script verifying all 7 LOG requirements via Docker Compose with enabled/disabled logging and JSON structure validation
- Dynamic secret loading via Docker Compose env_file on proxy service, eliminating hardcoded secret var names from docker-compose.yml
- Integration tests proving env_file secret loading works for all 5 ENV requirements using Docker compose exec container inspection
- Expanded Claude container from minimal node:22-slim to full dev environment with git, gcc/make, Python3/pip/venv, ripgrep, and fd-find
- Removed hardcoded container_name directives and added LOG_PREFIX/WHITELIST_PATH parameterization across all services for COMPOSE_PROJECT_NAME-based multi-instance isolation
- Multi-instance CLI via --instance NAME flag with auto-create, migration, list/remove commands, and installer creating instances/default/ layout
- 9 integration tests covering instance flag parsing, DNS validation, migration, compose isolation, LOG_PREFIX, list command, and config scoping
- Migrated 52 docker exec calls to docker compose exec across 5 test scripts and created test-map.json with 15 path-to-test mappings plus test.env with dummy credentials
- Production-ready pre-push hook with jq-based test selection from test-map.json, dedicated claude-test compose instance, clean-state teardown between suites, and PASS/FAIL summary table with requirement IDs
- Closed v1.0 audit gaps: test-map.json coverage expanded to 3 cross-cutting source files, all 41 requirements marked Complete, /validate documented as debug-only

---
