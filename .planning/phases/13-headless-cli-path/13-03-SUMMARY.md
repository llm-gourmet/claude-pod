---
phase: 13-headless-cli-path
plan: 03
subsystem: cli
tags: [bash, jq, awk, template-engine, prompt-templates]

# Dependency graph
requires:
  - phase: 13-01
    provides: spawn subcommand skeleton with arg parsing
  - phase: 13-02
    provides: do_spawn() with placeholder prompt and output envelope
provides:
  - resolve_template() finds prompt templates by event-type or explicit flag
  - render_template() substitutes 6 standard variables from event JSON
  - Multiline-safe ISSUE_BODY handling via awk
affects: [14-webhook-listener, 15-event-handlers]

# Tech tracking
tech-stack:
  added: []
  patterns: [awk-based multiline substitution, jq empty-coalesce for optional fields]

key-files:
  created: []
  modified: [bin/claude-secure]

key-decisions:
  - "resolve_template uses PROFILE+CONFIG_DIR globals (matches test contract from Plan 01)"
  - "ISSUE_BODY uses awk for multiline safety instead of sed (per research Pitfall 1)"
  - "sed uses | delimiter to handle / in repo names"

patterns-established:
  - "Template resolution: explicit flag > event-type derived name"
  - "Variable extraction: jq -r '.field // empty' for safe empty-string fallback"

requirements-completed: [HEAD-05]

# Metrics
duration: 1min
completed: 2026-04-11
---

# Phase 13 Plan 03: Prompt Template System Summary

**resolve_template + render_template functions with 6-variable substitution from event JSON, multiline ISSUE_BODY via awk, wired into spawn flow**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-11T22:07:33Z
- **Completed:** 2026-04-11T22:08:22Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

### Task 1: Implement resolve_template and render_template functions

Added two functions to `bin/claude-secure` and wired them into `do_spawn()`:

- `resolve_template(event_type, explicit_template)` - finds template file in `$CONFIG_DIR/profiles/$PROFILE/prompts/` directory. Prefers explicit `--prompt-template` flag over event-type derived name. Produces clear error messages for missing templates or missing prompts directory.
- `render_template(template_path, event_json)` - extracts 6 standard variables (REPO_NAME, EVENT_TYPE, ISSUE_TITLE, ISSUE_BODY, COMMIT_SHA, BRANCH) from event JSON via jq and substitutes `{{VAR}}` placeholders. Uses awk for multiline ISSUE_BODY substitution. Missing variables are replaced with empty string.

**Commit:** f078a5a

## Verification

All 16 tests pass including all HEAD-05 template tests:
- HEAD-05a: resolve_template finds template by event type
- HEAD-05b: resolve_template uses explicit override
- HEAD-05c: resolve_template fails for missing template
- HEAD-05d: render_template substitutes variables from event JSON
- HEAD-05e: render_template replaces missing vars with empty string

## Deviations from Plan

### Adjusted function signature (Rule 3 - Blocking Issue)

**Found during:** Task 1
**Issue:** Plan specified `resolve_template(profile_dir, event_type, explicit_template)` with 3 args, but existing tests from Plan 01 call `resolve_template("event_type", "explicit")` with 2 args using CONFIG_DIR/PROFILE globals.
**Fix:** Matched the test contract -- function uses globals instead of explicit profile_dir parameter.
**Files modified:** bin/claude-secure

## Known Stubs

None.

## Self-Check: PASSED
