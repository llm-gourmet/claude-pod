# Stack Research: v3.0 macOS Platform Support

**Domain:** Cross-platform (Linux/WSL2 + macOS) network-isolated security wrapper
**Researched:** 2026-04-13
**Confidence:** MEDIUM-HIGH (Apple docs for launchd/pf are stable; Docker Desktop Mac iptables-in-container behavior has verified known issues)

**Scope:** This document covers ONLY what's needed to port claude-secure from Linux/WSL2 to macOS. The v1.0/v2.0 stack (Docker Compose, Node.js 22 stdlib proxy, Python 3.11 stdlib validator, Bash hooks, SQLite, the four-layer security model) is validated and unchanged in its containerized form.

**The central architectural question answered here:** *Do we need pf on macOS at all?* Short answer: **No, not for the in-container enforcement layer** — iptables still runs inside the Linux VM that Docker Desktop provides. pf is only relevant if we ever need host-level enforcement (e.g., blocking the webhook listener's outbound calls), which is out of scope for v3.0. What we DO need on macOS: launchd for the host webhook listener, brew-based dependency management, guards around BSD-vs-GNU CLI differences in host-side Bash scripts, and careful Alpine base-image selection to dodge Docker-Desktop-Mac iptables incompatibilities.

## Executive Summary of Additions

| Category | What Changes on macOS | Why |
|----------|----------------------|-----|
| Network enforcement | **No change** — iptables still runs inside the validator container (which is Linux, inside Docker Desktop's LinuxKit VM) | Docker Desktop virtualizes a full Linux kernel; `cap_add: NET_ADMIN` + iptables in the container works the same, EXCEPT for Alpine-base-image backend mismatches (see Alpine finding below) |
| Container base image | **Switch validator from `python:3.11-alpine` to `python:3.11-slim` (Debian)** OR pin Alpine ≥ 3.19 and force iptables-nft symlinks | Alpine < 3.19 defaults to iptables-legacy; Docker Desktop Mac's host kernel uses nftables backend, and legacy iptables in-container produces `can't initialize iptables table 'filter': iptables who?` errors |
| Webhook listener service manager | **launchd** (LaunchDaemon plist in `/Library/LaunchDaemons/`) replacing systemd unit | No systemd on macOS; launchd is the only supported persistent-daemon mechanism |
| Dependency bootstrap | **Homebrew** for `bash` (macOS ships 3.2), `coreutils` (for `gdate`), `jq`, `uuidgen` (already present), Docker Desktop | macOS defaults are stale (bash 3.2 from 2007) or BSD variants; hook scripts use GNU-isms |
| Host-side Bash scripts | **Guard every `date`/`sed`/`stat`/`readlink` call** behind a platform detector or use `PATH` pinning to `/opt/homebrew/bin:/usr/local/bin` for `gdate`/`gsed` | BSD coreutils have incompatible flags (`date -d`, `sed -i ''`, `readlink -f`) that will silently corrupt hook behavior |
| Platform detection | Add `claude_secure_platform()` shell function returning `linux`/`wsl2`/`macos` from `uname -s` + `/proc/version` check | All platform-specific branches in installer, webhook listener setup, and systemctl/launchctl calls key off this |
| Webhook listener packaging | Same Python 3.11 stdlib code, but bootstrapped via launchd `ProgramArguments` instead of systemd `ExecStart`, logs to `/var/log/claude-secure/` via `StandardOutPath` | Python code is already portable; only the service-registration layer differs |
| pf (packet filter) | **Do NOT add** unless v3.1 introduces host-level webhook-listener egress enforcement | pf would only help if we wanted to sandbox the host-side webhook listener itself; the security model's enforcement point is already inside the Linux VM and remains iptables-based |

## The Critical Finding: pf Is Not Needed for the Core Security Model

The question posed — *"pf tooling for macOS network enforcement"* — is based on a reasonable but incorrect assumption: that porting to macOS means replacing iptables with pf. It doesn't, because the iptables rules in claude-secure are not applied on the host; they are applied **inside the validator container**, which runs in Docker Desktop's Linux VM on macOS. That VM has a full Linux kernel with netfilter, so `cap_add: NET_ADMIN` + `iptables -A OUTPUT ...` works exactly the same way as on native Linux.

The parts that *could* justify pf on macOS:
1. **Host-level enforcement of the webhook listener** — blocking the listener's Python process from reaching non-whitelisted hosts. This is out of scope for v3.0 (the listener only speaks HTTP on localhost to spawn containers).
2. **Belt-and-suspenders host firewall** — if we distrusted Docker Desktop's network isolation and wanted pf on the host as a second barrier. v1.0 didn't do this on Linux either; we rely on `internal: true` + in-container iptables. Adding pf on macOS would be a new security requirement, not a port.

**Recommendation:** Defer pf entirely. If v3.1 wants host-level egress filtering for the listener, that's a new feature, not a port. Document this non-requirement explicitly so reviewers don't assume it got missed.

## Recommended Stack Additions

### Service Management: launchd

| Technology | Version / Location | Purpose | Why Recommended | Confidence |
|------------|-------------------|---------|-----------------|------------|
| launchd (LaunchDaemon) | Built into macOS 10.4+, plist stored at `/Library/LaunchDaemons/com.claude-secure.webhook.plist`, loaded via `sudo launchctl bootstrap system /Library/LaunchDaemons/com.claude-secure.webhook.plist` | Run the webhook listener as a persistent root-owned system daemon | launchd is the **only** supported persistent-service mechanism on macOS since launchd replaced `init`/`cron`/`xinetd` in 10.4. Third-party supervisors (`supervisord`, `daemon-tools`) are extra dependencies; launchd is always present. LaunchDaemons (not LaunchAgents) is correct because the webhook listener must run as root to bind a privileged port and must run whether a user is logged in. | HIGH |
| `launchctl bootstrap` / `bootout` | macOS 10.11+ | Load/unload daemons at runtime during install/uninstall | `launchctl load -w` / `unload -w` still work but are officially deprecated in favor of `bootstrap` (load) / `bootout` (unload). Use the new commands for Sonoma/Sequoia compatibility. | HIGH |
| `launchctl kickstart -k system/com.claude-secure.webhook` | macOS 10.11+ | Restart the daemon after config changes | Replaces the old `launchctl stop && launchctl start` dance. `-k` kills existing process first. | HIGH |

**Plist schema — minimal working LaunchDaemon for the webhook listener:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-secure.webhook</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/claude-secure/webhook-listener.py</string>
        <string>--port</string>
        <string>9443</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>UserName</key>
    <string>root</string>

    <key>GroupName</key>
    <string>wheel</string>

    <key>WorkingDirectory</key>
    <string>/usr/local/libexec/claude-secure</string>

    <key>StandardOutPath</key>
    <string>/var/log/claude-secure/webhook.stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/claude-secure/webhook.stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>CLAUDE_SECURE_CONFIG</key>
        <string>/etc/claude-secure/webhook.json</string>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
```

**Key decisions encoded above:**
- `KeepAlive` as a dict (not `<true/>`) with `SuccessfulExit=false` + `Crashed=true` restarts on crash but NOT if the process exits 0 (preventing a clean shutdown from looping)
- `RunAtLoad=true` starts immediately on bootstrap (required because `KeepAlive` implies `RunAtLoad`)
- `ThrottleInterval=10` enforces a 10-second minimum between respawns (prevents tight crash loops)
- `UserName=root` + `GroupName=wheel` matches the v1.0 Linux security model (root-owned hook/config)
- `StandardOutPath`/`StandardErrorPath` are the launchd equivalent of systemd's `StandardOutput=append:/path`; the parent directory must exist with correct permissions before bootstrap or the daemon fails silently
- `PATH` must include `/opt/homebrew/bin` (Apple Silicon) AND `/usr/local/bin` (Intel brew) because launchd daemons inherit an almost-empty PATH

**NOT using the `Sockets` key:** The `Sockets` key enables on-demand activation (launchd holds the listening socket and spawns the daemon only on first connection). This would complicate the Python listener (must call `launch_activate_socket()` via ctypes to receive the fd) and save no resources for a tiny always-on HTTP server. Stick with the `ProgramArguments` + `KeepAlive` model — the Python server binds its own port.

**Install path convention:**
- Plist: `/Library/LaunchDaemons/com.claude-secure.webhook.plist` (root:wheel, 0644)
- Binary: `/usr/local/libexec/claude-secure/webhook-listener.py`
- Config: `/etc/claude-secure/webhook.json`
- Logs: `/var/log/claude-secure/`
- This mirrors how Homebrew and most third-party macOS daemons lay out their files under SIP-permitted paths.

**systemd → launchd mapping (for the installer's platform branch):**

| systemd concept | launchd equivalent |
|-----------------|---------------------|
| `ExecStart=/usr/bin/foo --arg` | `ProgramArguments = [ "/usr/bin/foo", "--arg" ]` |
| `Restart=on-failure` | `KeepAlive = { Crashed = true; SuccessfulExit = false; }` |
| `RestartSec=10` | `ThrottleInterval = 10` |
| `User=root` + `Group=wheel` | `UserName = root` + `GroupName = wheel` |
| `StandardOutput=append:/var/log/foo.log` | `StandardOutPath = /var/log/foo.log` |
| `WantedBy=multi-user.target` + `systemctl enable` | (automatic on `launchctl bootstrap`) |
| `systemctl start foo` | `launchctl bootstrap system /Library/LaunchDaemons/foo.plist` |
| `systemctl stop foo` | `launchctl bootout system /Library/LaunchDaemons/foo.plist` |
| `systemctl restart foo` | `launchctl kickstart -k system/foo` |
| `systemctl status foo` | `launchctl print system/foo` |
| `journalctl -u foo` | `tail -f $StandardOutPath $StandardErrorPath` (no central log stream) |

### Container Base Image: Replace or Pin Alpine (Validator Only)

| Change | Details | Rationale | Confidence |
|--------|---------|-----------|------------|
| Validator base: `python:3.11-alpine` → `python:3.11-slim-bookworm` | Size grows ~50MB → ~130MB but iptables works reliably on Docker Desktop Mac | Alpine < 3.19 ships `iptables-legacy` by default; Docker Desktop Mac's LinuxKit kernel uses nftables backend; legacy iptables in-container cannot see the nft tables and errors with `can't initialize iptables table 'filter': iptables who?`. Debian slim uses `iptables-nft` via update-alternatives and works out of the box. | HIGH |
| **Alternative (keep Alpine):** Pin `python:3.11-alpine3.19` or later AND explicitly install `iptables` (which is now nft-backed in 3.19+) | Smaller image (~55MB) retained, but requires testing on both Linux and Docker Desktop Mac | Alpine 3.19 switched its `iptables` package to the nft backend. This works in principle but adds a subtle version-pinning requirement the installer must enforce. | MEDIUM |
| Proxy base (`node:20-alpine` → `node:22-alpine`) | Update Node LTS (unrelated to macOS but due per v2.0 decision); Alpine is fine for proxy because it runs no iptables | Proxy container has no `cap_add: NET_ADMIN` and doesn't touch netfilter, so Alpine's iptables backend choice is irrelevant | HIGH |
| Claude container (`ubuntu:22.04`) | **No change** | Ubuntu is nft-backed on modern releases and the claude container doesn't run iptables directly (validator does via shared netns) | HIGH |

**Recommendation:** Take the slim-bookworm path. The 80MB size delta is immaterial for a local dev tool, and it eliminates an entire class of "works on Linux, mysteriously fails on Mac" bugs. Document the decision prominently — future contributors will ask why validator isn't Alpine.

### Docker Desktop for Mac

| Concern | Finding | Action |
|---------|---------|--------|
| `internal: true` on Compose networks | Works identically on Docker Desktop Mac because the flag is implemented inside the Docker daemon running in the Linux VM, not on the host. The daemon simply omits the NAT masquerade rule for that bridge, regardless of host OS. | No code change; verify with integration test that counts as a "macOS smoke test" |
| `cap_add: NET_ADMIN` in containers | Works on Docker Desktop Mac (the capability is set on the container inside the Linux VM). The previously-reported destabilization issues are specific to `--network host` + `NET_ADMIN` + iptables combined. We don't use host networking, so we're unaffected. | No code change; document this explicitly in PITFALLS.md |
| `network_mode: "service:claude"` (shared netns between validator and claude) | Works on Docker Desktop Mac — shared network namespace is a Linux kernel feature and the LinuxKit VM provides it | No code change |
| Docker Desktop version floor | Require Docker Desktop ≥ 4.44.3 (released Aug 2025) to get CVE-2025-9074 fix (critical container-escape via Docker Engine API over internal network) | Add version check to installer's `doctor` command |
| Docker Desktop install source | Homebrew cask (`brew install --cask docker`) installs Docker Desktop; alternative is direct `.dmg` from docker.com. Cask is scriptable in the installer. | Installer prompts with brew-cask command if Docker not found |
| File sharing / bind mounts | Docker Desktop Mac uses VirtioFS (default since 4.15) for `/Users`, `/tmp`, `/private` shares. Workspaces under `~/claude-secure/` work without configuration. Paths outside the default shared list need explicit configuration in Docker Desktop settings. | Document in installer: workspace must live under `$HOME` |
| Docker Desktop licensing | Free for personal use, small businesses (<250 employees AND <$10M revenue), and open-source work. Commercial use above those thresholds requires paid subscription. | Mention in README; not a code concern |

**Alternative runtimes considered:**

| Runtime | Verdict | Reason |
|---------|---------|--------|
| Docker Desktop | **Recommended** | Best compatibility; what 99% of Mac devs have installed |
| Colima | Acceptable fallback | Open source, free, Lima-based. Supports `internal: true`. No GUI. Slightly different behavior around file mounts. Listed as "also works" in docs but not the primary target. |
| OrbStack | Acceptable fallback | Commercial, faster startup, smaller footprint. Supports all Docker Compose features we use. Listed as "also works". |
| Rancher Desktop | Not recommended for this project | Adds k8s complexity; users who pick Rancher usually want k3s, which we don't use |
| Lima (raw) | Not recommended | Requires hand-rolled Docker setup; Colima wraps it better |
| Podman Desktop | Not recommended | Rootless by default on Mac, and rootless-compose ignores `cap_add: NET_ADMIN` in some configurations (documented Docker community issue). Would need additional compatibility work. |

### Host Dependencies via Homebrew

| Package | Brew formula | Why Required | Confidence |
|---------|--------------|--------------|------------|
| bash ≥ 5.0 | `brew install bash` | macOS ships bash 3.2.57 (2007!) under `/bin/bash` due to Apple avoiding GPLv3. Any `declare -A`, `mapfile`, `[[ -v var ]]`, `${var^^}`, or `${var,,}` in hooks fails on 3.2. Installer must explicitly invoke `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) via shebang or PATH override. | HIGH |
| coreutils | `brew install coreutils` | Provides `gdate`, `gsed`, `greadlink`, `gstat`, `gtimeout`, etc. Required because BSD variants of these have incompatible flags (see "CLI divergences" below). | HIGH |
| jq ≥ 1.7 | `brew install jq` | Already a v1.0 requirement; macOS does not ship jq | HIGH |
| Docker Desktop | `brew install --cask docker` | Core runtime; see Docker Desktop section above | HIGH |
| curl | built-in | macOS ships curl 8.x (recent); no brew needed | HIGH |
| uuidgen | built-in | macOS ships uuidgen; output format `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` matches Linux. **Caveat:** BSD uuidgen outputs UPPERCASE by default; Linux's util-linux uuidgen outputs lowercase. Normalize with `tr '[:upper:]' '[:lower:]'` in the hook. | HIGH |
| flock | **Not available on macOS**; `brew install flock` installs a third-party port (`discoteq/flock`), but it's unmaintained | Only needed if hooks use `flock` for lockfiles. Audit v1.0 scripts; if flock is used, substitute with `mkdir` atomicity or `lockfile-create` | MEDIUM — needs audit |
| GNU findutils (optional) | `brew install findutils` | If hooks use GNU-only `find` predicates (e.g., `-printf`), gfind from this package provides them | LOW (only if audit finds usage) |
| gettext / envsubst (optional) | built-in with macOS or `brew install gettext` | If hooks use `envsubst` for templating | LOW |

**Installer bootstrap order:**
1. Detect platform (`uname -s` → Darwin)
2. Check for Homebrew (`command -v brew`); if missing, prompt user to install via official one-liner — do NOT auto-install brew (user consent, trust boundary)
3. `brew install bash coreutils jq`
4. `brew install --cask docker` (or verify existing Docker Desktop)
5. Verify Docker Desktop is running (`docker info` succeeds)
6. Continue with OS-agnostic install steps, using `/opt/homebrew/bin` or `/usr/local/bin` paths for brew binaries

### CLI Divergences: BSD vs GNU (Host Scripts Only)

These affect ONLY Bash scripts that run on the host (installer, webhook listener wrapper, CLI shortcut). The Ubuntu-based claude container remains GNU throughout.

| Command | BSD (macOS default) | GNU (Linux / Homebrew) | Impact on claude-secure | Mitigation |
|---------|---------------------|------------------------|-------------------------|------------|
| `date` | `date -v+5d` (relative), no `-d` | `date -d '5 days ago'`, `date -d @1234567890` | HIGH — any audit log timestamp parsing, token-expiry calculations, ISO 8601 formatting | Call `gdate` (from `coreutils`) everywhere OR write a wrapper `_date()` that branches on platform |
| `sed -i` | `sed -i '' 's/x/y/' file` (mandatory backup arg) | `sed -i 's/x/y/' file` | HIGH — installer edits config files in place | Always pass empty backup: `sed -i.bak 's/x/y/' file && rm file.bak`, or use `gsed` |
| `readlink -f` | Not supported on BSD readlink | Supported on GNU readlink | MEDIUM — resolving hook script paths | Use `greadlink -f` or a Python one-liner `python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path"` |
| `stat` | `stat -f '%Sp %Su %Sg' file` | `stat -c '%A %U %G' file` | MEDIUM — permission verification in `doctor` command | Use `gstat -c` from coreutils |
| `base64 -w 0` | `-w` flag not recognized on BSD | Wraps at 76 cols by default, `-w 0` disables | LOW — if encoding webhook HMAC secrets | Pipe through `tr -d '\n'` for portability: `base64 | tr -d '\n'` |
| `mktemp -d` | `mktemp -d -t prefix` (prefix is suffix on BSD!) | `mktemp -d -t prefix.XXXXXX` | LOW — test script scratch dirs | Use explicit template: `mktemp -d "${TMPDIR:-/tmp}/claude-secure.XXXXXX"` |
| `xargs -r` | `-r` (no-run-if-empty) not on BSD | GNU default | LOW | Guard with `[ -s file ] && xargs < file` |
| `grep -P` (PCRE) | Not in BSD grep | GNU grep | LOW | Avoid; use `grep -E` (ERE) which works in both |
| `tac` | Not in BSD | GNU | LOW | Use `tail -r` on macOS (works) or `gtac` |
| `realpath` | Missing on older macOS, present in macOS 12+ | Always present | LOW | Use `grealpath` if coreutils installed; fallback to Python |

**Recommended pattern for host-side Bash scripts:**

```bash
# At the top of every host script that may run on macOS:
case "$(uname -s)" in
    Darwin)
        # Prefer GNU coreutils installed via brew
        if [ -d /opt/homebrew/bin ]; then
            export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH"
        else
            export PATH="/usr/local/opt/coreutils/libexec/gnubin:/usr/local/bin:$PATH"
        fi
        # Also ensure we're using brew bash (≥5), not /bin/bash (3.2)
        if [ -z "$CLAUDE_SECURE_BASH_UPGRADED" ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
            export CLAUDE_SECURE_BASH_UPGRADED=1
            exec "$(brew --prefix)/bin/bash" "$0" "$@"
        fi
        ;;
    Linux)
        : # GNU tools are native
        ;;
esac
```

The `libexec/gnubin` trick from coreutils is cleaner than calling `gdate`/`gsed` explicitly because it provides un-prefixed `date`, `sed`, `readlink`, etc. that shadow BSD versions for the script's lifetime. This keeps the rest of the script identical across platforms.

### pf (Packet Filter) — Deliberately Not Added

Documenting explicitly so nobody adds this thinking it was missed.

| Question | Answer |
|----------|--------|
| Does macOS support pf? | Yes, `pfctl` (signed Apple binary) is always present. Rules live in `/etc/pf.conf` and anchors in `/etc/pf.anchors/` |
| Is the macOS pf syntax current with modern OpenBSD pf? | **No** — macOS pf is forked from OpenBSD 4.6 (circa 2009) and has not been updated. Features like `match` rules, `type enc`, and modern `scrub` syntax from OpenBSD 5.x+ are not available. Rule-writing must stick to the OpenBSD 4.6 subset. |
| Could pf replace iptables for in-container enforcement? | **No** — the enforcement runs inside the validator container, which is Linux. pf doesn't exist in Linux. |
| Could pf enforce at the host level as defense-in-depth? | **Yes, but it's a new requirement, not a port.** The v1.0 security model relied on Docker network isolation + in-container iptables; adding host-level pf would be additive hardening. Track as v3.1 candidate if valuable. |
| What about SIP interference? | pfctl itself is permitted under SIP (it's a signed Apple binary). Custom anchors loaded from `/etc/pf.anchors/` or a user-writable path work fine. The concern would be Apple overwriting `/etc/pf.conf` on OS updates, which is why the documented pattern is to add your own anchor file and include it with a single-line `anchor "com.claude-secure" load anchor "com.claude-secure" from "/etc/pf.anchors/com.claude-secure"` line in `pf.conf`. |

**If pf is ever added later**, the dynamic-rule pattern is:

```bash
# Load persistent anchor at boot (via launchd or one-shot in installer)
echo 'anchor "com.claude-secure"' | sudo pfctl -a '*' -f -
echo 'load anchor "com.claude-secure" from "/etc/pf.anchors/com.claude-secure"' | sudo pfctl -a '*' -f -

# Define a persistent table inside the anchor
cat > /etc/pf.anchors/com.claude-secure <<EOF
table <claude_allowed> persist
block out quick all
pass out quick proto tcp to <claude_allowed>
EOF

# Add/remove IPs at runtime (no rule reload)
sudo pfctl -a com.claude-secure -t claude_allowed -T add 151.101.1.42
sudo pfctl -a com.claude-secure -t claude_allowed -T delete 151.101.1.42
sudo pfctl -a com.claude-secure -t claude_allowed -T show
```

Persistent tables avoid the `pfctl -f` rule-reload cycle, which would otherwise replace all rules in the anchor on every update.

## Alternatives Considered

| Decision | Chosen | Rejected | Why |
|----------|--------|----------|-----|
| Host service manager | launchd LaunchDaemon | supervisord, runit, s6 | launchd is built in; adding a supervisor is an unnecessary dependency and trust-boundary expansion |
| Webhook listener install path | `/usr/local/libexec/claude-secure/` | `~/Library/Application Support/claude-secure/` (user-local) | LaunchDaemons run as root; the binary must be in a root-readable, non-user-writable path. `libexec` is the FHS-correct location for daemons. |
| Network enforcement on macOS host | None (rely on Docker VM isolation) | Host pf rules mirroring container iptables | Duplicating enforcement on the host adds complexity without clear threat-model justification. Defer to v3.1 if requested. |
| Validator base image | `python:3.11-slim-bookworm` | `python:3.11-alpine3.19` (nft-capable) | Simpler to reason about, avoids subtle "which Alpine version ships which iptables backend" debugging. 80MB is acceptable for a dev tool. |
| Bash for host scripts | Homebrew bash 5.x via PATH shimming | Rewrite scripts in Python / Zsh-native | Installer and hooks are ~2300 LOC of bash today; rewriting is out of scope. Zsh is not compatible with bash-ism–heavy hook code. |
| CLI divergence strategy | Shim PATH with `coreutils/libexec/gnubin` | Case-statements calling `gdate`/`gsed` per-script | PATH-shim keeps script bodies identical across platforms and auditable; per-call prefixing doubles the maintenance burden |
| macOS version floor | macOS 13 Ventura | macOS 12 Monterey or macOS 14 Sonoma | 13 is the oldest Apple-supported version as of 2026; 14+ adds no features we need but would cut out valid users on 2019–2020 Macs |
| Apple Silicon vs Intel support | Support both | Apple Silicon only | Still a meaningful Intel user base for Mac devs through 2026–2027; Homebrew handles arch differences via `/opt/homebrew` vs `/usr/local` prefix |

## What NOT to Use on macOS

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `/bin/bash` (system bash) in hooks/installer | Version 3.2.57 from 2007; missing `declare -A`, `mapfile`, `[[ -v ]]`, nested parameter expansion | Homebrew bash 5.x (`/opt/homebrew/bin/bash` or `/usr/local/bin/bash`) |
| BSD `date` / `sed` / `readlink` / `stat` without guards | Incompatible flags will silently produce wrong output or fail non-obviously | Homebrew coreutils + PATH shim to `libexec/gnubin` |
| `launchctl load -w` / `unload -w` | Deprecated since macOS 10.11 in favor of bootstrap/bootout; may be removed in future macOS | `launchctl bootstrap system` / `launchctl bootout system` |
| `LaunchAgents` for the webhook listener | LaunchAgents run per-user, not on boot, and can't bind privileged ports | LaunchDaemons (system-wide, root) |
| `KeepAlive = true` (plain bool) | Respawns even on clean exits, tight crash loops | `KeepAlive = { Crashed = true; SuccessfulExit = false; }` + `ThrottleInterval = 10` |
| `python:3.11-alpine` (< 3.19) for validator | iptables-legacy incompatible with Docker Desktop Mac's nft-backed VM kernel | `python:3.11-slim-bookworm` or Alpine ≥ 3.19 with explicit iptables-nft install |
| Docker Desktop < 4.44.3 | CVE-2025-9074 allows container escape via internal network → Docker Engine API | Require ≥ 4.44.3 in `doctor` check |
| `--network host` on macOS | Docker Desktop's host-network bridge is incomplete and known to destabilize the daemon when combined with `NET_ADMIN`/iptables | We already don't use it; keep it that way |
| pf host rules for enforcement parity | Adds complexity, duplicates container-level enforcement, out of scope for a port | Document as v3.1 candidate if threat model expands |
| `flock` in new hook code | Not in BSD userland; third-party port is unmaintained | `mkdir`-based atomic locking, or `lockfile-create` from `brew install lockfile-progs` |
| `brew install iptables` on the host | There is no such formula, and host iptables wouldn't be relevant anyway | N/A — enforcement stays inside the container |

## Version Compatibility Matrix

| Component | Minimum Version | Target Version | Reason |
|-----------|----------------|----------------|--------|
| macOS | 13 Ventura | 14 Sonoma / 15 Sequoia | Apple-supported; launchd `bootstrap`/`bootout` stable; pfctl stable; virtioFS available in Docker Desktop |
| Apple Silicon | M1 (2020+) | Any | `/opt/homebrew` prefix path |
| Intel | Any Intel Mac running macOS 13 | — | `/usr/local` prefix path |
| Docker Desktop | 4.44.3 | Latest 4.x | CVE-2025-9074 fix; VirtioFS; Compose v2 built-in |
| Homebrew | 4.0+ | Latest | Stable on all supported macOS versions |
| bash (via brew) | 5.0 | 5.2+ | `declare -A`, `mapfile`, associative arrays, `[[ -v ]]` |
| coreutils (via brew) | 9.0 | Latest | Stable GNU date/sed/readlink/stat |
| jq (via brew) | 1.7 | 1.7+ | v1.0 requirement |
| Python (in container) | 3.11 | 3.11 | Unchanged from v1.0 |
| Node.js (in container) | 22 LTS | 22 LTS | Unchanged from v2.0 |

## Installer Additions (macOS branch)

The installer's platform-detection branch needs:

```bash
install_macos_dependencies() {
    # 1. Require Homebrew
    if ! command -v brew >/dev/null 2>&1; then
        die "Homebrew is required. Install from https://brew.sh and re-run."
    fi

    # 2. Install CLI dependencies
    local formulae=(bash coreutils jq)
    for f in "${formulae[@]}"; do
        if ! brew list --formula "$f" >/dev/null 2>&1; then
            brew install "$f"
        fi
    done

    # 3. Verify Docker Desktop
    if ! command -v docker >/dev/null 2>&1; then
        die "Docker Desktop not found. Install with: brew install --cask docker"
    fi
    if ! docker info >/dev/null 2>&1; then
        die "Docker Desktop is installed but not running. Start it from Applications."
    fi

    # 4. Version check: Docker Desktop ≥ 4.44.3 (CVE-2025-9074)
    local dd_version
    dd_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1-3)
    version_at_least "$dd_version" "27.0.0" || warn "Docker Desktop < 4.44.3 has CVE-2025-9074 (container escape)"

    # 5. Create launchd directories
    sudo mkdir -p /var/log/claude-secure /etc/claude-secure /usr/local/libexec/claude-secure
    sudo chown root:wheel /var/log/claude-secure /etc/claude-secure /usr/local/libexec/claude-secure
    sudo chmod 0755 /var/log/claude-secure /etc/claude-secure /usr/local/libexec/claude-secure
}

install_macos_webhook_listener() {
    local plist_src="${REPO_ROOT}/host/macos/com.claude-secure.webhook.plist"
    local plist_dst="/Library/LaunchDaemons/com.claude-secure.webhook.plist"

    sudo install -o root -g wheel -m 0755 \
        "${REPO_ROOT}/host/macos/webhook-listener.py" \
        /usr/local/libexec/claude-secure/webhook-listener.py

    sudo install -o root -g wheel -m 0644 "$plist_src" "$plist_dst"

    # Unload if previously loaded (idempotent install)
    sudo launchctl bootout system "$plist_dst" 2>/dev/null || true
    sudo launchctl bootstrap system "$plist_dst"

    # Verify it's running
    if ! sudo launchctl print system/com.claude-secure.webhook >/dev/null 2>&1; then
        die "Webhook listener failed to start. Check /var/log/claude-secure/webhook.stderr.log"
    fi
}
```

## Sources

- macOS `pfctl` syntax and anchors — [Quick and easy pf firewall rules on macOS — Neil Sabol](https://blog.neilsabol.site/post/quickly-easily-adding-pf-packet-filter-firewall-rules-macos-osx/) (MEDIUM — confirms OpenBSD 4.6 subset, anchor file loading pattern)
- [ss64 pfctl reference](https://ss64.com/mac/pfctl.html) (MEDIUM — command syntax reference)
- [Notes on MacOS pfctl — Mike Wilson, 2023](https://amikewilson.com/2023/09/11/notes-on-pfctl) (MEDIUM — recent confirmation that macOS pf is still OpenBSD 4.6-derived)
- launchd documentation — [launchd.info Tutorial](https://launchd.info/) (HIGH — authoritative community reference, covers plist schema)
- [Apple Developer: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) (HIGH — Apple archived docs; still accurate for schema)
- [launchd.plist(5) man page — keith.github.io mirror](https://keith.github.io/xcode-man-pages/launchd.plist.5.html) (HIGH — current xcode man pages)
- [What are launchd agents and daemons on macOS? — victoronsoftware](https://victoronsoftware.com/posts/macos-launchd-agents-and-daemons/) (MEDIUM — LaunchDaemons vs LaunchAgents distinction)
- Docker Desktop networking — [Networking on Docker Desktop (docs.docker.com)](https://docs.docker.com/desktop/features/networking/) (HIGH — official)
- [How Docker Desktop Networking Works Under the Hood — Docker Blog](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/) (HIGH — official architecture blog)
- Docker Desktop CVE-2025-9074 — [Critical Docker Desktop flaw allows container escape — CSO Online](https://www.csoonline.com/article/4046353/critical-docker-desktop-flaw-allows-container-escape.html) (HIGH — corroborated across multiple security outlets; fixed in 4.44.3)
- [Docker Fixes CVE-2025-9074 — The Hacker News](https://thehackernews.com/2025/08/docker-fixes-cve-2025-9074-critical.html) (HIGH — version fix confirmed)
- iptables-in-container on Docker Desktop Mac — [Docker Bug: Docker Desktop Crash on macOS — Medium](https://medium.com/@chinmayshringi4/docker-bug-docker-desktop-crash-on-macos-understanding-the-host-network-iptables-bug-3d3fc2884149) (MEDIUM — flags host-network+NET_ADMIN+iptables as the destabilizing combination we avoid)
- [iptables doesn't work on Intel based CentOS 7 Container — docker/for-mac#6297](https://github.com/docker/for-mac/issues/6297) (HIGH — GitHub issue confirms Alpine legacy iptables failure mode)
- Alpine iptables backend — [Alpine Linux should default to nf_tables backend — alpine/aports#14058](https://gitlab.alpinelinux.org/alpine/aports/-/issues/14058) (HIGH — confirms Alpine 3.19 switch to nft)
- [Iptables-legacy vs iptables-nft — Docker Community Forums](https://forums.docker.com/t/iptables-legacy-vs-iptables-nft/99902) (MEDIUM — host/container backend-mismatch failure mode)
- [Docker with nftables — docs.docker.com](https://docs.docker.com/engine/network/firewall-nftables/) (HIGH — official, notes nft support is experimental in engine 29.0+)
- BSD vs GNU CLI divergences — [Linux (GNU) vs. Mac (BSD) Command Line Utilities — Ponder The Bits](https://ponderthebits.com/2017/01/know-your-tools-linux-gnu-vs-mac-bsd-command-line-utilities-grep-strings-sed-and-find/) (HIGH — canonical reference)
- [Install GNU Utilities on macOS — smallsharpsoftwaretools](https://smallsharpsoftwaretools.com/tutorials/gnu-mac/) (MEDIUM — coreutils gnubin PATH-shim pattern)
- [Write Cross-Platform Shell: Linux vs macOS Differences That Break Production](https://tech-champion.com/programming/write-cross-platform-shell-linux-vs-macos-differences-that-break-production/) (MEDIUM — real-world failure modes)
- [GNU date vs BSD date — jbmurphy.com](https://www.jbmurphy.com/2011/02/17/gnu-date-vs-bsd-date/) (MEDIUM — specific `date -d` vs `date -v` divergence)
- [macOS uuidgen — Matt Brunt](https://brunty.me/post/uuidgen-on-macos/) (LOW — confirms BSD uuidgen present but uppercase-default)
- [Homebrew bash 5 installation — Rick Cogley](https://rick.cogley.info/post/use-homebrew-zsh-instead-of-the-osx-default/) (LOW — confirms macOS system bash is still 3.2.57)

**No Context7 verification performed** — Context7 does not have dedicated docs for launchd, pfctl, or macOS system internals. For those, Apple's archived developer documentation and community references (launchd.info, man pages) are the authoritative sources and were used.

**Confidence caveats:**
- launchd plist schema and pf anchor syntax are decades-stable; HIGH confidence
- Docker Desktop iptables-in-container behavior on Mac has multiple corroborating sources but IS version-sensitive; MEDIUM-HIGH confidence with a recommendation to **integration-test on real Docker Desktop Mac before declaring v3.0 ready**
- Alpine iptables backend version cutoff (3.19) is confirmed by the Alpine aports tracker but has not been directly tested in our validator's specific configuration; MEDIUM confidence — this is the top risk item and justifies the slim-bookworm recommendation as the conservative default
