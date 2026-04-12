# Phase 17: Operational Hardening — Discussion Log

**Date:** 2026-04-12
**Mode:** User-delegated auto-chain (user said "1" → Claude selected all gray areas and picked recommended options with rationale)
**Pattern:** Same as Phases 14, 15, 16

## Gray Areas Auto-Selected

All 8 gray areas presented to user; user delegated decision via "1".

| # | Gray Area | Selected Option | Rationale | CONTEXT.md Refs |
|---|-----------|----------------|-----------|----------------|
| 1 | Reaper trigger model | systemd timer @ 5 min interval | Matches "bounded time window" wording in OPS-03; mirrors Phase 14 listener unit pattern; simplest viable | D-01, D-02 |
| 2 | Orphan detection criteria | Compose project label + 10-minute age threshold | Zero coupling to audit log; survives audit rotation; multi-instance safe via label scoping | D-04, D-07 |
| 3 | Hardening directives revisit (Phase 14 D-24/D-26 followup) | Add safe subset (10 directives), explicitly skip the 6 confirmed-broken | Docs Phase 14's pitfalls inline; gates each new directive behind E2E test | D-11, D-12 |
| 4 | E2E integration test scope | Real Docker stack with stubbed Claude (CLAUDE_SECURE_FAKE_CLAUDE_STDOUT from Phase 16) | Exercises real network isolation + systemd + iptables; only Claude binary stubbed (cost) | D-13, D-14, D-15, D-16 |
| 5 | Reaper scope per cleanup pass | Containers + their volumes + networks; never images | Mirrors `spawn_cleanup` semantics; image rebuild expensive and unrelated | D-05 |
| 6 | Reaper failure handling | Systemd journal only (`journalctl -u claude-secure-reaper`) | Avoids second log file; audit log already has spawn truth; one-line-per-cycle structured logging | D-09, D-10 |
| 7 | iptables packet-level logging (Pending Todo) | NOT folded — defer to v2.1 backlog | Belongs to validator hardening, not OPS-03; would double Phase 17 scope | Folded Todos section |
| 8 | Concurrent execution test count | 3 parallel spawns (matches Phase 14 `Semaphore(3)` listener bound) | Maximum the listener accepts; tests audit append-safety contract | D-14 scenario 2 |

## Folded Items from Prior Phases

- **Phase 14 D-20 (event file retention)** → folded as D-06 (reaper extends to `$CONFIG_DIR/events/` files older than 24h)
- **Phase 14 D-24 follow-up (dedicated system user)** → NOT folded (installer complexity, no OPS-03 benefit)
- **Phase 14 deferred (rate limiting)** → NOT folded (orthogonal to orphan cleanup)
- **STATE.md Pending Todo (iptables packet-level logging)** → NOT folded (validator hardening, not OPS-03)

## Locked Decisions Summary

18 decisions, 8 sections:
- Reaper Trigger & Lifecycle (D-01..D-03)
- Orphan Detection (D-04..D-06)
- Multi-Instance Safety (D-07..D-08)
- Reaper Logging & Failure Handling (D-09..D-10)
- Listener Hardening Revisit (D-11..D-12)
- End-to-End Integration Test (D-13..D-16)
- Installer Extension (D-17..D-18)

## Next Steps

→ `/gsd:plan-phase 17 --auto` (research + plan + plan-checker, following the 14/15/16 chain pattern)
→ `/gsd:execute-phase 17 --auto --no-transition` (closes v2.0 milestone)

---

*Phase 17 closes the v2.0 Headless Agent Mode milestone (6/6 phases).*
