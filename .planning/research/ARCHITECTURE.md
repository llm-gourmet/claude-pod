# Architecture: macOS Port of claude-secure

**Milestone:** v3.0 macOS Support
**Researched:** 2026-04-13
**Confidence:** HIGH on enforcement placement and launchd lifecycle, MEDIUM on installer detection edge cases, MEDIUM on Docker Desktop internal-network DNS quirks.

## TL;DR — Four Load-Bearing Answers

1. **pf enforcement MUST move to the host.** The validator container's `iptables` strategy does not translate cleanly to Docker Desktop on macOS. iptables inside Docker Desktop runs *inside the LinuxKit VM*, not on macOS, and attempting to manipulate iptables with `NET_ADMIN` in that VM has a documented history of crashing Docker Desktop's network stack (v4.39+ also adds its own iptables rules that complicate the picture). Host-side `pfctl` with a dedicated anchor is the supported, safe path. The validator service still exists, but on macOS it becomes an **out-of-container** process that drives host pf anchors instead of container iptables.
2. **Installer detects via `uname -s` + `/proc/version`**, in that order: `Darwin` -> macOS; `Linux` + `microsoft` in `/proc/version` -> WSL2; `Linux` otherwise -> native Linux. Each branch has its own dependency preflight.
3. **launchd plists live in `/Library/LaunchDaemons/` for the webhook listener and the pf-anchor loader**, loaded with `launchctl bootstrap system/…` and removed with `launchctl bootout system/…`. The plists are root-owned 0644; the webhook listener script is root-owned and references instance paths the same way the systemd unit does today.
4. **Build order is: platform abstraction -> Docker Desktop compose compat -> host pf validator -> launchd listener -> tests.** pf enforcement is the highest-risk phase and gates everything downstream because it changes where the validator lives.

---

## 1. Existing Architecture Recap (what we're porting)

```
+------------------------------------------------------+
|                  Linux / WSL2 host                   |
|                                                      |
|  systemd: claude-secure-webhook.service              |
|     |  (HMAC verify, dispatch to claude-secure spawn)|
|     v                                                |
|  docker compose (per profile/instance)               |
|  +------------------+  +-------------------+         |
|  |  claude          |  |  validator        |         |
|  |  (ubuntu 22.04)  |<-+  (python:alpine)  |         |
|  |  hook -> POST    |  |  network_mode:    |         |
|  |  /register       |  |  service:claude   |         |
|  |                  |  |  iptables OUTPUT  |         |
|  +--------+---------+  +-------------------+         |
|           |                                          |
|           | ANTHROPIC_BASE_URL=proxy:8080            |
|           v                                          |
|  +------------------+                                |
|  |  proxy (node 22) |  external network              |
|  +---------+--------+  -> api.anthropic.com          |
|            |                                         |
|            +-- internal network (no egress)          |
+------------------------------------------------------+
```

Key facts that constrain the port:
- `validator` shares a **network namespace** with `claude` (`network_mode: service:claude`). Its iptables OUTPUT rules apply directly to claude's egress.
- Hook runs inside `claude`, registers call-IDs via HTTP on the shared loopback, and then performs the allowed network call.
- `proxy` is on both internal (for `claude`) and external (for `api.anthropic.com`) networks.
- Webhook listener runs on the **host**, not in a container, because it must bind a real TCP port visible to GitHub (via tunnel/port forward) and spawn `docker compose exec`.
- Installer is Bash, root-owns `/etc/claude-secure/…`, and currently branches on `/proc/version` for WSL2 quirks.

## 2. Question 1: Can the validator still use pf from inside a Docker Desktop container?

**Answer: No. Move enforcement to the macOS host with `pfctl` anchors.** Container-side iptables is both unsafe and semantically wrong on Docker Desktop.

### 2a. Why container-side enforcement breaks on macOS (HIGH confidence)

Docker Desktop on macOS is not "Docker on macOS". It is a LinuxKit VM running on macOS's Virtualization.framework (or HyperKit on older versions). Every container runs in that single VM. This creates three independent problems for the current iptables strategy:

1. **iptables inside the container still touches the VM kernel.** Any rule the validator adds applies inside the Docker Desktop VM. That's not macOS, it's a shared Linux environment whose network stack is already owned by Docker Desktop. Docker Desktop v4.39+ installs its own iptables rules in the VM to broker host<->container traffic, and there is a well-documented class of bugs where user-added iptables rules in privileged containers break Docker Desktop's entire network path until the VM is restarted. The failure mode is not "the rule doesn't take effect" — it is "Docker Desktop stops responding to `docker ps`" ([Medium writeup: Docker Desktop crash on macOS / iptables](https://medium.com/@chinmayshringi4/docker-bug-docker-desktop-crash-on-macos-understanding-the-host-network-iptables-bug-3d3fc2884149), [docker/for-mac #6297](https://github.com/docker/for-mac/issues/6297), [docker/for-mac #2489](https://github.com/docker/for-mac/issues/2489)).
2. **`pfctl` is not usable from inside the container at all.** pf is a BSD/Darwin construct. The Docker Desktop VM is Linux; there is no pf in the container. So "just swap iptables for pfctl in the validator container" is not an option — the binary and kernel machinery don't exist where the container lives.
3. **Even if iptables *did* work safely, it would not buy security.** Because all container traffic is NATed out of the VM through vpnkit, from macOS's point of view every outbound packet appears as a connection originated by the Docker Desktop helper process. That's the surface that macOS pf can see. So the host is where meaningful enforcement happens, and iptables in the VM can at best filter before vpnkit, inside an environment Docker Desktop considers its own ([Docker: How Docker Desktop Networking Works Under the Hood](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/), [moby/vpnkit](https://github.com/moby/vpnkit)).

### 2b. The host-side enforcement model

New topology on macOS:

```
+-----------------------------------------------------------+
|                       macOS host                          |
|                                                           |
|  launchd: com.claude-secure.webhook.plist                 |
|  launchd: com.claude-secure.validator.plist  <-- NEW      |
|     |                                                     |
|     v                                                     |
|  validator.py (Python 3.11, stdlib)                       |
|     - HTTP server on 127.0.0.1:<port>                     |
|     - SQLite call-ID store (WAL)                          |
|     - Drives pfctl anchor "claude-secure/<instance>"      |
|                                                           |
|  pf anchor "claude-secure/<instance>"                     |
|    block drop out quick proto { tcp udp } from any        |
|      to any port { 80 443 } user claude-secure            |
|    pass  out quick proto tcp to <allowed_ips>             |
|      port 443 user claude-secure                          |
|                                                           |
|  +--- Docker Desktop VM -------------------------------+  |
|  |  docker compose (same as Linux minus validator svc)|  |
|  |  +-------------+    +--------+                     |  |
|  |  |  claude     |--->|  proxy |---> vpnkit -> host  |  |
|  |  |  (hook:     |    +--------+     (all egress here)| |
|  |  |   POST to   |                                   |  |
|  |  |   host.docker.internal:<validator-port>)        |  |
|  |  +-------------+                                   |  |
|  +----------------------------------------------------+  |
+-----------------------------------------------------------+
```

How it enforces (HIGH confidence on pf anchor semantics, MEDIUM on the exact user/uid-based rule shape):

- At install time, `pfctl -a claude-secure -f <base-anchor>` loads a stub anchor that default-blocks egress from a dedicated uid or, alternatively, from the single loopback port the host-side proxy listens on.
- The validator updates the anchor **dynamically** by piping new rules into the anchor: `echo "<new rule>" | pfctl -a claude-secure/<instance> -f -`. This is the documented pattern for dynamic ruleset manipulation ([OpenBSD PF Anchors](https://www.openbsd.org/faq/pf/anchors.html), [Neil Sabol: pf on macOS](https://blog.neilsabol.site/post/quickly-easily-adding-pf-packet-filter-firewall-rules-macos-osx/), [ss64 pfctl](https://ss64.com/mac/pfctl.html)).
- Because all container egress appears to macOS as Docker Desktop helper traffic, you cannot distinguish claude-secure traffic by container IP on the host. You must either (a) make the **proxy** a host process bound to a specific uid and filter by uid in pf, or (b) bind the proxy inside the VM but route *all* Claude egress through a single known-port tunnel on macOS and filter that port. Option (a) is simpler and matches pf's uid-based filtering (`user <uid>`), which is available in macOS pf via Darwin's pf port.
- `-f -` replaces the anchor contents wholesale, so the validator tracks the live set of allowed call-IDs in memory/SQLite and re-materializes the full anchor whenever a call is registered or expires. This is the same "rewrite, not patch" pattern used by typical pfctl automation.

Trade-off this forces into the roadmap: **the proxy probably has to move to the host** on macOS (or at minimum, you need a dedicated host-side egress process the container tunnels through). That's a non-trivial change from the Linux topology where the proxy lives in the same docker-compose project. This is the single biggest architectural delta and the roadmap must make it explicit.

Alternative considered and rejected: running validator + iptables in a privileged container via `--cap-add NET_ADMIN --network host`. Rejected because (1) `network host` on Docker Desktop shares the *VM* network, not macOS, so the rules do not see macOS traffic; (2) this is the exact configuration documented to crash Docker Desktop ([docker/for-mac #6297](https://github.com/docker/for-mac/issues/6297)); (3) it gives false confidence — the filtering happens at a layer macOS cannot actually observe.

### 2c. What this means for existing components

| Component | Linux/WSL2 today | macOS port | Change type |
|-----------|------------------|------------|-------------|
| `claude` container | Ubuntu, runs Claude Code + hook | Unchanged | NONE |
| `proxy` container | Node 22 stdlib, internal+external nets | **Move to host** as a launchd-managed daemon, OR keep in container and add host tunnel | MAJOR |
| `validator` container | Python stdlib + iptables, `network_mode: service:claude` | **Delete** from docker-compose on macOS; replaced by host validator launchd daemon | MAJOR |
| Hook (`claude` image) | curls `http://127.0.0.1:<validator>/register` | curls `http://host.docker.internal:<validator>/register` | MINOR (URL only) |
| docker-compose.yml | 3 services, 2 networks | Profile-gated: on macOS, validator service absent; proxy either absent or tunnel-mode | MODERATE |
| iptables rules | Added/removed by validator via subprocess | Replaced by pfctl anchor file rewrites | NEW code, same pattern |
| Whitelist JSON | Shared | Shared | NONE |
| Secrets redaction logic | Inside proxy | Inside proxy (wherever proxy runs) | NONE if proxy unchanged, MINOR if moved |

Confidence: HIGH that the validator must leave the container. MEDIUM that the proxy must also move, because the alternative (tunneling from the VM to a specific host port and filtering that port) is technically feasible but adds a new component (tunnel) and a new failure mode (what if the container bypasses the tunnel?). The conservative choice is: move both to host; keep only `claude` in Docker Desktop. This also aligns with how the webhook listener already runs.

## 3. Question 2: Platform detection in the installer

**Answer: a three-way branch at the top of every entry point, with preflight functions per platform.**

### 3a. The detection function (HIGH confidence)

```bash
detect_platform() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin)
      echo "macos"
      ;;
    Linux)
      if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version; then
        echo "wsl2"
      else
        echo "linux"
      fi
      ;;
    *)
      echo "unsupported:$uname_s"
      return 1
      ;;
  esac
}
```

Notes and gotchas (MEDIUM confidence on every edge case):

- `uname -s` is the authoritative first switch. `Darwin` is macOS on both Intel and Apple Silicon. Do not use `$OSTYPE` as the primary signal — it's shell-dependent and you already rely on Bash elsewhere, so `uname` is simpler ([safjan.com: bash detect linux/macos](https://safjan.com/bash-determine-if-linux-or-macos/), [megamorf: detect OS in shell](https://megamorf.gitlab.io/2021/05/08/detect-operating-system-in-shell-script/)).
- WSL1 vs WSL2: both match `microsoft` in `/proc/version`. The installer only needs to care that it's WSL at all (because Docker Desktop on WSL2 behaves like Linux inside the WSL distro, and WSL1 is unsupported by the project). Grepping `microsoft|wsl` catches WSL2 kernel strings like `5.15.167.4-microsoft-standard-WSL2`.
- Apple Silicon vs Intel: both are `Darwin`. No branch needed for Phase 1 unless a tool (e.g., Homebrew prefix `/opt/homebrew` vs `/usr/local`) differs. Keep a `detect_arch` helper (`uname -m` -> `arm64|x86_64`) for any brew-path decisions.
- Homebrew bin path: `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel). The installer must `PATH`-prepend the right one when invoking `brew`, `jq`, `uuidgen`, because the default macOS shell PATH does not include either on a fresh clam-shell.

### 3b. Per-platform preflight (HIGH confidence on the tool list)

| Check | Linux | WSL2 | macOS |
|-------|-------|------|-------|
| Docker | `docker --version` | `docker --version` (via Docker Desktop integration or native engine) | `docker --version` from Docker Desktop |
| Docker Compose | `docker compose version` | same | same |
| jq | package manager | package manager | `brew install jq` |
| uuidgen | coreutils | coreutils | macOS ships `uuidgen` in base system |
| curl | pre-installed | pre-installed | pre-installed |
| Firewall tool | `iptables` | `iptables` | `pfctl` (pre-installed, but needs `sudo` every time) |
| Service manager | `systemctl` | `systemctl` (if systemd enabled in WSL2) or fallback | `launchctl` |
| Webhook listener runtime | Python 3 (systemd unit) | Python 3 | Python 3 (launchd plist) |

The installer should gate on each of these per platform and print actionable install instructions on miss (`brew install jq`, `sudo apt install jq`, etc.).

### 3c. Where detection is consumed

Every file-changing script that touches system state needs to dispatch on platform:

- `installer.sh` — top-level
- `uninstaller.sh` — top-level
- Anything that writes the webhook listener unit (systemd on Linux/WSL2, launchd on macOS)
- Anything that writes firewall rules (iptables helper on Linux/WSL2, pfctl helper on macOS)
- Test harness that spins up/tears down test state (must skip pf-specific tests on Linux, etc.)

Recommendation: put `detect_platform` in a single sourced file (`lib/platform.sh`) and have every script source it. This is also the cleanest mock point for CI — set `CLAUDE_SECURE_PLATFORM_OVERRIDE=macos` and tests can exercise the macOS code path on a Linux runner.

## 4. Question 3: launchd plist location and lifecycle

**Answer: `/Library/LaunchDaemons/` for system-wide daemons, root-owned 0644 plists, bootstrap/bootout for load/unload.** (HIGH confidence — this is stock macOS daemon practice.)

### 4a. Where plists live

| Scope | Path | Owner | When to use |
|-------|------|-------|-------------|
| System-wide daemon (runs as root, persists across logins) | `/Library/LaunchDaemons/com.claude-secure.<name>.plist` | root:wheel 0644 | Webhook listener, validator (if pf requires root), pf anchor loader |
| Per-user agent (runs only while user is logged in) | `~/Library/LaunchAgents/com.claude-secure.<name>.plist` | user 0644 | Not recommended for claude-secure — webhook must survive logout |
| System-wide agent | `/Library/LaunchAgents/` | root:wheel | Not needed |

Naming: launchd expects the plist filename to match the `Label` key inside the plist, by convention. Use reverse-DNS labels: `com.claude-secure.webhook`, `com.claude-secure.validator`, `com.claude-secure.pf-anchor`. ([launchd.info](https://launchd.info/), [Apple: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html), [launchd.plist(5)](https://keith.github.io/xcode-man-pages/launchd.plist.5.html))

### 4b. Plist shape (illustrative — validator example)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-secure.validator</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>python3</string>
    <string>/usr/local/libexec/claude-secure/validator.py</string>
    <string>--config</string>
    <string>/etc/claude-secure/validator.conf</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/claude-secure/validator.out.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/claude-secure/validator.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin</string>
  </dict>
</dict>
</plist>
```

The webhook plist is structurally identical, just different `ProgramArguments`, `Label`, and log paths.

### 4c. Install lifecycle

**Install (root):**

```bash
install -o root -g wheel -m 0644 \
  "$STAGING/com.claude-secure.webhook.plist" \
  /Library/LaunchDaemons/com.claude-secure.webhook.plist

launchctl bootstrap system \
  /Library/LaunchDaemons/com.claude-secure.webhook.plist

launchctl enable system/com.claude-secure.webhook
launchctl kickstart -k system/com.claude-secure.webhook
```

**Uninstall (root):**

```bash
launchctl bootout system/com.claude-secure.webhook || true
rm -f /Library/LaunchDaemons/com.claude-secure.webhook.plist
```

**Status:**

```bash
launchctl print system/com.claude-secure.webhook
```

Notes (HIGH confidence):
- `bootstrap`/`bootout` is the modern replacement for `load`/`unload`. `load` and `unload` still exist but are deprecated and behave unpredictably across macOS versions. Use bootstrap/bootout unconditionally ([ss64: launchctl](https://ss64.com/mac/launchctl.html)).
- `kickstart -k` force-starts (and restarts if running) the job. Useful in the installer to avoid requiring a reboot to verify install.
- `launchctl enable` persists the enabled state across reboots independently of bootstrap. Include it so an uninstall-reinstall cycle doesn't leave the job disabled.
- `|| true` on bootout is intentional — bootout errors if the service isn't loaded, and uninstall must be idempotent.
- System keychain / `sudo`: bootstrap on the `system` domain requires root. The installer already expects root for `/etc/claude-secure`, so this is not a new requirement.

### 4d. pf anchor persistence across reboots

macOS does **not** automatically re-apply custom pf rules at boot. The installer must create a third launchd plist (`com.claude-secure.pf-loader.plist`) that runs `pfctl -e -f /etc/claude-secure/pf.conf` at `RunAtLoad` with `KeepAlive=false` (one-shot). This plist loads the *base* anchor; the validator daemon populates sub-anchor content at runtime.

Alternative: ship the rule as an addition to `/etc/pf.conf`. Rejected because editing /etc/pf.conf is invasive, conflicts with other tools that manage pf, and is harder to cleanly uninstall. An anchor + one-shot loader plist is the idiomatic pattern ([Neil Sabol: pf on macOS](https://blog.neilsabol.site/post/quickly-easily-adding-pf-packet-filter-firewall-rules-macos-osx/), [Murus OS X PF Manual](https://murusfirewall.com/Documentation/OS%20X%20PF%20Manual.pdf)).

## 5. Question 4: Build order for the macOS phases

The dependency graph is driven by the enforcement relocation. Do not start on launchd until the host-side validator exists; do not start on the host-side validator until the platform abstraction exists; do not ship until integration tests mock the macOS path.

### 5a. Dependency chain

```
Phase A (foundation)           Phase B (Docker Desktop compat)     Phase C (enforcement)
+-------------------------+    +--------------------------+        +--------------------------+
| Platform detection      |--->| docker-compose.yml       |------->| Host-side validator      |
| lib/platform.sh         |    | profile-gated services   |        | (Python, pfctl driver)   |
| installer branch stubs  |    | hook URL fix             |        | pf anchor base + helper  |
| preflight per platform  |    | host.docker.internal     |        | Proxy relocation (maybe) |
+-------------------------+    +--------------------------+        +------------+-------------+
                                                                                |
                                                                                v
Phase D (launchd lifecycle)                                        Phase E (tests & hardening)
+--------------------------+                                       +--------------------------+
| webhook plist install    |  <--- depends on C for validator      | macOS CI path            |
| validator plist install  |       plist shape                     | mock platform detection  |
| pf-loader plist install  |                                       | pf anchor teardown check |
| uninstaller bootout      |                                       | Docker Desktop smoke test|
+--------------------------+                                       +--------------------------+
```

### 5b. Recommended phase order

1. **Phase A — Platform abstraction (foundation).** `lib/platform.sh`, preflight per platform, installer/uninstaller branch scaffolding, no behavior change on Linux/WSL2. Add a `CLAUDE_SECURE_PLATFORM_OVERRIDE` env var for CI mocking. Low risk, unblocks everything else.
2. **Phase B — Docker Desktop compose compat.** Verify that the current `claude` container boots under Docker Desktop, fix any Linux-isms (kernel capabilities the image assumes, volume-mount UID gotchas). Add compose profile flag to omit the `validator` service on macOS. Change hook's registration URL from `127.0.0.1` to an abstracted host (env var set per platform; on macOS this becomes `host.docker.internal`, on Linux it stays `127.0.0.1`). This phase is validated by "claude container boots on macOS and can call the proxy, even without enforcement".
3. **Phase C — Host-side validator + pf anchors.** The big rock. Port the Python validator to run as a host process. Write the pfctl anchor driver (rewrite-the-whole-anchor pattern). Decide and implement whether the proxy also moves to host (strong recommendation: yes). Smoke-test that call-IDs can be registered and pf anchor updates reflect them. This phase has the highest research-debt and may need its own spike before the roadmap finalizes — specifically: can we use `user <uid>` filtering in macOS pf, or does the proxy need to bind a dedicated port we filter by instead? (pf on OpenBSD supports `user`, macOS pf is a Darwin port and the feature set is close but not identical — needs verification during Phase C.)
4. **Phase D — launchd lifecycle.** Now that there are daemons to manage (webhook, validator, pf loader), write the plists, bootstrap/bootout in installer/uninstaller, logging paths, idempotency. Low-risk mechanical work **only because** Phase C defined what's being managed.
5. **Phase E — Tests and hardening.** Mock platform detection so Linux CI runs the macOS code paths where possible. Real Docker Desktop smoke test on an actual macOS runner (GitHub Actions has `macos-14` / `macos-15` runners with Docker Desktop pre-installable, but cold-start times are a cost — budget for it). Verify pf anchor cleanup on uninstall and on instance removal. Verify the "Docker Desktop crash" failure mode is not reachable — no iptables code path is executed on macOS.

### 5c. Explicit gating rules

- Phase B must not start until Phase A's platform detection ships, or you'll litter the compose changes with duplicated `if [[ "$OSTYPE" == darwin* ]]` checks.
- Phase C **gates** Phase D. There is no point in writing a validator launchd plist for a validator that doesn't exist yet.
- Phase D gates Phase E for the lifecycle tests (you can't test uninstall until install exists), but Phase E's mock-based code-path tests can start in parallel with D.
- The proxy-relocation decision (host vs container+tunnel) happens in Phase C and is the biggest open risk. If the roadmap needs a spike task, this is where it goes.

## 6. Anti-patterns — things that will look tempting and are wrong

1. **`--network host` + `--cap-add NET_ADMIN` in validator on Docker Desktop.** Documented Docker Desktop crash trigger. Do not use ([docker/for-mac #6297](https://github.com/docker/for-mac/issues/6297)).
2. **Editing `/etc/pf.conf` directly.** Breaks uninstall cleanliness and collides with other tools. Use anchors.
3. **Filtering container traffic by container IP on the macOS host.** vpnkit NATs everything; from macOS's perspective, all containers look like one process. Filter by uid or by a single known outbound port ([Docker Desktop networking blog](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/)).
4. **Using `launchctl load`/`unload`** instead of `bootstrap`/`bootout`. Deprecated, inconsistent across macOS versions.
5. **Assuming `uname -s == Linux` implies native Linux.** WSL2 matches this. Check `/proc/version` for `microsoft|wsl`.
6. **Putting the installer's sudo prompts in the middle of work.** Front-load all root-requiring steps (pf anchor install, plist install, /Library/LaunchDaemons writes) behind a single `sudo -v` at the start of the installer, so the user sees one password prompt, not five.
7. **Hardcoding `/usr/local/bin` for Homebrew on Apple Silicon.** Use `$(brew --prefix)` or detect `arch`.

## 7. Open questions for the roadmap / future research

1. **Can macOS pf filter by `user <uid>`, or must we filter by port?** OpenBSD supports `user`; Darwin's pf is a fork with drift. Needs verification with a 5-minute `pfctl -nf` test on a real macOS box during Phase C. If `user` doesn't work, the plan becomes "bind proxy to a fixed port and filter by port". Both are workable; picking one affects the pf anchor template.
2. **Does the proxy also move to the host?** Leaning yes. Alternative is a host-side tunnel process, which adds another moving part. Roadmap should either commit to "proxy as launchd daemon on macOS" or spike both in Phase C.
3. **Docker Desktop `internal: true` network DNS behavior.** There is a known bug ([docker/for-mac #7262](https://github.com/docker/for-mac/issues/7262)) where DNS resolution can fail on internal bridge networks on Docker Desktop. Needs a quick smoke test during Phase B — the current `claude` container may need `dns:` entries in its compose config on macOS.
4. **GitHub Actions macOS runner cost and reliability for Phase E.** Budget tokens-per-CI-run before committing to a real macOS integration test in CI.
5. **Homebrew-installed `coreutils` collision.** macOS's base `uuidgen`, `curl`, `jq` (if installed) work fine, but some users alias GNU versions via `coreutils` brew package. Installer preflight should not assume GNU semantics (e.g., `sed -i` differs between BSD and GNU).

## 8. Component change matrix — what the roadmap must schedule

| Component | Verdict | Phase |
|-----------|---------|-------|
| `lib/platform.sh` (new) | NEW | A |
| `installer.sh` platform branches | MODIFY | A |
| `uninstaller.sh` platform branches | MODIFY | A |
| `docker-compose.yml` profile gates | MODIFY | B |
| `claude` Dockerfile | UNCHANGED (verify only) | B |
| Hook registration URL | MODIFY (parameterize) | B |
| `validator.py` — container runner | DELETE on macOS path | C |
| `validator.py` — host runner | NEW (based on existing code) | C |
| pf anchor driver module | NEW | C |
| `/etc/claude-secure/pf.conf` base anchor | NEW | C |
| `proxy` location (container -> host?) | MAYBE MOVE | C |
| `com.claude-secure.webhook.plist` | NEW | D |
| `com.claude-secure.validator.plist` | NEW | D |
| `com.claude-secure.pf-loader.plist` | NEW | D |
| `launchctl bootstrap/bootout` helpers | NEW | D |
| systemd unit (Linux/WSL2) | UNCHANGED | — |
| iptables helper (Linux/WSL2) | UNCHANGED | — |
| Integration test harness | MODIFY (platform mock + macOS path) | E |
| GitHub Actions macOS job | NEW (optional) | E |

## 9. Confidence assessment

| Area | Level | Notes |
|------|-------|-------|
| iptables-in-container is unsafe on Docker Desktop | HIGH | Multiple docker/for-mac issues, vendor blog, independent writeups all agree |
| pfctl anchors are the right mechanism | HIGH | Standard pattern, documented in Apple's own tooling |
| Host-side validator is required | HIGH | Follows directly from the above two |
| Proxy must also move to host | MEDIUM | Technically optional; strongly recommended to avoid tunnel complexity |
| `uname -s` + `/proc/version` detection | HIGH | Well-established bash pattern |
| launchd `bootstrap`/`bootout` lifecycle | HIGH | Apple-documented, stable since macOS 10.10 |
| `user <uid>` filtering works in macOS pf | MEDIUM | OpenBSD supports it; Darwin port needs verification |
| Docker Desktop `internal: true` DNS works reliably | MEDIUM | Known bug exists but has workarounds |
| GitHub Actions macOS runner is viable for E2E | MEDIUM | Possible but slow; may prefer local manual testing for v3.0 |

## Sources

- [Medium: Docker Desktop Crash on macOS: Host Network & iptables Bug](https://medium.com/@chinmayshringi4/docker-bug-docker-desktop-crash-on-macos-understanding-the-host-network-iptables-bug-3d3fc2884149)
- [docker/for-mac #6297 — iptables doesn't work on Intel CentOS 7 container](https://github.com/docker/for-mac/issues/6297)
- [docker/for-mac #2489 — No longer able to manage TCP packet flow in DockerForMac VM](https://github.com/docker/for-mac/issues/2489)
- [docker/for-mac #7262 — Internet DNS resolution no longer works in internal bridge network](https://github.com/docker/for-mac/issues/7262)
- [Docker Docs: iptables and firewall integration](https://docs.docker.com/engine/network/firewall-iptables/)
- [Docker Docs: Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker Blog: How Docker Desktop Networking Works Under the Hood](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/)
- [moby/vpnkit](https://github.com/moby/vpnkit)
- [OpenBSD PF: Anchors](https://www.openbsd.org/faq/pf/anchors.html)
- [Neil Sabol: Quick and easy pf firewall rules on macOS](https://blog.neilsabol.site/post/quickly-easily-adding-pf-packet-filter-firewall-rules-macos-osx/)
- [ss64: pfctl command reference](https://ss64.com/mac/pfctl.html)
- [Murus: OS X PF Manual (PDF)](https://murusfirewall.com/Documentation/OS%20X%20PF%20Manual.pdf)
- [launchd.info tutorial](https://launchd.info/)
- [Apple: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [launchd.plist(5) man page (Keith Smiley mirror)](https://keith.github.io/xcode-man-pages/launchd.plist.5.html)
- [ss64: launchctl command reference](https://ss64.com/mac/launchctl.html)
- [safjan.com: bash detect Linux or macOS](https://safjan.com/bash-determine-if-linux-or-macos/)
- [megamorf: Detect operating system in shell script](https://megamorf.gitlab.io/2021/05/08/detect-operating-system-in-shell-script/)
