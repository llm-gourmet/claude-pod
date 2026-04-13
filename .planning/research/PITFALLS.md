# Pitfalls Research -- macOS Port

**Domain:** Porting a Docker-based Linux/WSL2 security tool (claude-secure) to macOS. Adds pf (packet filter), launchd, Docker Desktop, and Bash 3.2 as new failure surfaces.
**Researched:** 2026-04-13
**Confidence:** HIGH for pf/launchd/Bash behavior (verified via Apple Developer Forums, Docker docs, ss64 man pages). MEDIUM for Docker Desktop internal-network edge cases (behavior changed in recent versions, one verification point was a 2026 Docker Desktop release note).

This research focuses on mistakes specific to porting an *existing* Linux security tool to macOS. It assumes the v1.0/v2.0 architecture is already battle-tested on Linux and WSL2; the question is what breaks when you add macOS as a third platform.

---

## Critical Pitfalls

### Pitfall 1: pf "zombie anchors" persist after flush on Ventura+ (only a reboot clears them)

**What goes wrong:**
On macOS Ventura and later, `pfctl -a claude-secure -F all` flushes the *rules* inside an anchor but leaves the anchor reference itself in the main ruleset. The anchor node persists in memory until reboot. When the installer (or uninstaller) re-creates the same anchor name, rules can accumulate or old blocking rules can linger alongside new ones. Users who run `claude-secure uninstall` then `claude-secure install` in the same session will get stale pf state that behaves unpredictably -- worst case: a block rule from a previous install silently drops legitimate proxy traffic and tests pass on CI but fail on a developer's laptop that has been up for days.

**Why it happens:**
- Starting with Ventura, pfctl retains anchors even after flushing rules/states/tables. This is an OS-level behavior change (documented on Apple Developer Forums), not a pfctl bug.
- Linux iptables has no equivalent concept -- `iptables -F` cleanly removes rules, and chains can be deleted with `-X`. Developers porting from Linux assume flush == clean slate.
- The default reflex ("just re-run the installer") works on Linux but fails silently on macOS.

**Consequences:**
- Intermittent test failures that only reproduce on long-running dev machines
- Security bypass: if a developer's old anchor had a permissive rule that a new version doesn't, the old rule still applies
- Debugging pain: `pfctl -sr -a claude-secure` may show *both* old and new rules, or show them inconsistently

**Prevention:**
- Use a **dedicated top-level anchor name** (e.g., `claude-secure`) that is nested *within* `/etc/pf.anchors/claude-secure.anchors` -- never modify the main ruleset directly
- Uninstaller must explicitly call `pfctl -a claude-secure -F all` **and** warn the user that a reboot is required for complete cleanup on Ventura+
- Installer must detect existing anchor state via `pfctl -sr -a claude-secure` and refuse to proceed if stale rules exist, emitting a clear "reboot or run uninstall --force" message
- Integration tests must run on a fresh boot or in a VM with a snapshot rollback between tests -- cannot rely on `pfctl -F` for test isolation

**Detection:**
- `pfctl -sr -a claude-secure | wc -l` shows a non-zero count after uninstall
- Rule counts diverge between `pfctl -sr` and the expected ruleset diff
- Developer reports "it worked yesterday, now it doesn't"

**Phase:** Foundation phase (pf migration). Install/uninstall lifecycle must be designed around this from day one, not patched later.

---

### Pitfall 2: Using LaunchAgent instead of LaunchDaemon for the webhook listener (or vice versa)

**What goes wrong:**
The v2.0 webhook listener is documented as "host systemd process with HMAC-SHA256 verification." On Linux this runs as a system service, always on, regardless of user login. On macOS there are two fundamentally different launchd contexts:
- **LaunchDaemon** (`/Library/LaunchDaemons/`): runs as root, starts at boot, no user session needed
- **LaunchAgent** (`/Library/LaunchAgents/` or `~/Library/LaunchAgents/`): runs as a user, only when a user is logged in (or via gui/<uid> domain, only when logged into the GUI)

If the installer drops the plist into `~/Library/LaunchAgents/` because it's easier (no sudo required), the webhook listener dies the moment the user logs out or the laptop sleeps+shuts down. GitHub webhooks arriving at that moment are dropped silently -- the listener "works" in testing but misses events in production. Conversely, if the installer uses a LaunchDaemon but the listener needs access to user keychain items (OAuth tokens stored via `claude setup-token`), the daemon runs as root with no user session and cannot read the user's keychain, so auth silently fails and the listener returns 500s to GitHub.

**Why it happens:**
- Linux systemd has "user" units (`systemctl --user`) and "system" units (`systemctl`) but both survive logout by default if lingering is enabled; the distinction is less load-bearing
- The macOS distinction is not symmetric: a LaunchDaemon has **more privilege** but **less context** (no user keychain, no home-dir convenience, different TMPDIR)
- Copying example plists from blogs often conflates the two
- Testing happens while logged in, so LaunchAgent "works" until the first unattended reboot

**Consequences:**
- Silent webhook drops (missed CI-failure events = security incidents not handled)
- Auth failures when the listener needs user-scoped resources (keychain, OAuth refresh)
- Inconsistent behavior between CI runs and developer laptops

**Prevention:**
- **Decision:** Webhook listener must be a **LaunchDaemon** (`/Library/LaunchDaemons/com.claude-secure.webhook.plist`) because webhooks must fire regardless of login state. The listener must be architected so it does *not* need user keychain access -- OAuth tokens/HMAC secrets must be stored in a root-readable file or loaded via environment variables injected at plist load time (`EnvironmentVariables` key).
- Installer must `sudo` when copying the plist and set ownership `root:wheel` with mode `0644` -- launchd refuses to load plists that are group- or world-writable
- Installer must use the modern `launchctl bootstrap system /Library/LaunchDaemons/com.claude-secure.webhook.plist` command, not the deprecated `launchctl load`
- Uninstaller must use `launchctl bootout system/com.claude-secure.webhook` before deleting the plist -- simply removing the file leaves the service running until reboot
- Document explicitly why LaunchDaemon was chosen and what breaks if someone "fixes" it to a LaunchAgent
- If the listener *does* need user-context resources (e.g., for `claude-secure spawn` to read user workspace paths), split into two services: a root LaunchDaemon that receives webhooks and a LaunchAgent that executes spawn jobs, communicating via a file-based queue

**Detection:**
- `launchctl print system/com.claude-secure.webhook` shows service state
- Test: reboot machine, do not log in, send a test webhook from another machine, verify it was processed
- Monitor `/var/log/system.log` or `log show --predicate 'process == "launchd"'` for plist load errors

**Phase:** Webhook/launchd phase. Must also drive a small refactor of the webhook listener to avoid user-context dependencies.

---

### Pitfall 3: Docker Desktop iptables inside containers is "best effort" -- the validator service may silently fail to install rules

**What goes wrong:**
The v1.0 architecture runs iptables inside the `validator` container with `cap_add: [NET_ADMIN]` to enforce network-level call validation on the `claude` container (via shared network namespace). On Linux hosts this works because the container shares the host kernel. On macOS, Docker Desktop runs a LinuxKit VM, and iptables rules *do* work inside containers -- but kernel modules for less common iptables targets (REJECT, NFLOG, conntrack extensions) may not be loaded in the LinuxKit VM. Users have reported `iptables v1.4.21: can't initialize iptables table 'filter': iptables who? (do you need to insmod?)` errors, particularly on Apple Silicon running Intel (x86_64) images via Rosetta. Even when iptables works, Docker Desktop 4.39+ introduced host-side iptables rules that block specific container-to-host traffic patterns in ways that differ from Linux.

**Why it happens:**
- The LinuxKit VM is a minimal kernel and does not include every iptables module available on a full Linux distro
- Apple Silicon + x86_64 containers = emulation layer that doesn't always expose netlink correctly
- Docker Desktop evolves its network stack between versions; a rule that worked in 4.25 may break in 4.40
- The project uses `network_mode: service:claude` (shared network namespace) which is a Docker feature that works the same syntactically but whose *enforcement* depends on kernel capabilities

**Consequences:**
- Validator appears to start correctly but iptables rules silently fail to apply -- calls that should be blocked go through
- **Security bypass masked as a working install**: this is the worst possible failure mode because tests may pass on the macOS developer's machine but the security layer is not actually enforcing anything
- Architecture mismatch (x86_64 image on Apple Silicon) leads to random errors that don't reproduce on CI

**Prevention:**
- **Build arm64-native container images** for macOS. The `validator` and `claude` containers must be multi-arch (`linux/amd64, linux/arm64`) -- do not rely on Rosetta emulation for any container that uses NET_ADMIN
- **Sanity check iptables at validator startup**: the validator entrypoint must attempt to insert a test rule and verify it appears in `iptables -L`, failing loudly with a clear macOS-specific error message if it doesn't
- **Integration test: negative assertion.** A test must attempt a call to a non-whitelisted domain and verify it is *blocked at the network layer*, not just rejected by the hook. If the hook is the only enforcement, the test passes but security is broken
- **Pin Docker Desktop version compatibility** in docs (e.g., "tested with Docker Desktop 4.30-4.42") and CI tests must include the minimum supported version
- Document required Docker Desktop settings: "Use Rosetta for x86/amd64 emulation" must be *off* for this project on Apple Silicon; use native arm64 images
- Consider a fallback: if iptables enforcement cannot be verified, refuse to start and point the user at the error message, rather than degrading silently

**Detection:**
- Validator startup probe: test rule insertion + verification
- Integration test: curl a blocked domain from inside the claude container, expect connection refused at the TCP level (not an HTTP 403 from the hook)
- Log NET_ADMIN capability check: `capsh --print` in validator entrypoint
- Architecture check: `uname -m` at container start, warn if not matching host

**Phase:** Docker Desktop compatibility phase. Should be the **first** macOS phase because every other macOS pitfall is moot if the core enforcement layer is silently broken.

---

### Pitfall 4: SIP does not block pfctl or launchctl, but it does block modifications to /etc/pf.conf and default pf anchors

**What goes wrong:**
Developers researching "SIP and pfctl" often conclude one of two wrong things:
1. **"SIP blocks pfctl entirely, we need SIP disabled"** -- false, and asking users to disable SIP is a non-starter for a security tool
2. **"SIP doesn't affect us, we can edit /etc/pf.conf"** -- false, SIP protects `/etc/pf.conf` and `/etc/pf.anchors/*` (the Apple-provided ones) even from root

If the installer tries to write to `/etc/pf.conf` it may succeed on some macOS versions and fail on others (SIP relaxation over time is uneven). Worse, if the installer *appends* a `load anchor` directive to `/etc/pf.conf`, a future macOS update will overwrite the file and silently remove the claude-secure hook -- users think the tool is protecting them but pf is no longer loading claude-secure rules.

**Why it happens:**
- SIP's scope is "system-owned files protected by entitlement" -- not "can this binary run at all"
- pfctl is an Apple-signed binary with entitlements, so it runs fine under SIP
- `/Library/LaunchDaemons/` is **not** SIP-protected (it's in /Library, not /System), so LaunchDaemon install works, but the ruleset file location matters
- Confusion between "SIP protects this path" and "SIP blocks this tool"

**Consequences:**
- Installer fails on some macOS versions and succeeds on others (with silent future breakage)
- macOS updates silently disable the security tool when they regenerate /etc/pf.conf
- Users disable SIP based on bad advice from a blog, weakening their whole machine's security

**Prevention:**
- **Never modify /etc/pf.conf.** Store the claude-secure ruleset at a non-SIP-protected path: `/Library/Application Support/claude-secure/pf.anchors.conf` or `/usr/local/etc/claude-secure/pf.anchors.conf`
- The LaunchDaemon runs `pfctl -e -f /Library/Application Support/claude-secure/pf.anchors.conf` at boot, loading rules into a dedicated anchor. This bypasses /etc/pf.conf entirely and survives macOS updates
- Installer must **never** instruct users to disable SIP. Document "SIP must remain enabled" as a hard requirement -- if a feature cannot work with SIP on, that feature is out of scope
- On install, verify SIP status via `csrutil status` and emit a warning if SIP is *disabled* (this is a security tool; the host should be hardened)
- Path verification test: installer asserts the target ruleset path is writable without SIP override

**Detection:**
- `csrutil status` at install time
- Installer writes a canary file to `/Library/Application Support/claude-secure/` and reads it back
- Post-install smoke test verifies the anchor is loaded: `pfctl -sr -a claude-secure | head`

**Phase:** Foundation (pf phase). Path decisions here are load-bearing for all later work.

---

## Moderate Pitfalls

### Pitfall 5: Bash 3.2 syntax incompatibilities silently break installer and hook scripts

**What goes wrong:**
macOS ships `/bin/bash` version **3.2.57 from 2007** because Apple stopped upgrading bash when it relicensed to GPLv3. v1.0 has 2,348 lines of Bash code developed against modern Bash (5.x) on Linux. Any of the following will break on macOS:
- `declare -A assoc_array` -- associative arrays are Bash 4.0+
- `mapfile -t lines < file` / `readarray` -- Bash 4.0+
- `${var,,}` (lowercase) / `${var^^}` (uppercase) -- Bash 4.0+
- `|&` pipe-stderr shorthand -- Bash 4.0+
- `&>>` redirect-append -- Bash 4.0+
- `coproc` -- Bash 4.0+
- `${!prefix*}` and some advanced parameter expansions work differently

The installer and hook scripts will fail with syntax errors or, worse, silently misbehave (e.g., `${var,,}` on Bash 3.2 just returns the variable unchanged, so case-insensitive domain matching fails open).

**Why it happens:**
- Developers test on Linux where `/bin/bash` is 5.x; code passes shellcheck and integration tests
- Users running on macOS have Homebrew bash 5.x in `/opt/homebrew/bin/bash` but `/bin/bash` is still 3.2
- Shebang lines like `#!/bin/bash` always resolve to 3.2 on macOS regardless of PATH
- `shellcheck` warnings for Bash 4+ features are opt-in (`--shell=bash` does not pin version)

**Prevention:**
- **Shebang strategy**: use `#!/usr/bin/env bash` and document that users must have Bash 4+ on PATH via `brew install bash`. Installer checks `bash --version` and refuses to run if less than 4.0
- **Codify the version requirement**: every script that ships in the project must begin with a version check:
  ```bash
  if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: claude-secure requires bash 4.0+. Run: brew install bash" >&2
    exit 1
  fi
  ```
- Run `shellcheck --shell=bash --severity=warning` in CI and add a **separate CI job that runs scripts under Bash 3.2** (via Docker image or macOS runner) to catch 3.2 incompatibilities
- Audit existing 2,348 lines for: `declare -A`, `mapfile`, `readarray`, `${var,,}`, `${var^^}`, `|&`, `&>>`, `coproc`. Replace or guard each
- Do **not** rely on `PATH` manipulation to find a newer bash -- the shebang is what decides

**Detection:**
- CI job running scripts under Bash 3.2 in a container
- Grep for forbidden syntax: `rg 'declare -A|mapfile|readarray|\$\{[a-zA-Z_][a-zA-Z0-9_]*,,\}|\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^\}'`

**Phase:** Bash compatibility phase (likely early, parallel with pf foundation). Affects installer, hooks, uninstaller, CLI wrapper.

---

### Pitfall 6: BSD userland utilities differ from GNU -- sed -i, date arithmetic, and awk one-liners break

**What goes wrong:**
macOS ships BSD coreutils, not GNU. The following common idioms in v1.0 will fail or corrupt files on macOS:
- `sed -i 's/old/new/' file` -- on BSD, `-i` requires an argument (the backup extension). On Linux this works; on macOS it interprets `s/old/new/` as the backup extension and **creates a backup file named `s/old/new/`** while leaving the original unmodified. Worse, the command proceeds silently.
- `date -d "1 hour ago"` -- GNU-only. BSD uses `date -v-1H`. Any code computing expiry timestamps will fail.
- `date -d @1234567890` (unix timestamp to date) -- GNU-only. BSD uses `date -r 1234567890`.
- `grep -P` (Perl regex) -- not in BSD grep
- `readlink -f` -- GNU-only. BSD has `readlink` without `-f`; use `realpath` or a pure-bash loop
- `xargs -r` -- GNU-only (BSD xargs does not have "no-run-if-empty"). Code expecting empty input to be a no-op will fail
- `sort -R` (random) -- GNU-only; BSD does not have it
- `awk` gensub, asort, PROCINFO -- gawk extensions, not in BSD awk

**Why it happens:**
- Install scripts grew organically on Linux; every idiom that worked went in
- Testing was on Linux and WSL2, both of which have GNU coreutils
- Some failures are silent (sed -i creating a backup and not editing) -- others are loud (date -d errors) -- the silent ones are worst

**Consequences:**
- sed -i silently not editing files: config updates don't apply, security settings appear set but aren't
- date arithmetic failing: call-ID TTLs wrong or uninitialized
- Installer corrupts files by creating `s/...` backup files in random directories

**Prevention:**
- **Require GNU coreutils via Homebrew**: installer checks for `gsed`, `gdate`, `gawk`, `greadlink` and adds a project-local shim directory to PATH. Installer refuses to proceed if `brew list coreutils gnu-sed gawk` fails
- **Portable idiom for sed -i**: always use `sed -i.bak '...' file && rm -f file.bak`. This works on both BSD and GNU and is trivial to grep for compliance
- **Portable date**: write a small `date_utils.sh` library function `date_epoch_minus_seconds 3600` that detects `date --version` (GNU) vs BSD and uses the appropriate syntax. All scripts call the library, never `date` directly
- **CI gate**: run the full test suite under macOS runners (GitHub Actions `macos-latest`) in addition to Linux, and fail on any non-portable utility invocation
- **Lint step**: `rg 'sed -i [^\.]' scripts/` catches unsafe sed usage; `rg 'date -d' scripts/` catches GNU date usage

**Detection:**
- macOS CI runner with the full integration test suite
- Pre-commit hook greps for known-unsafe patterns

**Phase:** Bash compatibility phase (alongside Pitfall 5). These are typically caught by the same audit.

---

### Pitfall 7: Docker Desktop's VM networking makes `host.docker.internal` behave differently from Linux `host-gateway`

**What goes wrong:**
The webhook listener (v2.0) runs on the host and needs to talk to the claude container (or vice versa: containers need to talk to the host listener). On Linux the project uses host networking or bridge networks with `host-gateway`. On Docker Desktop for macOS:
- `host.docker.internal` resolves to the host's IP from inside a container -- works
- The **reverse** (host reaching a container by its internal IP) does *not* work -- the bridge network is inside the VM, not bridged to macOS
- `--network=host` on macOS attaches the container to the *VM's* network, not the macOS host's -- any port bound with `--network=host` is only reachable from inside the VM, invisible to the user

If the webhook listener (host process) needs to reach a validator endpoint inside a container by IP, it will fail. If the installer uses `--network=host` because it "worked on Linux," exposed ports silently don't appear on localhost.

**Why it happens:**
- The VM boundary is invisible in Compose files; the same `docker-compose.yml` runs on both but behaves differently
- Linux has no VM, so `--network=host` and bridge networks are the same level of abstraction; on macOS they are not

**Prevention:**
- **Always use published ports** (`ports: ["127.0.0.1:8080:8080"]`) for any container that needs host access. Never rely on `--network=host` or direct bridge IP access
- **Host-to-container communication** must go through `localhost:<published_port>`; document this and bake it into the Compose file
- **Container-to-host communication** must use `host.docker.internal` (which works on macOS and can be emulated on Linux via `extra_hosts: ["host.docker.internal:host-gateway"]`)
- Integration tests must verify the webhook listener can reach all required endpoints on macOS, not just that containers can talk to each other

**Detection:**
- Compose file lint: grep for `network_mode: host` and forbid it (with exceptions documented)
- Integration test: from host, curl the validator port and the proxy port; verify both respond

**Phase:** Docker Desktop compatibility phase. Touches Compose file + webhook listener wiring.

---

## Minor Pitfalls

### Pitfall 8: /etc/paths and PATH in LaunchDaemons -- daemons start with a minimal PATH

**What goes wrong:**
LaunchDaemons start with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew binaries (`/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on Intel) are **not** on PATH. If the webhook listener script calls `docker` (which is installed by Docker Desktop in `/usr/local/bin` on most systems) or `brew`-installed tools like `gdate`, they will not be found.

**Prevention:**
- Set `EnvironmentVariables.PATH` explicitly in the plist to include `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
- Or, call all external tools via absolute path and document dependencies
- Test: `launchctl print system/com.claude-secure.webhook` shows effective environment

**Phase:** Webhook/launchd phase.

---

### Pitfall 9: macOS file permissions on mounted Docker volumes differ from Linux

**What goes wrong:**
The v1.0 security model requires hook scripts and whitelist.json to be **root-owned and immutable by the Claude process**. On Linux, mounted volumes preserve host ownership. On Docker Desktop for macOS, files in mounted volumes appear inside containers with the UID/GID of the Docker Desktop VM user, not the host user. The "root-owned and read-only" guarantee may not hold the way Linux admins expect.

**Prevention:**
- Instead of relying on host file permissions, **bake immutable files into the container image at build time** (COPY with chown in Dockerfile). Do not mount sensitive files read-write from host
- For files that must be mounted (e.g., whitelist.json the user edits), mount read-only (`:ro`) and verify at container startup that the file is not writable
- Integration test: attempt to modify whitelist.json from inside the claude container, expect EROFS

**Phase:** Docker Desktop compatibility phase.

---

### Pitfall 10: codesign / Gatekeeper blocks unsigned helper binaries

**What goes wrong:**
If the installer ships any compiled helper (Go binary, Rust tool, etc.) it will be blocked by Gatekeeper on first run with "cannot be opened because the developer cannot be verified." Users have to manually right-click > Open or run `xattr -d com.apple.quarantine`, which is a terrible first-run experience for a security tool.

**Prevention:**
- Ship only shell scripts and interpreted code (Node.js, Python) -- no compiled helpers. This matches v1.0's architecture
- If compiled tools become necessary, pay for Apple Developer ID ($99/year) and notarize, OR document the xattr workaround and accept the friction
- Installer can pre-emptively `xattr -dr com.apple.quarantine <install_dir>` on files it ships

**Phase:** Packaging/install phase (if compiled helpers are ever needed).

---

### Pitfall 11: Keychain vs environment variable for HMAC secret storage

**What goes wrong:**
Linux convention: store secrets in root-readable files (`/etc/claude-secure/webhook.secret` with mode 0600). macOS convention: Keychain. Mixing the two causes confusion -- if the installer stores the HMAC secret in the user's login keychain, a LaunchDaemon (running as root) cannot read it. If it stores in `/etc/`, macOS users may object that a security tool isn't using Keychain.

**Prevention:**
- Be consistent: use root-readable files on both platforms. Document explicitly that this is intentional for LaunchDaemon compatibility
- Set mode 0600, owner root:wheel, and verify at service startup
- Do not use System Keychain (which is technically accessible to root) unless you are prepared to handle `security` CLI quirks and promptable access

**Phase:** Webhook/launchd phase.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Platform detection | Detection logic returns "darwin" but scripts assume BSD tools without version checking | Single detection function that gates every platform-specific code path; tests run on all three targets |
| Docker Desktop / validator | Iptables silently fails inside LinuxKit VM (Pitfall 3) -- security layer broken but tests pass | Validator must self-test iptables rule insertion at startup; negative integration test asserts TCP-level block, not HTTP-level |
| pf migration | Ventura zombie anchors (Pitfall 1); SIP-protected paths (Pitfall 4) | Dedicated anchor in non-SIP path; installer/uninstaller lifecycle documented; test on fresh boot |
| launchd webhook | LaunchDaemon vs LaunchAgent (Pitfall 2); PATH in daemon env (Pitfall 8); Keychain vs file (Pitfall 11) | LaunchDaemon with explicit PATH; root-readable secret file; modern bootstrap/bootout commands |
| Bash/userland audit | Bash 3.2 syntax (Pitfall 5); BSD utilities (Pitfall 6) | Homebrew bash 4+ required; GNU coreutils required; CI runs under macOS + bash 3.2 gate |
| Integration tests | Tests pass on macOS but security is silently broken | Every test must include a negative assertion (call is blocked at network layer, not just HTTP-rejected) |
| Installer UX | SIP disable requested, Gatekeeper warnings, permission prompts | Never request SIP disable; no compiled helpers; document all first-run prompts users will see |
| Uninstaller | Stale pf rules, orphaned LaunchDaemons, Docker networks not cleaned | Uninstaller runs `launchctl bootout`, `pfctl -a ... -F all`, `docker compose down -v` and warns that reboot may be required |

---

## Cross-Cutting Theme: "Silent Failures Are the Worst Failures"

The pattern across nearly every pitfall above is that macOS failure modes tend to be **silent**:
- pf zombie anchors: old rules linger invisibly
- Bash 3.2 `${var,,}`: returns unchanged, doesn't error
- sed -i on BSD: creates a backup file, doesn't edit
- LaunchAgent-instead-of-Daemon: dies at logout, no error
- Docker Desktop iptables: capability granted, rules don't apply
- SIP /etc/pf.conf: edit appears to succeed, macOS update overwrites it

For a security tool, silent failure is **worse than a loud crash** because users trust that the tool is protecting them. Every macOS code path must include an **active self-verification step** that confirms the expected behavior and fails loudly if verification fails. The planning process should treat "no verification test" as a blocking issue for any macOS phase.

---

## Sources

**High confidence (official docs or Apple-maintained):**
- [pfctl man page (ss64)](https://ss64.com/mac/pfctl.html) -- pfctl commands, anchor syntax
- [launchctl man page (ss64)](https://ss64.com/mac/launchctl.html) -- bootstrap/bootout, domain targets
- [launchd.plist(5) (Keith Smiley mirror)](https://keith.github.io/xcode-man-pages/launchd.plist.5.html) -- RunAtLoad, KeepAlive, EnvironmentVariables keys
- [Apple Developer Docs -- SIP](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection) -- SIP scope
- [Apple Developer Forums -- pfctl leaking anchors on Ventura+](https://developer.apple.com/forums/thread/745158) -- Ventura zombie anchors
- [Apple Support -- SIP](https://support.apple.com/en-us/102149) -- protected paths
- [Docker Docs -- Networking on Docker Desktop](https://docs.docker.com/desktop/features/networking/) -- VM boundary, `host.docker.internal`, --network=host limitations
- [Docker Docs -- Mac permission requirements](https://docs.docker.com/desktop/setup/install/mac-permission-requirements/) -- vmnetd, privileged ports
- [Docker for Mac issue #6297](https://github.com/docker/for-mac/issues/6297) -- iptables in containers on macOS, LinuxKit VM limitations

**Medium confidence (community/blog, verified against multiple sources):**
- [Setting up pf firewall on macOS (Iyán, Medium)](https://iyanmv.medium.com/setting-up-correctly-packet-filter-pf-firewall-on-any-macos-from-sierra-to-big-sur-47e70e062a0e) -- anchor-based approach, LaunchDaemon pattern
- [Inventive HQ -- macOS pf tutorial](https://inventivehq.com/knowledge-base/macos/how-to-configure-macos-firewall-pf) -- SIP interaction, persistent rules
- [launchd.info tutorial](https://launchd.info/) -- LaunchDaemon vs LaunchAgent distinction
- [TechRepublic -- launch agents vs daemons](https://www.techrepublic.com/article/macos-know-the-difference-between-launch-agents-and-daemons-and-use-them-to-automate-processes/) -- user-context vs system-context
- [Binding to privileged ports without root on macOS (Zameer Manji, 2024)](https://zameermanji.com/blog/2024/1/5/binding-to-privileged-ports-without-root-on-macos/) -- launchd socket activation
- [Eclectic Light -- Login Item vs LaunchAgent/Daemon](https://eclecticlight.co/2018/05/22/running-at-startup-when-to-use-a-login-item-or-a-launchagent-launchdaemon/)
- [HackMD -- BSD vs GNU vs Busybox utility differences](https://hackmd.io/@maelvls/bsd-vs-gnu-vs-busybox-incompat) -- sed, date, awk portability
- [Small Sharp Software Tools -- Install GNU utilities on macOS](https://smallsharpsoftwaretools.com/tutorials/gnu-mac/) -- gsed, gdate, gawk install
- [sed -i Linux-ism warning (Hacker News)](https://news.ycombinator.com/item?id=31252592) -- BSD sed -i behavior
- [ghostty issue #3042 -- bash 3.2 on macOS](https://github.com/ghostty-org/ghostty/issues/3042) -- Bash 3.2 compatibility patterns
- [Getting around Docker's host network limitation on Mac](https://medium.com/@lailadahi/getting-around-dockers-host-network-limitation-on-mac-9e4e6bfee44b) -- VM network boundary

**Low confidence (single-source, flagged for validation):**
- Docker Desktop 4.39+ host iptables behavior change -- mentioned in one search hit, worth verifying against Docker's changelog before depending on it
- macOS 4+ bash availability via Homebrew shebang strategy is common but `#!/usr/bin/env bash` ambiguity with PATH environment should be tested on a clean macOS install

**Training data only (lowest confidence, needs verification before implementation):**
- Exact list of iptables modules absent from LinuxKit VM -- should be enumerated by actually running the validator on Docker Desktop for macOS and listing available modules
- Whether Docker Desktop's Rosetta emulation affects NET_ADMIN specifically (vs general syscall translation) -- test empirically on Apple Silicon before finalizing arm64 image requirement
