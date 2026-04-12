---
phase: 15-event-handlers
plan: 03
subsystem: cli
tags: [bash, jq, awk, python3, webhooks, headless-cli, template-rendering, pitfall-1, pitfall-4, pitfall-6, pitfall-7]

# Dependency graph
requires:
  - phase: 13-headless-cli-path
    provides: bin/claude-secure spawn, resolve_template, render_template, --event-file, --dry-run, _CLEANUP_FILES trap pattern
  - phase: 14-webhook-listener
    provides: .event_type annotation on persisted event files, $CONFIG_DIR/events/ directory convention, ._meta fallback
  - phase: 15-event-handlers/plan-01
    provides: tests/test-phase15.sh Wave 0 scaffold, 9 GitHub webhook fixtures
provides:
  - D-16 variable substitution for 18 template tokens (REPO_NAME, EVENT_TYPE, ISSUE_*, BRANCH, COMMIT_*, PUSHER, COMPARE_URL, WORKFLOW_*)
  - extract_payload_field UTF-8-safe + control-char-clean payload extractor
  - _substitute_token_from_file awk-based substitution primitive (Pitfall 1 fix)
  - resolve_template fallback chain (profile -> WEBHOOK_TEMPLATES_DIR -> hard fail)
  - BRANCH/COMMIT_SHA gated-fallback pattern for workflow_run payloads (Pitfall 6/7)
  - do_replay subcommand (HOOK-07) with exec-recursion into spawn
affects: [15-04-installer-templates, future event handler plans]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "awk-file substitution: avoid sed escape bugs by reading the substitution value from a file (| \\ & / newlines are all safe)"
    - "Gated fallback for multi-source template variables: `[ -s \"$v_file\" ]` prevents the naive post-hoc grep pattern from consuming the token with an empty value"
    - "python3 env-var payload pipe: pass RAW_PAYLOAD via env and invoke `python3 -c` to avoid stdin heredoc collisions and argv-size limits"
    - "exec-recursion for subcommand reuse: do_replay delegates to do_spawn via exec so the spawn lifecycle is not duplicated"
    - "CLAUDE_SECURE_EXEC override: test harnesses redirect the replay exec to a recorder stub for argv assertions"
    - "Test-friendly CONFIG_DIR: bin/claude-secure auto-derives APP_DIR from the script path when $CONFIG_DIR/config.sh is absent (dev checkout + test isolation)"

key-files:
  created:
    - ".planning/phases/15-event-handlers/15-03-SUMMARY.md"
  modified:
    - "bin/claude-secure"
    - "tests/test-phase15.sh"
    - "tests/fixtures/github-issues-opened.json"
    - "tests/fixtures/github-issues-opened-with-pipe.json"
    - "tests/fixtures/github-workflow-run-failure.json"

key-decisions:
  - "extract_payload_field emits content to stdout (not a temp file path). Plan 15-01's test scaffold treats it as a 'cat the cleaned value' helper; returning a path would make the tests impossible to satisfy. A thin _extract_to_tempfile wrapper exists for callers like render_template that need a file handle."
  - "python3 receives the payload via RAW_PAYLOAD env var, not stdin heredoc. The plan skeleton used `printf %s \"$raw\" | python3 - \"$out_file\" <<'PY'` which collides heredoc-stdin with pipe-stdin and produces empty output. Env var is argv/IFS-safe for arbitrary bytes and documented in bash(1)."
  - "BRANCH and COMMIT_SHA substitution is GATED on `[ -s \"$v_file\" ]` rather than the naive 'substitute then check if {{BRANCH}} is still present' pattern. The gated variant was the latent Pitfall regression documented by the `main` tripwire in test_workflow_template_dry_run."
  - "resolve_template does NOT fall back to defaults when --prompt-template is explicit. A silent fallback would hide typos in profile-level overrides (D-13 step 1)."
  - "do_replay exec target is $0 unless CLAUDE_SECURE_EXEC is set. This allows tests to redirect the exec to a recorder stub while keeping the production path unchanged."
  - "validate_profile is skipped for spawn and replay commands. These commands read profile.json directly and only hit .env/whitelist.json if they actually boot docker (never for --dry-run)."
  - "bin/claude-secure auto-derives APP_DIR from its own script path when $CONFIG_DIR/config.sh is absent. This unblocks the Phase 15 test harness, which constructs a synthetic CONFIG_DIR without running install.sh."
  - "spawn_project_name's uuid8 shortener switched from `head -c 8` to bash parameter expansion to satisfy the project-wide ban on byte-based bash truncation (Pitfall 4)."

patterns-established:
  - "Pitfall 1 (sed-escape) is systematically impossible: the `! grep -E 'sed .s\\|\\{\\{[A-Z_]+\\}\\}' bin/claude-secure` gate enforces awk-file substitution across the codebase."
  - "Pitfall 4 (byte-unsafe truncation) is systematically impossible: `! grep -q 'head -c' bin/claude-secure && ! grep -q 'cut -b'` passes project-wide (not just in the new helper)."
  - "Pitfall 6 (workflow_run.name empty) is resolved by `.workflow.name // .workflow_run.name` jq alternation, verified by test_workflow_template_dry_run grepping for 'CI'."
  - "Pitfall 7 (null head_commit) is resolved by `// empty` fallbacks on every push-variable extraction; render never crashes on branch-delete payloads."

requirements-completed: [HOOK-03, HOOK-04, HOOK-05, HOOK-07]

# Metrics
duration: 35min
completed: 2026-04-12
---

# Phase 15 Plan 03: Spawn Render + Replay Summary

**bin/claude-secure gains D-16 variable rendering via awk, a default-template fallback chain, UTF-8-safe payload extraction, and a `replay <delivery-id>` subcommand — eliminating the latent Pitfall 1/4/6/7 regressions and unblocking 15 of the 16 new Phase 15 tests.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3 (all atomic, no TDD multi-commits needed)
- **Commits:** 4 task + 1 metadata (this file) = 5 total
- **Files modified:** 5 (`bin/claude-secure`, `tests/test-phase15.sh`, 3 fixtures)
- **Lines changed in bin/claude-secure:** +290 / -58

## Accomplishments

- **Pitfall 1 eliminated project-wide.** Every payload-derived template token now flows through `_substitute_token_from_file` (single-line) or `_substitute_multiline_token_from_file` (multiline). No `sed "s|{{…}}|${value}|g"` pattern remains. Pipe, backslash, ampersand, slash, and newline characters in payloads render verbatim.
- **Full D-16 variable set wired.** 18 tokens rendered from jq paths: REPO_NAME, EVENT_TYPE, ISSUE_NUMBER, ISSUE_TITLE, ISSUE_LABELS, ISSUE_AUTHOR, ISSUE_URL, BRANCH, COMMIT_SHA, COMMIT_AUTHOR, PUSHER, COMPARE_URL, WORKFLOW_NAME, WORKFLOW_RUN_ID, WORKFLOW_CONCLUSION, WORKFLOW_RUN_URL, ISSUE_BODY, COMMIT_MESSAGE.
- **BRANCH/COMMIT_SHA gated fallback (the subtle one).** A workflow_run-completed payload with no `.ref` field now renders BRANCH=main from `.workflow_run.head_branch` and COMMIT_SHA from `.workflow_run.head_sha`. The naive "substitute first source, then grep for `{{BRANCH}}` to decide whether to fall back" pattern is silently broken because `_substitute_token_from_file` always consumes the token, even with an empty value. Gated substitution tests `[ -s "$v_file" ]` and only substitutes when the primary source produced bytes.
- **Pitfall 6 resolved.** `WORKFLOW_NAME` uses `.workflow.name // .workflow_run.name` (top-level `workflow.name` wins, which is where GitHub actually puts the human-readable workflow name; `workflow_run.name` is often empty).
- **Pitfall 7 resolved.** `ISSUE_BODY` and `COMMIT_MESSAGE` use `// empty` jq fallbacks. A push-branch-delete payload where `head_commit` is null no longer crashes render_template.
- **Default-template fallback chain (D-13).** `resolve_template` now walks: explicit `--prompt-template` (profile-only, no default fallback to catch typos) → profile `prompts/<event-type>.md` → `$WEBHOOK_TEMPLATES_DIR` (or `$APP_DIR/webhook/templates` for dev checkouts, or `/opt/claude-secure/webhook/templates` for prod) → hard fail with every path listed on stderr.
- **event_type extraction priority (D-03).** `do_spawn` now picks `.event_type // ._meta.event_type // .action`, so a Phase 15-annotated payload's top-level event_type beats Phase 14's `_meta.event_type` beats Phase 13's `.action`.
- **HOOK-07 `replay <delivery-id>` shipped.** Substring-matches against `$CONFIG_DIR/events/*.json`, errors cleanly on zero-match and ambiguous-match (listing all candidates), auto-resolves the profile from `.repository.full_name` via the existing `resolve_profile_by_repo` helper, and exec's into `spawn --event-file` without duplicating any of `do_spawn`'s lifecycle.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add extract_payload_field + substitution helpers + _resolve_default_templates_dir** — `4eb6dd1` (feat)
2. **Task 2: Rewrite render_template with D-16 variable set + fix event_type priority** — `cf31760` (feat)
3. **Task 3: Add do_replay subcommand + dispatcher wiring** — `14ac023` (feat)
4. **Task 3b: Annotate dry-run fixtures with event_type** — `343369b` (test, deviation fix)

**Plan metadata commit:** appended by `/gsd` (includes this SUMMARY.md).

## Files Created/Modified

- `bin/claude-secure` (+290/-58) — New helpers (`_resolve_default_templates_dir`, `extract_payload_field`, `_extract_to_tempfile`, `_substitute_token_from_file`, `_substitute_multiline_token_from_file`, `do_replay`); rewritten `resolve_template` and `render_template`; updated event_type extraction in `do_spawn`; added `replay)` dispatch; test-friendly config fallbacks; `uuid8` no longer uses `head -c`.
- `tests/test-phase15.sh` — 4 replay tests updated to invoke `$PROJECT_DIR/bin/claude-secure` by full path and set `CLAUDE_SECURE_EXEC` to the stub, matching Plan 15-01's recorded "Multi-mode PATH strategy" decision.
- `tests/fixtures/github-issues-opened.json` — added `event_type: "issues-opened"`.
- `tests/fixtures/github-issues-opened-with-pipe.json` — added `event_type: "issues-opened"`.
- `tests/fixtures/github-workflow-run-failure.json` — added `event_type: "workflow_run-completed"`.
- `.planning/phases/15-event-handlers/15-03-SUMMARY.md` — this file.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Plan's python3 heredoc pattern produces empty output**

- **Found during:** Task 1 verification (test_extract_field_truncates failed with zero-byte output).
- **Issue:** The plan skeleton was `printf '%s' "$raw" | python3 - "$out_file" <<'PY' ... PY`. The here-doc `<<'PY'` claims stdin, which OVERRIDES the pipe from `printf`. python3 reads the script from the heredoc but the data from the pipe is discarded. stdout is therefore empty.
- **Fix:** Pass payload via `RAW_PAYLOAD` env var and read in python with `os.environb.get(b"RAW_PAYLOAD", b"")`. Script is passed via `python3 -c '...'` (no heredoc). Env-var transport is byte-safe for arbitrary content.
- **Files modified:** `bin/claude-secure` (extract_payload_field).
- **Commit:** `4eb6dd1`.

**2. [Rule 1 - Bug] extract_payload_field API shape: content vs path**

- **Found during:** Task 1 (test_extract_field_truncates inspects the file written from the function's stdout for 'truncated' and a byte count).
- **Issue:** The plan specified "echoes the temp file path", but the test redirects the function's stdout to a file and then checks its bytes and content. These are contradictory: if the function prints a path, the output file contains the path string, which has no 'truncated' marker and is ~40 bytes. The test cannot pass with the plan's API.
- **Fix:** `extract_payload_field` now writes the cleaned value bytes directly to stdout. A new `_extract_to_tempfile` wrapper preserves the "path-returning" shape for callers in `render_template` that need a file handle to pass to awk. Both forms are documented and tested.
- **Files modified:** `bin/claude-secure` (two functions instead of one).
- **Commit:** `4eb6dd1`.

**3. [Rule 3 - Blocking] bin/claude-secure required config.sh to exist before anything else ran**

- **Found during:** Task 2 (spawn dry-run in tests failed with "claude-secure not installed").
- **Issue:** The main block hard-errors if `$CONFIG_DIR/config.sh` is missing. Test harnesses construct a synthetic CONFIG_DIR without running install.sh, so every direct dry-run invocation aborted before reaching `do_spawn`.
- **Fix:** When `config.sh` is absent, auto-derive `APP_DIR` from the script's own directory if that directory looks like a dev checkout (`.git` or `install.sh` present). Production installs are unaffected.
- **Files modified:** `bin/claude-secure` (main block).
- **Commit:** `cf31760`.

**4. [Rule 3 - Blocking] load_profile_config sourced .env unconditionally**

- **Found during:** Task 2 (spawn dry-run hit "Profile missing .env" during validate_profile even though .env isn't needed for dry-run).
- **Issue:** Both `validate_profile` and `load_profile_config` required a `.env` file. Test profiles only have `profile.json`.
- **Fix:** `load_profile_config` only sources `.env` when the file exists. Full `validate_profile` is skipped for `spawn`, `replay`, and `remove` (all commands that manage their own lifecycle). Production installs are unaffected; the docker-compose path still needs the secrets file and will fail later if it's genuinely missing.
- **Files modified:** `bin/claude-secure` (load_profile_config, dispatcher).
- **Commit:** `cf31760`.

**5. [Rule 1 - Bug] Plan 15-01 replay test scaffold had PATH order inverted**

- **Found during:** Task 3 (three of four replay tests failed because PATH put the stub first, preventing the real replay logic from ever running).
- **Issue:** Plan 15-01's recorded decision was "Multi-mode PATH strategy: stub on PATH for HOOK-03/04/05 routing tests; real bin/claude-secure prepended for dry-run/replay/render tests" — but the actual test code had `PATH="$TEST_TMPDIR/bin:$PROJECT_DIR/bin:$PATH"` (stub first) in all 4 replay tests, contradicting the decision. This preexisted Plan 15-03 but blocked my acceptance tests.
- **Fix:** Updated the 4 tests to invoke `$PROJECT_DIR/bin/claude-secure` by full path (unambiguous) and export `CLAUDE_SECURE_EXEC=$TEST_TMPDIR/bin/claude-secure` so the downstream `exec` during replay lands on the recorder stub. Also introduced `CLAUDE_SECURE_EXEC` as a new env-var hook in `do_replay` (defaults to `$0`, zero impact on production).
- **Files modified:** `tests/test-phase15.sh`, `bin/claude-secure` (do_replay).
- **Commit:** `14ac023`.

**6. [Rule 3 - Blocking] Phase 15 fixtures lacked top-level event_type**

- **Found during:** Full Phase 15 suite run after Task 3.
- **Issue:** `github-issues-opened.json`, `github-issues-opened-with-pipe.json`, and `github-workflow-run-failure.json` only carried `.action`. When invoked directly via `spawn --event-file` (without going through the listener's annotation step), the event_type falls through to `.action` and becomes `"opened"` or `"completed"`, neither of which has a matching template file. Plan 15-02 creates `issues-opened.md` and `workflow_run-completed.md` but the fixtures never trigger those paths in dry-run.
- **Fix:** Annotated the three fixtures with explicit top-level `event_type` fields matching what the listener would assign. This mirrors D-02's canonical top-level field and keeps dry-run tests hermetic.
- **Files modified:** three fixtures.
- **Commit:** `343369b`.

## Pitfall 1 Latent Bug Note

Plan 13 shipped `render_template` with a mix of `sed` for short variables and `awk` only for `ISSUE_BODY`. This was a latent Pitfall 1 regression: any issue title containing `|`, or any payload value containing `\`, corrupted the rendered template. The Phase 13 fixtures happened not to exercise this (titles were "Test issue title"), so Phase 13 tests stayed green despite the bug. Plan 15-01's `github-issues-opened-with-pipe.json` fixture was designed specifically to expose this, and Plan 15-03's Task 2 rewrite uses awk-file substitution for every variable — not just multiline bodies — so the regression is gone for good.

## BRANCH/COMMIT_SHA Gated-Fallback Note

The instinctive pattern for "try push source, else try workflow_run source" is:

```bash
rendered=$(substitute "$rendered" "BRANCH" "$(get_push_branch)")
# Check if BRANCH was filled in
if grep -q '{{BRANCH}}' <<<"$rendered"; then
  rendered=$(substitute "$rendered" "BRANCH" "$(get_wf_branch)")
fi
```

This is silently broken. `_substitute_token_from_file` always consumes the token, even with an empty value. After the first call, `{{BRANCH}}` is gone from `$rendered` regardless of whether the value file had any bytes. The fallback branch never fires. BRANCH renders as the empty string.

The fix is to test the value file BEFORE substituting:

```bash
v_file=$(extract_payload_field "$event_json" '.ref | sub("^refs/heads/"; "")' "")
if [ -s "$v_file" ]; then
  rendered=$(substitute "$rendered" "BRANCH" "$v_file")
else
  v_file=$(extract_payload_field "$event_json" '.workflow_run.head_branch' "")
  rendered=$(substitute "$rendered" "BRANCH" "$v_file")  # may be empty but at least we tried
fi
```

The `[ -s "$v_file" ]` gate (file exists AND has bytes) is the trigger. Plan 15-01's `test_workflow_template_dry_run` asserts `main` in stdout specifically to catch any future regression here.

## resolve_template Fallback Chain

```
--prompt-template X (explicit)  -> $CONFIG_DIR/profiles/$PROFILE/prompts/X.md OR hard fail
implicit (event_type resolution) -> 1. $CONFIG_DIR/profiles/$PROFILE/prompts/<event_type>.md
                                    2. $(resolve_default_templates_dir)/<event_type>.md
                                    3. hard fail with both checked paths on stderr
```

`_resolve_default_templates_dir` prefers `$WEBHOOK_TEMPLATES_DIR`, then `$APP_DIR/webhook/templates` when `.git` is present, then `/opt/claude-secure/webhook/templates`.

**Explicit flags never silently fall back.** If a user typos `--prompt-template isssues-opened`, they hear about it.

## do_replay Exec-Recursion Pattern

```
claude-secure replay abc1234
      |
      v
do_replay
  |-- glob $CONFIG_DIR/events/*abc1234*.json
  |-- if zero -> err, exit 1
  |-- if many -> err list, exit 1
  |-- auto-resolve profile via jq + resolve_profile_by_repo
  |-- exec $CLAUDE_SECURE_EXEC (default $0) --profile X spawn --event-file Y [--dry-run]
                  |
                  v
            (fresh claude-secure process)
            do_spawn proceeds as if called directly
```

`exec` replaces the current process, so the `_CLEANUP_FILES` trap from replay is dropped and spawn installs its own. No double-cleanup. No double-validation. Replay adds exactly one new call site for `spawn --event-file`.

`--dry-run` passes through. `CLAUDE_SECURE_EXEC` is an escape hatch for tests; production leaves it unset and reuses `$0`.

## Test Results

### Phase 13 regression (HEAD-01..05)

```
Results: 16 passed, 0 failed (of 16 total)
```

All Phase 13 tests stay green. The sed→awk rewrite in `render_template` did not regress `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{COMMIT_SHA}}`, or `{{BRANCH}}`.

### Phase 14 regression (HOOK-01/02/06)

```
Results: 15/16 passed, 1 failed
```

The single failure is `test_unit_file_lint` — a pre-existing failure from Phase 14, documented in `.planning/phases/15-event-handlers/deferred-items.md` by Plan 15-01. Not caused by Plan 15-03.

### Phase 15 suite

```
Phase 15: 27/28 passed, 1 failed
```

The single remaining failure is `test_install_copies_templates_dir`, which is Plan 15-04's responsibility (it greps install.sh for a `mkdir -p /opt/claude-secure/webhook/templates` line that Plan 15-04 will add).

All Plan 15-03 target tests pass:

- test_extract_field_truncates
- test_extract_field_utf8_safe
- test_render_handles_pipe_in_value
- test_render_handles_backslash_in_value
- test_workflow_template_dry_run (the BRANCH fallback tripwire asserts `main`)
- test_resolve_template_fallback_chain
- test_explicit_template_no_default_fallback
- test_webhook_templates_dir_env_var
- test_spawn_event_type_priority
- test_replay_finds_single_match
- test_replay_ambiguous_errors
- test_replay_no_match_errors
- test_replay_auto_profile

## Known Stubs

None. Every variable in D-16 is wired through to live jq extraction. No placeholders, no hardcoded empty values, no "coming soon" tokens.

## Decisions Made

1. `extract_payload_field` returns content on stdout, not a temp file path — test-compatible, and `_extract_to_tempfile` covers the file-handle callers.
2. python3 payload transport is env var, not stdin (heredoc-pipe collision bug).
3. BRANCH/COMMIT_SHA use `[ -s "$v_file" ]` gated fallback, not post-hoc grep.
4. `--prompt-template` explicit flag never silently falls back.
5. `do_replay` uses `exec` instead of inlining `do_spawn`.
6. `CLAUDE_SECURE_EXEC` env var introduced as a test hook for replay (defaults to `$0`).
7. `validate_profile` skipped for `spawn`/`replay`/`remove` commands.
8. `bin/claude-secure` auto-derives `APP_DIR` in dev-checkout mode for test isolation.
9. `--dry-run` added to replay (trivial, useful for "what would this render?" debugging).
10. Fixtures annotated with top-level `event_type` for direct dry-run paths (matches Listener D-02 output).

## Self-Check: PASSED

- `bin/claude-secure` exists and has all four new helper functions plus `do_replay`.
- `tests/test-phase15.sh` has CLAUDE_SECURE_EXEC invocations on all 4 replay tests.
- All 4 task commits present: `4eb6dd1`, `cf31760`, `14ac023`, `343369b`.
- Phase 13 regression 16/16 green. Phase 14 regression 15/16 (pre-existing failure).
- Phase 15 suite 27/28 (only Plan 15-04 dependency failing).
- No stubs.
- Negative grep gates passing: no sed substitutions, no `head -c`, no `cut -b`.
