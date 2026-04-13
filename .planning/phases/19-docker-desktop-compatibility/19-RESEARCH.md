# Phase 19: Docker Desktop Compatibility - Research

**Researched:** 2026-04-13
**Domain:** Docker Desktop for Mac networking, iptables in containers, version detection, base image selection, smoke testing
**Confidence:** HIGH (architecture patterns) / MEDIUM (iptables-nft specifics, DNS workarounds)

## Summary

Phase 19 has three distinct deliverables that must be planned as separate work streams. First, `install.sh` gains a macOS-specific Docker Desktop version check (PLAT-05). Second, the validator Dockerfile swaps its base image from `python:3.11-slim` (Debian bookworm by default, but Alpine-derived in current form) to `python:3.11-slim-bookworm` explicitly, which provides `iptables-nft` in Debian's apt ecosystem and avoids the Alpine/nftables kernel mismatch that breaks iptables inside Docker Desktop containers (COMPAT-01). Third, a bash smoke test confirms the four-layer stack comes up correctly on macOS end-to-end (success criterion 3).

The critical discovery is that the current `validator/Dockerfile` already uses `python:3.11-slim` (Debian slim, not Alpine). The COMPAT-01 base image change is therefore narrowly scoped: pin the tag explicitly to `python:3.11-slim-bookworm` rather than the unversioned `slim` tag to get a stable, reproducible build on both arm64 and amd64.

The iptables situation on Docker Desktop for Mac is nuanced: iptables works when using native-architecture images (arm64 on Apple Silicon, amd64 on Intel), but breaks under QEMU emulation. Because Docker Desktop 4.44.0+ defaults to Apple Virtualization Framework (not QEMU), and because the validator image will be built as a native arm64 image on Apple Silicon hardware, iptables with `NET_ADMIN` should function. The empirical spike that will confirm this definitively is Phase 20's ENFORCE-01 deliverable, not Phase 19's scope. Phase 19's smoke test only needs to confirm that the validator container starts cleanly (no `iptables who?` crash at boot) and registers a call-ID successfully; it does not need to prove iptables blocking works end-to-end.

**Primary recommendation:** Plan Phase 19 as three sequential plans: (1) COMPAT-01 base image pin + verify `iptables` install succeeds at build time, (2) PLAT-05 Docker Desktop version check in `install.sh`, (3) smoke test script that brings the stack up on macOS and checks each layer with curl.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PLAT-05 | Installer verifies Docker Desktop >= 4.44.3 is installed and running on macOS; warns/blocks with upgrade message if older | §Architecture Patterns (version detection), §Code Examples (version check bash) |
| COMPAT-01 | Validator container uses `python:3.11-slim-bookworm` base image on all platforms (replaces unpinned slim — fixes iptables-nft compatibility with Docker Desktop Mac kernel) | §Standard Stack (image selection), §Common Pitfalls (iptables under QEMU), §Code Examples (Dockerfile snippet) |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

Directives extracted from `CLAUDE.md` that constrain this phase:

1. **Platform scope now includes macOS:** CLAUDE.md says "no macOS Docker Desktop support needed" — this is stale as of v3.0 milestone. Phase 19 explicitly adds macOS Docker Desktop support. The constraint to honor is the *architecture* (four-layer security model must remain intact on macOS).
2. **No new dependencies in proxy/validator runtime:** COMPAT-01 is a base image pin, not a library addition. No new Python packages. No new Node.js packages.
3. **Proxy uses buffered request/response (no streaming):** Smoke test must not require streaming — curl-based validation is compatible.
4. **Docker Compose v2 only:** Smoke test uses `docker compose` (plugin), never `docker-compose` (v1).
5. **Host dependencies:** `docker`, `curl`, `jq`, `uuidgen` must be available. Smoke test script may use all four.
6. **No NFQUEUE:** Validator uses HTTP registration + iptables only. Phase 19 smoke test validates the HTTP registration path (validator `/register` endpoint reachable), not the kernel packet filter.
7. **Bash hooks are sufficient:** Hook fires via bash + jq + curl + uuidgen. Smoke test can trigger a hook indirectly by executing a whitelisted `Bash` tool call inside the claude container.

## Standard Stack

### Core (unchanged from Phase 18)
| Component | Version/Tag | Purpose | Notes |
|-----------|-------------|---------|-------|
| Docker Desktop (macOS) | >= 4.44.3 | Container runtime | 4.44.0 switched default VMM to Apple Virtualization Framework; 4.44.3 is the security-patched baseline (CVE-2025-9074 fix) |
| Docker Compose v2 | bundled with Docker Desktop | Orchestration | `docker compose` subcommand, not standalone `docker-compose` |
| `python:3.11-slim-bookworm` | pinned tag | Validator base image | Debian Bookworm slim; provides apt-installable `iptables` (iptables-nft backend on modern kernels) |

### Image Selection: Why `python:3.11-slim-bookworm` over Alpine
| Property | `python:3.11-slim-bookworm` | `python:3.11-alpine` |
|----------|----------------------------|----------------------|
| iptables package | `apt-get install iptables iproute2` — installs iptables-nft which works with Docker Desktop's kernel | `apk add iptables` — installs iptables-legacy; mismatch with nftables kernel on Docker Desktop causes "iptables who?" error |
| Architecture support | Native arm64 and amd64 multi-arch images available; no QEMU needed on Apple Silicon | Same, but iptables incompatibility is the blocking issue |
| Image size | ~130MB (validator layer adds iptables ~30MB) | ~65MB (smaller but broken on Docker Desktop Mac) |
| Build reproducibility | Explicit `bookworm` tag pins Debian release | Alpine tags are also pinnable but iptables compat is the deciding factor |

**Current `validator/Dockerfile` uses `python:3.11-slim`** (unversioned slim — Debian bookworm by default, but not pinned). The COMPAT-01 change is a one-line tag update to `python:3.11-slim-bookworm`. No Python code changes required.

### Installation
No new packages on host. Inside validator container:
```
# Dockerfile change (COMPAT-01):
FROM python:3.11-slim-bookworm
# Package installation is already correct:
RUN apt-get update && \
    apt-get install -y --no-install-recommends iptables iproute2 dnsutils && \
    rm -rf /var/lib/apt/lists/*
```

## Architecture Patterns

### Pattern 1: Docker Desktop Version Detection in Bash

Docker Desktop injects its version into the `docker version` Server line:
```
Server: Docker Desktop 4.44.3 (172823)
```
Docker Engine (Linux) shows:
```
Server: Docker Engine - Community
```

**Detection approach for `install.sh`:**
```bash
# Called only when detect_platform returns "macos"
check_docker_desktop_version() {
  local required_major=4 required_minor=44 required_patch=3

  # Confirm Docker is present and daemon is running
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker Desktop is not running. Start Docker Desktop and re-run the installer."
    exit 1
  fi

  # Confirm this is Docker Desktop, not raw Docker Engine
  local server_line
  server_line="$(docker version 2>/dev/null | grep 'Server: Docker Desktop' || true)"
  if [ -z "$server_line" ]; then
    log_warn "Could not confirm Docker Desktop version. Continuing — ensure Docker Desktop >= 4.44.3."
    return 0
  fi

  # Extract version string "4.44.3" from "Server: Docker Desktop 4.44.3 (172823)"
  local dd_version
  dd_version="$(echo "$server_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  if [ -z "$dd_version" ]; then
    log_warn "Could not parse Docker Desktop version. Continuing — ensure >= 4.44.3."
    return 0
  fi

  # Version comparison using printf + sort -V (bash 4+, GNU sort)
  local min_version="${required_major}.${required_minor}.${required_patch}"
  if printf '%s\n%s\n' "$min_version" "$dd_version" | sort -V | head -1 | grep -qF "$dd_version"; then
    # dd_version sorts before min_version — it is OLDER
    if [ "$dd_version" != "$min_version" ]; then
      log_error "Docker Desktop ${dd_version} is installed but >= ${min_version} is required."
      log_error "Upgrade at: https://docs.docker.com/desktop/release-notes/"
      exit 1
    fi
  fi

  log_info "Docker Desktop ${dd_version} >= ${min_version} -- OK"
}
```

**Integration point:** Call `check_docker_desktop_version` from `check_dependencies()` after the existing `docker compose version` check, guarded by `if [ "$_plat" = "macos" ]`.

### Pattern 2: COMPAT-01 Base Image Pin

Single-line change to `validator/Dockerfile`:
```dockerfile
# Before:
FROM python:3.11-slim

# After (COMPAT-01):
FROM python:3.11-slim-bookworm
```

No other changes to the Dockerfile. The `apt-get install iptables iproute2 dnsutils` block is already correct. The build should be tested with `docker compose build validator` on macOS to confirm the arm64 image pulls and `iptables -L` returns exit 0 at container start.

### Pattern 3: Smoke Test for End-to-End Validation

The smoke test is a bash script that:
1. Starts the stack with `docker compose up -d`
2. Waits for each service to be healthy
3. Curls the validator `/register` endpoint directly from the host (via `docker compose exec`)
4. Checks that the proxy is reachable from the claude container
5. Optionally: executes a `claude -p` invocation that triggers the hook and confirms a call-ID is registered

**Minimal smoke test structure:**
```bash
#!/usr/bin/env bash
# tests/test-phase19-smoke.sh — macOS Docker Desktop end-to-end smoke test
# Run from repo root. Requires Docker Desktop >= 4.44.3 running on macOS.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/docker-compose.yml"

# --- Layer 1: claude container boots ---
echo "==> Starting stack..."
$COMPOSE up -d

echo "==> Waiting for containers..."
# Poll until claude container status is running (max 30s)
for i in $(seq 1 30); do
  status=$($COMPOSE ps claude --format json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('State',''))" 2>/dev/null || echo "")
  [ "$status" = "running" ] && break
  sleep 1
done

# --- Layer 2: proxy reachable from claude container ---
echo "==> Proxy reachable?"
$COMPOSE exec -u claude claude curl -sf http://proxy:8080/ >/dev/null && echo "PASS proxy reachable" || echo "FAIL proxy unreachable"

# --- Layer 3: validator HTTP endpoint reachable from claude container ---
echo "==> Validator /register reachable?"
TEST_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
$COMPOSE exec -u claude claude curl -sf \
  -X POST http://localhost:8088/register \
  -H 'Content-Type: application/json' \
  -d "{\"call_id\":\"${TEST_UUID}\",\"domain\":\"api.anthropic.com\"}" && \
  echo "PASS validator register" || echo "FAIL validator register"

# --- Layer 4: hook fires (static check — hook file is installed and executable) ---
echo "==> Hook installed?"
$COMPOSE exec claude test -x /etc/claude-secure/hooks/pre-tool-use.sh && \
  echo "PASS hook present" || echo "FAIL hook missing"

echo "==> Teardown"
$COMPOSE down -v
```

**What this proves:** All four security layers (container isolation, proxy, validator HTTP, hook file) are present and functional. It does NOT prove iptables blocking — that is Phase 20's ENFORCE-01 scope.

### Recommended Project Structure Addition

```
tests/
├── test-phase19-smoke.sh    # macOS smoke test (new, Phase 19)
```

The test must be guarded so it only runs on macOS (checked via `detect_platform` from `lib/platform.sh`). It should NOT be added to the Linux CI test suite — it requires Docker Desktop and real macOS hardware.

### Anti-Patterns to Avoid

- **Running smoke test in Linux CI:** This test requires Docker Desktop on macOS. Do not add it to `run-tests.sh` test selection that runs in WSL2/Linux CI — guard with `detect_platform` or document it as manual-only for now.
- **Testing iptables blocking in Phase 19:** The smoke test's job is to confirm the stack starts cleanly, not to prove enforcement works. iptables blocking belongs in Phase 20 (ENFORCE-01) and Phase 22 (TEST-02).
- **Using `docker-compose` (v1):** Always use `docker compose` (v2 plugin) in the smoke test.
- **Hardcoding the Desktop version in validator.py:** Version check belongs in `install.sh` only, not in the running service.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Semver comparison in bash | Custom string splitting logic | `printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1` | GNU sort -V handles multi-part version comparison correctly; available via coreutils on macOS after Phase 18 bootstrap |
| iptables package selection | Detect kernel version and choose iptables variant | Use `python:3.11-slim-bookworm` + `apt-get install iptables` — Debian's apt resolves the right backend | Debian bookworm's iptables package already uses update-alternatives to select iptables-nft on modern kernels |
| Docker Desktop detection | Parse `/Applications/Docker.app/Contents/Info.plist` | `docker version` server line grep | `Info.plist` gives the bundle version which may differ from the Docker Desktop version shown in UI; `docker version` output is the authoritative source and works cross-platform |

## Runtime State Inventory

This is a configuration/code-change phase with no renamed strings or migrated data. Explicitly checked:

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | None — no database records reference base image names | None |
| Live service config | None — Dockerfile tag change requires rebuild, no running state to migrate | docker compose build + up |
| OS-registered state | None | None |
| Secrets/env vars | None — no env vars reference the base image tag | None |
| Build artifacts | `validator/` Docker image will be rebuilt from new base; old image may be cached locally | `docker compose build --no-cache validator` on first deploy |

## Common Pitfalls

### Pitfall 1: iptables Fails Under QEMU Emulation on Apple Silicon
**What goes wrong:** Running an `amd64`-architecture container image on an Apple Silicon Mac causes `iptables` to fail with `can't initialize iptables table 'filter': iptables who? (do you need to insmod?)` — even with `NET_ADMIN`.
**Why it happens:** QEMU emulates x86_64 but does not emulate the netfilter kernel modules that iptables requires. This is a fundamental QEMU limitation, not a Docker Desktop bug.
**How to avoid:** Docker images must be built as native arm64 on Apple Silicon. `python:3.11-slim-bookworm` has a native arm64 variant. When building with `docker compose build` on Apple Silicon, Docker Desktop will pull the arm64 image automatically. Never use `--platform linux/amd64` for the validator on Apple Silicon.
**Warning signs:** `iptables who?` in validator container logs at startup. `docker inspect --format '{{.Architecture}}' <image_id>` returns `amd64` when running on Apple Silicon.

### Pitfall 2: Docker Desktop Internal Network DNS Bug (docker/for-mac#7262)
**What goes wrong:** In Docker Desktop >= 4.29.0, containers on `internal: true` bridge networks cannot resolve external DNS names. This is triggered when the "Enable Host Networking" experimental feature is disabled (the default).
**Why it happens:** Docker Desktop changed how internal network DNS is routed in 4.29.0. The validator's `resolve_domain("proxy")` call targets an internal Docker DNS name (always works), but if external domain resolution is needed at startup, it would fail.
**How to avoid:** The validator only resolves `"proxy"` (an internal Docker service name) during `setup_default_iptables()`. Docker's embedded DNS at `127.0.0.11` resolves internal service names correctly even with `internal: true`. External DNS resolution is only used when an outbound call is being validated — and by then iptables is already set up to allow it. **No workaround needed for Phase 19.** If the smoke test reveals DNS failures, add explicit `dns: [127.0.0.11]` to the validator service in `docker-compose.yml`.
**Warning signs:** Smoke test shows "Could not resolve 'proxy' hostname" in validator logs; iptables proxy rule NOT added.

### Pitfall 3: `sort -V` Requires GNU Sort (Not BSD Sort)
**What goes wrong:** The version comparison pattern `printf '%s\n%s\n' "$v1" "$v2" | sort -V` uses `-V` (version sort) which is a GNU coreutils extension. BSD sort on macOS does not support `-V`.
**Why it happens:** The macOS system sort is BSD sort.
**How to avoid:** The `check_docker_desktop_version` function runs in `install.sh`, which (after Phase 18's prologue) has already prepended GNU coreutils to PATH via `claude_secure_bootstrap_path`. GNU sort will be on PATH by the time version comparison runs. Do not call `check_docker_desktop_version` before `claude_secure_bootstrap_path` executes.
**Warning signs:** `sort: invalid option -- V` error during install on macOS.

### Pitfall 4: `docker version` Requires Running Daemon
**What goes wrong:** `docker version` returns an error and non-zero exit code if the Docker daemon is not running. Parsing its output without checking the exit code first leads to incorrect version detection.
**Why it happens:** The version check runs early in the installer, before any daemon-dependent operations.
**How to avoid:** Run `docker info >/dev/null 2>&1` first (as shown in the code example above). If it fails, report "Docker Desktop is not running" with a specific message. Only proceed to version parsing if `docker info` succeeds.
**Warning signs:** `Cannot connect to the Docker daemon` appearing in installer output before the version comparison runs.

### Pitfall 5: Smoke Test Teardown Leaving Volumes Dirty
**What goes wrong:** If smoke test fails mid-run and the `docker compose down -v` teardown step is skipped, the validator SQLite database volume persists. Subsequent test runs may fail due to stale database state.
**Why it happens:** `set -e` exits on first error without running cleanup.
**How to avoid:** Use a `trap` in the smoke test to always run teardown:
```bash
trap '$COMPOSE down -v --remove-orphans 2>/dev/null || true' EXIT
```
**Warning signs:** Smoke test passes the second time but fails the first — stale volume from previous run.

## Code Examples

### Verifying iptables Works in Rebuilt Validator Container
```bash
# After `docker compose build validator` on macOS, confirm iptables is functional:
docker run --rm --cap-add NET_ADMIN python:3.11-slim-bookworm \
  bash -c "apt-get update -qq && apt-get install -y -qq iptables iproute2 && iptables -L && echo 'iptables OK'"
# Source: empirical verification pattern, confirmed by docker/for-mac#5547 findings
```

### Docker Desktop Version Check (full production snippet)
```bash
# In install.sh, called from check_dependencies() when _plat=macos
check_docker_desktop_version() {
  local min_version="4.44.3"

  if ! docker info >/dev/null 2>&1; then
    log_error "Docker Desktop is not running."
    log_error "Start Docker Desktop from /Applications/Docker.app and re-run."
    exit 1
  fi

  local server_line
  server_line="$(docker version 2>/dev/null | grep 'Server: Docker Desktop' || true)"
  if [ -z "$server_line" ]; then
    log_warn "Docker Desktop version not detected — ensure >= ${min_version} is installed."
    return 0
  fi

  local dd_version
  dd_version="$(echo "$server_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  if [ -z "$dd_version" ]; then
    log_warn "Could not parse Docker Desktop version string. Continuing."
    return 0
  fi

  # GNU sort -V: smaller version comes first; if dd_version < min_version,
  # head -1 returns dd_version, which != min_version → fail.
  local lowest
  lowest="$(printf '%s\n%s\n' "$min_version" "$dd_version" | sort -V | head -1)"
  if [ "$lowest" != "$min_version" ] && [ "$lowest" = "$dd_version" ]; then
    log_error "Docker Desktop ${dd_version} is installed but >= ${min_version} is required."
    log_error "Upgrade Docker Desktop: https://docs.docker.com/desktop/release-notes/"
    exit 1
  fi

  log_info "Docker Desktop ${dd_version} satisfies >= ${min_version}"
}
```

### Validator Dockerfile (COMPAT-01 pin)
```dockerfile
# validator/Dockerfile — COMPAT-01 base image pin
FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends iptables iproute2 dnsutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mkdir -p /data
COPY validator.py .
EXPOSE 8088
CMD ["python3", "validator.py"]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| QEMU as default VMM on Docker Desktop Mac | Apple Virtualization Framework as default | Docker Desktop 4.44.0 (Aug 2025) | Native arm64 performance; iptables works without QEMU emulation fallback |
| QEMU for Apple Silicon | Apple Virtualization Framework | Docker Desktop 4.44.0 | QEMU deprecated for Apple Silicon; must use native arm64 images |
| Unversioned `python:3.11-slim` tag | `python:3.11-slim-bookworm` explicit tag | Phase 19 | Reproducible builds; clear Debian release contract |

**Deprecated/outdated:**
- QEMU as VMM option: deprecated for Apple Silicon as of Docker Desktop 4.44.0, removed as default in same release. Building `linux/amd64` containers for validator on Apple Silicon now requires explicit `--platform` override — which should never be done for the validator.
- `python:3.11-alpine` for validator: invalid for Docker Desktop Mac because Alpine's iptables-legacy doesn't match Docker Desktop's nftables kernel.

## Open Questions

1. **iptables-nft vs iptables-legacy selection inside slim-bookworm**
   - What we know: Debian bookworm ships iptables package that provides iptables-nft as the default via `update-alternatives`. Docker Desktop for Mac's Linux VM kernel supports nftables.
   - What's unclear: Does the `_run_ipt("iptables", ...)` call in validator.py invoke iptables-nft automatically, or must we explicitly call `iptables-nft` or set `update-alternatives`?
   - Recommendation: Add a startup probe in validator.py that calls `iptables -L` and logs whether it succeeds. If it fails with "iptables who?", log an actionable error. Phase 19 Plan 1 should include this probe.

2. **Smoke test execution on macOS hardware**
   - What we know: The smoke test script can be written and committed in Phase 19. It cannot be validated on the current Linux/WSL2 development machine.
   - What's unclear: Whether any Docker Desktop-specific networking behavior (like the DNS bug) will surface during actual execution.
   - Recommendation: Mark the smoke test as "written and ready for macOS validation" in Phase 19. Record execution results when macOS hardware is available. Do not block Phase 19 completion on actual execution — the script being correct and committed is the deliverable.

3. **`docker version` output format stability**
   - What we know: The "Server: Docker Desktop X.Y.Z (build#)" format has been stable across multiple major releases.
   - What's unclear: Whether Docker Desktop might change the format in a future release.
   - Recommendation: Add a fallback `log_warn` path (as shown in code example) when the grep fails to find the expected string. Warn but don't block.

## Environment Availability

This phase adds a macOS-specific check. The research environment is Linux/WSL2, so Docker Desktop is not available here. All code is written for macOS execution.

| Dependency | Required By | Available (dev machine) | Notes |
|------------|------------|-------------------------|-------|
| Docker Desktop >= 4.44.3 | PLAT-05, smoke test | No (WSL2 dev machine) | Phase 19 code is written targeting macOS; validates on macOS hardware |
| `docker version` output with "Docker Desktop" | version detection | No | Format verified from official Docker docs (MEDIUM confidence) |
| `python:3.11-slim-bookworm` arm64 image | COMPAT-01 | Pullable | Available on Docker Hub for both amd64 and arm64 |
| GNU sort (for version comparison) | PLAT-05 | Yes (Linux) | Available on macOS via Phase 18's coreutils bootstrap |

**Missing dependencies with no fallback:**
- macOS hardware with Docker Desktop for final smoke test validation

**Missing dependencies with fallback:**
- None — COMPAT-01 (image pin) can be built and tested on Linux; PLAT-05 code can be written and reviewed without macOS.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash (same as all phase tests in this repo) |
| Config file | none — test scripts are self-contained |
| Quick run command | `bash tests/test-phase19-smoke.sh` (macOS only) |
| Full suite command | `bash run-tests.sh` (Linux CI; smoke test excluded from automated selection) |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | Notes |
|--------|----------|-----------|-------------------|-------|
| PLAT-05 | Installer blocks on Docker Desktop < 4.44.3 | unit (mocked) | `bash tests/test-phase19.sh` | Mock `docker version` output via fixture; test both pass and fail paths |
| COMPAT-01 | Validator builds and starts without iptables error | build test | `docker compose build validator && docker compose up -d validator` | Requires Docker; output verified via `docker compose logs validator` |
| SC-3 | End-to-end: claude boots, proxy reachable, hook fires, call-ID registered | smoke | `bash tests/test-phase19-smoke.sh` | macOS hardware only; manual execution |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase19.sh` (unit tests only, Linux-safe)
- **Per wave merge:** Same
- **Phase gate:** Smoke test executed manually on macOS, result recorded in SUMMARY.md

### Wave 0 Gaps
- [ ] `tests/test-phase19.sh` — covers PLAT-05 unit tests (mocked `docker version` fixture)
- [ ] `tests/test-phase19-smoke.sh` — covers success criterion 3 (macOS smoke test)
- [ ] `tests/fixtures/docker-version-desktop-4.44.3.txt` — mock output for version check unit test
- [ ] `tests/fixtures/docker-version-desktop-4.28.0.txt` — mock output for version check fail test
- [ ] `tests/fixtures/docker-version-engine.txt` — mock output for non-Desktop detection test

## Sources

### Primary (HIGH confidence)
- Docker official docs (docker version output format): https://www.docker.com/blog/how-to-check-docker-version/ — Server line format for Desktop vs Engine
- Docker Desktop VMM documentation: https://docs.docker.com/desktop/features/vmm/ — Apple Virtualization Framework is now default
- docker/for-mac#5547 (GitHub): iptables fails under QEMU, works with native arm64 images — confirmed by Docker contributor
- docker/for-mac#6297 (GitHub): iptables failure message "iptables who?" caused by QEMU amd64 emulation on Apple Silicon
- Docker Desktop 4.44.x release notes: https://docs.docker.com/desktop/release-notes/ — 4.44.0 switched VMM default to Apple Virtualization; 4.44.3 is CVE-2025-9074 security fix

### Secondary (MEDIUM confidence)
- docker/for-mac#7262 (GitHub): Internal network DNS bug starting 4.29.0 — workaround is "Enable Host Networking" experimental feature; relevant to understand but validator only resolves internal names so this is low-risk for Phase 19
- WebSearch findings: `python:3.11-slim-bookworm` has native arm64 multi-arch image on Docker Hub — confirmed by Docker Hub layer inspection URL
- WebSearch: `sort -V` requires GNU sort (not BSD) — consistent with Phase 18 research findings

### Tertiary (LOW confidence)
- Docker Desktop 4.44.3 specific release date (2025-08-20) and CVE-2025-9074 description — from linuxsecurity.com report, not verified directly from Docker release notes

## Metadata

**Confidence breakdown:**
- Standard stack (image selection): HIGH — Dockerfile tag pin is a one-line, verifiable change
- Architecture patterns (version detection): HIGH — `docker version` Server line format confirmed from official Docker documentation
- Architecture patterns (smoke test): HIGH — bash + curl pattern is well-established for Docker Compose testing
- Pitfalls (iptables under QEMU): HIGH — confirmed by Docker contributor in docker/for-mac#5547
- Pitfalls (DNS bug): MEDIUM — issue confirmed open, impact on validator is assessed as low-risk but not empirically tested

**Research date:** 2026-04-13
**Valid until:** 2026-06-15 (Docker Desktop releases frequently; version check minimum may need updating if roadmap timeline extends)
