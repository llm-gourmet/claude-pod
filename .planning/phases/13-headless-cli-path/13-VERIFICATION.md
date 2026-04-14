---
phase: 13-headless-cli-path
verified: 2026-04-14T00:00:00Z
status: passed
score: 5/5 must-haves verified (HEAD-01, HEAD-02, HEAD-03, HEAD-04, HEAD-05)
verdict: PASS
---

# Phase 13: Headless CLI Path Verification Report

**Phase Goal:** Deliver a headless spawn subcommand that runs a non-interactive Claude Code session via `claude -p` inside a Docker container, captures structured JSON output in an envelope, supports max-turns budgeting and prompt templates with variable substitution — satisfying HEAD-01 through HEAD-05.

**Verdict:** PASS

**Re-verification:** No — initial verification (backfill, Phase 27).

---

## Goal Achievement

### Observable Truths (from HEAD-01 through HEAD-05 acceptance criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can spawn a non-interactive Claude Code session via `claude-secure spawn --profile <name> --event <payload>` (HEAD-01) | VERIFIED | `13-01-SUMMARY.md` `requirements-completed: [HEAD-01, HEAD-04]`; `do_spawn()` function with arg parsing for `--event`, `--event-file`, `--profile` (required), `--prompt-template`, `--dry-run`; validation sequence checks JSON validity, event-file existence. HEAD-01 tests a-e all pass. Commit `a82a43b`. |
| 2 | Headless session uses `-p` with `--output-format json` and captures structured result in an envelope (HEAD-02) | VERIFIED | `13-02-SUMMARY.md` `requirements-completed: [HEAD-02, HEAD-03, HEAD-04]`; `build_output_envelope()` wraps Claude JSON in `{profile, event_type, timestamp, claude: <raw>}`; `build_error_envelope()` for failures with stderr; test HEAD-02a passes: output envelope structure verified. Commit `a1796a0`. |
| 3 | User can set per-profile `--max-turns` budget to limit execution scope (HEAD-03) | VERIFIED | `13-02-SUMMARY.md` `requirements-completed: [HEAD-02, HEAD-03, HEAD-04]`; `--max-turns` value conditionally forwarded from `profile.json` field to `claude -p --max-turns N`; tests HEAD-03a (field present, value read) and HEAD-03b (field absent, flag omitted) both pass. Commit `a1796a0`. |
| 4 | Spawned instance is ephemeral — containers created, execute, and tear down automatically (HEAD-04) | VERIFIED | `13-01-SUMMARY.md` `requirements-completed: [HEAD-01, HEAD-04]`; `spawn_project_name()` generates `cs-<profile>-<uuid8>` names for container isolation; `spawn_cleanup()` trap runs `docker compose down -v` on any exit path (success or failure); tests HEAD-04a (ephemeral naming pattern) and HEAD-04b pass. Commits `a82a43b` (naming + cleanup), `a1796a0` (wired into execution lifecycle). |
| 5 | User can define prompt templates per profile with variable substitution (HEAD-05) | VERIFIED | `13-03-SUMMARY.md` `requirements-completed: [HEAD-05]`; `resolve_template(event_type, explicit_template)` finds templates in `$CONFIG_DIR/profiles/$PROFILE/prompts/`; `render_template(template_path, event_json)` substitutes 6 variables (REPO_NAME, EVENT_TYPE, ISSUE_TITLE, ISSUE_BODY, COMMIT_SHA, BRANCH) via jq + awk for multiline safety; HEAD-05 tests a-e all pass. Commit `f078a5a`. |

**Score:** 5/5 truths verified.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `bin/claude-secure` | spawn subcommand functions: `spawn_project_name()`, `spawn_cleanup()`, `do_spawn()`, `build_output_envelope()`, `build_error_envelope()`, `resolve_template()`, `render_template()` | VERIFIED | All 7 functions implemented across Plans 13-01 (skeleton), 13-02 (execution lifecycle), 13-03 (template system). Commits `a82a43b`, `a1796a0`, `f078a5a`. `--bare` flag intentionally omitted to preserve PreToolUse security hooks (documented key-decision). |
| `tests/test-phase13.sh` | 16 integration tests covering HEAD-01 through HEAD-05 with source-then-guard SKIP pattern | VERIFIED | Created in commit `d2eb526`. Source-then-guard pattern: source `bin/claude-secure` first, then type-check for SKIP. All 16 tests pass across Plans 13-01 through 13-03 (confirmed in `13-02-SUMMARY.md` and `13-03-SUMMARY.md`). |
| `tests/test-map.json` | Routes `bin/claude-secure` and self to `test-phase13.sh` | VERIFIED | Updated in commit `a82a43b` (`13-01-SUMMARY.md`). Mappings for `bin/claude-secure` and `tests/test-phase13.sh` added. |

---

## Key Link Verification (Wiring)

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `do_spawn` | Docker execution | `docker compose up -d --wait` → `docker compose exec -T claude claude -p` → `spawn_cleanup` | WIRED | Full lifecycle: containers start, `claude -p` executes headlessly, cleanup trap always fires. `-T` flag for non-interactive tty. |
| `do_spawn` | template system | `resolve_template(event_type)` → `render_template(template_path, event_json)` → prompt passed to `claude -p` | WIRED | Template resolution prefers explicit `--prompt-template` over event-type derived name per key-decision. |
| `spawn_project_name` | ephemeral isolation | `cs-<profile>-$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)` | WIRED | Unique 8-char suffix prevents container collisions between concurrent spawn runs. Pattern confirmed in `13-01-SUMMARY.md`. |
| `build_output_envelope` | structured output | `{profile, event_type, timestamp, claude: <raw_json>}` | WIRED | Claude's `--output-format json` output captured and wrapped. `build_error_envelope` handles failure case. |
| `do_spawn` | Phase 14 spawn contract | `--profile NAME`, `--event-file PATH` flags | WIRED | Phase 14 listener invokes `claude-secure spawn --profile name --event-file path` — flags match `do_spawn` arg parsing. |

---

## Key Design Decision: `--bare` Flag Omission

The `--bare` flag was intentionally excluded from the `claude -p` invocation. This preserves the PreToolUse security hooks inside the container. Including `--bare` would bypass the hook layer, undermining the core security guarantee of claude-secure. This is documented in `13-02-SUMMARY.md` under key-decisions: "Omit --bare flag: Security hooks (PreToolUse) are critical per CLAUDE.md mandate; --bare skips them."

---

## Behavioral Spot-Checks

| Behavior | Test | Result | Status |
|----------|------|--------|--------|
| spawn arg parsing: --profile required | HEAD-01a | --profile absent fails with error | PASS |
| spawn arg parsing: --event JSON valid | HEAD-01b | valid JSON accepted | PASS |
| spawn arg parsing: --event-file exists | HEAD-01c | missing file fails | PASS |
| spawn arg parsing: --dry-run exits cleanly | HEAD-01d/DRY-RUN | prints resolved prompt, no containers | PASS |
| spawn arg parsing: ephemeral name format | HEAD-01e/HEAD-04a | cs-<profile>-<uuid8> pattern | PASS |
| Output envelope structure | HEAD-02a | {profile, event_type, timestamp, claude} keys present | PASS |
| max_turns read from profile | HEAD-03a | --max-turns N passed to claude -p | PASS |
| max_turns absent from profile | HEAD-03b | --max-turns omitted from invocation | PASS |
| Ephemeral cleanup trap fires | HEAD-04b | spawn_cleanup runs on exit, docker compose down -v | PASS |
| Template resolved by event type | HEAD-05a | prompts/issues.md found for event_type=issues | PASS |
| Template explicit override | HEAD-05b | --prompt-template flag takes precedence | PASS |
| Template missing → error | HEAD-05c | clear error message when template not found | PASS |
| render_template variable substitution | HEAD-05d | all 6 vars substituted from event JSON | PASS |
| render_template missing vars → empty | HEAD-05e | missing jq fields replaced with empty string | PASS |
| **Full suite** | 16/16 | All HEAD-01 through HEAD-05 + DRY-RUN pass | PASS |

---

## Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| HEAD-01 | 13-01-PLAN | `claude-secure spawn --profile <name> --event <payload>` subcommand | SATISFIED | `do_spawn()` arg parsing, validation, `spawn_project_name()`, `spawn_cleanup()` trap. HEAD-01 tests a-e pass. Commit `a82a43b`. |
| HEAD-02 | 13-02-PLAN | Headless session captures structured JSON output envelope | SATISFIED | `build_output_envelope()` and `build_error_envelope()` wrap Claude `-p --output-format json` output. HEAD-02a passes. Commit `a1796a0`. |
| HEAD-03 | 13-02-PLAN | Per-profile `--max-turns` budget | SATISFIED | `--max-turns` conditionally forwarded from `profile.json`; HEAD-03a/b both pass. Commit `a1796a0`. |
| HEAD-04 | 13-01-PLAN, 13-02-PLAN | Ephemeral containers with automatic teardown | SATISFIED | `spawn_project_name()` for unique names; `spawn_cleanup()` trap for guaranteed teardown; HEAD-04a/b pass. Commits `a82a43b`, `a1796a0`. |
| HEAD-05 | 13-03-PLAN | Prompt templates with 6-variable substitution | SATISFIED | `resolve_template()` and `render_template()` with awk for multiline safety; HEAD-05a-e all pass. Commit `f078a5a`. |

**Coverage:** 5/5 requirements satisfied across Plans 13-01, 13-02, 13-03.

---

## Anti-Patterns Found

**Scan targets:** `bin/claude-secure` (spawn functions), `tests/test-phase13.sh`.

| File | Issue | Severity | Resolution |
|------|-------|----------|------------|
| `tests/test-phase13.sh` (original) | Type guards checked `type do_spawn` before sourcing `bin/claude-secure` — functions never found, all tests SKIP | BUG (auto-fixed Rule 1) | Fixed in commit `a82a43b`: restructured all test functions to source first, then type-check. Documented in `13-01-SUMMARY.md` Deviations section. |
| `bin/claude-secure` (original Plan 02 draft) | `LOG_DIR` unbound under `set -u` when `do_spawn` called without full `load_profile_config` | BUG (auto-fixed Rule 3) | Fixed in commit `a1796a0`: added `LOG_DIR="${LOG_DIR:-$CONFIG_DIR/logs}"` defensive default. Documented in `13-02-SUMMARY.md`. |

No remaining anti-patterns. Both issues were auto-fixed during execution. No TODO/FIXME/stub/placeholder matches in any Phase 13 artifact post-completion (`13-03-SUMMARY.md` states "Known Stubs: None").

---

## Gaps Summary

**None.** All five requirements (HEAD-01 through HEAD-05) are satisfied. 16/16 tests pass per SUMMARY evidence across Plans 13-01, 13-02, 13-03. The `--bare` flag omission is an intentional security decision, not a gap. Both auto-fixed bugs (test ordering, unbound LOG_DIR) were resolved within their respective plan commits. Verification was late (Phase 13 executed 2026-04-11/12, verification created 2026-04-14 via Phase 27 backfill) but the code and tests were present and passing from the start.

**Verdict: PASS — Phase 13 headless CLI path requirements fully satisfied.**

---

*Verified: 2026-04-14*
*Verifier: Claude (gsd-verifier, backfill via Phase 27)*
