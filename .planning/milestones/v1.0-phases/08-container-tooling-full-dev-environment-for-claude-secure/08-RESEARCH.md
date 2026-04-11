# Phase 8: Container Tooling -- Full Dev Environment - Research

**Researched:** 2026-04-10
**Domain:** Docker Compose development workflow, test orchestration, linting, dev-mode tooling
**Confidence:** HIGH

## Summary

Phase 8 is about developer experience for working on claude-secure itself. The project currently has 3 services (claude, proxy, validator) with shell-based integration tests spread across 6 test files. There is no unified way to run tests, no dev-mode configuration for hot-reloading source changes, no linting automation, and no single-command development workflow. A developer working on the proxy or validator must manually rebuild images after every code change.

The phase should deliver: (1) a `docker-compose.dev.yml` override that enables source-code bind mounts and hot-reload for proxy and validator, (2) a Makefile with targets for build, test, lint, dev, and clean, (3) ShellCheck linting for all bash scripts, and (4) a unified test runner that executes all phase tests in sequence and reports results.

**Primary recommendation:** Use `docker compose watch` with `sync+restart` for proxy/validator development, a Makefile as the central command surface, and containerized ShellCheck for linting (not a host dependency).

## Project Constraints (from CLAUDE.md)

- **Platform**: Linux (native) and WSL2 only
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen on host
- **Security**: Hook scripts, settings, whitelist must be root-owned and immutable
- **Architecture**: Proxy uses buffered request/response (no streaming)
- **No npm/pip dependencies** in security-critical paths (proxy/validator use stdlib only)
- **GSD Workflow**: Must use GSD commands for file changes

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Docker Compose `develop.watch` | v2.24+ (already required) | Source sync and auto-restart during development | Built into Compose, no additional dependency. `sync+restart` action syncs files and restarts the container process without rebuilding the image. |
| GNU Make | 4.3 (system) | Development command surface | Available on all Linux systems. Self-documenting via `make help`. Preferred over custom shell scripts for multi-target workflows. |
| ShellCheck (containerized) | latest via `koalaman/shellcheck` | Bash script linting | Not installed on host -- run via Docker to avoid adding host dependencies. Catches common shell scripting errors in hooks, installer, CLI, and tests. |
| `docker compose --profile test` | v2.24+ | Test container isolation | Already in the stack recommendation from CLAUDE.md. Keeps test runners separate from production services. |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `docker compose config --quiet` | Validate compose file syntax | In `make lint` target, before any build |
| `docker compose build --check` | Dockerfile best-practice checks | In `make lint` target, catches Dockerfile anti-patterns |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Makefile | Just (justfile) | Better syntax but not pre-installed on most Linux systems. Make is ubiquitous. |
| Makefile | Task (taskfile.yml) | YAML-based, requires Go binary. Make is zero-install. |
| docker compose watch | Bind mounts in override file | Watch handles sync+restart automatically. Manual bind mounts require manual restarts. |
| Containerized ShellCheck | Host-installed shellcheck | Adding host dependency contradicts minimal-dependency philosophy. Docker image is ~8MB. |

## Architecture Patterns

### Recommended Project Structure (additions)
```
claude-secure/
+-- Makefile                    # NEW: dev command surface
+-- docker-compose.yml          # existing (production)
+-- docker-compose.dev.yml      # NEW: dev overrides (watch config)
+-- tests/
|   +-- test-phase1.sh          # existing
|   +-- test-phase2.sh          # existing
|   +-- test-phase3.sh          # existing
|   +-- test-phase4.sh          # existing
|   +-- test-phase6.sh          # existing
|   +-- test-phase7.sh          # existing
|   +-- run-all.sh              # NEW: unified test runner
```

### Pattern 1: Docker Compose Watch for Development
**What:** `docker compose watch` with `sync+restart` syncs source files into running containers and restarts the process without rebuilding the image.
**When to use:** During active development of proxy.js or validator.py.
**Example:**
```yaml
# docker-compose.dev.yml
services:
  proxy:
    develop:
      watch:
        - action: sync+restart
          path: ./proxy/proxy.js
          target: /app/proxy.js
  validator:
    develop:
      watch:
        - action: sync+restart
          path: ./validator/validator.py
          target: /app/validator.py
```
Run with: `docker compose -f docker-compose.yml -f docker-compose.dev.yml watch`

### Pattern 2: Makefile as Command Surface
**What:** A Makefile with phony targets that wraps all common dev operations.
**When to use:** Always -- every developer interaction goes through `make`.
**Example targets:**
```makefile
.PHONY: build up down dev test lint clean help

build:             ## Build all Docker images
	docker compose build

up:                ## Start all services
	docker compose up -d

down:              ## Stop and remove all services
	docker compose down

dev:               ## Start services with hot-reload (watch mode)
	docker compose -f docker-compose.yml -f docker-compose.dev.yml up --watch

test:              ## Run all integration tests
	bash tests/run-all.sh

lint:              ## Lint all bash scripts and Dockerfiles
	docker compose config --quiet
	docker run --rm -v "$(PWD):/mnt" koalaman/shellcheck:stable \
	    /mnt/bin/claude-secure \
	    /mnt/claude/hooks/pre-tool-use.sh \
	    /mnt/install.sh \
	    /mnt/tests/*.sh

clean:             ## Remove containers, images, and volumes
	docker compose down -v --rmi local

help:              ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
```

### Pattern 3: Unified Test Runner
**What:** A single script that runs all test-phase*.sh files in order, collects results, and reports a summary.
**When to use:** `make test` or CI pipeline.
**Key behaviors:**
- Starts containers once at the beginning
- Runs each test file in sequence
- Collects pass/fail counts per phase
- Reports total summary at the end
- Exits non-zero if any test fails
- Tears down containers at the end (optional flag to keep running)

### Anti-Patterns to Avoid
- **Bind-mounting over root-owned files:** The claude container has root-owned hooks and settings at `/etc/claude-secure/`. Dev overrides must NOT bind-mount over these paths or security testing becomes invalid.
- **Adding host dependencies for dev tooling:** ShellCheck, hadolint, etc. should run in containers. The project philosophy is minimal host dependencies.
- **Separate Dockerfiles for dev:** The containers are simple enough that a dev override file suffices. Separate Dockerfiles double maintenance.
- **Using `docker compose watch` for the claude container:** The claude container runs Claude Code CLI -- there is no source code to hot-reload. Watch is only useful for proxy and validator.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| File sync to containers | Custom inotifywait watcher | `docker compose watch` | Built-in, handles debouncing, ignores temp files, restarts processes |
| Shell script linting | Manual review | ShellCheck via Docker | Catches subtle bugs (unquoted variables, word splitting, SC2086 etc.) |
| Compose file validation | Eyeballing YAML | `docker compose config --quiet` | Catches merge errors, invalid references, missing env vars |
| Self-documenting commands | README section | Makefile `help` target with grep | Auto-generates help from comments, stays in sync with targets |

## Common Pitfalls

### Pitfall 1: Watch mode and network_mode: service:X
**What goes wrong:** The validator uses `network_mode: service:claude`, which means it shares the claude container's network namespace. If `docker compose watch` rebuilds or restarts the claude container, the validator loses its network.
**Why it happens:** `network_mode: service:X` creates a hard dependency on the referenced container's lifecycle.
**How to avoid:** Use `sync+restart` (not `rebuild`) for the validator. If the claude container restarts, the validator must also restart. Document this dependency.
**Warning signs:** Validator suddenly cannot bind to port 8088 or iptables rules disappear.

### Pitfall 2: ShellCheck false positives in heredocs
**What goes wrong:** ShellCheck warns about unquoted variables inside heredocs or jq templates.
**Why it happens:** ShellCheck cannot distinguish jq filter syntax from shell variable expansion.
**How to avoid:** Use `# shellcheck disable=SCXXXX` for specific known false positives. Do not blanket-disable checks.
**Warning signs:** Lint target fails on correct code.

### Pitfall 3: Test runner assumes containers are already running
**What goes wrong:** Tests pass locally but fail in CI because containers were not started.
**Why it happens:** Individual test scripts call `docker compose up -d` but the unified runner may skip this.
**How to avoid:** The unified test runner must handle container lifecycle: start before tests, optionally tear down after.
**Warning signs:** "connection refused" errors in test output.

### Pitfall 4: Docker Compose file merge order
**What goes wrong:** Dev overrides silently replace production values instead of merging.
**Why it happens:** Docker Compose merges maps but replaces arrays and scalars.
**How to avoid:** Dev override should only ADD new keys (like `develop.watch`), not replace existing `volumes` or `environment` arrays. Test with `docker compose -f docker-compose.yml -f docker-compose.dev.yml config` to verify merge result.
**Warning signs:** Missing environment variables or volumes after merge.

### Pitfall 5: Containerized ShellCheck cannot follow sourced files
**What goes wrong:** ShellCheck warns "Can't follow non-constant source" for `source "$CONFIG_DIR/config.sh"`.
**Why it happens:** The sourced file path is a variable, and ShellCheck cannot resolve it inside the container.
**How to avoid:** Add `# shellcheck source=/dev/null` or `# shellcheck source=path` directives where needed. These already exist in some scripts.
**Warning signs:** SC1090/SC1091 warnings.

## Code Examples

### docker-compose.dev.yml (complete)
```yaml
# Development overrides -- use with: docker compose -f docker-compose.yml -f docker-compose.dev.yml up --watch
services:
  proxy:
    develop:
      watch:
        - action: sync+restart
          path: ./proxy/proxy.js
          target: /app/proxy.js

  validator:
    develop:
      watch:
        - action: sync+restart
          path: ./validator/validator.py
          target: /app/validator.py
```

### Unified test runner (tests/run-all.sh)
```bash
#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_PHASES=()

cd "$PROJECT_DIR" || exit 1

echo "Starting containers..."
docker compose up -d --wait --timeout 30 || { echo "FATAL: containers failed to start"; exit 1; }

for test_file in "$SCRIPT_DIR"/test-phase*.sh; do
  phase=$(basename "$test_file" .sh | sed 's/test-//')
  echo ""
  echo "========================================"
  echo "  Running $phase tests"
  echo "========================================"
  if bash "$test_file"; then
    echo "  $phase: ALL PASSED"
  else
    FAILED_PHASES+=("$phase")
    echo "  $phase: SOME FAILED"
  fi
done

echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
if [ ${#FAILED_PHASES[@]} -eq 0 ]; then
  echo "  All phases passed."
  exit 0
else
  echo "  Failed phases: ${FAILED_PHASES[*]}"
  exit 1
fi
```

### Makefile help target auto-documentation
```makefile
help:  ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual `docker compose up` + rebuild | `docker compose watch` with sync+restart | Compose v2.22+ (2024), GA in v2.24+ | Eliminates rebuild-restart cycle during dev |
| docker-compose v1 (standalone binary) | `docker compose` v2 (plugin) | Deprecated 2023, EOL July 2023 | Project already uses v2 |
| Custom file-watcher scripts (inotifywait) | `docker compose watch` | Compose v2.22+ | Built-in, handles edge cases, no extra dependency |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + curl + jq (shell-based integration tests) |
| Config file | None (scripts are self-contained) |
| Quick run command | `make test` |
| Full suite command | `bash tests/run-all.sh` |

### Phase Requirements -> Test Map

Since Phase 8 has no formal requirement IDs yet, the validation targets are:

| Behavior | Test Type | Automated Command |
|----------|-----------|-------------------|
| `make build` succeeds | smoke | `make build` exits 0 |
| `make dev` starts watch mode | manual | Start `make dev`, edit proxy.js, verify restart |
| `make test` runs all phases | integration | `make test` exits 0 |
| `make lint` catches shell errors | smoke | `make lint` exits 0 on clean code |
| ShellCheck runs on all bash scripts | smoke | Part of `make lint` |
| docker-compose.dev.yml merges cleanly | smoke | `docker compose -f docker-compose.yml -f docker-compose.dev.yml config --quiet` |

### Wave 0 Gaps
- [ ] `tests/run-all.sh` -- unified test runner (does not exist yet)
- [ ] `Makefile` -- dev command surface (does not exist yet)
- [ ] `docker-compose.dev.yml` -- dev overrides (does not exist yet)

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | All containers | Yes | 29.3.1 | -- |
| Docker Compose v2 | Orchestration, watch | Yes | v5.1.1 | -- |
| GNU Make | Makefile | Yes | 4.3 | -- |
| ShellCheck | Linting | No (not on host) | -- | Run via Docker: `koalaman/shellcheck:stable` |
| hadolint | Dockerfile linting | No | -- | `docker compose build --check` (built-in) |
| Node.js | Proxy dev | Yes (in container) | 22.x | -- |
| Python | Validator dev | Yes (in container) | 3.11+ | -- |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:**
- ShellCheck: run via Docker container (no host install needed)
- hadolint: use `docker compose build --check` instead

## Open Questions

1. **Should `make dev` also enable all logging by default?**
   - What we know: Logging flags (LOG_HOOK, LOG_ANTHROPIC, LOG_IPTABLES) are env vars set by the CLI wrapper
   - What's unclear: Whether dev mode should always enable logging for debugging convenience
   - Recommendation: Yes, enable all logging in dev mode (`LOG_HOOK=1 LOG_ANTHROPIC=1 LOG_IPTABLES=1`)

2. **Should the unified test runner tear down containers after tests?**
   - What we know: Individual test scripts assume containers are already running
   - What's unclear: Whether teardown helps (clean state) or hurts (slow re-spin on next run)
   - Recommendation: Add `--keep` flag, default to teardown for CI, keep-running for local dev

3. **Should docker-compose.dev.yml be gitignored or committed?**
   - What we know: Standard practice is to gitignore overrides for personal config
   - What's unclear: This is project-level dev tooling, not personal preference
   - Recommendation: Commit it. It is shared dev tooling, not personal config. Personal overrides can go in `docker-compose.override.yml` (gitignored).

## Sources

### Primary (HIGH confidence)
- [Docker Compose Watch docs](https://docs.docker.com/compose/how-tos/file-watch/) -- watch syntax, actions, ignore patterns
- [Docker Compose profiles docs](https://docs.docker.com/compose/how-tos/profiles/) -- profile-based service selection
- Project codebase inspection -- docker-compose.yml, Dockerfiles, test scripts, CLI wrapper

### Secondary (MEDIUM confidence)
- [Docker Compose override strategies](https://oneuptime.com/blog/post/2026-01-30-docker-compose-override-strategies/view) -- base + override pattern
- [Containerizing test tooling (Docker blog)](https://www.docker.com/blog/containerizing-test-tooling-creating-your-dockerfile-and-makefile/) -- Makefile + Docker patterns

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all tools are mature, well-documented, and already available
- Architecture: HIGH -- patterns follow Docker Compose official docs and project conventions
- Pitfalls: HIGH -- derived from direct inspection of docker-compose.yml (network_mode, volumes, etc.)

**Research date:** 2026-04-10
**Valid until:** 2026-05-10 (stable tooling, unlikely to change)
