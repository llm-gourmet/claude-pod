---
phase: 16
plan: 04
subsystem: install.sh + README.md
tags: [wave-2, ops-01, installer, docs, operator-onboarding]
requires:
  - Phase 16 Plan 01 default report templates (webhook/report-templates/*.md)
  - Phase 16 Plan 02 resolve_report_template fallback chain (D-08)
  - Phase 16 Plan 03 do_spawn publish_report + write_audit_entry integration
  - Phase 15 install.sh step 5b (template copy pattern being mirrored)
provides:
  - install.sh step 5c — copies webhook/report-templates/*.md to /opt/claude-secure/webhook/report-templates/ on every install
  - README "Phase 16 — Result Channel" operator section (one-time setup, audit log, template customization, --skip-report, security notes)
  - test_installer_ships_report_templates static invariant
  - test_readme_documents_phase16 static invariant
affects:
  - install.sh (15-line step 5c insertion between step 5b and step 6)
  - README.md (101-line Phase 16 section between Logging and Testing)
  - tests/test-phase16.sh (2 new static invariant tests; 31 → 33 total)
tech-stack:
  added: []
  patterns:
    - D-12 always-refresh installer pattern: cp individual files (never rm -rf) so operator-added custom templates survive reinstall
    - Step-5b clone with templates → report-templates substitution and explicit dir chmod 755 (umask-independence)
    - Static-grep invariant tests for installer + docs (no runtime fixtures needed)
key-files:
  created:
    - .planning/phases/16-result-channel/16-04-SUMMARY.md
  modified:
    - install.sh
    - README.md
    - tests/test-phase16.sh
decisions:
  - Skipped optional `test_install_report_templates` sandboxed-DESTDIR harness — chose static grep invariant instead. Rationale: install.sh writes to /opt unconditionally and DESTDIR re-architecture is out of scope; the static greps cover the four `must_haves.truths` items (path present ≥3x, # 5c marker, no rm -rf, log line) without requiring sudo or tmpfs scaffolding.
  - Added `chmod 755` on the report-templates directory in addition to file `chmod 644`. Step 5b only sets file mode; step 5c sets both because a fresh `mkdir -p` under sudo can produce umask-dependent directory permissions on some hosts.
  - README inserted between "Logging" and "Testing" rather than between "Phase 15" and "Security" — there is no existing "Phase 15" or "Headless" section; Logging is the closest operator-facing observability anchor.
  - Wrote "No force-push, ever." (lowercase form) to satisfy the Plan 04 acceptance criterion `grep -c 'force-push\|force push' README.md >= 1` literally; the original "Force-push is never used." prose was case-mismatched.
metrics:
  duration: ~12m
  completed: 2026-04-12
---

# Phase 16 Plan 04: Wave 2 Installer Extension + Operator Docs Summary

Wired the Phase 16 default report templates into `install.sh` so a clean host receives them at `/opt/claude-secure/webhook/report-templates/` on every (re)install, then documented the full operator onboarding flow (PAT, profile `.env`, audit log, template customization, security guarantees) in `README.md`. Closes the OPS-01 ship-loop: a fresh host now needs only `sudo bash install.sh` plus the documented profile.json + .env edits to start producing pushed report commits.

## Tasks Completed

### Task 1: install.sh step 5c — copy report templates to /opt
- **Commit:** 98e47a0
- **Files:** install.sh (lines 358-371, 15 inserted lines)
- **Pattern:** Structural clone of step 5b (lines 348-356) with `templates → report-templates` substitution and an explicit `chmod 755` on the directory (umask-independence on fresh `mkdir -p` under sudo).
- **D-12 always-refresh:** `sudo cp ... *.md` overwrites individual files but never `rm -rf`s the directory, so any operator-added templates (e.g. `pull_request-opened.md` or local profile-style overrides dropped in `/opt`) survive reinstalls.
- **Graceful skip:** if `$app_dir/webhook/report-templates` is missing in the source checkout (older bisect/rollback states), the step logs a warning and continues — exactly mirroring the step 5b behavior.
- **Verification:** `bash -n install.sh` passes; the path `/opt/claude-secure/webhook/report-templates` appears 5× in the script (mkdir, cp source, cp dest, dir chmod, file chmod, log line); `# 5c` marker present once; no `rm -rf` against report-templates anywhere; line order is `5 → 5b → 5c → 6` as required.

### Task 2: README "Phase 16 — Result Channel" operator section
- **Commit:** 202e9a7
- **Files:** README.md (lines 235-335, 101 inserted lines, ~913 words)
- **Sections:**
  1. **One-time setup: documentation repo + PAT** — repo init checklist, fine-grained PAT scope (`contents: write` on report repo only), profile `.env` placement, profile.json field configuration with copy-pasteable jq one-liner.
  2. **Audit log** — file path with multi-instance LOG_PREFIX note, mandatory key list, three jq filter recipes (tail successes, find push failures, total cost per profile), enumeration of the four `status` enum values.
  3. **Customizing report templates** — full D-08 fallback chain documented as natural prose (no decision IDs leaked), description of the always-refresh installer pattern, complete variable list including Phase 16 extensions (`RESULT_TEXT`, `ERROR_MESSAGE`, `COST_USD`, `DURATION_MS`, `SESSION_ID`, `TIMESTAMP`, `STATUS`).
  4. **Skipping publish (local-only runs)** — `--skip-report` flag + `CLAUDE_SECURE_SKIP_REPORT=1` env var with two example invocations.
  5. **Security notes** — `GIT_ASKPASS` PAT delivery (never argv/URL/history), profile `.env` value redaction with `<REDACTED:KEY>` markers, no force-push guarantee with rebase-once retry policy, 16KB UTF-8-safe result truncation, POSIX O_APPEND atomicity invariant for the per-instance audit file.
- **Placement:** Between the existing "Logging" section and "Testing" section — operator observability anchor.
- **Style hygiene:** Zero raw decision IDs in user-facing prose (`grep -cE 'D-[0-9]{2}' README.md` returns 0). No existing sections were rewritten or reordered (diff is pure insertion).
- **Counts (acceptance criteria):** Phase 16=2, REPORT_REPO_TOKEN=2, executions.jsonl=5, report_repo=3, skip-report=2, CLAUDE_SECURE_SKIP_REPORT=2, GIT_ASKPASS=1, force-push=1, contents: write=1, REDACTED=2.

## Test Results

- **Phase 16:** 33/33 PASS (was 31; added `test_installer_ships_report_templates` and `test_readme_documents_phase16` static invariants)
- **Phase 13:** 16/16 PASS (no regression)
- **Phase 14:** 15/16 PASS — pre-existing `test_unit_file_parses` failure documented in `.planning/phases/16-result-channel/deferred-items.md` from 16-02 sweep, not caused by Phase 16
- **Phase 15:** 28/28 PASS (no regression)

The two new Phase 16 static invariants follow the Wave 0 → Wave 2 Nyquist pattern: each was committed in a RED state first (test commit precedes implementation commit) and flipped GREEN by the implementation commit immediately following.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Critical correctness] Added explicit `chmod 755` on the report-templates directory**
- **Found during:** Task 1
- **Issue:** Plan body shows `sudo chmod 644 /opt/claude-secure/webhook/report-templates/*.md` (file mode only). On hosts with restrictive umask (e.g. `077`) a fresh `sudo mkdir -p` can produce a 700 directory, blocking `resolve_report_template` from reading the templates as the unprivileged claude user.
- **Fix:** Added `sudo chmod 755 /opt/claude-secure/webhook/report-templates` immediately after the file chmod, matching the plan's `must_haves.truths` "Directory mode 755, file mode 644" requirement.
- **Files modified:** install.sh
- **Commit:** 98e47a0

**2. [Rule 1 - Spec/criterion mismatch] README "force-push" lowercase form**
- **Found during:** Task 2 verification
- **Issue:** Initial draft said "Force-push is never used." (capital F). The plan acceptance criterion is `grep -c 'force-push\|force push' README.md >= 1` (case-sensitive lowercase). Even though the test_readme_documents_phase16 grep used `-i`, the explicit acceptance criterion was unmet.
- **Fix:** Reworded to "No force-push, ever. Force-push is never used by the report publisher."
- **Files modified:** README.md
- **Commit:** 202e9a7 (single combined commit)

### Choice deviations (not auto-fixed, documented for traceability)

**1. Static-grep invariant instead of sandboxed `$DESTDIR` install harness**
- **Plan note:** "Phase 16 test `test_install_report_templates` (if added in this task) flips GREEN using a sandboxed `$DESTDIR` harness"
- **Choice:** Added `test_installer_ships_report_templates` as a static grep invariant on install.sh source instead.
- **Rationale:** install.sh hardcodes `/opt/claude-secure` paths via `sudo` — a `$DESTDIR` re-architecture would touch >12 step blocks and is well outside Wave 2 scope. The plan said "if added", and the static grep covers all four `must_haves.truths` items the plan explicitly requires (path ≥3×, `# 5c` marker, no `rm -rf`, log line). Manual end-to-end smoke remains the path for the production-mode acceptance.

## Authentication Gates

None.

## Files Created/Modified

**Modified:**
- `install.sh` — +15 lines (step 5c block at lines 358-371)
- `README.md` — +101 lines (Phase 16 section at lines 235-335)
- `tests/test-phase16.sh` — +93 lines (2 new test functions + 2 main() registrations)

**Created:**
- `.planning/phases/16-result-channel/16-04-SUMMARY.md`

## Commits

- 51d1793 — `test(16-04): add failing test for installer report-templates step 5c` (RED for Task 1)
- 98e47a0 — `feat(16-04): add install.sh step 5c for report templates` (GREEN for Task 1)
- 33dd43b — `test(16-04): add failing test for README Phase 16 operator docs` (RED for Task 2)
- 202e9a7 — `docs(16-04): add README Phase 16 Result Channel operator docs` (GREEN for Task 2)

## OPS-01 / OPS-02 Shipping Status

With Plan 16-04 complete, OPS-01 (report push) and OPS-02 (audit log) are end-to-end shippable on a clean host. The minimum onboarding is now:

1. `sudo bash install.sh` (places templates and listener at `/opt/claude-secure/`)
2. Create a GitHub doc repo + PAT with `contents: write`
3. Add `REPORT_REPO_TOKEN=...` to `~/.claude-secure/profiles/<name>/.env`
4. Set `report_repo` / `report_branch` / `report_path_prefix` in profile.json
5. Trigger a webhook (or run `claude-secure replay`) — the spawn produces a report commit and an audit line

Phase 16 is complete: all four plans (16-01 templates, 16-02 resolver, 16-03 publish/audit integration, 16-04 installer/docs) green; all 33 Phase 16 tests pass; zero new regressions in earlier phases.

## Self-Check: PASSED

- install.sh:358-371 (step 5c block) — verified present via grep
- README.md:235-335 (Phase 16 section) — verified present via grep
- tests/test-phase16.sh — `test_installer_ships_report_templates` + `test_readme_documents_phase16` registered in main() and pass
- Commit hashes 51d1793, 98e47a0, 33dd43b, 202e9a7 — verified via `git log --oneline -10`
- Phase 16: 33/33 PASS, Phase 13: 16/16 PASS, Phase 15: 28/28 PASS, Phase 14: 15/16 PASS (pre-existing deferred failure)
