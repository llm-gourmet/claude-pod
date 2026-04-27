# Codebase Index

> **Maintenance note:** Update this file whenever a source file is added, renamed, or removed.

## Context to the repository
- [README.md](README.md) — CLI and repo summary
- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture, Call Chain Sequence
- [VISION.md](VISION.md) — The reason for this repository

## Orchestration Scripts

- [install.sh](install.sh) — Installs claude-pod: builds Docker images, generates config, installs Claude Code hooks, and creates the CLI shortcut
- [uninstall.sh](uninstall.sh) — Removes the claude-pod installation, Docker images, and Claude Code hooks
- [run-tests.sh](run-tests.sh) — Runs the full integration test suite against the live Docker stack
- [docker-compose.yml](docker-compose.yml) — Declares the claude, proxy, and validator containers with internal network isolation

## CLI

- [bin/claude-pod](bin/claude-pod) — Main CLI entry point: wraps `claude` with Docker isolation and exposes subcommands (spawn, profile, update, uninstall, etc.)

## Container Definitions

- [claude/Dockerfile](claude/Dockerfile) — Container image for the Claude Code process: Ubuntu base with Claude Code CLI, bash, jq, curl, and uuidgen
- [proxy/Dockerfile](proxy/Dockerfile) — Container image for the Anthropic proxy service: Node.js Alpine base
- [validator/Dockerfile](validator/Dockerfile) — Container image for the call validator service: Python Alpine base with iptables

## Security Services

- [proxy/proxy.js](proxy/proxy.js) — Buffered forward proxy that redacts secrets from requests before forwarding to `api.anthropic.com` and restores them in responses
- [validator/validator.py](validator/validator.py) — HTTP service that registers call-IDs in SQLite and enforces outbound network access via iptables rules
- [webhook/listener.py](webhook/listener.py) — GitHub webhook receiver that verifies HMAC-SHA256 signatures and dispatches events to `claude-pod spawn`

## Hooks

- [claude/hooks/pre-tool-use.sh](claude/hooks/pre-tool-use.sh) — PreToolUse hook that intercepts Bash/WebFetch/WebSearch calls, validates the target domain against the profile whitelist, and registers call-IDs with the validator

## Library & Utilities

- [lib/platform.sh](lib/platform.sh) — Platform detection and PATH bootstrapping shared by install.sh and the CLI (bash 3.2-safe)
- [scripts/migrate-profile-prompts.sh](scripts/migrate-profile-prompts.sh) — One-shot migration script that converts profile directories to the file-based tasks/system_prompts layout
- [scripts/new-project.sh](scripts/new-project.sh) — Scaffolds a new project directory from templates

## Tests

- [tests/test-phase1.sh](tests/test-phase1.sh) — Integration tests for Docker infrastructure requirements (DOCK-01–DOCK-06, WHIT-01–WHIT-03)
- [tests/test-phase2.sh](tests/test-phase2.sh) — Integration tests for call validation (CALL-01–CALL-07)
- [tests/test-phase3.sh](tests/test-phase3.sh) — Integration tests for secret redaction (SECR-01–SECR-05)
- [tests/test-phase4.sh](tests/test-phase4.sh) — Integration tests for installation and platform detection (INST-01–INST-06, PLAT-01–PLAT-03)
- [tests/test-phase6.sh](tests/test-phase6.sh) — Integration tests for service logging (LOG-01–LOG-07)
- [tests/test-phase7.sh](tests/test-phase7.sh) — Integration tests for env-file strategy (ENV-01–ENV-05)
- [tests/test-phase9.sh](tests/test-phase9.sh) — Integration tests for multi-instance support (MULTI-01–MULTI-09)
- [tests/test-phase12.sh](tests/test-phase12.sh) — Integration tests for the profile system (PROF-01–PROF-03, superuser mode, list)
- [tests/test-phase13.sh](tests/test-phase13.sh) — Integration tests for the headless CLI spawn path (HEAD-01–HEAD-05)
- [tests/test-phase14.sh](tests/test-phase14.sh) — Integration tests for the webhook listener (HOOK-01, HOOK-02, HOOK-06)
- [tests/test-phase15.sh](tests/test-phase15.sh) — Integration and unit tests for webhook event handlers (HOOK-03–HOOK-05, HOOK-07)
- [tests/test-phase16.sh](tests/test-phase16.sh) — Integration and unit tests for the result channel: docs-repo push and JSONL audit log (OPS-01, OPS-02)
- [tests/test-phase17.sh](tests/test-phase17.sh) — Unit tests for operational hardening: container reaper and systemd directives (OPS-03)
- [tests/test-phase17-e2e.sh](tests/test-phase17-e2e.sh) — End-to-end tests for Phase 17 operational hardening (OPS-03)
- [tests/test-phase18.sh](tests/test-phase18.sh) — Unit tests for platform abstraction and bash portability (lib/platform.sh)
- [tests/test-phase19.sh](tests/test-phase19.sh) — Unit tests for Docker Desktop compatibility (COMPAT-01)
- [tests/test-phase19-smoke.sh](tests/test-phase19-smoke.sh) — Smoke test that brings the full stack up on macOS Docker Desktop and verifies all four security layers
- [tests/test-bootstrap-docs.sh](tests/test-bootstrap-docs.sh) — Unit tests for the `bootstrap-docs` subcommand (BOOT-01–BOOT-15)
- [tests/test-cli-commands.sh](tests/test-cli-commands.sh) — Unit tests for CLI commands not covered by phase tests (CLI-01+)
- [tests/test-gh-webhook-listener-cli.sh](tests/test-gh-webhook-listener-cli.sh) — Unit tests for the `gh-webhook-listener` CLI subcommand (WLCLI-01–WLCLI-13)
- [tests/test-gh-webhook-listener-filter-cli.sh](tests/test-gh-webhook-listener-filter-cli.sh) — Unit tests for webhook listener filter CLI options (WLFILTER-01–WLFILTER-09)
- [tests/test-profile-scaffold-event-tasks.sh](tests/test-profile-scaffold-event-tasks.sh) — Tests for profile scaffold files, default system prompt, and spawn dry-run on a fresh profile
- [tests/test-profile-task-prompts.sh](tests/test-profile-task-prompts.sh) — Unit tests for file-based tasks/system_prompts resolution and the migration script
- [tests/test-profile-secret.sh](tests/test-profile-secret.sh) — Unit tests for `claude-pod profile <name> secret` subcommands (PROFS-01+)
- [tests/test-uninstall-cmd.sh](tests/test-uninstall-cmd.sh) — Unit tests for the `claude-pod uninstall` subcommand
- [tests/test-update-cmd.sh](tests/test-update-cmd.sh) — Unit tests for `claude-pod update` and `upgrade` subcommands
- [tests/test-webhook-spawn.sh](tests/test-webhook-spawn.sh) — Tests that the webhook listener correctly calls `claude-pod spawn` and logs events
- [tests/test-payload-filter.sh](tests/test-payload-filter.sh) — Unit and integration tests for event-type-specific webhook payload filtering (PAY-01–PAY-10)
