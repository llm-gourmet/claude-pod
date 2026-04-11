---
phase: 12-profile-system
plan: 01
subsystem: cli
tags: [bash, jq, profiles, docker-compose, tdd]

# Dependency graph
requires:
  - phase: 09-multi-instance
    provides: Instance system patterns (name validation, auth setup, compose integration)
provides:
  - Profile-based CLI wrapper with validate/create/resolve/merge/list functions
  - Source-only guard for test sourcing of bin/claude-secure functions
  - Fail-closed profile validation (7 checks)
  - Superuser mode with merged whitelists and .env files
  - Repo-to-profile resolution for webhook routing
affects: [13-headless-cli, 14-webhook-listener]

# Tech tracking
tech-stack:
  added: []
  patterns: [source-only guard via __CLAUDE_SECURE_SOURCE_ONLY, atomic profile creation via tmpdir-then-mv, jq-based JSON config parsing]

key-files:
  created: [tests/test-phase12.sh]
  modified: [bin/claude-secure]

key-decisions:
  - "Source-only guard pattern (__CLAUDE_SECURE_SOURCE_ONLY) enables test sourcing without executing main block"
  - "validate_profile uses return 1 instead of exit 1 so tests can source and call functions"
  - "Superuser mode merges all profile whitelists with jq unique_by(.env_var) deduplication"
  - "CONFIG_DIR defaults to HOME but can be overridden via env var for test isolation"

patterns-established:
  - "Source-only guard: __CLAUDE_SECURE_SOURCE_ONLY=1 source bin/claude-secure loads functions without executing"
  - "Profile directory layout: ~/.claude-secure/profiles/<name>/{profile.json, .env, whitelist.json}"
  - "Fail-closed validation: 7-check sequence, return 1 on any failure, never fallback to default"
  - "Atomic profile creation: build in tmpdir, mv to final location"

requirements-completed: [PROF-01, PROF-02, PROF-03]

# Metrics
duration: 5min
completed: 2026-04-11
---

# Phase 12 Plan 01: Profile System CLI Rewrite Summary

**Complete rewrite of bin/claude-secure from instance system to profile system with JSON config, fail-closed validation, superuser merge mode, and 19 passing tests**

## What Was Built

Rewrote `bin/claude-secure` (~350 lines) from scratch, replacing the entire instance system with a profile-based architecture. The script now uses JSON config (`profile.json` via `jq`) instead of shell variables (`config.sh`), supports optional `--profile NAME` scoping (superuser mode when omitted), and enforces fail-closed validation on all profile operations.

### Key Functions

| Function | Purpose | Requirement |
|----------|---------|-------------|
| `validate_profile_name()` | DNS-safe name validation (regex + length) | PROF-01 |
| `validate_profile()` | 7-check fail-closed validation | PROF-03 |
| `create_profile()` | Atomic profile creation with tmpdir pattern | PROF-01 |
| `setup_profile_auth()` | OAuth/API key auth setup (reused pattern) | PROF-01 |
| `resolve_profile_by_repo()` | Scan profiles for matching repo field | PROF-02 |
| `merge_whitelists()` | Union secrets with jq unique_by dedup | Superuser |
| `merge_env_files()` | Concatenate all profile .env files | Superuser |
| `load_profile_config()` | Set Docker Compose env vars from profile | All |
| `load_superuser_config()` | Merge all profiles for superuser mode | Superuser |
| `list_profiles()` | Table with PROFILE/REPO/STATUS/WORKSPACE | D-14 |

### Clean Break from Instances

- `--instance` flag rejected with descriptive error
- All instance code deleted: `migrate_if_needed()`, `INSTANCE_DIR`, `validate_instance_name()`, `create_instance()`, `setup_instance_auth()`
- No backward compatibility layer (per D-03)

## Test Coverage

19 tests in `tests/test-phase12.sh` covering all requirements:

| Group | Tests | What They Cover |
|-------|-------|-----------------|
| PROF-01 | 4 | Profile creation, JSON validity, name validation (valid + invalid) |
| PROF-02 | 3 | Repo field reading, profile resolution, unknown repo handling |
| PROF-03 | 7 | All 7 failure modes: missing dir, missing profile.json, invalid JSON, missing workspace field, nonexistent workspace, missing .env, missing whitelist.json |
| Superuser | 3 | Merged whitelist secrets, merged .env keys, deduplication |
| List | 1 | Column headers present |
| Clean break | 1 | --instance flag rejection |

## Deviations from Plan

None - plan executed exactly as written.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 (TDD RED) | 3dc6552 | Test scaffold with 19 test cases |
| 2 (TDD GREEN) | cccc603 | Full bin/claude-secure rewrite, all tests pass |
