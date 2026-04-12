# Phase 17: Operational Hardening - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Mode:** User-delegated auto-chain (pattern: user said "1" → Claude selected all gray areas and picked recommended options with rationale, same pattern as Phases 14/15/16)

<domain>
## Phase Boundary

Phase 17 closes the v2.0 milestone with two deliverables:

1. **Container reaper** — A systemd timer that periodically removes orphaned spawn artifacts (containers + their volumes + networks + stale event files) left behind by failed runs, OOM kills, host crashes, and any code path where the `spawn_cleanup` EXIT trap (Phase 13) never fired.
2. **End-to-end integration test** — A single self-contained suite that exercises the full webhook → spawn → report pipeline against the real Docker stack, covering HMAC rejection, concurrent execution, orphan cleanup, and resource limit enforcement. This is the integration safety net for v2.0.

The phase satisfies **OPS-03** and folds in three Phase 14 deferred items that align with reaper scope: event file retention (D-20), and revisits the listener-unit hardening directives Phase 14 backed away from (D-24, D-26). It does NOT add features beyond OPS-03 — no rate limiting, no dedicated system user, no health webhook, no cost dashboards.

**Scope anchor:** Reaper as a systemd timer + the E2E test. Everything else is deferred.

</domain>

<decisions>
## Implementation Decisions

### Reaper Trigger & Lifecycle

- **D-01:** Reaper is a **systemd timer + oneshot service pair**, mirroring the existing `webhook/claude-secure-webhook.service` pattern from Phase 14. Files: `webhook/claude-secure-reaper.service` (Type=oneshot, ExecStart=/usr/local/bin/claude-secure reap) and `webhook/claude-secure-reaper.timer` (OnBootSec=2min, OnUnitActiveSec=5min, Persistent=true). Installer copies both into `/etc/systemd/system/` alongside the listener unit.
- **D-02:** Reaper interval is **5 minutes** (`OnUnitActiveSec=5min`). Rationale: matches the "bounded time window" wording in the OPS-03 success criterion, gives operators a tight enough recovery window without spawning a tight loop, and aligns with the Phase 13 max-turns budget timing. Configurable later via drop-in if operators request it; not parameterized in v2.0.
- **D-03:** Reaper invocation is **`claude-secure reap`** — a new top-level subcommand in `bin/claude-secure` (parallel to `spawn`, `replay`, `whitelist`, etc.). Rationale: keeps the reap logic colocated with the existing helpers it reuses (`docker compose down`, profile resolution, `LOG_PREFIX` handling), avoids a second binary, and lets the reaper benefit from the Phase 12 multi-instance prefix convention for free.

### Orphan Detection

- **D-04:** Orphan detection is **label-based + age-thresholded**, NOT audit-coupled. The reaper iterates `docker ps --filter "label=com.docker.compose.project=<INSTANCE_PREFIX>spawn-*" --format '{{.ID}} {{.Label "com.docker.compose.project"}} {{.CreatedAt}}'` and tears down any project whose containers are older than `REAPER_ORPHAN_AGE_SECS` (default **600 seconds = 10 minutes**, twice the timer interval). Rationale: zero coupling to `executions.jsonl` (survives audit log rotation, missing files, schema drift), label-scoped (multi-instance safe), and the 10-minute floor leaves comfortable headroom for the longest legitimate Phase 13 spawns (max-turns budget caps these well under 10 min).
- **D-05:** Per matched compose project, the reaper executes **`docker compose -p <project> down -v --remove-orphans --timeout 10`**. The `-v` flag removes the project's anonymous volumes (matches `spawn_cleanup` semantics from `bin/claude-secure:336`). Networks are removed by `down` automatically. **Images are never touched** — image rebuild is expensive and unrelated to orphan state.
- **D-06:** Reaper also reaps **stale event files** under `$CONFIG_DIR/events/` (Phase 14 D-20 deferred item). Files older than `REAPER_EVENT_AGE_SECS` (default **86400 seconds = 24 hours**) are deleted. This is the only retention policy; persistence beyond 24h is the operator's job (e.g., copy to a doc repo). Stale files are deleted regardless of whether the audit log shows the run completed — the audit log is the source of truth for what happened, the events directory is a transient buffer.

### Multi-Instance Safety

- **D-07:** Reaper honors the **v1.0 LOG_PREFIX convention**. When invoked, it reads `INSTANCE_PREFIX` from `config.sh` (or empty for the default instance) and only matches compose projects whose label prefix matches. This means `claude-secure-default` reap never touches `claude-secure-test` containers. Two instances on one host run two timer units, each scoped to its prefix.
- **D-08:** Reaper uses **`flock` on `$LOG_DIR/${LOG_PREFIX}reaper.lock`** to prevent two reaper instances of the same prefix racing each other (e.g., timer fires while a manual `claude-secure reap` is in flight). Lock acquisition is non-blocking (`flock -n`); if held, reaper exits 0 silently with a journal log line. Rationale: oneshot Type guarantees one timer-driven run at a time, but manual invocation breaks that — flock is the belt to systemd's suspenders.

### Reaper Logging & Failure Handling

- **D-09:** Reaper logs to **systemd journal only** via stdout/stderr (`journalctl -u claude-secure-reaper`). One line per cycle: `reaper: cycle start prefix=<X>`, `reaper: reaped <project> age=<N>s` per kill, `reaper: cycle end killed=<N> events_deleted=<M> errors=<E>`. **No separate JSONL** — adding another log file complicates rotation and the audit log already records spawns; reaper actions are pure ops state.
- **D-10:** Reaper failures are **best-effort, non-fatal**. If `docker compose down` fails for one project, log the error to journal and continue to the next match. Reaper only exits nonzero if the entire cycle errors out (e.g., docker daemon unreachable) so systemd can mark the unit failed and surface it via `systemctl status`. Rationale: a single stuck container shouldn't block reaping the rest.

### Listener Hardening Revisit (Phase 14 D-24/D-26 follow-up)

- **D-11:** **Add the safe subset of systemd hardening directives** to BOTH `claude-secure-webhook.service` and the new `claude-secure-reaper.service`. The safe subset is empirically derived from Phase 14's pitfalls: directives that do NOT touch `/var/run/docker.sock`, `/tmp` (compose state), filesystem writes for compose, or capability-bound docker subprocess calls. The locked subset:
  - `ProtectKernelTunables=true`
  - `ProtectKernelModules=true`
  - `ProtectKernelLogs=true`
  - `ProtectControlGroups=true`
  - `RestrictNamespaces=true` (does NOT block container namespaces — only the listener process's own unshare/clone calls)
  - `LockPersonality=true`
  - `RestrictRealtime=true`
  - `RestrictSUIDSGID=true`
  - `MemoryDenyWriteExecute=true` (Python listener doesn't JIT)
  - `SystemCallArchitectures=native`
  
  **Explicitly NOT added** (Phase 14 confirmed each breaks docker compose subprocess): `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`, `CapabilityBoundingSet`, `ProtectHome`, `PrivateDevices`. Rationale documented inline in the unit file as a comment block so future maintainers don't re-attempt the hardening that already burned Phase 14.
- **D-12:** Each new directive lands behind an **integration test gate** in the E2E suite — after install, the test verifies the listener actually starts and processes a webhook end-to-end. If any directive in D-11 turns out to break the listener on the test host, the failing directive is removed from the unit file (NOT added back as commented-out — silently dead config attracts re-enable attempts). The locked list in D-11 is the post-test-validated set.

### End-to-End Integration Test

- **D-13:** E2E test file: **`tests/test-phase17-e2e.sh`** — a single self-contained harness that runs against the real Docker stack with a stubbed Claude binary (reuses `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` from Phase 16). NOT merged into `tests/test-phase17.sh` (which is the unit-level reaper test). Two files = two layers, matches the per-phase pattern from 12-16.
- **D-14:** E2E covers **exactly four scenarios** (mapped 1:1 to OPS-03 success criterion 2):
  1. **HMAC rejection** — POST a payload with a wrong signature → assert 401, no spawn invoked, audit log unchanged.
  2. **Concurrent execution** — POST 3 valid payloads in parallel (matches Phase 14 `Semaphore(3)` bound) → assert 3 audit entries, 3 reports pushed to bare repo, no JSONL line corruption (`jq -c` parses every line).
  3. **Orphan cleanup** — Manually `docker run --label com.docker.compose.project=<prefix>spawn-fake-orphan` a sentinel container with backdated creation time → run `claude-secure reap` → assert sentinel container is gone, real instances untouched.
  4. **Resource limit enforcement** — Spawn a container, `docker inspect` it, assert `Memory` and `MemorySwap` match the limit declared in `docker-compose.yml` for the spawn service. (Verifies Phase 13's Concern #3 that "Docker Compose `deploy.resources.limits` vs `mem_limit` -- verify with `docker inspect`" actually wired through.)
- **D-15:** E2E test runtime budget: **≤90 seconds**. Concurrent execution is the slowest scenario; bounded by the Phase 16 stub spawn time (~5s) × 3 in parallel + 60s ceiling. If runtime exceeds 90s on the dev host, the test fails the budget guard rather than silently slowing the suite.
- **D-16:** E2E uses a **dedicated `tests/fixtures/profile-e2e/`** profile directory with its own `.env` (containing `REPORT_REPO_TOKEN=ghp_FAKEE2E`), a local bare report repo path (under `$TMPDIR`), and `INSTANCE_PREFIX=e2e-` so it never collides with the operator's real instance. Cleanup: `trap` removes the entire `$TMPDIR/e2e-*` tree and runs `claude-secure --instance e2e reap` at exit.

### Installer Extension

- **D-17:** `install.sh install_webhook_service` extends to **also copy the reaper unit + timer** in a new step (after the existing 5c report-templates step). The two new files (`claude-secure-reaper.service`, `claude-secure-reaper.timer`) install to `/etc/systemd/system/` with mode 644, and the timer is `enable --now`-ed alongside the listener (subject to the same WSL2 `systemd=true` gate from Phase 14 D-26). Rationale: reaper is operationally meaningless without the listener (no orphans without spawns), so they install/enable together.
- **D-18:** Installer prints a **post-install hint** when the timer is enabled: `"Reaper timer active — runs every 5 minutes. View activity: journalctl -u claude-secure-reaper -f"`. This is the operator's first signal that the reaper is alive.

### Folded Todos
- **iptables packet-level logging** (Pending Todo) — **NOT folded**. Re-reviewed: belongs to validator service hardening, not OPS-03. Out of scope for Phase 17. Stays in backlog for v2.1.
- **Phase 14 D-20: event file retention/cleanup** — **FOLDED** as D-06. Reaper extension is the natural home.
- **Phase 14 D-24 follow-up: dedicated system user for listener** — **NOT folded**. Adds installer complexity (group management, ownership transfers) without addressing OPS-03 directly. Stays deferred.
- **Phase 14 deferred: rate limiting on /webhook** — **NOT folded**. Orthogonal to orphan cleanup. Stays deferred.

### Claude's Discretion
- Exact prose of the unit file comment blocks documenting the D-11 safe subset
- Whether reaper subcommand lives in `bin/claude-secure` directly or factors into a `do_reap` helper function (recommended: `do_reap` to mirror `do_spawn` / `do_replay`)
- Whether the manual-orphan sentinel in D-14 scenario 3 is a real `docker run` or a mock label-only entry (recommended: real `docker run busybox sleep 3600` so the test exercises real container teardown)
- Test fixture reuse from Phase 16 (recommended: reuse `tests/fixtures/envelope-success.json`, `tests/fixtures/report-repo-bare/` setup helpers)
- JSON ordering of journal log lines (cosmetic)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Prior Phase Contracts
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` — `spawn_cleanup` EXIT trap (the "happy path" cleanup that the reaper backstops), max-turns budget rationale, container lifecycle
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — D-20 (event file retention deferred), D-23..D-26 (systemd unit pattern, WSL2 gate), D-24 (root listener justification — same applies to reaper unit), the unit file comment block warning against re-enabling broken hardening
- `.planning/phases/15-event-handlers/15-CONTEXT.md` — Concurrent execution semantics (`Semaphore(3)` listener bound) — drives D-14 scenario 2 worker count
- `.planning/phases/16-result-channel/16-CONTEXT.md` — D-04 LOG_PREFIX convention applied to reaper (D-07), `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` test stub reused for E2E (D-13), audit log shape (reaper does NOT write to it)

### Project-level
- `.planning/REQUIREMENTS.md` — OPS-03 definition; HEALTH-01/02 explicitly out of scope
- `.planning/PROJECT.md` — Multi-instance support, isolation guarantees the reaper must preserve
- `.planning/STATE.md` — Pending Todos (iptables logging stays in backlog), Blockers/Concerns (Phase 13 #3 resource limit verification — D-14 scenario 4 closes this)
- `CLAUDE.md` — Tech stack constraints (bash, python3, jq, docker compose v2)

### Implementation References
- `bin/claude-secure:336` — `spawn_cleanup()` (`docker compose down -v --remove-orphans` — pattern reaper inherits)
- `bin/claude-secure:298-302` — `cleanup_containers()` (existing instance-level container cleanup; reaper extends this with age threshold + label scoping)
- `bin/claude-secure:700+` — `do_spawn` function (the function whose orphans we're cleaning up)
- `bin/claude-secure` subcommand dispatch — pattern for adding `reap` subcommand
- `webhook/claude-secure-webhook.service` — Unit file pattern for `claude-secure-reaper.service`; the comment block at top documenting Phase 14's hardening pitfalls is the template for D-11
- `install.sh:280-405` — `install_webhook_service` function (the extension point for D-17, reaper unit/timer install)
- `install.sh:348-371` — Phase 15/16 step 5b/5c pattern (template installer steps to mirror)
- `tests/test-phase16.sh` — Phase 16 harness pattern (`run_spawn_integration` helper, `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` stub) — reuse for E2E
- `docker-compose.yml` — `deploy.resources.limits` or `mem_limit` declarations; D-14 scenario 4 inspects these

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`spawn_cleanup()`** at `bin/claude-secure:336` — Already runs `docker compose down -v --remove-orphans` on EXIT trap. Reaper does the same operation, just for projects whose trap never fired.
- **`cleanup_containers()`** at `bin/claude-secure:298` — Existing instance-level cleanup; reaper extends with age threshold + label scope.
- **Profile loader / `INSTANCE_PREFIX` resolution** (Phase 12) — Reaper reuses the same convention so multi-instance hosts get clean separation for free.
- **`webhook/claude-secure-webhook.service`** — Unit file template: `[Unit]/[Service]/[Install]` blocks, comment header documenting locked decisions, journalctl as the log path.
- **`install.sh install_webhook_service`** — The step-by-step installer pattern with WSL2 gate, systemctl daemon-reload + enable --now, error handling, post-install hint. Phase 17 clones this for the timer.
- **`tests/test-phase16.sh::run_spawn_integration`** + `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` — The stubbed-Claude integration harness reused verbatim by E2E.
- **`tests/fixtures/envelope-success.json`** + **`tests/fixtures/report-repo-bare/`** — Phase 16 fixtures the E2E test reuses.

### Established Patterns
- **systemd unit installer step** — Phase 14 D-23..D-26 + Phase 15 5b + Phase 16 5c. Extend with 5d for reaper.
- **WSL2 systemd gate** — Phase 14 D-26 warn-don't-block pattern; reaper inherits.
- **Stubbed-Claude integration tests** — Phase 16 escape hatch (`CLAUDE_SECURE_FAKE_CLAUDE_STDOUT`) is the only way to E2E without burning real API cost.
- **`flock` for multi-process coordination** — Standard bash pattern, used elsewhere in the codebase for state file safety.
- **Label-based container selection** — Docker Compose sets `com.docker.compose.project=<name>` automatically; reaper uses this as the orphan-discovery primary key.

### Integration Points
- **`bin/claude-secure` subcommand dispatch** — Add `reap)` case alongside existing `spawn)`, `replay)`, etc.
- **`install.sh install_webhook_service`** — Extend with reaper unit/timer install step (5d).
- **Two new files in `webhook/`** — `claude-secure-reaper.service`, `claude-secure-reaper.timer`. Sit alongside the listener unit so installer logic stays clustered.
- **`tests/test-phase17.sh`** (unit) + **`tests/test-phase17-e2e.sh`** (integration) — Two-tier test split.
- **`tests/test-map.json`** — Append OPS-03 mappings.

</code_context>

<specifics>
## Specific Ideas

- **Nyquist self-healing test pattern** carries forward: Wave 0 writes failing test scaffold for both `test-phase17.sh` and `test-phase17-e2e.sh`; later waves flip them green.
- **Reaper "kill list" test pattern**: For unit tests, mock `docker ps` output via a wrapper script on `$PATH` that returns a fixture string. Reaper's selection logic then operates on the fixture, no real docker daemon needed for unit tests. E2E test uses the real daemon.
- **OPS-03 grep guard**: Test asserts `git grep -E 'docker.*--force|rm -rf /opt|rm -rf /etc'` returns ZERO matches across reaper code paths. The reaper is privileged — paranoia about scope is warranted.
- **Reaper dry-run flag**: Add `claude-secure reap --dry-run` that prints what WOULD be killed without acting. Mirrors Phase 13's `--dry-run` and gives operators a manual safety check before trusting the timer.
- **D-04 age threshold safety**: 600s default explicitly leaves a 5x cushion over the longest expected legitimate spawn (~120s for a max-turns-15 run with stubbed Claude). Real Claude runs that legitimately exceed 10 min would be killed by the reaper — this is the deliberate trade-off, documented in PROJECT.md after Phase 17 ships.
- **D-11 hardening directives**: Apply via a single patch to BOTH unit files in one commit so the test gate (D-12) catches any breakage in the same wave that introduces it.

</specifics>

<deferred>
## Deferred Ideas

- **iptables packet-level logging** — Stays in backlog (validator service hardening, not OPS-03). v2.1 candidate.
- **Dedicated system user for listener + reaper** — Phase 14 D-24 trade-off still holds. Defer until a compelling reason emerges.
- **Rate limiting on /webhook** — Orthogonal to OPS-03. Reverse proxy / tunnel layer is the right home.
- **Reaper interval configurability** — Currently hardcoded 5min; expose via systemd drop-in if operators ask.
- **Reaper metrics export** (Prometheus, statsd) — Adds dependency. journalctl is enough for v2.0.
- **Reaper notification on kill** (webhook back to a Slack/Discord) — HEALTH-02. Out of scope.
- **Aggregate orphan reports** (a daily summary) — Out of scope; journalctl filtering covers it.
- **Reaping `events/` based on audit log cross-reference** — Rejected in favor of pure age-based (D-06 rationale).
- **Image pruning** — Explicitly excluded from D-05; image rebuild is expensive.
- **Reaping bind-mount workspaces** — Workspaces are user data, never reaped automatically.
- **End-to-end test against real Claude API** — Cost-prohibitive; D-13 stubs Claude. Operator can run a manual smoke test if desired (documented as a manual verification, mirror of Phase 16's manual real-PAT test).

### Reviewed Todos (not folded)
- **iptables packet-level logging** — already covered above; not Phase 17 scope.

</deferred>

---

*Phase: 17-operational-hardening*
*Context gathered: 2026-04-12*
