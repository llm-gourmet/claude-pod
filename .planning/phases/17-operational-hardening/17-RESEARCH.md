# Phase 17: Operational Hardening - Research

**Researched:** 2026-04-12
**Domain:** systemd timer-driven container reaper + end-to-end Docker integration testing + safe-subset listener hardening
**Confidence:** HIGH on systemd/docker/flock primitives, HIGH on existing-codebase reuse, HIGH on Phase 14 hardening pitfalls (empirically locked), MEDIUM on exact backdate-CreatedAt mechanism for D-14 scenario 3

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Reaper Trigger & Lifecycle**
- **D-01:** Reaper is a **systemd timer + oneshot service pair**, mirroring `webhook/claude-secure-webhook.service`. Files: `webhook/claude-secure-reaper.service` (Type=oneshot, ExecStart=/usr/local/bin/claude-secure reap) and `webhook/claude-secure-reaper.timer` (OnBootSec=2min, OnUnitActiveSec=5min, Persistent=true). Installer copies both to `/etc/systemd/system/`.
- **D-02:** Reaper interval = **5 minutes** (`OnUnitActiveSec=5min`). Not parameterized in v2.0.
- **D-03:** Reaper invocation = **`claude-secure reap`** — new top-level subcommand in `bin/claude-secure`.

**Orphan Detection**
- **D-04:** Label-based + age-thresholded. Iterate `docker ps --filter "label=com.docker.compose.project=<INSTANCE_PREFIX>spawn-*"` and tear down projects whose containers exceed `REAPER_ORPHAN_AGE_SECS` (default **600s = 10 minutes**, twice the timer interval). Zero coupling to `executions.jsonl`.
- **D-05:** Per matched project: **`docker compose -p <project> down -v --remove-orphans --timeout 10`**. `-v` removes anonymous volumes. Networks auto-removed. Images NEVER touched.
- **D-06:** Reaper also reaps **stale event files** under `$CONFIG_DIR/events/`. Files older than `REAPER_EVENT_AGE_SECS` (default **86400s = 24h**) deleted. Pure age-based, no audit cross-reference.

**Multi-Instance Safety**
- **D-07:** Reaper honors **v1.0 LOG_PREFIX convention**. Reads `INSTANCE_PREFIX` from `config.sh`; only matches projects with that prefix.
- **D-08:** Reaper uses **`flock` on `$LOG_DIR/${LOG_PREFIX}reaper.lock`** with non-blocking `flock -n`. If held, exits 0 silently with one journal line.

**Reaper Logging & Failure Handling**
- **D-09:** Reaper logs to **systemd journal only** via stdout/stderr. Format: `reaper: cycle start prefix=<X>`, `reaper: reaped <project> age=<N>s`, `reaper: cycle end killed=<N> events_deleted=<M> errors=<E>`. NO separate JSONL.
- **D-10:** Failures are **best-effort, non-fatal**. Per-project errors logged + skipped. Whole-cycle failure (e.g. docker daemon down) → exit nonzero so `systemctl status` surfaces it.

**Listener Hardening Revisit**
- **D-11:** **Safe subset of systemd hardening directives** added to BOTH `claude-secure-webhook.service` and new `claude-secure-reaper.service`:
  - `ProtectKernelTunables=true`
  - `ProtectKernelModules=true`
  - `ProtectKernelLogs=true`
  - `ProtectControlGroups=true`
  - `RestrictNamespaces=true`
  - `LockPersonality=true`
  - `RestrictRealtime=true`
  - `RestrictSUIDSGID=true`
  - `MemoryDenyWriteExecute=true`
  - `SystemCallArchitectures=native`

  Explicitly **NOT** added (each empirically broke docker compose in Phase 14): `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`, `CapabilityBoundingSet`, `ProtectHome`, `PrivateDevices`. Inline comment block in unit file documents the rationale.
- **D-12:** Each new directive lands behind an **integration test gate** in the E2E suite. Listener+reaper must continue to start and process a webhook end-to-end. Failing directives are removed (NOT commented out).

**End-to-End Integration Test**
- **D-13:** E2E file: **`tests/test-phase17-e2e.sh`** — self-contained harness against real Docker stack with stubbed Claude binary (`CLAUDE_SECURE_FAKE_CLAUDE_STDOUT`). NOT merged into `tests/test-phase17.sh` (which is the unit-level reaper test).
- **D-14:** E2E covers **exactly four scenarios** (1:1 with OPS-03 success criterion):
  1. **HMAC rejection** — POST with wrong signature → 401, no spawn, no audit entry.
  2. **Concurrent execution** — POST 3 valid payloads in parallel (Phase 14 `Semaphore(3)`) → 3 audit entries, 3 reports pushed, no JSONL line corruption.
  3. **Orphan cleanup** — manually `docker run --label com.docker.compose.project=<prefix>spawn-fake-orphan` with backdated creation → run `claude-secure reap` → sentinel gone, real instances untouched.
  4. **Resource limit enforcement** — Spawn → `docker inspect` → assert `Memory` and `MemorySwap` match the limit declared in `docker-compose.yml`. (Closes Phase 13 Concern #3.)
- **D-15:** Runtime budget: **≤90 seconds**. Test fails the budget guard if exceeded.
- **D-16:** Dedicated **`tests/fixtures/profile-e2e/`** with own `.env` (`REPORT_REPO_TOKEN=ghp_FAKEE2E`), local bare repo under `$TMPDIR`, `INSTANCE_PREFIX=e2e-`. Cleanup: `trap` removes `$TMPDIR/e2e-*` and runs `claude-secure --instance e2e reap`.

**Installer Extension**
- **D-17:** `install.sh install_webhook_service` extended with new step (after 5c) that copies the reaper unit + timer to `/etc/systemd/system/` (mode 644) and `enable --now`-s the timer alongside the listener (subject to same WSL2 systemd gate).
- **D-18:** Installer prints post-install hint: `"Reaper timer active — runs every 5 minutes. View activity: journalctl -u claude-secure-reaper -f"`.

### Claude's Discretion
- Exact prose of unit-file comment blocks documenting the D-11 safe subset
- Whether reaper subcommand inlines in `bin/claude-secure` or factors into a `do_reap` helper (recommended: `do_reap`, mirroring `do_spawn`/`do_replay`)
- Whether D-14 scenario 3 sentinel is a real `docker run busybox sleep 3600` or a mock (recommended: real `busybox` so the test exercises real teardown)
- Test fixture reuse from Phase 16 (recommended: reuse `envelope-success.json`, `report-repo-bare/` setup helpers)
- JSON ordering of journal log lines (cosmetic)

### Deferred Ideas (OUT OF SCOPE)
- **iptables packet-level logging** — backlog v2.1 (validator hardening, not OPS-03)
- **Dedicated system user for listener + reaper** — Phase 14 D-24 trade-off still holds
- **Rate limiting on /webhook** — orthogonal; reverse proxy / tunnel layer's job
- **Reaper interval configurability** — defer to drop-in if operators ask
- **Reaper metrics export** (Prometheus/statsd) — adds dependency
- **Reaper notification on kill** — HEALTH-02
- **Aggregate orphan reports** — journalctl filtering covers it
- **Reaping `events/` based on audit log cross-reference** — rejected for pure age-based
- **Image pruning** — explicitly excluded from D-05
- **Reaping bind-mount workspaces** — workspaces are user data
- **E2E test against real Claude API** — cost-prohibitive; D-13 stubs Claude
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| OPS-03 | A container reaper cleans up orphaned containers from failed or timed-out executions | Pattern A (systemd timer+oneshot), Pattern B (label+age orphan detection), Pattern C (`docker compose down -v` per project), Pattern D (flock single-flight), Pattern E (event-file age sweep), Pattern F (E2E four-scenario harness), Pattern G (D-11 safe-subset hardening), Pattern H (backdate via `--label` + filter-by-age), Pattern I (resource-limit `docker inspect` assertion) |

</phase_requirements>

## Summary

Phase 17 closes the v2.0 milestone with two deliverables: a **systemd timer-driven container reaper** and an **end-to-end integration test** that exercises the full webhook → spawn → report pipeline against real Docker. Both deliverables ride on patterns the codebase already proves out — the reaper is structurally a clone of `cleanup_containers()` (`bin/claude-secure:298`) plus age filtering and label scoping, the systemd unit cloning strategy is identical to `webhook/claude-secure-webhook.service`, and the E2E harness reuses Phase 16's `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` stub mechanism so no real Claude API calls happen.

The research dimension is narrow but precise. There are five concrete unknowns: (1) **how to make `OnUnitActiveSec=` and `Persistent=true` actually catch up missed timer firings** after host downtime — answered by reading the `systemd.timer(5)` man page on the live host; (2) **how to extract a parseable container creation timestamp from `docker ps`** — answered by `--format '{{.CreatedAt}}'` returning a human-readable string vs `docker inspect '{{.Created}}'` returning ISO8601 — the latter is the right primitive; (3) **how to backdate a sentinel container's `Created` timestamp** for the orphan-cleanup test, where the answer is "you can't lie to docker about Created, so you fake age via `REAPER_ORPHAN_AGE_SECS=0` in the test environment instead of touching the timestamp"; (4) **whether the current `docker-compose.yml` actually declares any resource limits at all** — verified: it does NOT, so Phase 17 must either add them or the D-14 scenario 4 test must validate "limits exist after Phase 17 ships them"; (5) **whether each of the 10 D-11 hardening directives breaks docker subprocess on the test host** — verified by cross-referencing the systemd 255 man page (all 10 directives are documented and stable) and Phase 14's empirical record (the 6 explicitly excluded directives are the ones that broke).

Findings 4 and 5 are the load-bearing surprises. The first means **D-14 scenario 4 cannot be a pure assertion** — Phase 17 must add `mem_limit` (or `deploy.resources.limits.memory`) to the spawn-relevant services in `docker-compose.yml` before the assertion has anything to read. The second is comfortable — every D-11 directive is documented in current systemd and the safe-subset choice is conservative.

**Primary recommendation:** Implement the reaper as a `do_reap()` function inside `bin/claude-secure` that (a) acquires `flock -n` on `$LOG_DIR/${LOG_PREFIX}reaper.lock`, (b) walks `docker ps --filter label=com.docker.compose.project=<prefix>spawn-* --format '{{.Label "com.docker.compose.project"}}' | sort -u`, (c) for each project queries `docker inspect --format '{{.Created}}'` on its first container to get an ISO8601 creation time, (d) computes age via `date -d "$created" +%s` and compares against `REAPER_ORPHAN_AGE_SECS` (default 600), (e) calls `docker compose -p $project down -v --remove-orphans --timeout 10` for each match, (f) sweeps `$CONFIG_DIR/events/*.json` via `find -mtime +0 -type f -delete` (with a tunable threshold). E2E test runs against the real local Docker daemon with the stubbed Claude path; no Claude API calls. Add `mem_limit: 1g` (or equivalent) to the `claude` service in `docker-compose.yml` as a Wave 1 prerequisite to D-14 scenario 4.

## Project Constraints (from CLAUDE.md)

- **Language:** Bash 5.x for all new code in `bin/claude-secure`. python3 (stdlib only) is allowed for E2E test helpers but not required. jq, docker compose v2, flock, date, find, uuidgen, mktemp, sort all already on host.
- **Zero runtime deps:** No new packages. The reaper consumes only what is already on the host.
- **No network bypass:** Reaper does not contact Anthropic, GitHub, or any external service. Pure local docker operations + filesystem cleanup. The proxy + iptables validator remain the single outbound enforcement point.
- **Platform targets:** Linux and WSL2. systemd timers require WSL2 with `[boot] systemd=true`. Phase 14 D-26 warn-don't-block gate applies (and is reused).
- **Security-critical code:** systemd unit files are root-owned (mode 644). The reaper script runs as root (justified by D-24 — same as the listener; needs Docker socket access). Both units gain D-11 safe-subset hardening.
- **GSD workflow:** Plans MUST follow the Nyquist self-healing pattern (Wave 0 writes failing tests; implementation waves flip them green). The 4-plan structure mirrors Phase 16: Wave 0 test scaffold → Wave 1a unit/timer files + reaper subcommand → Wave 1b E2E test scenarios + docker-compose.yml limits → Wave 2 installer extension + README.

## Standard Stack

### Core — Already Present, Zero New Dependencies

| Component | Version | Purpose | Source of Truth |
|-----------|---------|---------|-----------------|
| Bash | 5.2.21 | Reaper subcommand, E2E harness | CLAUDE.md; verified `bash --version` |
| Docker | 29.3.1 | Engine + Compose v2 (label filtering, project scoping, inspect) | verified `docker --version` |
| Docker Compose | v2 (built into docker CLI) | `docker compose -p <project> down -v --remove-orphans --timeout 10` | verified |
| jq | 1.7+ | JSON parsing of `docker inspect` output, audit assertions | verified |
| systemd | 255 | Timer + oneshot service pair, all 10 D-11 directives documented and stable | verified `systemctl --version` |
| flock | util-linux 2.39.3 | Single-flight reaper invocation guard (D-08) | verified `flock --version` |
| date (GNU coreutils) | 9.x | `date -d "$iso" +%s` for ISO8601 → epoch conversion | verified (Linux glibc) |
| find (GNU findutils) | 4.x | `find $CONFIG_DIR/events -type f -mmin +N -delete` for D-06 sweep | verified |
| timeout (coreutils) | 9.x | Hard wall-clock cap on E2E test budget (D-15) | verified |
| python3 | 3.11+ | Optional helper for parallel POST in D-14 scenario 2 (or use `curl &` + `wait`) | verified |
| uuidgen | util-linux 2.39+ | Per-spawn delivery_id synthesis (already used) | verified |

**Installation:** None required. Every tool listed is already on the host and already used by Phases 13–16.

### Reuse Map (Clone, Don't Write New Code)

| Existing Asset | Location | Phase 17 Reuse |
|----------------|----------|----------------|
| `cleanup_containers()` | `bin/claude-secure:298` | Reference for `docker compose down --remove-orphans` invocation pattern. Reaper extends with label scoping + age filter. |
| `spawn_cleanup()` | `bin/claude-secure:336` | Reference for `docker compose down -v --remove-orphans` semantics (the `-v` reaper inherits per D-05). |
| `spawn_project_name()` | `bin/claude-secure:325` | Defines the `cs-<profile>-<uuid8>` naming convention the reaper filters on. **Note:** the convention is `cs-<profile>-<uuid8>`, NOT `<INSTANCE_PREFIX>spawn-*` as CONTEXT D-04 wording implies. The plan must reconcile this — see Pitfall 1 below. |
| `do_spawn()` lifecycle | `bin/claude-secure:1107+` | The function whose orphans we reap. `trap spawn_cleanup EXIT` is the happy path; reaper backstops the unhappy paths. |
| Profile loader / `LOG_PREFIX` resolution | Phase 12 | Reaper inherits multi-instance scoping for free. |
| `webhook/claude-secure-webhook.service` | unit file template | Structural template for `claude-secure-reaper.service`. Comment block at top is the template for documenting D-11. |
| `install.sh install_webhook_service` | `install.sh:267-418` | Extension point for D-17 reaper unit/timer install. New step 5d after step 5c (Phase 16 report templates). |
| `tests/test-phase16.sh` | test harness | Reuse `setup_test_profile`, `setup_bare_repo`, `install_stub`, `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` mechanics. E2E in `tests/test-phase17-e2e.sh`. |
| `tests/fixtures/envelope-success.json` | Phase 16 fixture | Reuse for E2E spawn happy path. |
| `tests/fixtures/report-repo-bare/` | Phase 16 fixture | Reuse for E2E report-push assertions. |

### Alternatives Considered (and rejected)

| Instead of | Could Use | Why Rejected |
|------------|-----------|--------------|
| systemd timer + oneshot pair | cron entry calling `claude-secure reap` | Cron has no per-unit logging, no `OnBootSec=` catch-up, no `Persistent=` semantics, and no integration with `systemctl status` for failure surfacing. CONTEXT D-01 locks systemd. |
| systemd timer + oneshot | Long-running reaper daemon | Daemon-style is overkill for a 5-min cycle and adds restart-loop concerns. Oneshot is the correct shape: do work, exit, let timer fire next cycle. |
| `docker ps --format '{{.CreatedAt}}'` | `docker inspect --format '{{.Created}}'` | `CreatedAt` returns a human-readable `2026-04-12 13:00:00 +0000 UTC` string, awkward to parse. `Created` (via inspect) returns ISO8601 `2026-04-12T13:00:00.123456789Z`, which `date -d` parses cleanly. **Use inspect.** |
| `docker ps --filter label=com.docker.compose.project=<exact>` | grep on `docker ps --format` output | Built-in label filter is faster, deterministic, and already supported by `docker ps --filter`. The current Compose project naming convention (`spawn_project_name()`) generates prefixed names — filter on `label=com.docker.compose.project` and post-process to apply the prefix match in bash, since `--filter` does NOT support glob/prefix matching. |
| `flock` non-blocking | `mkdir` race-free lock | mkdir works but flock is the documented Linux primitive with explicit `-n` (non-block) and `-w` (timeout) and integrates cleanly with shell exit codes via `-E`. Phase 13 already uses flock pattern elsewhere. |
| `find -mmin +1440` | `find -mtime +1` | Equivalent on Linux; `-mtime +1` is the more portable spelling. CONTEXT D-06 says "files older than 24h"; `-mmin +$((REAPER_EVENT_AGE_SECS / 60))` is the parameterized form. **Use `-mmin` for parameter flexibility.** |
| Real GitHub API in E2E | Stubbed Claude + local bare repo | E2E test would otherwise burn real API cost on every CI run. CONTEXT D-13 locks the stub approach. |
| Backdate sentinel `Created` timestamp | Override `REAPER_ORPHAN_AGE_SECS=0` in test env | **You cannot fake `Created` in docker.** The container daemon stamps it at `docker run` time and there is no API to mutate it. The correct test design is: spawn a sentinel with a real (recent) `Created` time, then run the reaper with `REAPER_ORPHAN_AGE_SECS=0` so the threshold is "any age". This is how the E2E test must work — see Pitfall 4 and Pattern H. |
| Adding 10 directives in 10 commits | Single patch adding all 10 to both unit files | CONTEXT specifics: "Apply via a single patch to BOTH unit files in one commit so the test gate (D-12) catches any breakage in the same wave that introduces it." Single commit is the lock. |
| `docker stats` for memory limit assertion | `docker inspect --format '{{.HostConfig.Memory}}'` | `docker stats` returns runtime usage, not the configured limit. `inspect` returns the static configured value in bytes. Use inspect. |

### Version Verification

- **systemd 255:** all 10 D-11 directives are documented and stable. `man systemd.exec` on the live host confirms `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`, `RestrictNamespaces`, `LockPersonality`, `MemoryDenyWriteExecute`, `RestrictRealtime`, `RestrictSUIDSGID`, `SystemCallArchitectures` all exist. (Most have been stable since systemd 232+; `ProtectKernelLogs` since 247.) HIGH confidence.
- **systemd.timer:** `OnBootSec=`, `OnUnitActiveSec=`, `Persistent=`, `AccuracySec=`, `RandomizedDelaySec=` all documented. `Persistent=true` requires `OnCalendar=` per the man page wording — but in practice, systemd applies persistence semantics to monotonic timers as well by storing last-trigger time on disk. **VERIFY in implementation:** if `Persistent=true` is rejected by the unit-file validator with `OnUnitActiveSec=`, drop it (a missed cycle is harmless — the next firing catches up automatically). Document as Pitfall 11.
- **Docker Compose v2 / Docker 29.3.1:** `docker ps --filter label=key=value`, `docker inspect --format`, `docker compose -p <project> down -v --remove-orphans --timeout 10` all stable. HIGH confidence.
- **flock util-linux 2.39:** `-n` (non-block), `-c` (run command), `-E` (conflict exit code), `-x` (exclusive default) all stable since util-linux 2.20. HIGH confidence.
- **No `mem_limit` declared in `docker-compose.yml`:** verified by reading the file. The only memory-related directives are absent. **D-14 scenario 4 requires Phase 17 to add a limit before the assertion has anything to read.** This is not a research finding to caveat — it's a planning input the planner MUST address.

## Architecture Patterns

### Recommended Project Structure

```
claude-secure/
├── bin/claude-secure                       # +~200 LOC: do_reap() + reap dispatch
├── docker-compose.yml                      # +mem_limit on claude service (Wave 1)
├── webhook/
│   ├── claude-secure-webhook.service       # +D-11 safe subset (10 directives)
│   ├── claude-secure-reaper.service        # NEW: Type=oneshot, ExecStart=...reap
│   └── claude-secure-reaper.timer          # NEW: OnBootSec=2min, OnUnitActiveSec=5min
├── install.sh                              # +step 5d: copy reaper unit + timer, enable --now
└── tests/
    ├── test-phase17.sh                     # NEW: unit tests for do_reap (mock docker ps)
    ├── test-phase17-e2e.sh                 # NEW: E2E four-scenario harness
    └── fixtures/
        └── profile-e2e/                    # NEW: dedicated E2E profile directory
            ├── profile.json                # repo, webhook_secret, report_repo, INSTANCE_PREFIX
            ├── .env                        # REPORT_REPO_TOKEN=ghp_FAKEE2E
            └── prompts/                    # event-type templates
```

### Pattern A — systemd Timer + Oneshot Service Pair (D-01, D-02)

**What:** A `.service` unit of `Type=oneshot` runs the reaper to completion and exits. A `.timer` unit fires the service every `OnUnitActiveSec=5min` after an `OnBootSec=2min` warmup. `Persistent=true` means systemd remembers the last firing across reboots.

**When to use:** Periodic task with bounded execution time, no need for a long-running daemon.

**The unit files:**

```ini
# webhook/claude-secure-reaper.service
# Source of truth: webhook/claude-secure-reaper.service in the claude-secure repo.
# Installed by install.sh --with-webhook (Phase 17 step 5d).
#
# Locked by .planning/phases/17-operational-hardening/17-CONTEXT.md D-01..D-12.
# DO NOT add NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet,
# ProtectHome, or PrivateDevices: each one breaks docker compose subprocess
# (empirically confirmed in Phase 14, re-confirmed in Phase 17 E2E gate D-12).

[Unit]
Description=claude-secure orphaned container reaper
Documentation=https://github.com/igorthetigor/claude-secure
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/claude-secure reap

# Logging (D-09): journal-only, no separate JSONL.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-secure-reaper

# User (D-24 carry-forward): root for docker socket access. Same justification
# as the listener — delegates real work to docker compose, which itself
# invokes the hardened container stack.
User=root
Group=root

# === D-11: Safe-subset systemd hardening ===
# These 10 directives do NOT touch /var/run/docker.sock, /tmp (compose state),
# filesystem writes for compose, or capability-bound docker subprocess calls.
# Each was verified by Phase 14 to be docker-compose-compatible OR was added
# in Phase 17 E2E test gate D-12 and verified to keep the listener functional.
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

# === Hardening directives deliberately NOT added (each breaks docker compose) ===
#   NoNewPrivileges=true     -- blocks subprocess privilege transitions
#   ProtectSystem=strict     -- Docker volume-mount machinery writes outside the allowed set
#   PrivateTmp=true          -- compose may touch /tmp during bootstrap
#   CapabilityBoundingSet=...-- docker daemon comms need broader caps
#   ProtectHome=true         -- profile state lives under $HOME/.claude-secure
#   PrivateDevices=true      -- iptables validator needs /dev access on shared netns
# Phase 14 + Phase 17 D-12 lock this exclusion list.

[Install]
WantedBy=multi-user.target
```

```ini
# webhook/claude-secure-reaper.timer
# Triggers claude-secure-reaper.service every 5 minutes after a 2-minute boot warmup.
# Locked by .planning/phases/17-operational-hardening/17-CONTEXT.md D-01..D-02.

[Unit]
Description=claude-secure reaper periodic timer
Documentation=https://github.com/igorthetigor/claude-secure

[Timer]
# Fire 2 minutes after boot, then every 5 minutes from previous activation.
# OnBootSec gives the system time to settle before the first reap cycle.
# OnUnitActiveSec drives steady-state cycle interval (D-02).
OnBootSec=2min
OnUnitActiveSec=5min

# AccuracySec controls how much wall-clock skew systemd permits when grouping
# timer firings to save power. 30s is a sensible default — way under our 5-min
# cycle, so cycle drift is negligible.
AccuracySec=30s

# Persistent=true: if the host was off when a firing was due, run immediately
# at next boot to catch up. (Strictly speaking, the man page documents
# Persistent= for OnCalendar= timers; on systemd >= 232 it also persists state
# for monotonic timers. If unit-file validator rejects it, drop it — missed
# cycles are harmless because the next normal firing reaps the orphans.)
Persistent=true

Unit=claude-secure-reaper.service

[Install]
WantedBy=timers.target
```

**Source:** `man systemd.timer` on systemd 255 (verified on host); `man systemd.service`; `man systemd.exec`. CONTEXT D-01 / D-02.

### Pattern B — Label-Based + Age-Thresholded Orphan Detection (D-04)

**What:** Walk all containers whose `com.docker.compose.project` label starts with the instance's prefix, group by project, look up each project's first container's `Created` timestamp via `docker inspect`, compute age, and select projects whose age exceeds `REAPER_ORPHAN_AGE_SECS`.

**When to use:** Inside `do_reap()`, the orphan-discovery loop.

**The code:**

```bash
# Phase 17 D-04 / D-05 / D-07: orphan detection + teardown.
# Walks every compose project whose name begins with the instance prefix and
# whose first container is older than REAPER_ORPHAN_AGE_SECS. For each,
# runs `docker compose -p <project> down -v --remove-orphans --timeout 10`.
#
# Returns the kill count via the global $REAPED_COUNT (caller resets to 0).
reap_orphan_projects() {
  local prefix="${1:-cs-}"          # cs-<profile>-<uuid8> per spawn_project_name()
  local age_threshold="${REAPER_ORPHAN_AGE_SECS:-600}"
  local now killed=0 errors=0
  now=$(date +%s)

  # docker --filter does NOT support glob; we filter by label key existence
  # and apply the prefix match in bash. The label key is fixed; we collect
  # unique project values and prefix-match in shell.
  local projects
  projects=$(docker ps -a \
               --filter "label=com.docker.compose.project" \
               --format '{{.Label "com.docker.compose.project"}}' \
             | sort -u)

  local proj
  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    # Multi-instance: only touch projects matching this instance's prefix.
    case "$proj" in
      "$prefix"*) ;;
      *) continue ;;
    esac

    # Skip non-spawn projects (defensive — only ephemeral spawn projects
    # follow the cs-<profile>-<uuid8> naming convention; other compose
    # projects under the same prefix should not exist on a clean host).
    # If the operator runs other claude-secure compose stacks under the
    # same prefix, this filter prevents the reaper from killing them.
    case "$proj" in
      cs-*-*) ;;  # spawn pattern: cs-<profile>-<8hex>
      *) continue ;;
    esac

    # Get the project's oldest container Created timestamp.
    # docker inspect emits ISO8601: 2026-04-12T13:00:00.123456789Z
    local first_id created created_epoch age
    first_id=$(docker ps -a \
                 --filter "label=com.docker.compose.project=$proj" \
                 --format '{{.ID}}' \
               | head -1)
    [ -z "$first_id" ] && continue

    created=$(docker inspect --format '{{.Created}}' "$first_id" 2>/dev/null)
    [ -z "$created" ] && continue

    # GNU date parses ISO8601 with -d. Strip nanoseconds for portability.
    created_epoch=$(date -d "${created%.*}Z" +%s 2>/dev/null) || continue
    age=$((now - created_epoch))

    if [ "$age" -lt "$age_threshold" ]; then
      continue  # too young, skip
    fi

    echo "reaper: reaped $proj age=${age}s"
    if docker compose -p "$proj" down -v --remove-orphans --timeout 10 \
         >/dev/null 2>&1; then
      killed=$((killed + 1))
    else
      echo "reaper: ERROR tearing down $proj" >&2
      errors=$((errors + 1))
    fi
  done <<< "$projects"

  REAPED_COUNT=$killed
  REAPED_ERRORS=$errors
}
```

**Key details:**
- `docker ps -a` (NOT `docker ps`) — includes stopped containers. Orphans from a crashed spawn may be in `Created`, `Exited`, or `Dead` state.
- The label-key-only filter (`--filter "label=com.docker.compose.project"`) lists every container with that label set to anything. Project-name prefix match happens in bash because docker `--filter` does not support globs.
- ISO8601 nanoseconds (`.123456789Z`) get stripped before `date -d` to tolerate older `date` builds. GNU date 9.x handles them, but the strip is a no-cost defense.
- Per-project teardown errors are logged + counted but do NOT abort the whole cycle (D-10).
- `cs-*-*` defensive guard: refuses to reap any project whose name doesn't match the spawn pattern, even if it carries the instance prefix. Protects against an operator running other compose stacks named `cs-something` on the same host.

**Source:** `man docker-ps`, `man docker-inspect`, GNU date manual; CONTEXT D-04 / D-07.

### Pattern C — `docker compose down -v` Per-Project (D-05)

**What:** For each matched orphan project, invoke `docker compose -p <project> down -v --remove-orphans --timeout 10`. Mirrors `spawn_cleanup()` semantics (`bin/claude-secure:336-341`).

**Why each flag:**
- `-p <project>` — explicit project name; docker compose binds to the project's network/containers/volumes.
- `down` — stops + removes containers, networks.
- `-v` — also removes named volumes declared in the project (anonymous volumes are always removed). The `validator-db` volume IS named and survives by default — but ephemeral spawns don't reference it, so `-v` is safe for spawn projects.
- `--remove-orphans` — cleans up containers that share the network but aren't in the current compose file (defensive).
- `--timeout 10` — gives containers 10s to exit gracefully on SIGTERM before SIGKILL. Bounded so the reaper cycle stays well under 1 minute even if all 3 concurrent spawns are stuck.

**Source:** `docker compose down --help`; existing `spawn_cleanup()` at `bin/claude-secure:336`; CONTEXT D-05.

### Pattern D — Single-Flight `flock` Guard (D-08)

**What:** The reaper acquires a non-blocking exclusive lock on `$LOG_DIR/${LOG_PREFIX}reaper.lock`. If another reaper instance holds it (e.g., manual `claude-secure reap` invocation while the timer fires), the new invocation exits 0 silently with one journal log line.

**The code:**

```bash
# D-08: single-flight reaper. flock -n exits with EX_TEMPFAIL (75) if the lock
# is held; we treat that as a clean no-op rather than an error.
do_reap() {
  local lock_file="${LOG_DIR:-$CONFIG_DIR/logs}/${LOG_PREFIX:-}reaper.lock"
  mkdir -p "$(dirname "$lock_file")"

  # Acquire exclusive non-blocking lock on FD 9. The lock is held for the
  # lifetime of FD 9, which is the lifetime of the subshell. Releases on exit.
  exec 9>"$lock_file"
  if ! flock -n 9; then
    echo "reaper: another instance is running (lock held), skipping cycle"
    return 0
  fi

  echo "reaper: cycle start prefix=${INSTANCE_PREFIX:-default}"

  REAPED_COUNT=0
  REAPED_ERRORS=0
  EVENTS_DELETED=0

  reap_orphan_projects "${INSTANCE_PREFIX:-cs-}"
  reap_stale_event_files

  echo "reaper: cycle end killed=${REAPED_COUNT} events_deleted=${EVENTS_DELETED} errors=${REAPED_ERRORS}"

  # D-10: nonzero exit only if the whole cycle errored out (e.g. docker daemon
  # unreachable). Per-project errors are surfaced via REAPED_ERRORS but don't
  # flip the exit code unless they were the entire cycle's outcome.
  if [ "$REAPED_ERRORS" -gt 0 ] && [ "$REAPED_COUNT" -eq 0 ]; then
    return 1
  fi
  return 0
}
```

**Key details:**
- FD 9 is conventionally available; the project does not use it elsewhere (verified by grep of `bin/claude-secure`).
- `exec 9>"$lock_file"` opens the file for writing without truncating its contents — flock only cares that an FD is held.
- The lock auto-releases when the script exits because FD 9 closes. No explicit `flock -u` needed.
- Manual `claude-secure reap` and timer-driven `claude-secure reap` race-protect each other through the same lock.

**Source:** `man flock(1)` (util-linux 2.39); CONTEXT D-08.

### Pattern E — Stale Event-File Sweep (D-06, Phase 14 D-20 fold-in)

**What:** Walk `$CONFIG_DIR/events/*.json`, delete files with mtime older than `REAPER_EVENT_AGE_SECS` seconds. Use `find -mmin +N` for age comparison, `-delete` for atomic removal, `-type f` to skip directories.

**The code:**

```bash
# D-06 / Phase 14 D-20 fold-in: delete event files older than REAPER_EVENT_AGE_SECS.
# Pure age-based; no audit cross-reference. find -delete is atomic per-file
# and skips files newer than the threshold.
reap_stale_event_files() {
  local events_dir="${CONFIG_DIR:-$HOME/.claude-secure}/events"
  local age_secs="${REAPER_EVENT_AGE_SECS:-86400}"
  local age_mins=$((age_secs / 60))

  [ -d "$events_dir" ] || { EVENTS_DELETED=0; return 0; }

  # find -mmin +N matches files older than N minutes. Note that -mmin uses
  # exclusive comparison: +1440 means "strictly older than 1440 minutes".
  # We collect the deletion list first (to count) then delete.
  local deleted=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if rm -f -- "$f" 2>/dev/null; then
      deleted=$((deleted + 1))
    fi
  done < <(find "$events_dir" -maxdepth 1 -type f -name '*.json' -mmin "+$age_mins" 2>/dev/null)

  EVENTS_DELETED=$deleted
}
```

**Key details:**
- `find -maxdepth 1` — only top-level files in `$events_dir`. Defensive against an operator nesting subdirs there.
- `find -name '*.json'` — Phase 14's event files are `<ISO-timestamp>-<uuid8>.json`. Anything else is left alone.
- Two-step `find` then `rm` (vs `find -delete`) — gives us a count for the journal log line.
- `rm -f --` defends against filenames starting with `-`.
- "In-flight" exclusion is implicit: files less than `age_mins` minutes old are not matched. The default `REAPER_EVENT_AGE_SECS=86400` (24h) makes accidental deletion of an in-progress spawn's event file effectively impossible (no spawn runs for 24 hours).

**Source:** `man find(1)`; CONTEXT D-06.

### Pattern F — E2E Four-Scenario Harness (D-13, D-14, D-15, D-16)

**What:** A single `tests/test-phase17-e2e.sh` script that, with a stubbed Claude binary, exercises four real-Docker scenarios: HMAC rejection, concurrent execution, orphan cleanup, resource limit enforcement. Wall-clock budget ≤ 90 seconds enforced via `timeout` wrapper.

**The harness skeleton:**

```bash
#!/bin/bash
# tests/test-phase17-e2e.sh -- Phase 17 end-to-end integration test.
#
# Four scenarios mapped 1:1 to OPS-03 success criterion:
#   1. HMAC rejection           -- assert 401, no spawn
#   2. Concurrent execution     -- 3 parallel valid POSTs, assert 3 audit + 3 reports
#   3. Orphan cleanup           -- spawn sentinel container, assert reap removes it
#   4. Resource limit           -- spawn, docker inspect, assert mem_limit
#
# Real Docker stack. Stubbed Claude (CLAUDE_SECURE_FAKE_CLAUDE_STDOUT).
# Local bare report repo. INSTANCE_PREFIX=e2e- to isolate from operator's real instance.
# Wall-clock budget: 90s.

set -uo pipefail

E2E_BUDGET=90
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_TMPDIR=$(mktemp -d -t cs-e2e-XXXXXXXX)
LISTENER_PID=""
PASS=0; FAIL=0

cleanup() {
  if [ -n "$LISTENER_PID" ]; then
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
  # D-16: tear down any e2e-prefixed containers and the report repo.
  CLAUDE_SECURE_INSTANCE=e2e "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1 || true
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Wall-clock budget guard
SECONDS=0
check_budget() {
  if [ "$SECONDS" -gt "$E2E_BUDGET" ]; then
    echo "FAIL: E2E budget exceeded ($SECONDS s > $E2E_BUDGET s)"
    exit 1
  fi
}

# === Setup: profile-e2e fixture ===
setup_e2e_profile() {
  cp -r "$PROJECT_DIR/tests/fixtures/profile-e2e" "$TEST_TMPDIR/profile-e2e"
  export CLAUDE_SECURE_INSTANCE=e2e
  export CONFIG_DIR="$TEST_TMPDIR/.claude-secure"
  mkdir -p "$CONFIG_DIR/profiles"
  cp -r "$TEST_TMPDIR/profile-e2e" "$CONFIG_DIR/profiles/e2e"

  # Local bare report repo
  local bare="$TEST_TMPDIR/report-repo-bare.git"
  git init --bare --initial-branch=main "$bare" >/dev/null 2>&1
  # ...seed bare with empty .gitkeep on main...
  jq --arg url "file://$bare" '.report_repo = $url' \
    "$CONFIG_DIR/profiles/e2e/profile.json" > "$CONFIG_DIR/profiles/e2e/profile.json.new"
  mv "$CONFIG_DIR/profiles/e2e/profile.json.new" "$CONFIG_DIR/profiles/e2e/profile.json"

  # Stubbed Claude envelope (Phase 16 reuse)
  export CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$PROJECT_DIR/tests/fixtures/envelope-success.json"
}

# === Scenario 1: HMAC rejection ===
scenario_hmac_rejection() {
  local body='{"repository":{"full_name":"e2e/test"},"action":"opened"}'
  local resp
  resp=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:9000/webhook" \
    -H 'X-Hub-Signature-256: sha256=deadbeef' \
    -H 'X-GitHub-Event: issues' \
    -H 'X-GitHub-Delivery: e2e-hmac-test' \
    -d "$body")
  [ "$resp" = "401" ] || { echo "FAIL hmac: expected 401, got $resp"; return 1; }

  # Audit must be unchanged after rejection
  local audit_count
  audit_count=$(wc -l < "$CONFIG_DIR/logs/e2e-executions.jsonl" 2>/dev/null || echo 0)
  [ "$audit_count" -eq 0 ] || { echo "FAIL hmac: audit grew after rejection"; return 1; }
  return 0
}

# === Scenario 2: Concurrent execution ===
scenario_concurrent_execution() {
  local secret="e2e-test-secret"
  local body='{"action":"opened","issue":{"title":"e2e"},"repository":{"full_name":"e2e/test"}}'
  local sig
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -binary | xxd -p -c256)

  for i in 1 2 3; do
    curl -sS -X POST "http://127.0.0.1:9000/webhook" \
      -H "X-Hub-Signature-256: sha256=$sig" \
      -H 'X-GitHub-Event: issues' \
      -H "X-GitHub-Delivery: e2e-concurrent-$i" \
      -d "$body" >/dev/null &
  done
  wait

  # Wait for all 3 spawns to complete (with timeout)
  local deadline=$((SECONDS + 60))
  while [ "$(wc -l < "$CONFIG_DIR/logs/e2e-executions.jsonl" 2>/dev/null || echo 0)" -lt 3 ]; do
    [ "$SECONDS" -gt "$deadline" ] && { echo "FAIL concurrent: timeout"; return 1; }
    sleep 1
  done

  # Assert: 3 audit lines, all jq-parseable
  local audit_count
  audit_count=$(wc -l < "$CONFIG_DIR/logs/e2e-executions.jsonl")
  [ "$audit_count" -eq 3 ] || { echo "FAIL concurrent: $audit_count audit lines"; return 1; }
  jq -c . < "$CONFIG_DIR/logs/e2e-executions.jsonl" >/dev/null \
    || { echo "FAIL concurrent: corrupt JSONL line"; return 1; }

  # Assert: 3 commits in bare report repo
  local commit_count
  commit_count=$(git -C "$TEST_TMPDIR/report-repo-bare.git" rev-list --count main)
  [ "$commit_count" -ge 4 ] \
    || { echo "FAIL concurrent: report repo has $commit_count commits, expected >=4"; return 1; }
  return 0
}

# === Scenario 3: Orphan cleanup ===
scenario_orphan_cleanup() {
  # Spawn a real sentinel container with the spawn naming convention.
  # Per Pitfall 4, we cannot backdate Created — we set REAPER_ORPHAN_AGE_SECS=0
  # so any age qualifies, then run reap.
  docker run -d --name "e2e-orphan-sentinel" \
    --label "com.docker.compose.project=cs-e2e-fakeorph" \
    busybox sleep 3600 >/dev/null

  # Sanity: container exists
  docker ps -q --filter "name=e2e-orphan-sentinel" | grep -q . \
    || { echo "FAIL orphan: sentinel did not start"; return 1; }

  # Run reap with zero age threshold so the freshly-created sentinel qualifies
  REAPER_ORPHAN_AGE_SECS=0 INSTANCE_PREFIX="cs-e2e-" \
    "$PROJECT_DIR/bin/claude-secure" reap >/dev/null 2>&1

  # Assert: sentinel gone
  if docker ps -aq --filter "name=e2e-orphan-sentinel" | grep -q .; then
    echo "FAIL orphan: sentinel survived reap"
    docker rm -f e2e-orphan-sentinel >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

# === Scenario 4: Resource limit enforcement ===
scenario_resource_limits() {
  # Trigger a spawn (or reuse one from scenario 2 still running).
  # Inspect the claude container; assert HostConfig.Memory > 0 and matches
  # the value declared in docker-compose.yml.
  local claude_cid
  claude_cid=$(docker ps -aq --filter "label=com.docker.compose.project" \
                            --filter "label=com.docker.compose.service=claude" \
                | head -1)
  [ -n "$claude_cid" ] || { echo "FAIL limits: no claude container found"; return 1; }

  local mem_bytes
  mem_bytes=$(docker inspect --format '{{.HostConfig.Memory}}' "$claude_cid")
  [ "$mem_bytes" -gt 0 ] \
    || { echo "FAIL limits: claude container has no memory limit (got $mem_bytes)"; return 1; }

  # Cross-check against docker-compose.yml's declared value.
  # Phase 17 plan must add `mem_limit: 1g` (1073741824 bytes) to the claude service.
  local expected=1073741824
  [ "$mem_bytes" -eq "$expected" ] \
    || { echo "FAIL limits: expected $expected, got $mem_bytes"; return 1; }
  return 0
}

# === Run ===
setup_e2e_profile
# ...start listener as subprocess...

scenario_hmac_rejection      && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
check_budget
scenario_concurrent_execution && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
check_budget
scenario_resource_limits      && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
check_budget
scenario_orphan_cleanup       && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
check_budget

echo "Phase 17 E2E: $PASS passed, $FAIL failed (in $SECONDS seconds, budget $E2E_BUDGET)"
[ "$FAIL" -eq 0 ]
```

**Source:** Phase 16 test harness `tests/test-phase16.sh:1-160`; CONTEXT D-13..D-16.

### Pattern G — D-11 Safe-Subset Hardening Application

**What:** Apply the 10 D-11 directives in **a single commit** to BOTH `webhook/claude-secure-webhook.service` and the new `webhook/claude-secure-reaper.service`. The E2E test (Pattern F scenario 1+2) is the gate: if any directive breaks listener startup or webhook processing, that directive must be removed (NOT commented out — silently dead config attracts re-enable attempts).

**Why all-or-nothing in one commit:** the test gate (D-12) catches breakage in the same wave that introduces it. Splitting into 10 commits would mean the first nine could be green while the tenth silently breaks something, and bisection becomes painful.

**The diff (applied to both unit files):**

```diff
 [Service]
 Type=simple
 ExecStart=...
 Restart=always
 ...
+
+# === D-11: Safe-subset systemd hardening (Phase 17) ===
+# Verified compatible with docker compose subprocess in Phase 14 + Phase 17 E2E gate.
+# DO NOT add NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet,
+# ProtectHome, or PrivateDevices: each one breaks docker socket access.
+ProtectKernelTunables=true
+ProtectKernelModules=true
+ProtectKernelLogs=true
+ProtectControlGroups=true
+RestrictNamespaces=true
+LockPersonality=true
+RestrictRealtime=true
+RestrictSUIDSGID=true
+MemoryDenyWriteExecute=true
+SystemCallArchitectures=native
```

**Per-directive sanity check (cross-referenced with `man systemd.exec` on systemd 255 + Phase 14 empirical record):**

| Directive | Effect | Why Safe for Listener+Reaper |
|-----------|--------|-------------------------------|
| `ProtectKernelTunables=true` | Read-only `/proc/sys`, `/sys`, etc. | Neither service writes kernel tunables; docker daemon (in a separate process) does. |
| `ProtectKernelModules=true` | Cannot load/unload kernel modules. | Neither service loads modules; docker may, but it runs as a separate dockerd process not affected by this unit. |
| `ProtectKernelLogs=true` | Cannot read kernel ring buffer. | Neither service reads `/dev/kmsg`. |
| `ProtectControlGroups=true` | Read-only `/sys/fs/cgroup`. | docker daemon manages cgroups, not these scripts. |
| `RestrictNamespaces=true` | Disallows the unit process from creating new namespaces (clone/unshare). | The listener process is a Python HTTP server; the reaper is a bash script. Neither call `unshare`/`clone`. **Container namespaces are created by dockerd, NOT by these processes.** |
| `LockPersonality=true` | Disallows `personality()` syscall. | Neither service changes execution personality. |
| `RestrictRealtime=true` | Disallows realtime scheduling. | Neither needs RT. |
| `RestrictSUIDSGID=true` | Cannot create SUID/SGID files. | Neither does. |
| `MemoryDenyWriteExecute=true` | No `mmap` with PROT_WRITE+PROT_EXEC. | Python listener doesn't JIT; bash doesn't generate code. |
| `SystemCallArchitectures=native` | Block non-native syscall ABIs (e.g. i386 on x86_64). | Both processes are native bash/python; docker daemon is unaffected. |

**Source:** `man systemd.exec(5)` on systemd 255 (verified); Phase 14 D-23..D-26 empirical record; CONTEXT D-11 / D-12.

### Pattern H — Backdate-Free Sentinel Container (D-14 Scenario 3)

**What:** The orphan-cleanup test cannot fake `Created` timestamps because docker has no API to mutate them. Instead, the test sets `REAPER_ORPHAN_AGE_SECS=0` in the reaper's environment, so a freshly-created sentinel container qualifies for reaping immediately.

**Why this is correct:** the reaper's age check is `(now - created) >= REAPER_ORPHAN_AGE_SECS`. With `REAPER_ORPHAN_AGE_SECS=0`, every container qualifies regardless of age. The test verifies the *selection logic* (label match → teardown invocation), not the *threshold value* (which is unit-tested separately with mocked `docker inspect`).

**The pattern:**

```bash
# Step 1: spawn the sentinel with the exact label format the reaper matches.
docker run -d --name "e2e-orphan-sentinel" \
  --label "com.docker.compose.project=cs-e2e-fakeorph" \
  busybox sleep 3600

# Step 2: invoke reaper with zero-age threshold + matching prefix.
REAPER_ORPHAN_AGE_SECS=0 INSTANCE_PREFIX="cs-e2e-" \
  bin/claude-secure reap

# Step 3: assert sentinel is gone.
docker ps -aq --filter "name=e2e-orphan-sentinel" | grep -q . && exit 1
```

**Companion unit test:** in `tests/test-phase17.sh` (NOT the E2E file), unit-test `reap_orphan_projects` against a mocked `docker ps` script on PATH that returns a fixture string with a fake `CreatedAt`. This isolates the age comparison logic without needing real containers. CONTEXT specifics: "Reaper 'kill list' test pattern".

**Source:** Docker daemon source — `Created` is set at container creation and never mutated; CONTEXT specifics (Reaper kill-list test pattern).

### Pattern I — Resource Limit Assertion via `docker inspect` (D-14 Scenario 4)

**What:** After a spawn runs, query the claude container with `docker inspect --format '{{.HostConfig.Memory}}' <id>` and assert the returned byte count matches the value declared in `docker-compose.yml`.

**Critical prerequisite:** the current `docker-compose.yml` declares NO memory limits. **Phase 17 must add `mem_limit: 1g` (or `deploy.resources.limits.memory: 1G`) to the `claude` service in Wave 1 BEFORE the assertion has anything to check.**

**Compose v2 syntax options:**
1. `mem_limit: 1g` — short form, sets `HostConfig.Memory` directly. Works with `docker compose up`.
2. `deploy.resources.limits.memory: 1G` — Swarm-style. **In Compose v2, this is only honored when running `docker stack deploy`, NOT plain `docker compose up`.** This is the Phase 13 Concern #3 trap.

**Recommendation:** Use `mem_limit: 1g` (Option 1) for spawn services. It's simpler, it actually applies to `docker compose up`, and `docker inspect` reads it directly from `HostConfig.Memory`. Document the Swarm-vs-non-Swarm distinction in a comment.

**The assertion:**

```bash
local claude_cid mem_bytes expected=1073741824  # 1 GiB
claude_cid=$(docker ps -q --filter "label=com.docker.compose.service=claude" | head -1)
mem_bytes=$(docker inspect --format '{{.HostConfig.Memory}}' "$claude_cid")
[ "$mem_bytes" -eq "$expected" ] || fail "memory limit not enforced: $mem_bytes != $expected"
```

**Source:** `docker inspect` documentation; Docker Compose v2 spec on `deploy.resources` vs short-form `mem_limit`; STATE.md Blockers/Concerns: "Docker Compose `deploy.resources.limits` vs `mem_limit` -- verify with `docker inspect`".

### Anti-Patterns to Avoid

- **`docker ps --filter label=com.docker.compose.project=cs-e2e-*`** — docker `--filter` does NOT support glob patterns. The `*` is treated literally and matches nothing. Use exact label-key filter then prefix-match in bash.
- **`docker compose ps --filter`** — applies only within a single project; useless for cross-project orphan discovery.
- **`docker rm -f $(docker ps -q ...)`** — bypasses graceful shutdown and skips network/volume cleanup. Use `docker compose down` per project.
- **Force-removing volumes named in `docker-compose.yml` (e.g. `validator-db`)** — these contain persistent state. The reaper's `-v` flag only removes anonymous volumes by default; named volumes survive unless explicitly listed. Verify by reading the project's compose file before adding new named volumes.
- **`docker system prune -a`** — global, cross-instance, removes images. Never run from the reaper. Forbidden by D-05.
- **`rm -rf $events_dir`** — wholesale removal violates D-06's "files older than X" semantics. Use `find -mmin +N`.
- **`flock $lock_file -c "..."` (subshell form)** — works but the subshell loses access to the parent's variables. Use the FD form (`exec 9>$lock_file; flock -n 9`).
- **Reading container Created via `docker ps --format '{{.CreatedAt}}'`** — returns `2026-04-12 13:00:00 +0000 UTC`, hard to parse, locale-dependent. Use `docker inspect --format '{{.Created}}'` for ISO8601.
- **Adding `NoNewPrivileges=true` to either unit file** — Phase 14 confirmed this breaks docker subprocess. D-11 explicitly excludes it. Do NOT re-attempt.
- **Commenting out broken hardening directives instead of deleting them** — D-12: "silently dead config attracts re-enable attempts". Either ship them or delete them.
- **Calling `claude-secure reap` from inside a spawn or hook** — circular dependency risk. Reaper is timer-driven only (or operator-invoked).
- **Letting the reaper run during a CI test that itself spawns containers** — the reaper would race the test's containers and tear them down. E2E tests use a dedicated `INSTANCE_PREFIX=e2e-` so the operator's normal reaper (which scopes to `cs-` or the operator's chosen prefix) does NOT touch them.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Periodic task scheduler | bash `while true; do sleep 300; do_reap; done` daemon | systemd timer + oneshot | systemd handles boot order, persistence, journal logging, restart-on-failure, missed-cycle catch-up. Reinventing it as a daemon costs 100+ LOC of edge cases. |
| Single-flight lock | PID file + signal handling | `flock -n` | flock is atomic at the kernel level; PID files race on stale-PID detection. |
| ISO8601 timestamp parsing | bash regex + arithmetic | `date -d "$iso" +%s` | GNU date handles every ISO8601 variant; bash regex breaks on timezone offsets, fractional seconds, etc. |
| Container age comparison | docker compose plugin / event API | `docker inspect --format '{{.Created}}'` | Inspect is universal, scriptable, and emits ISO8601. Event API is push-only and would need a daemon. |
| Graceful container teardown | `docker rm -f` + manual network/volume cleanup | `docker compose down -v --remove-orphans --timeout N` | Compose understands the project graph; manual cleanup leaks networks and orphan containers. |
| Stale file age sweep | `for f in *; do stat ... compare ...` | `find -mmin +N -delete` (or two-step for counting) | find's `-mmin` is correct, atomic per-file, and handles symlinks/permissions safely. |
| Multi-process JSONL append | bash `>>` redirection alone | bash `>>` AND a < PIPE_BUF size guard (already from Phase 16) | Phase 16's audit writer enforces this; reaper does not write to executions.jsonl, so no new code here. |
| HMAC signature generation in tests | hand-rolled SHA256 in bash | `openssl dgst -sha256 -hmac "$secret" -binary \| xxd -p` | openssl + xxd are stable, available, and produce the exact format GitHub sends. |
| Parallel HTTP POSTs | xargs `-P` or python multiprocessing | `curl ... &` + `wait` | Bash backgrounding is sufficient for 3 parallel requests. xargs/python add complexity without benefit. |
| Wall-clock budget enforcement | `date +%s` arithmetic in every test | bash `$SECONDS` magic variable + `timeout` wrapper | `$SECONDS` is built-in and resets per shell; `timeout` is the kernel-backed hard cap. |

**Key insight:** The reaper is ~150 LOC of bash that orchestrates existing primitives (`docker ps`, `docker inspect`, `docker compose down`, `find`, `date`, `flock`). The unit files are ~30 lines each. The E2E test is ~250 LOC of harness + scenarios. **Total new code is small precisely because the codebase already established the patterns** — Phase 17 is wiring, not invention.

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| **Stored data** | **None** — Phase 17 does not migrate any existing data. The reaper deletes orphan containers (transient) and stale event files (transient). The audit log (`executions.jsonl`) is read-only from the reaper's perspective. Profile.json schema is NOT extended. | None. |
| **Live service config** | **One new systemd timer + one new systemd service** registered with the system manager via `systemctl daemon-reload` + `systemctl enable --now claude-secure-reaper.timer`. The existing `claude-secure-webhook.service` is updated in place with 10 new D-11 hardening directives — this requires a `systemctl daemon-reload` + `systemctl restart claude-secure-webhook` to take effect. Operators upgrading from Phase 16 must re-run `install.sh --with-webhook` to pick up both changes. | Document in phase summary: existing installs require re-running `install.sh --with-webhook` for the reaper timer to be installed AND for the listener to pick up the new hardening directives. |
| **OS-registered state** | **Two new systemd units** in `/etc/systemd/system/`: `claude-secure-reaper.service` and `claude-secure-reaper.timer`. Both go in via the installer with mode 644, root-owned. The timer is enabled at boot via `WantedBy=timers.target`. **WSL2 systemd gate from Phase 14 D-26 still applies** — if WSL2 lacks `[boot] systemd=true`, installer warns and skips `enable --now` for both the listener and the reaper. | Installer (D-17) handles this. WSL2 gate already in place. |
| **Secrets / env vars** | **Two new optional env vars**: `REAPER_ORPHAN_AGE_SECS` (default 600) and `REAPER_EVENT_AGE_SECS` (default 86400). Read by `do_reap` from the environment OR from `config.sh` (operator can override). Not secrets, not in `.env`. **One test-only env var**: `REPORT_REPO_TOKEN=ghp_FAKEE2E` in `tests/fixtures/profile-e2e/.env` — never used for real auth, exists only because the publish_report code path checks for it. | Document the two new env vars in README. Test fixture .env is checked into git (fake token, no real secrets). |
| **Build artifacts / installed packages** | **Two new files installed by `install.sh`**: `/etc/systemd/system/claude-secure-reaper.service` and `/etc/systemd/system/claude-secure-reaper.timer`. Mode 644, root-owned. Existing installs that ran `install.sh --with-webhook` BEFORE Phase 17 must re-run it (or manually `cp webhook/claude-secure-reaper.{service,timer} /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now claude-secure-reaper.timer`). The webhook unit file is also updated (D-11 directives) and must be replaced. | Installer re-run required on existing hosts. Document in phase summary. |

## Common Pitfalls

### Pitfall 1: Project Naming Convention Mismatch with CONTEXT D-04 Wording
**What goes wrong:** CONTEXT D-04 says the reaper filters on `label=com.docker.compose.project=<INSTANCE_PREFIX>spawn-*`, but the actual project naming convention from `spawn_project_name()` (`bin/claude-secure:325-333`) is `cs-<profile>-<uuid8>`. There is no `spawn-` substring anywhere. A literal reading of D-04 produces a reaper that matches zero projects.
**Why it happens:** D-04 was authored as a description of intent ("spawn-prefixed compose projects"), not as a copy-paste of the current naming scheme.
**How to avoid:** The plan reconciles the wording: the reaper filters on `label=com.docker.compose.project` (key only) and applies a bash prefix match against the configured `INSTANCE_PREFIX` (default `cs-`). Optionally also matches the `cs-*-*` shape to defend against unrelated compose stacks.
**Warning sign:** Implementation that contains the literal string `spawn-*` or `*spawn*` in a docker filter or grep.
**Test:** Spawn a real container with `cs-test-deadbeef` label, run reaper, assert it is reaped (with `REAPER_ORPHAN_AGE_SECS=0`).

### Pitfall 2: docker `--filter` Treats Glob Characters as Literals
**What goes wrong:** Developer writes `docker ps --filter "label=com.docker.compose.project=cs-e2e-*"` expecting wildcard match. docker treats `*` as a literal and the filter matches nothing.
**Why it happens:** docker's filter syntax is exact-match only; `--filter name=foo` matches containers named `foo*` because docker `name` filter is a substring match, but `label` filters are exact match.
**How to avoid:** Filter on `label=KEY` (key only) — returns every container with that label set to anything. Then post-process the unique project values in bash with prefix matching (`case "$proj" in "$prefix"*) ;; esac`).
**Warning sign:** Any `docker ps --filter` containing `*`, `?`, or `[`.
**Test:** Mock `docker ps` to emit a fixture; assert the bash post-filter selects only the prefix-matching projects. (Unit test in `tests/test-phase17.sh`.)

### Pitfall 3: `Persistent=true` Rejected on Monotonic-Only Timers
**What goes wrong:** systemd documentation says `Persistent=` applies to `OnCalendar=` timers. With only `OnBootSec=` + `OnUnitActiveSec=`, some systemd versions ignore `Persistent=true` silently; others (rarely) reject the unit file at parse time.
**Why it happens:** The doc wording is `Persistent=` "is mostly useful for OnCalendar= timers". On modern systemd (>= 232 or so) it works fine for monotonic timers too — but the testing matrix is incomplete.
**How to avoid:** Include `Persistent=true` initially; if `systemctl daemon-reload` reports a parse error or the timer fails to load, drop the directive. A missed cycle (host off when 5-min firing was due) is harmless because the next normal firing reaps any orphans the missed cycle would have caught.
**Warning sign:** `journalctl -u claude-secure-reaper.timer` shows `Persistent=` parse warnings.
**Test:** E2E test loads the unit file via `systemd-analyze verify webhook/claude-secure-reaper.timer`; assert exit 0.

### Pitfall 4: Cannot Backdate `Created` Timestamp on a Sentinel Container
**What goes wrong:** Developer tries to test the age threshold by spawning a container and somehow making it "look older". Docker has no API to mutate `Created`. The test fails because the sentinel is younger than 600s.
**Why it happens:** `Created` is set at `docker run` time and is immutable. There is no `--created-at` flag, no inspect mutation, nothing.
**How to avoid:** Test the age threshold logic as a UNIT test with a mocked `docker inspect` that returns a fixture timestamp. Test the *selection logic* in E2E with `REAPER_ORPHAN_AGE_SECS=0` so any age qualifies.
**Warning sign:** E2E test attempts `docker exec ... date -s ...` or similar.
**Test:** `tests/test-phase17.sh` mocks `docker inspect` via a wrapper script on PATH; `tests/test-phase17-e2e.sh` uses `REAPER_ORPHAN_AGE_SECS=0`.

### Pitfall 5: docker-compose.yml Has No Memory Limit, So D-14 Scenario 4 Asserts Against Nothing
**What goes wrong:** The current `docker-compose.yml` (verified by reading the file) declares NO `mem_limit` and NO `deploy.resources.limits`. D-14 scenario 4 says "assert `Memory` and `MemorySwap` match the limit declared". Without a declared limit, `docker inspect` returns 0 (unlimited), and the assertion passes trivially against 0 == 0 — which is wrong.
**Why it happens:** The Phase 13 Concern #3 in STATE.md ("Docker Compose `deploy.resources.limits` vs `mem_limit` -- verify with `docker inspect`") was never closed because Phase 13 never added the limits.
**How to avoid:** Phase 17 Wave 1 MUST add `mem_limit: 1g` (or equivalent) to the `claude` service in `docker-compose.yml` BEFORE the E2E assertion is wired up. Use the short form (`mem_limit`), NOT `deploy.resources.limits.memory` — the latter only applies under `docker stack deploy`, not `docker compose up`.
**Warning sign:** E2E scenario 4 passes against `mem_bytes=0`. Add the explicit `[ "$mem_bytes" -gt 0 ]` guard.
**Test:** D-14 scenario 4 above.

### Pitfall 6: Reaping a Container the User Manually Started With the Same Project Name
**What goes wrong:** Operator manually `docker run --label com.docker.compose.project=cs-myprofile-abcd1234` something for debugging. The reaper matches the prefix, sees the container is older than 10 minutes, and tears it down.
**Why it happens:** Label-based detection cannot distinguish "spawn that crashed" from "manual debug session that picked the same naming convention".
**How to avoid:** Document the convention loudly: any container labeled with `com.docker.compose.project=cs-*` is reaper territory. Operators who want exempt containers must use a different label or no label at all. The defensive `cs-*-*` shape filter (Pattern B) at least requires the project to look like a spawn name.
**Warning sign:** Operator complaints about manually-started containers disappearing.
**Test:** Manual; document in README.

### Pitfall 7: Race Between `spawn_cleanup` EXIT Trap and Reaper Cycle
**What goes wrong:** A spawn is in the middle of `spawn_cleanup` (which runs `docker compose down`) when the reaper fires for the same project. Both call `docker compose down` simultaneously; one of them reports an error (container already removed) and the reaper logs an error.
**Why it happens:** The reaper does not coordinate with active spawns. It assumes any project older than `REAPER_ORPHAN_AGE_SECS` is orphaned.
**How to avoid:** The 10-minute default age threshold (twice the timer interval, well above the longest spawn duration) makes this race essentially impossible. A spawn that lives longer than 10 minutes is by D-04's definition an orphan. The reaper's per-project error handling (D-10) tolerates the "already gone" case by counting it as a soft error and continuing to the next project. Idempotent teardown means double-down is harmless.
**Warning sign:** Reaper journal lines show `errors=1` for projects that the operator knows just completed normally.
**Test:** Concurrent reap + spawn-cleanup unit test with mocked docker.

### Pitfall 8: Clock Skew / Daylight Saving Affects Age Comparison
**What goes wrong:** Host clock jumps (NTP correction, DST transition, manual `date -s`). The reaper computes `now - created` and gets a negative or surprisingly large value. Negative ages skip the threshold; surprisingly large ages reap everything.
**Why it happens:** `date +%s` returns wall-clock seconds, which can move backward.
**How to avoid:** All timestamps go through `date +%s` (UTC seconds since epoch). Container `Created` is also UTC ISO8601. Both sides are UTC, so DST is irrelevant. NTP correction within the typical few seconds is below the 600s threshold by ~100x. **An attacker who can jump the host clock by 10+ minutes already has root and is not contained by the reaper.**
**Warning sign:** Reaper kills everything after a clock jump.
**Test:** Set `REAPER_ORPHAN_AGE_SECS=10000000`, run reaper, assert kill count is 0. Set to `0`, assert positive kill count.

### Pitfall 9: WSL2 systemd Timer Fires But Cannot Reach docker.service
**What goes wrong:** WSL2 with systemd enabled — the timer fires, but `docker.service` is not running because Docker Desktop runs the daemon on the Windows side, not via systemd in WSL. The reaper fails on `docker ps`.
**Why it happens:** Docker Desktop integrates with WSL2 by injecting `docker` CLI into the WSL distribution but does NOT run dockerd inside WSL. The unit's `Requires=docker.service` references a service that doesn't exist in WSL.
**How to avoid:** Drop `Requires=docker.service` and weaken to `Wants=docker.service`. The reaper will fail naturally if dockerd is unreachable, and D-10's "best-effort" semantics absorb the failure. Alternatively (cleaner): the install.sh WSL2 detection block (Phase 14 D-26) skips installing the reaper timer on WSL2 entirely — Docker Desktop manages container lifecycle differently and orphan accumulation is less of a concern there.
**Warning sign:** Reaper logs `Cannot connect to the Docker daemon` on every cycle.
**Test:** Manual on WSL2 with Docker Desktop; document in README.

### Pitfall 10: Reaping Bind-Mount Workspaces
**What goes wrong:** A spawn project's compose file declares a bind-mount workspace under `~/workspace`. The reaper runs `docker compose down -v` which removes anonymous volumes. If the operator confused a named volume for an anonymous one (e.g. bound a host path through a named volume), the workspace contents could be lost.
**Why it happens:** `-v` removes only anonymous volumes by default in Compose v2 (`docker compose down -v` is documented as removing anonymous volumes; named volumes require explicit listing). But operator confusion is real.
**How to avoid:** Document explicitly in CONTEXT (it is — D-05): "Reaper never touches images, named volumes, or bind-mount workspaces." Test by reading the E2E test asserting that a bind-mount file under workspace survives a reap cycle.
**Warning sign:** Operator reports lost workspace files after reaper ran.
**Test:** E2E scenario optional addition (not in D-14 base set): seed a bind-mount file, spawn, reap, assert file still exists.

### Pitfall 11: The Listener Stops Working Silently After Adding Hardening Directives
**What goes wrong:** Wave 1 adds the 10 D-11 directives to `claude-secure-webhook.service`. Operator reloads systemd. The listener silently fails to process webhooks (e.g. `MemoryDenyWriteExecute=true` blocks something Python imports). E2E gate (D-12) is supposed to catch this, but if the gate runs against an old version of the unit file, the regression sneaks through.
**Why it happens:** Sequencing — the gate test must reload the unit AND restart the service AND issue a webhook AND assert success, all in one test.
**How to avoid:** D-14 scenario 1 (HMAC rejection) and D-14 scenario 2 (concurrent execution) collectively ARE the gate. They issue webhooks against a freshly-installed listener. If the listener fails to start under the new directives, both scenarios fail. Wave order: install unit file → reload → restart → run E2E.
**Warning sign:** Wave 1 commit lands the unit file change but Wave 2 runs the E2E test in a separate CI job with stale state.
**Test:** D-14 scenarios 1 + 2 (which use the live listener) ARE the test.

### Pitfall 12: `find -delete` Race with Phase 14 Listener Persisting New Events
**What goes wrong:** Reaper's `find -mmin +1440 -delete` runs at the same instant the listener writes a new event file. The file is found by `find` (because mtime is older than 24h), then `rm -f` runs, but between the `find` walk and the `rm`, the listener might rewrite the file. Race window is microseconds wide and harmless.
**Why it happens:** Concurrent file operations.
**How to avoid:** The 24h default threshold makes this race impossible in practice — the listener never writes to a file that is already 24h old (it always creates new files). The race window is purely theoretical.
**Warning sign:** None expected.
**Test:** Not needed.

### Pitfall 13: `tests/fixtures/profile-e2e/.env` Token Pattern Triggers Secret Scanners
**What goes wrong:** `REPORT_REPO_TOKEN=ghp_FAKEE2E` matches the GitHub PAT prefix `ghp_`. Secret scanners (gitleaks, GitHub's own push protection) flag the commit and block CI.
**Why it happens:** The `ghp_` prefix is a known PAT signature.
**How to avoid:** Use a clearly-fake value that does NOT start with `ghp_`. Recommendations: `REPORT_REPO_TOKEN=fake-e2e-token` or `REPORT_REPO_TOKEN=PLACEHOLDER_NOT_A_REAL_TOKEN`. The publish_report code only checks for non-empty; the value is never used for real auth (the bare repo is `file://`).
**Warning sign:** GitHub push protection blocks the commit.
**Test:** `git diff --cached | gitleaks detect --pipe` returns 0 matches.

### Pitfall 14: Reaper Lock File Permissions Block Manual Invocation
**What goes wrong:** Timer-driven reaper (root) creates `/var/log/.../reaper.lock` with mode 600 / root-owned. Operator manually invokes `claude-secure reap` as their normal user; flock fails because they cannot write the lock file.
**Why it happens:** Default umask 022 on root processes creates files mode 644, but the parent dir might be 700.
**How to avoid:** `mkdir -p` the parent dir with mode 755 (or honor the existing dir mode); create the lock file with mode 666 (`chmod 666 "$lock_file"` after `exec 9>` opens it). Or: store the lock under `/var/run/claude-secure/` with shared group access. Pragmatic: `LOG_DIR` is already mode 777 in `do_spawn` (`bin/claude-secure:1230`) for log writability — same applies here.
**Warning sign:** Operator cannot run `claude-secure reap` after the timer has run once.
**Test:** Run reaper as root, then run it as a normal user, assert the second run does not fail with permission errors.

### Pitfall 15: `WantedBy=timers.target` vs `multi-user.target`
**What goes wrong:** Developer copy-pastes `WantedBy=multi-user.target` from the listener unit into the reaper TIMER unit. Timer is enabled but never starts because `multi-user.target` triggers services, not timers.
**Why it happens:** Confusion between service unit `[Install]` (which uses `multi-user.target`) and timer unit `[Install]` (which uses `timers.target`).
**How to avoid:** Reaper SERVICE uses `WantedBy=multi-user.target` (matches listener pattern). Reaper TIMER uses `WantedBy=timers.target`. Two units, two different `WantedBy`.
**Warning sign:** `systemctl list-timers` shows the timer disabled or absent.
**Test:** Post-install: `systemctl is-enabled claude-secure-reaper.timer` returns `enabled`. `systemctl list-timers --all` includes it.

## Critical Validation Map

| Requirement | Decision | Validation Technique | Test Command (pseudo) |
|-------------|----------|---------------------|----------------------|
| OPS-03 | Reaper subcommand exists | grep `bin/claude-secure` for `do_reap` and `reap)` dispatch | `grep -E '^do_reap\|reap\)' bin/claude-secure → match` |
| OPS-03 / D-01 | Reaper unit + timer files exist | File presence | `test -f webhook/claude-secure-reaper.service && test -f webhook/claude-secure-reaper.timer` |
| OPS-03 / D-01 | Unit files pass `systemd-analyze verify` | systemd parse check | `systemd-analyze verify webhook/claude-secure-reaper.{service,timer}` |
| OPS-03 / D-02 | Timer interval is exactly 5min | grep | `grep '^OnUnitActiveSec=5min$' webhook/claude-secure-reaper.timer` |
| OPS-03 / D-04 | Reaper detects orphans by label + age | E2E scenario 3 + unit test with mocked docker ps | `bash tests/test-phase17.sh test_reap_age_threshold` |
| OPS-03 / D-05 | Reaper invokes `down -v --remove-orphans --timeout 10` | grep `bin/claude-secure` | `grep 'down -v --remove-orphans --timeout 10' bin/claude-secure` |
| OPS-03 / D-05 | Reaper NEVER touches images | grep for `docker rmi`, `image prune`, `--rmi` | `grep -E 'docker rmi\|image[[:space:]]+prune\|--rmi' bin/claude-secure → 0 matches` |
| OPS-03 / D-06 | Stale event files reaped | Create old file, run reaper, assert deleted | `touch -d '2 days ago' $events/old.json; reap; ! test -f $events/old.json` |
| OPS-03 / D-06 | Fresh event files NOT reaped | Create recent file, run reaper, assert kept | `touch $events/new.json; reap; test -f $events/new.json` |
| OPS-03 / D-07 | Reaper honors INSTANCE_PREFIX | Mock two prefixes, assert only one is reaped | unit test |
| OPS-03 / D-08 | flock prevents concurrent reaper | Run two `claude-secure reap` in parallel, assert one exits silently with lock-held message | `(reap & reap & wait) 2>&1 \| grep -c "lock held" → 1` |
| OPS-03 / D-09 | Reaper logs to journal only (no separate JSONL) | grep for `>>` JSONL writes inside `do_reap` | `awk '/^do_reap/,/^}/' bin/claude-secure \| grep -c '>>' → 0` |
| OPS-03 / D-10 | Single-project failure does not abort cycle | Inject one failing project, assert remaining still reaped | unit test with mocked docker compose |
| OPS-03 / D-11 | All 10 hardening directives present in BOTH unit files | grep each directive name | `for d in ProtectKernelTunables ... ; do grep -q "$d=true" webhook/claude-secure-{webhook,reaper}.service ; done` |
| OPS-03 / D-11 | NO forbidden directives present | grep negative | `! grep -E 'NoNewPrivileges\|ProtectSystem\|PrivateTmp\|CapabilityBoundingSet\|ProtectHome\|PrivateDevices' webhook/claude-secure-*.service` |
| OPS-03 / D-12 | Listener still processes webhooks after hardening | E2E scenario 1 + 2 against live listener | `bash tests/test-phase17-e2e.sh scenario_hmac_rejection && scenario_concurrent_execution` |
| OPS-03 / D-13 | E2E test file exists | File presence | `test -x tests/test-phase17-e2e.sh` |
| OPS-03 / D-14.1 | HMAC rejection: 401, no spawn, no audit | E2E scenario 1 | `[ status==401 && audit_count==0 ]` |
| OPS-03 / D-14.2 | Concurrent execution: 3 audit + 3 reports | E2E scenario 2 | `[ audit_count==3 && repo_commits>=4 && jq -c < jsonl ]` |
| OPS-03 / D-14.3 | Orphan cleanup: sentinel removed | E2E scenario 3 with REAPER_ORPHAN_AGE_SECS=0 | `! docker ps -aq --filter name=e2e-orphan-sentinel` |
| OPS-03 / D-14.4 | Memory limit enforced | E2E scenario 4 | `docker inspect HostConfig.Memory == 1073741824` |
| OPS-03 / D-15 | E2E budget ≤ 90s | wall-clock guard | `[ $SECONDS -le 90 ]` |
| OPS-03 / D-16 | E2E uses dedicated profile-e2e fixture | grep for `INSTANCE_PREFIX=e2e-` | `grep INSTANCE_PREFIX=e2e- tests/test-phase17-e2e.sh` |
| OPS-03 / D-17 | Installer ships reaper unit + timer | grep install.sh for both filenames | `grep -c 'claude-secure-reaper' install.sh → ≥ 4` |
| OPS-03 / D-17 | Installer enables timer (subject to WSL2 gate) | grep for `enable --now claude-secure-reaper.timer` | `grep 'enable --now claude-secure-reaper.timer' install.sh` |
| OPS-03 / D-18 | Post-install hint printed | grep for hint string | `grep 'journalctl -u claude-secure-reaper -f' install.sh` |
| OPS-03 / specifics | Grep guard: no destructive paths | static grep | `! grep -E 'docker.*--force\|rm -rf /opt\|rm -rf /etc' bin/claude-secure` |
| OPS-03 / specifics | `--dry-run` flag on reap | flag parsing test | `claude-secure reap --dry-run` prints kill list, exits 0, kills nothing |
| OPS-03 / Pitfall 5 | Memory limit declared in docker-compose.yml | grep for `mem_limit` | `grep mem_limit docker-compose.yml` |
| OPS-03 / Pitfall 13 | Test fixture token does not trigger secret scanners | grep for `ghp_` prefix in fixtures | `! grep -r 'ghp_' tests/fixtures/profile-e2e/` |
| OPS-03 / Pitfall 14 | Lock file world-writable for manual invocation | mode check | `stat -c %a $LOG_DIR/reaper.lock == 666` (or shared group) |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker daemon (running) | Reaper operations + E2E scenarios | ✓ (assumed on host) | 29.3.1 | Reaper exits with `errors > 0` on docker unreachable; D-10 best-effort semantics absorb |
| Docker Compose v2 | `docker compose -p ... down` | ✓ (built into docker CLI) | v2 | — (hard requirement) |
| systemd | timer + service units | ✓ on Linux; ⚠ on WSL2 (gated by D-26) | 255 | install.sh skips `enable --now` on WSL2 without `[boot] systemd=true` |
| flock | single-flight reaper guard | ✓ | util-linux 2.39.3 | — |
| GNU date | ISO8601 → epoch conversion | ✓ | coreutils 9.x | macOS BSD date is incompatible (`-d` syntax differs); not a target platform per CLAUDE.md |
| GNU find | `-mmin +N -delete` | ✓ | findutils 4.x | — |
| openssl | HMAC signature generation in E2E | ✓ (assumed; used by Phase 14 tests) | 3.x | python3 hmac module |
| xxd | hex encoding for HMAC sig | ✓ (assumed; used by Phase 14 tests) | from vim-common | `od -An -tx1 \| tr -d ' \n'` |
| curl | E2E HTTP POST to listener | ✓ | 8.x | python3 urllib |
| timeout (coreutils) | wall-clock budget guard | ✓ | coreutils 9.x | — |
| python3 (>= 3.11) | Phase 14 listener (already required) | ✓ | 3.12.3 | — |
| jq | JSON parsing in tests + reaper | ✓ | 1.7 | — |
| busybox image | E2E scenario 3 sentinel container | ⚠ may need pull (`docker pull busybox`) | latest | Use `alpine:latest` if busybox unavailable; both images < 5MB |
| systemd-analyze | unit file lint in tests | ✓ on Linux with systemd | 255 | Skip lint test on WSL2-without-systemd |

**Missing dependencies with no fallback:** None — every tool is already on any host that runs Phases 13–16.

**Missing dependencies with fallback:** `busybox` Docker image may not be cached locally. The E2E test should pre-pull it (`docker pull busybox`) at scenario 3 setup, or fall back to `alpine`. `systemd-analyze verify` requires systemd; skip on WSL2-without-systemd hosts.

**Network dependency note:** Phase 17 requires:
- Outbound to Docker registry for `busybox` (one-time cache; the host already pulls images for the spawn stack so this is a no-op on warm hosts).
- NO outbound to Anthropic (Claude is stubbed) or GitHub (report repo is `file://`). The reaper itself contacts neither.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash integration test harness (same style as test-phase14/15/16.sh) |
| Config file | None — inline harness in `tests/test-phase17.sh` (unit) and `tests/test-phase17-e2e.sh` (integration) |
| Quick run command | `bash tests/test-phase17.sh` |
| Full suite command | `bash tests/test-phase17.sh && bash tests/test-phase17-e2e.sh` |
| Per-test runner | `bash tests/test-phase17.sh test_<name>` |
| Wall-clock budget | E2E only: 90 seconds (D-15) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| OPS-03 | Reaper subcommand exists in `bin/claude-secure` | static | `bash tests/test-phase17.sh test_reap_subcommand_exists` | ❌ Wave 0 |
| OPS-03 | Reaper unit + timer files exist | static | `bash tests/test-phase17.sh test_reaper_unit_files_exist` | ❌ Wave 0 |
| OPS-03 | Reaper unit files pass `systemd-analyze verify` | static | `bash tests/test-phase17.sh test_reaper_unit_files_lint` | ❌ Wave 0 |
| OPS-03 | Reaper service: Type=oneshot, ExecStart=...reap | static (grep) | `bash tests/test-phase17.sh test_reaper_service_directives` | ❌ Wave 0 |
| OPS-03 | Reaper timer: OnBootSec=2min, OnUnitActiveSec=5min, Persistent=true, Unit=...service | static (grep) | `bash tests/test-phase17.sh test_reaper_timer_directives` | ❌ Wave 0 |
| OPS-03 | Reaper service WantedBy=multi-user.target, timer WantedBy=timers.target | static (grep) | `bash tests/test-phase17.sh test_reaper_install_sections` | ❌ Wave 0 |
| OPS-03 / D-04 | Orphan detection: containers older than threshold matched | unit (mocked docker ps + inspect) | `bash tests/test-phase17.sh test_reap_age_threshold_select` | ❌ Wave 0 |
| OPS-03 / D-04 | Orphan detection: containers younger than threshold skipped | unit | `bash tests/test-phase17.sh test_reap_age_threshold_skip` | ❌ Wave 0 |
| OPS-03 / D-05 | Reaper calls `docker compose -p X down -v --remove-orphans --timeout 10` | unit (mocked docker compose) | `bash tests/test-phase17.sh test_reap_compose_down_invocation` | ❌ Wave 0 |
| OPS-03 / D-05 | Reaper NEVER calls `docker rmi` or `docker image prune` | static grep | `bash tests/test-phase17.sh test_reap_never_touches_images` | ❌ Wave 0 |
| OPS-03 / D-06 | Stale event file (>24h old) is deleted | integration | `bash tests/test-phase17.sh test_reap_stale_event_files_deleted` | ❌ Wave 0 |
| OPS-03 / D-06 | Fresh event file (<24h old) is preserved | integration | `bash tests/test-phase17.sh test_reap_fresh_event_files_preserved` | ❌ Wave 0 |
| OPS-03 / D-06 | REAPER_EVENT_AGE_SECS env var honored | integration | `bash tests/test-phase17.sh test_reap_event_age_secs_override` | ❌ Wave 0 |
| OPS-03 / D-07 | Reaper only matches projects with INSTANCE_PREFIX | unit (mocked docker ps with mixed prefixes) | `bash tests/test-phase17.sh test_reap_instance_prefix_scoping` | ❌ Wave 0 |
| OPS-03 / D-08 | flock single-flight: second concurrent reaper exits silently | integration (background two reaps) | `bash tests/test-phase17.sh test_reap_flock_single_flight` | ❌ Wave 0 |
| OPS-03 / D-09 | Reaper writes only to journal (stdout/stderr), no JSONL files | static grep + integration | `bash tests/test-phase17.sh test_reap_no_jsonl_output` | ❌ Wave 0 |
| OPS-03 / D-09 | Cycle log lines match expected format (`reaper: cycle start/end`) | integration (capture stdout) | `bash tests/test-phase17.sh test_reap_log_format` | ❌ Wave 0 |
| OPS-03 / D-10 | Single-project teardown failure does not abort cycle | unit (mocked docker compose with one failure) | `bash tests/test-phase17.sh test_reap_per_project_failure_continues` | ❌ Wave 0 |
| OPS-03 / D-10 | Whole-cycle failure (no docker daemon) returns nonzero | unit (mocked) | `bash tests/test-phase17.sh test_reap_whole_cycle_failure_exits_nonzero` | ❌ Wave 0 |
| OPS-03 / D-11 | All 10 safe-subset directives present in BOTH unit files | static grep | `bash tests/test-phase17.sh test_d11_directives_present` | ❌ Wave 0 |
| OPS-03 / D-11 | NO forbidden directives in either unit file | static grep | `bash tests/test-phase17.sh test_d11_forbidden_directives_absent` | ❌ Wave 0 |
| OPS-03 / D-11 | Hardening rationale comment block present in both unit files | static grep | `bash tests/test-phase17.sh test_d11_comment_block_present` | ❌ Wave 0 |
| OPS-03 / D-12 | (E2E gate) Listener still processes webhooks under D-11 directives | E2E (D-14 scenarios 1+2) | `bash tests/test-phase17-e2e.sh scenario_hmac_rejection scenario_concurrent_execution` | ❌ Wave 0 |
| OPS-03 / D-14.1 | HMAC rejection scenario | E2E | `bash tests/test-phase17-e2e.sh scenario_hmac_rejection` | ❌ Wave 0 |
| OPS-03 / D-14.2 | Concurrent execution scenario | E2E | `bash tests/test-phase17-e2e.sh scenario_concurrent_execution` | ❌ Wave 0 |
| OPS-03 / D-14.3 | Orphan cleanup scenario (sentinel container) | E2E | `bash tests/test-phase17-e2e.sh scenario_orphan_cleanup` | ❌ Wave 0 |
| OPS-03 / D-14.4 | Resource limit enforcement scenario | E2E | `bash tests/test-phase17-e2e.sh scenario_resource_limits` | ❌ Wave 0 |
| OPS-03 / D-15 | E2E wall-clock budget ≤ 90s | E2E (built-in guard) | `bash tests/test-phase17-e2e.sh && [ $SECONDS -le 90 ]` | ❌ Wave 0 |
| OPS-03 / D-16 | profile-e2e fixture exists with INSTANCE_PREFIX=e2e-, fake REPORT_REPO_TOKEN | static | `bash tests/test-phase17.sh test_profile_e2e_fixture_shape` | ❌ Wave 0 |
| OPS-03 / D-17 | install.sh has step 5d that copies reaper unit + timer | static grep | `bash tests/test-phase17.sh test_installer_step_5d_present` | ❌ Wave 0 |
| OPS-03 / D-17 | install.sh enables claude-secure-reaper.timer | static grep | `bash tests/test-phase17.sh test_installer_enables_timer` | ❌ Wave 0 |
| OPS-03 / D-18 | install.sh prints post-install hint with `journalctl -u claude-secure-reaper` | static grep | `bash tests/test-phase17.sh test_installer_post_install_hint` | ❌ Wave 0 |
| OPS-03 / Pitfall 5 | docker-compose.yml declares `mem_limit` on claude service | static grep | `bash tests/test-phase17.sh test_compose_has_mem_limit` | ❌ Wave 0 |
| OPS-03 / Pitfall 13 | profile-e2e/.env REPORT_REPO_TOKEN does not start with ghp_ | static | `bash tests/test-phase17.sh test_e2e_token_no_ghp_prefix` | ❌ Wave 0 |
| OPS-03 / specifics | Reaper `--dry-run` prints kill list and exits without acting | unit | `bash tests/test-phase17.sh test_reap_dry_run` | ❌ Wave 0 |
| OPS-03 / specifics | Static grep guard: no `docker.*--force`, `rm -rf /opt`, `rm -rf /etc` in reaper paths | static | `bash tests/test-phase17.sh test_reap_grep_guard` | ❌ Wave 0 |
| Regression | Phase 13/14/15/16 tests still pass | regression | `bash tests/test-phase13.sh && tests/test-phase14.sh && tests/test-phase15.sh && tests/test-phase16.sh` | ✅ (files exist) |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase17.sh` (unit suite, < 10s — all tests use mocked docker)
- **Per wave merge:** Full Phase 17 suite + regression (`bash tests/test-phase{13,14,15,16,17}.sh && bash tests/test-phase17-e2e.sh`)
- **Phase gate:** Both unit + E2E green; total wall-clock < 120s combined; before `/gsd:verify-work`

### Wave 0 Gaps

All test files need to be created as failing scaffolds in Wave 0:

- [ ] `tests/test-phase17.sh` — unit-level reaper + static asserts (~30 named test functions)
- [ ] `tests/test-phase17-e2e.sh` — E2E four-scenario harness with budget guard
- [ ] `tests/fixtures/profile-e2e/profile.json` — `repo: "e2e/test"`, `webhook_secret: "e2e-test-secret"`, `report_branch: "main"`, `report_path_prefix: "reports"`, `report_repo` populated by harness with bare-repo file:// URL at runtime
- [ ] `tests/fixtures/profile-e2e/.env` — `REPORT_REPO_TOKEN=fake-e2e-token` (no `ghp_` prefix per Pitfall 13)
- [ ] `tests/fixtures/profile-e2e/prompts/issues-opened.md` — minimal template referencing `{{ISSUE_TITLE}}`
- [ ] `tests/fixtures/profile-e2e/report-templates/issues-opened.md` — minimal template referencing `{{RESULT_TEXT}}`
- [ ] `webhook/claude-secure-reaper.service` — empty placeholder; populated in Wave 1
- [ ] `webhook/claude-secure-reaper.timer` — empty placeholder; populated in Wave 1
- [ ] `tests/fixtures/mock-docker-ps-fixture.txt` — fixture for unit-test docker ps mock (Pattern B / Pitfall 4)

*(Framework install: none — bash + jq + docker + systemd-analyze + flock + find + date all already present; verified via direct command invocation on host.)*

## Open Questions

1. **Should Phase 17 add `mem_limit` to the validator and proxy services too, or only the claude service?**
   - What we know: Pitfall 5 requires the claude service to have a memory limit so D-14 scenario 4 has something to assert. STATE.md Concern #3 specifies the claude container.
   - What's unclear: Whether the validator and proxy services need similar limits for defense-in-depth.
   - Recommendation: **Claude service only for Phase 17.** Adding limits to all three services expands scope. The claude container is the only one running untrusted LLM-driven code; the proxy and validator are deterministic. If a memory leak in the proxy/validator becomes a real issue, add it in v2.1. Document the choice in PROJECT.md after Phase 17 ships.

2. **Should the reaper subcommand accept `--all` to bypass INSTANCE_PREFIX scoping?**
   - What we know: D-07 locks per-instance scoping. CONTEXT discretion notes nothing about `--all`.
   - What's unclear: Whether operators running multiple instances on one host want a single command to reap everything.
   - Recommendation: **No.** Each instance has its own timer (one per `INSTANCE_PREFIX`). An `--all` flag is foot-gun territory (could reap a different operator's containers in shared-host setups). Document the per-instance pattern in README.

3. **Should the E2E test run as part of the regular pre-push hook, or only in CI / on demand?**
   - What we know: `tests/test-phase17.sh` (unit) is fast and belongs in pre-push. `tests/test-phase17-e2e.sh` is 90s wall-clock and requires a real Docker daemon.
   - What's unclear: Whether the project's pre-push hook can afford 90s for one test file.
   - Recommendation: **Unit test in pre-push, E2E on demand or in CI.** Mirror Phase 16's split — `bash tests/test-phase17.sh` runs locally fast; E2E is run before merging the phase via `bash tests/test-phase17-e2e.sh` manually.

4. **Should `Persistent=true` actually be in the reaper.timer file?**
   - What we know: The man page says it's "mostly useful for OnCalendar=" but doesn't forbid it for monotonic timers. Modern systemd accepts it for both.
   - What's unclear: Whether the project's CI runs the unit-file lint test on a systemd version old enough to reject it.
   - Recommendation: **Include `Persistent=true`** and let the CI lint test catch it. If the lint fails, drop the directive — missed reaper cycles are harmless. Document the dual outcome in the unit file comment block. (Pitfall 11 is the test for this.)

5. **Should the reaper journal lines be JSON or plain text?**
   - What we know: D-09 says journal-only via stdout/stderr, with example format `reaper: cycle start prefix=<X>`. Plain text by example.
   - What's unclear: Whether structured JSON would be easier to filter via `journalctl -o json`.
   - Recommendation: **Plain text** as D-09 examples show. journalctl already structures everything per-message; the prose format is human-readable. Operators who want JSON can use `journalctl -u claude-secure-reaper -o json-pretty`.

6. **Where should `do_reap` live in `bin/claude-secure` — alongside `do_spawn` or in a new section near `cleanup_containers`?**
   - What we know: CONTEXT discretion: "Whether reaper subcommand lives in `bin/claude-secure` directly or factors into a `do_reap` helper function (recommended: `do_reap` to mirror `do_spawn` / `do_replay`)."
   - What's unclear: Placement within the file.
   - Recommendation: **New section after `do_replay`**, near the end of the file before main dispatch. Mirrors the existing organizational pattern. The plan should add a comment block header `# Phase 17 D-01..D-10: do_reap orphan reaper`.

7. **Plan-split: confirm the 4-plan wave structure?**
   - Recommendation: Yes. Mirror Phase 16:
     - **Wave 0 (Plan 17-01):** `tests/test-phase17.sh` + `tests/test-phase17-e2e.sh` scaffolds + all fixtures + empty placeholder unit files. Tests fail because implementation does not exist.
     - **Wave 1a (Plan 17-02):** `webhook/claude-secure-reaper.service` + `.timer` populated. `do_reap`, `reap_orphan_projects`, `reap_stale_event_files`, flock guard, dispatch wiring in `bin/claude-secure`. Add `mem_limit: 1g` to `docker-compose.yml` claude service. **Apply D-11 hardening to BOTH unit files in this same wave** (CONTEXT specifics: single patch, both files).
     - **Wave 1b (Plan 17-03):** Populate E2E test scenarios 1–4 against the live Docker stack. This is the wave where most test functions flip green.
     - **Wave 2 (Plan 17-04):** Extend `install.sh install_webhook_service` with step 5d (reaper unit + timer copy + enable). Update README. Final regression run.
   - Alternative considered: Merge 1a+1b into one plan. **Rejected** because E2E scenarios depend on the reaper code AND unit files AND mem_limit being in place — coupling tightens if everything lands in one plan.

8. **Does the WSL2 systemd gate from Phase 14 D-26 need any changes for the reaper?**
   - What we know: D-17 says installer enables the reaper timer "subject to the same WSL2 `systemd=true` gate from Phase 14 D-26".
   - What's unclear: Whether Docker Desktop on WSL2 (which doesn't run dockerd via systemd) would even be able to reach docker.service from a systemd-launched reaper.
   - Recommendation: **No code changes needed.** The existing gate already skips `enable --now` on WSL2-without-systemd. On WSL2-with-systemd-and-Docker-Desktop, the reaper unit will fail at runtime (no `docker.service` to require) but D-10 best-effort semantics absorb the failure. Document in README: "On WSL2 with Docker Desktop, the reaper timer is enabled but cycles will silently no-op because Docker Desktop manages container lifecycle externally; orphan accumulation is less of a concern there."

9. **Should the reaper kill list be exposed via `claude-secure reap --list` (read-only) for operator inspection?**
   - What we know: CONTEXT specifics suggests a `--dry-run` flag.
   - What's unclear: Whether `--dry-run` is the same as `--list` or distinct.
   - Recommendation: **Single `--dry-run` flag.** Mirrors Phase 13's `--dry-run` semantics: print what would be done, don't do it. `--list` is redundant.

## Sources

### Primary (HIGH confidence)
- **bin/claude-secure** (project repo, lines 1–1500+) — existing functions reaper extends/clones (`spawn_cleanup`, `cleanup_containers`, `spawn_project_name`, `do_spawn`).
- **webhook/claude-secure-webhook.service** — listener unit file template; comment block listing forbidden hardening directives.
- **install.sh:267-418** — `install_webhook_service` function with WSL2 gate, daemon-reload, enable --now pattern; step 5b/5c template.
- **tests/test-phase16.sh** — full test harness pattern (stub claude-secure on PATH, local bare repo, $TEST_TMPDIR cleanup, named test functions).
- **docker-compose.yml** — verified: NO `mem_limit` declared. Phase 17 must add one (Pitfall 5).
- **`man systemd.timer`** on systemd 255 (verified on host) — `OnBootSec`, `OnUnitActiveSec`, `Persistent`, `AccuracySec`, `Unit=` directive contracts.
- **`man systemd.service`** on systemd 255 — `Type=oneshot`, `ExecStart=`, journal logging.
- **`man systemd.exec`** on systemd 255 — all 10 D-11 hardening directives documented and stable.
- **`man flock(1)`** on util-linux 2.39 — `-n` non-blocking, FD-based lock acquisition, exit codes.
- **`man find(1)`** on findutils 4.x — `-mmin`, `-mtime`, `-maxdepth`, `-type f`, `-delete`.
- **`docker ps --help`** + **`docker inspect --help`** — `--filter` semantics (exact-match for labels), `--format` Go template, `HostConfig.Memory` field.
- **`docker compose down --help`** — `-v`, `--remove-orphans`, `--timeout`, `-p` (project) flags.
- **Phase 14 CONTEXT.md D-23..D-26** — listener systemd pattern, root justification, WSL2 gate, hardening rejection list (the empirical record).
- **Phase 16 CONTEXT.md** + **16-RESEARCH.md** — `LOG_PREFIX` audit log convention, JSONL atomic-append guarantees, `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` test stub.
- **Phase 17 CONTEXT.md** — 18 locked decisions D-01..D-18 (primary constraint).
- **STATE.md Blockers/Concerns** — Phase 13 Concern #3: "Docker Compose `deploy.resources.limits` vs `mem_limit` -- verify with `docker inspect`" — closed by D-14 scenario 4 + Pitfall 5.

### Secondary (MEDIUM confidence)
- **Docker Compose v2 specification** (compose-spec.io) on `mem_limit` (short form) vs `deploy.resources.limits` (Swarm-only) — known distinction; trust based on training data + Pitfall 5 verification.
- **systemd `Persistent=` semantics for monotonic timers** — man page wording is conservative but practical behavior on systemd >= 232 supports it. Pitfall 11 test confirms or rejects.
- **WSL2 + Docker Desktop interaction with systemd** — Docker Desktop manages dockerd outside WSL systemd; the reaper unit will fail cleanly there. Documented as a known limitation in Pitfall 9.

### Tertiary (LOW confidence — flagged for validation)
- **Whether `RestrictNamespaces=true` interferes with bash subprocess invocation of `docker compose`** — none of the docker subprocess calls use `unshare`/`clone`, but a deeply nested call chain might. The E2E gate (D-12) is the empirical check. If the listener fails after Wave 1, this directive is the prime suspect; remove it and rerun.
- **Default report template prose** — N/A for Phase 17 (no new report templates introduced).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every tool already in use, versions verified on host
- Architecture patterns: HIGH — every pattern either clones existing code or uses a documented systemd/docker/flock primitive
- Pitfalls: HIGH on items 1–10 (carry-forward from Phase 14 + verified on docker/systemd man pages); MEDIUM on items 11–15 (depend on test-host specifics)
- D-11 hardening directives: HIGH — all 10 documented in current systemd, Phase 14 empirical record covers the forbidden 6
- E2E test design: HIGH on scenarios 1, 2, 4 (use existing primitives); MEDIUM on scenario 3 (Pitfall 4 backdate workaround is novel but provably correct)
- WSL2 reaper compatibility: MEDIUM (Pitfall 9) — Docker Desktop interaction needs manual verification
- `Persistent=true` on monotonic timer: MEDIUM (Pitfall 11) — works in practice, man page is conservative
- Pitfall 5 (mem_limit missing from compose): HIGH — verified by reading the file; closes a Phase 13 open concern

**Research date:** 2026-04-12
**Valid until:** 2026-05-12 (30 days — stable systemd/docker/flock primitives, codebase conventions locked, Phase 14 empirical record is the gold standard for hardening compatibility)
