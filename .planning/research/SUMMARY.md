# Project Research Summary

**Project:** claude-secure v3.0 — macOS Support
**Domain:** Cross-platform port of a Docker-based network-isolation security wrapper from Linux/WSL2 to macOS
**Researched:** 2026-04-13
**Confidence:** MEDIUM-HIGH

## Executive Summary

claude-secure v3.0 adds macOS as a supported platform. The existing four-layer security model (Docker isolation, PreToolUse hook validation, Node.js buffered proxy with secret redaction, Python+iptables call validator) does not need to be redesigned in principle — Docker Desktop provides a full Linux kernel VM where container-level iptables continues to work. However, two macOS-specific differences force meaningful changes: (1) the host service manager is launchd, not systemd, requiring new plist-based daemon definitions; and (2) macOS ships a badly outdated Bash 3.2 and BSD coreutils rather than GNU, which will silently break the approximately 2,300 lines of existing host-side Bash scripts.

The biggest unresolved question for this milestone is where network enforcement lives on macOS. The three research agents disagree in a way that cannot be resolved without testing on real hardware. The Stack agent argues iptables still works inside Docker Desktop's LinuxKit VM and pf is not needed. The Architecture agent argues iptables-in-container has a documented history of crashing Docker Desktop's network stack on macOS and enforcement must move to a host-side pfctl anchor driven by a launchd daemon. The Features agent, drawing from those same docker/for-mac issues, concludes the proxy chokepoint is the safer fallback. This conflict is the single biggest open question for v3.0 and must be resolved empirically before Phase C begins. Both possible outcomes (iptables-in-VM stays, or host-side pf replaces it) have clear implementation paths documented in the research.

The macOS port is well-understood from an infrastructure standpoint: launchd plists, Homebrew dependency bootstrap, platform detection via uname -s, and the enforcement decision gate the rest. The macOS-specific pitfalls are numerous but well-documented and skew toward silent failure — the most dangerous mode for a security tool. Every macOS implementation phase must include active self-verification tests that fail loudly, not just pass/fail integration tests at the HTTP layer.

---

## Key Findings

### Stack Additions for macOS

The v1.0/v2.0 stack (Docker Compose, Node.js 22 stdlib proxy, Python 3.11 stdlib validator, SQLite, Bash hooks) carries forward unchanged inside containers. The macOS delta is entirely on the host side and in one container image change.

**Core technologies added or changed:**

- **launchd (LaunchDaemon)**: Replaces systemd for all persistent host daemons. Webhook listener and (if pf path is chosen) the validator daemon both become `/Library/LaunchDaemons/` plists loaded via `launchctl bootstrap system`. Use `bootstrap`/`bootout` exclusively — `load`/`unload` are deprecated and unreliable across macOS versions. `KeepAlive` must be a dict (`Crashed=true, SuccessfulExit=false`) with `ThrottleInterval=10` to prevent crash-loop runaway. Plists must be root:wheel 0644 or launchd refuses to load them.
- **Homebrew bash 5.x**: macOS ships `/bin/bash` 3.2.57 (2007, pre-GPLv3). `declare -A`, `mapfile`, `${var,,}`, `${var^^}`, `|&`, `&>>` all fail or silently misbehave on 3.2. Scripts must self-exec via a PATH-shimmed brew bash 5+ if `BASH_VERSINFO[0] < 4`. Shebang must be `#\!/usr/bin/env bash`, never `#\!/bin/bash`.
- **Homebrew coreutils (GNU)**: BSD `date`, `sed -i`, `readlink -f`, `stat`, `xargs -r` all have incompatible flags that silently corrupt behavior. Recommended pattern: prepend `$(brew --prefix)/opt/coreutils/libexec/gnubin` to PATH at the top of every host script. Do not scatter `gdate`/`gsed` calls — the PATH-shim approach keeps scripts auditable.
- **Validator base image switch**: `python:3.11-alpine` < 3.19 ships `iptables-legacy`; Docker Desktop Mac's LinuxKit VM uses the nftables backend. Mismatch causes `can't initialize iptables table 'filter': iptables who?` errors. Switch to `python:3.11-slim-bookworm` (Debian, uses iptables-nft by default). Alternatively pin Alpine 3.19+ with explicit nft-backed iptables install, but the 80MB size delta for slim-bookworm is acceptable for a dev tool.
- **`host.docker.internal` for hook registration**: On Linux, hooks register call-IDs with the validator via `127.0.0.1:<port>`. On macOS, containers must use `host.docker.internal`. Parameterize as `VALIDATOR_HOST` env var set per platform.
- **Docker Desktop floor**: Require version 4.44.3+ for CVE-2025-9074 fix. Add to `doctor` preflight.
- **pf (packet filter) — deferred**: pf is deliberately not added unless the Phase C empirical test confirms iptables-in-container is unreliable on macOS. If added, it uses a dedicated anchor at `/Library/Application Support/claude-secure/` loaded by a one-shot launchd plist. Never modify `/etc/pf.conf` directly (SIP risk, macOS update overwrites it).

### Features: macOS Delta

The FEATURES.md file covers v2.0 headless agent mode research; the macOS-specific feature breakdown was provided as inline data:

| Status | Count | Representative Examples |
|--------|-------|------------------------|
| IDENTICAL — no change on macOS | 17 | Proxy secret redaction, hook validation logic, Docker Compose internal networking, Claude Code invocation |
| GUARD — platform branch required | 5 | Installer, uninstaller, webhook listener setup, firewall rule management, CLI PATH handling |
| PORT — macOS-specific implementation | 3 | Service manager (launchd), network enforcement (iptables vs pf — open decision), host dependency bootstrap (Homebrew) |
| REDESIGN — non-trivial architectural change | 2 | Validator placement (container vs host-side daemon), proxy placement (container vs host-side if pf path chosen) |
| NOT AVAILABLE | 1 | `flock`-based file locking; substitute with `mkdir` atomicity |

**Must-have (table stakes) for macOS launch:**
- All four security layers must be active and verifiable on Docker Desktop 4.44.3+
- Webhook listener must run on boot without a logged-in user (LaunchDaemon, not LaunchAgent)
- Installer must complete successfully on both Apple Silicon and Intel Macs
- Uninstaller must cleanly remove all daemons, anchors, and config without requiring manual steps

**Defer to v3.1:**
- Host-level pf enforcement of the webhook listener's own egress (new feature, not a port)
- Colima/OrbStack support as tested alternatives (document as "should work" only)
- Automated macOS E2E CI if GitHub Actions macOS runner cost is prohibitive

### Architecture Approach

The macOS architecture diverges from Linux/WSL2 at exactly one point: the enforcement layer and the service manager. Everything inside Docker Compose (proxy, claude container, hook scripts) is unchanged. Everything above the Docker boundary (systemd to launchd, iptables-container-managed vs pf-host-managed) is platform-specific.

**The open architectural decision — must be resolved empirically in Phase C:**

| Option A: iptables stays in container | Option B: enforcement moves to host pf |
|--------------------------------------|---------------------------------------|
| Stack agent recommendation | Architecture and Features agent recommendation |
| Lower implementation cost | Higher implementation cost |
| Works if crashes are `--network=host`-specific | Required if NET_ADMIN + bridge networking also crashes |
| Validator stays a container service | Validator becomes a launchd daemon; container removed from compose on macOS |
| Proxy stays in container | Proxy likely moves to host as a launchd daemon |
| pf not added | pf anchor at `/Library/Application Support/claude-secure/` |
| Resolution: boot Docker Desktop, add NET_ADMIN + bridge, run iptables, observe for 30 min | Same test, watching for crashes |

**Major components and macOS disposition:**

1. **`claude` container** — UNCHANGED. Hook registration URL parameterized to `host.docker.internal` on macOS.
2. **`proxy` container** — UNCHANGED (Option A). Moved to host launchd daemon (Option B, to enable uid-based pf filtering).
3. **`validator` container** — UNCHANGED (Option A). Deleted from compose on macOS, replaced by host-side launchd daemon driving pfctl anchors (Option B).
4. **`lib/platform.sh`** — NEW. Single sourced detection function returning `macos`/`wsl2`/`linux`. `CLAUDE_SECURE_PLATFORM_OVERRIDE` env var for CI mocking.
5. **`com.claude-secure.webhook.plist`** — NEW. LaunchDaemon replacing the Linux systemd webhook unit.
6. **`com.claude-secure.validator.plist`** — NEW, Option B only.
7. **`com.claude-secure.pf-loader.plist`** — NEW, Option B only. One-shot RunAtLoad to restore pf anchor after reboot.
8. **`installer.sh` / `uninstaller.sh`** — MODIFIED. Platform branches for all system-state operations.

### Critical Pitfalls

1. **Docker Desktop iptables silent bypass** — Validator starts successfully, NET_ADMIN is granted, but iptables rules silently fail to apply inside the LinuxKit VM, meaning all outbound calls pass through regardless of whitelist. This is the worst possible failure mode: security appears working but is not. Prevention: validator entrypoint must insert a test rule and verify it appears in `iptables -L`, failing loudly if not. Integration tests must assert TCP-level blocking (not just HTTP 403). Use native arm64 images on Apple Silicon — no Rosetta emulation for containers with NET_ADMIN.

2. **pf zombie anchors on Ventura+** — `pfctl -a claude-secure -F all` flushes rules but leaves the anchor node in memory until reboot. Old blocking rules can linger after uninstall+reinstall in the same session. Prevention: installer detects stale anchors via `pfctl -sr -a claude-secure` and refuses to proceed; uninstaller warns reboot may be required; integration tests run from a fresh boot or VM snapshot.

3. **Bash 3.2 silent misbehavior** — macOS `/bin/bash` is 3.2.57. `${var,,}` (lowercase expansion) returns the variable unchanged rather than erroring, causing domain matching to fail open — a security bypass that does not produce errors. Prevention: every host script version-checks `BASH_VERSINFO[0]` at entry and self-execs via Homebrew bash 5+ if below 4. CI must include a Bash 3.2 gate job. Audit all 2,300 existing lines for 4.0+ syntax.

4. **LaunchAgent vs LaunchDaemon** — If the webhook listener plist lands in `~/Library/LaunchAgents/` instead of `/Library/LaunchDaemons/`, the daemon dies at logout and GitHub webhook events are silently dropped. Prevention: always use `/Library/LaunchDaemons/`, root:wheel 0644, `launchctl bootstrap system`. Document explicitly why LaunchDaemon was chosen.

5. **BSD coreutils silent data corruption** — `sed -i 's/x/y/' file` on macOS creates a backup file named `s/x/y/` and leaves the original unmodified — no error, config updates silently do not apply. `date -d` errors at runtime. Prevention: PATH-shim GNU coreutils from Homebrew via `$(brew --prefix)/opt/coreutils/libexec/gnubin` at the top of every host script. CI must run integration tests on a macOS runner.

6. **SIP blocks `/etc/pf.conf` edits** — Editing `/etc/pf.conf` may succeed on some macOS versions but is silently overwritten by OS updates. Prevention: never modify `/etc/pf.conf`. Use a dedicated anchor file at a non-SIP path, loaded by a one-shot launchd plist. Verify `csrutil status` remains enabled — SIP disabled is a blocking issue for a security tool.

---

## Implications for Roadmap

### The Enforcement Decision Blocks Phase Ordering

The iptables-vs-pf question is not a design preference — it determines whether the validator stays in Docker Compose or moves to a host launchd daemon, which in turn determines whether the proxy moves, how many launchd plists exist, and what the pf anchor lifecycle looks like. Phase D cannot be planned until Phase C commits to an option.

### Suggested Phase Order

**Phase A: Platform Abstraction (Foundation)**
**Rationale:** Every subsequent phase has a platform branch. Without `lib/platform.sh` and the installer skeleton, every file touched later will need duplicate edits. No behavior change on Linux/WSL2.
**Delivers:** `lib/platform.sh` with `detect_platform()` and `detect_arch()`. `CLAUDE_SECURE_PLATFORM_OVERRIDE` for CI mocking. Installer/uninstaller macOS branches that stub with `die "macOS: not yet implemented"`. Per-platform dependency preflight (Homebrew check, brew install bash/coreutils/jq, Docker Desktop version check). Bash version check + self-exec shim. GNU coreutils PATH shim. `flock` usage audit of existing 2,300 lines.
**Avoids:** Bash 3.2 silent misbehavior (version check installed here), BSD coreutils silent corruption (PATH shim installed here).
**Research flag:** Standard patterns, no additional research needed.

**Phase B: Docker Desktop Compose Compatibility**
**Rationale:** Must confirm the `claude` container boots and the existing security layers function under Docker Desktop before investing in enforcement changes. If something is fundamentally broken here, it changes the scope of all later phases.
**Delivers:** Verified `docker-compose.yml` boots on Docker Desktop. Hook registration URL parameterized (`VALIDATOR_HOST` env var). Validator base image switched to `python:3.11-slim-bookworm`. Compose profile gate so the `validator` service can be conditionally excluded on macOS if Phase C chooses Option B. Smoke test: claude container boots, proxy reachable, hook fires, call-ID registered.
**Avoids:** Alpine iptables-legacy incompatibility (image switch), `--network=host` anti-pattern (documented prohibition), host-to-container networking pitfall (published ports only, not bridge IP).
**Research flag:** Needs Docker Desktop smoke test on real macOS hardware to confirm `internal: true` DNS and shared network namespace work correctly. Docker/for-mac #7262 (internal bridge DNS) may require `dns:` workaround.

**Phase C: Enforcement Decision + Implementation (Highest Risk)**
**Rationale:** This is the open question. Phase C begins with an explicit spike: boot Docker Desktop on macOS, run the validator container with `NET_ADMIN` + bridge network (no `--network=host`), attempt to add and verify iptables OUTPUT rules, observe whether Docker Desktop's network stack remains stable. If stable: take Option A (iptables stays). If rules fail or Docker Desktop crashes: take Option B (host pf).
**Delivers (Option A):** Validator entrypoint self-test (rule insert + verify, fail loud if absent). Integration test asserting TCP-level block. Native arm64 container images confirmed.
**Delivers (Option B):** `validator.py` ported as host process with pfctl anchor driver (rewrite-whole-anchor pattern). pf base anchor file at `/Library/Application Support/claude-secure/`. Proxy either moved to host or host-side tunnel established. `docker-compose.yml` on macOS omits validator service. Host validator HTTP server reachable via `host.docker.internal` from containers.
**Avoids:** iptables silent bypass pitfall, pf zombie anchor pitfall (Option B), SIP pitfall (Option B).
**Research flag:** REQUIRES empirical verification on macOS hardware before implementation begins. This is the only phase that cannot be fully planned from research alone. Budget 90 minutes for the spike as Phase C task 0.

**Phase D: launchd Lifecycle**
**Rationale:** Phase C defines which host daemons exist. Phase D writes and installs the plists. Mechanical work with well-documented patterns — safe to execute quickly once Phase C commits to an option.
**Delivers:** `com.claude-secure.webhook.plist` (LaunchDaemon, always). `com.claude-secure.validator.plist` and `com.claude-secure.pf-loader.plist` (Option B only). Installer: `launchctl bootstrap system`, `launchctl enable system/<label>`, `launchctl kickstart -k`. Uninstaller: `launchctl bootout system/<label>`, plist removal, pf anchor cleanup with reboot warning. Explicit PATH in every plist EnvironmentVariables block.
**Avoids:** LaunchAgent vs LaunchDaemon pitfall, deprecated `launchctl load` pitfall, PATH-in-daemon pitfall, keychain vs file pitfall (root-readable `/etc/claude-secure/` files only, no System Keychain).
**Research flag:** Standard patterns, no additional research needed.

**Phase E: Tests and Hardening**
**Rationale:** macOS failure modes are disproportionately silent. Every feature needs active verification, not just a "did it run" check. This phase closes the CI gap — Linux-only CI is insufficient for a multi-platform tool.
**Delivers:** Mock-based tests of macOS code paths runnable on Linux CI via `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos`. Negative integration tests asserting TCP-level block on non-whitelisted domains. pf anchor state verification after install and after uninstall (zombie anchor check). Uninstall-reinstall idempotency test. Bash 3.2 compatibility gate CI job. Docker Desktop smoke test on real macOS hardware or macOS GitHub Actions runner.
**Avoids:** All silent failure pitfalls by enforcing "every macOS code path has an active self-verification test" as a blocking quality gate.
**Research flag:** GitHub Actions macOS runner cost (`macos-14`/`macos-15`) should be evaluated before committing to automated E2E CI. Consider manual macOS testing for v3.0 with automated tests deferred to v3.1 if cost is prohibitive.

### Phase Ordering Rationale

- A before everything: platform detection is load-bearing scaffolding. Without it, every subsequent file needs duplicate edits.
- B before C: confirms the base case works before investing in the hardest problem. A Docker Desktop incompatibility discovered in B could reframe C's scope.
- C before D: launchd plists are hollow until the enforcement decision determines which daemons exist.
- D before E (lifecycle tests): cannot test uninstall until install exists. Mock-based E tests can run in parallel with D.
- The proxy-relocation decision (Option B only) happens in C and is the highest-risk sub-decision within that phase.

### Research Flags

Needs empirical verification before planning commits:
- **Phase C:** The iptables-vs-pf enforcement question is the only unresolved architectural issue. 90 minutes on macOS hardware resolves it. Do not plan Phase C implementation in detail until the spike result is known.
- **Phase B:** Docker Desktop `internal: true` DNS has a known bug (docker/for-mac #7262). Needs smoke test during Phase B.

Standard patterns, no additional research needed:
- **Phase A:** `uname -s` detection, Homebrew install, launchd/systemd mapping — all fully documented in STACK.md and ARCHITECTURE.md.
- **Phase D:** launchd LaunchDaemon patterns are stable since macOS 10.4. All plist keys needed are covered in research.
- **Phase E:** Testing patterns follow from Phase C decisions.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack (launchd, Homebrew, image switch) | HIGH | Stable Apple APIs and Docker documentation. Validator image switch has strong rationale from multiple sources. |
| Features (macOS delta) | MEDIUM | Based on inline data, not a full FEATURES.md for v3.0. The 17/5/3/2/1 breakdown is directionally correct but not empirically verified per-feature. |
| Architecture (component topology) | MEDIUM-HIGH | launchd and pf mechanics are HIGH confidence. The enforcement decision itself is MEDIUM until empirical test resolves it. |
| Pitfalls | HIGH | All major pitfalls are well-sourced (Apple Developer Forums, docker/for-mac issues, official Apple docs). The "silent failure" theme is consistent and actionable. |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **Enforcement architecture open question**: Cannot be resolved by research alone. Must be scheduled as the explicit first task of Phase C. A 90-minute test on macOS hardware resolves it definitively.
- **`user <uid>` pf filtering on Darwin pf**: macOS pf is forked from OpenBSD 4.6 (2009). Whether `user <uid>` egress filtering is available in the Darwin fork needs a `pfctl -nf` test. If unsupported, enforcement uses port-based filtering instead. Affects pf anchor template design in Option B.
- **`flock` usage audit**: STACK.md flags `flock` as unavailable on macOS. The existing scripts need to be audited for `flock` usage before Phase A completes. Substitute with `mkdir`-based atomicity.
- **Bash 4+ syntax audit**: 2,300 lines of existing scripts need scanning for `declare -A`, `mapfile`, `readarray`, `${var,,}`, `${var^^}`, `|&`, `&>>`. Mechanical task, belongs in Phase A.
- **Docker Desktop `internal: true` DNS**: docker/for-mac #7262 documents DNS failures on internal bridge networks. Needs smoke test in Phase B; may require explicit `dns:` config in docker-compose.yml on macOS.

---

## Sources

### Primary (HIGH confidence — official docs or Apple-maintained)
- Apple Developer Forums thread/745158: pfctl zombie anchors on Ventura+
- Apple Developer Docs: SIP scope and protected paths
- launchd.plist(5) man page: RunAtLoad, KeepAlive, EnvironmentVariables keys
- launchctl man page (ss64): bootstrap/bootout semantics, domain targets
- docker/for-mac #6297 and #2489: iptables in containers on macOS, LinuxKit VM crashes
- Docker Blog: How Docker Desktop Networking Works Under the Hood (vpnkit, VM boundary)
- Docker Docs: Networking on Docker Desktop, Mac permission requirements

### Secondary (MEDIUM confidence — community, multiple sources agree)
- Neil Sabol: pf on macOS — anchor-based approach, LaunchDaemon pattern
- launchd.info: LaunchDaemon vs LaunchAgent distinction
- Medium: Docker Desktop crash on macOS via host network + iptables
- OpenBSD PF Anchors: dynamic rule rewrite pattern (extrapolated to Darwin pf fork)
- HackMD: BSD vs GNU vs Busybox utility differences
- safjan.com and megamorf: bash detect Linux/macOS via uname -s

### Tertiary (LOW confidence — single source or needs empirical validation)
- Docker Desktop 4.39+ host iptables behavior change: mentioned in one search hit; verify against Docker changelog
- Whether `user <uid>` filtering works in Darwin pf: needs `pfctl -nf` test on real hardware
- Exact iptables modules absent from LinuxKit VM: enumerate empirically by running validator on Docker Desktop Mac

---
*Research completed: 2026-04-13*
*Milestone: v3.0 macOS Support*
*Ready for roadmap: YES, with Phase C enforcement-decision spike scheduled as first task*
