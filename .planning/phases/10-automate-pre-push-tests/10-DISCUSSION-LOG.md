# Phase 10: Automate Pre-Push Tests - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 10-automate-pre-push-tests
**Areas discussed:** Test selection strategy, Instance awareness, CI/local parity, Failure UX, Test data & container lifecycle

---

## Test Selection Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| All tests, sequential | Run all test-phase*.sh in order. Simple but slow. | |
| Smart subset based on changes | Detect changed files via git diff, run only relevant tests. | ✓ |
| Parallel with isolation | Run independent suites in parallel with separate compose projects. | |

**User's choice:** Smart subset based on changes
**Notes:** User also wants RUN_ALL_TESTS=1 override to force all tests.

### Follow-up: No-match behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Skip tests, allow push | No code files changed, no tests needed | ✓ |
| Run minimal smoke test | Always run phase 1 as baseline | |
| Run all tests | When uncertain, be safe | |

**User's choice:** Skip tests, allow push

---

## Instance Awareness

| Option | Description | Selected |
|--------|-------------|----------|
| Dedicated test instance | Tests always use a special 'test' instance, isolated from user sessions | ✓ |
| Use whatever is running | Detect first running instance, run tests against it | |
| Require explicit instance | User must set TEST_INSTANCE env var | |

**User's choice:** Dedicated test instance

### Follow-up: Teardown lifecycle

| Option | Description | Selected |
|--------|-------------|----------|
| Auto teardown | docker compose down after tests finish | |
| Leave running | Keep test containers alive between pushes | |
| Teardown on success only | Leave up on failure for debugging, teardown on success | ✓ |

**User's choice:** Teardown on success only

---

## CI/Local Parity

| Option | Description | Selected |
|--------|-------------|----------|
| Same test runner, both use it | Single script for local and CI | |
| Pre-push is local only, CI is separate | Hook for speed, CI from scratch | ✓ |
| No CI yet, local only | Focus on hook, CI as future phase | |

**User's choice:** Pre-push is local only, CI is separate

---

## Failure UX

| Option | Description | Selected |
|--------|-------------|----------|
| Summary table + block | Table of requirement IDs with PASS/FAIL per suite | ✓ |
| Full test output + block | Complete output of each failing test | |
| Summary, full on request | Summary default, full output logged to file | |

**User's choice:** Summary table + block

---

## Test Data & Container Lifecycle

**User's input:** Each test suite starts with identical preconditions. A test container is spun up and each suite begins from the same clean state.

| Option | Description | Selected |
|--------|-------------|----------|
| Container restart between suites | docker compose restart between each suite | |
| Reset script between suites | Lightweight reset without full restart | |
| Full teardown + rebuild | docker compose down && up between each suite | ✓ |

**User's choice:** Full teardown + rebuild

---

## Claude's Discretion

- File-to-test mapping design (static config vs. convention-based)
- Summary table format and styling

## Deferred Ideas

- CI pipeline integration — separate future phase
- Parallel test execution — rejected for simplicity
- Lightweight reset between suites — rejected for reliability
