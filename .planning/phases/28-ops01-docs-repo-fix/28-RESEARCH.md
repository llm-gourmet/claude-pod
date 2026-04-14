# Phase 28: OPS-01 docs_repo Backfill Fix - Research

**Researched:** 2026-04-14
**Domain:** Bash shell script — surgical bug fix in `bin/claude-secure` `do_spawn` function
**Confidence:** HIGH

## Summary

This is a one-line (semantically one-hunk) bug fix phase. The defect is precisely localized at `bin/claude-secure:2077-2081` inside `do_spawn`: three `jq` reads unconditionally re-read `.report_repo`, `.report_branch`, and `.report_path_prefix` from `profile.json`, silently overwriting the `REPORT_REPO` / `REPORT_BRANCH` / `REPORT_PATH_PREFIX` environment variables that Phase 23's `resolve_docs_alias` already back-filled from the new canonical `docs_*` fields. For profiles migrated to the Phase 23 schema (which have `docs_repo` but no `report_repo`), the result is `REPORT_REPO=""`, which makes `publish_report` short-circuit with `return 2` and silently skip report publishing.

The fix is mechanical: change the `jq` fallback chain to `.report_repo // .docs_repo // empty` for the URL, `.report_branch // .docs_branch // "main"` for the branch, and leave `report_path_prefix` as-is (there is no Phase 23 alias for the prefix). The risk surface is tiny — the function is already well-tested by `test-phase16.sh` (33 tests) and `test-phase23.sh`, and a new regression test must be added to a test suite before the fix lands (Wave 0 / Nyquist RED-GREEN gate) so the bug is captured and prevented from re-appearing.

**Primary recommendation:** Single-plan phase. Wave 0 adds a failing regression test to `tests/test-phase23.sh` that asserts a Phase 23-style profile (`docs_repo` only) successfully publishes a report through `run_spawn_integration` (or equivalent). Wave 1 patches the three `jq` expressions in `do_spawn` to the `.new // .legacy // default` pattern. Phase closes when both the new test and the existing Phase 16 `test_no_report_repo_skips_push` pass.

<user_constraints>
## User Constraints (from CONTEXT.md)

CONTEXT.md does not exist for this phase — no `/gsd:discuss-phase` was run. The only upstream constraint is the audit finding in `.planning/v2.0-MILESTONE-AUDIT.md`:

> **Priority: Medium (Forward Compatibility)**
> OPS-01 docs_repo backfill bypass — `do_spawn:2077` uses `.report_repo // empty` only; profiles migrated to Phase 23's `docs_repo` canonical field will have `REPORT_REPO` overwritten to empty, causing silent report skip. Affects Phase 23+ profiles only. Fix: `jq -r '.report_repo // .docs_repo // empty'`

### Locked Decisions
None — no discussion phase. The audit prescribes the fix precisely.

### Claude's Discretion
- Whether to also patch `report_branch` (Phase 23 has `docs_branch` alias) and `report_path_prefix` (no Phase 23 alias — cosmetic only) in the same hunk.
- Whether the regression test lives in `test-phase23.sh` (v4.0 schema side) or `test-phase16.sh` (publish_report side) or a new slim suite.
- Whether to also add a small static/lint guard (e.g., a comment + grep check in the test) so future refactors don't re-introduce the clobber.

### Deferred Ideas (OUT OF SCOPE)
- Removing the legacy `report_repo` field entirely — tracked in `.planning/todos/pending/2026-04-14-remove-legacy-report-repo-token-support.md`.
- Moving all the report env exports out of `do_spawn` into `load_profile_config` (architectural cleanup) — this phase is a point fix, not a refactor.
- Fixing other v2.0 audit gaps (missing VERIFICATION.md files, stale VALIDATION.md) — those are Phase 27.
- `create_profile` UX prompt for `.repo` — that is Phase 29.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| OPS-01 | After execution, a structured markdown report is written and pushed to a separate documentation repo | The code at `bin/claude-secure:1349` (`publish_report`) already implements OPS-01 for profiles using the legacy `report_repo` field. Phase 28 must restore this guarantee for profiles migrated to the Phase 23 canonical `docs_repo` field, by making `do_spawn` honor the back-fill that `resolve_docs_alias` already performs. No new implementation — a defect fix that restores forward-compat for the already-satisfied requirement. |

**Forward-compat framing:** OPS-01 is already `[x]` in `REQUIREMENTS.md`. This phase does not add a new requirement — it closes a latent regression that would break OPS-01 for any user who follows the Phase 23 migration path. The requirement is "satisfied" for v2.0 profiles today; this phase ensures it stays satisfied across the v4.0 schema transition.
</phase_requirements>

## Project Constraints (from CLAUDE.md)

| Constraint | Relevance to Phase 28 |
|------------|------------------------|
| GSD workflow enforcement — use `/gsd:execute-phase` for planned work | This phase must go through the normal plan → execute → verify flow. |
| Must work on Linux (native) and WSL2 | `jq` and bash syntax used must be portable; `jq -r '.a // .b // empty'` is standard jq since 1.5. |
| Dependencies: Docker, jq, bash, curl, uuidgen available on host | All satisfied — the fix is pure bash/jq, no new dependencies. |
| Hook scripts, settings, and whitelist must be root-owned | Not relevant — this edits `bin/claude-secure`, which is the host-side wrapper (user-invoked), not an in-container hook. |
| No NFQUEUE / no kernel-module deps | Not relevant — no network-layer changes. |
| v2.0 Traceability: OPS-01 mapped to Phase 16 → Phase 28 (currently `Pending`) | After this phase completes, `REQUIREMENTS.md` line 96 should remain `[x]` and the traceability row should flip to `Complete`. |

The fix must not regress any existing Phase 16 test (`test_no_report_repo_skips_push`, the D-12 report URL format test, Pitfall 3 secret-scrub test) and must not regress any Phase 23 test (`test_legacy_report_repo_alias`, `test_docs_env_projection`).

## Bug Localization (HIGH confidence — direct code read)

### The offending hunk

`bin/claude-secure:2072-2081`:

```bash
  # Phase 16 / D-12: read report_repo fields from profile.json and export as env vars
  # so publish_report can consume them via REPORT_REPO / REPORT_BRANCH / REPORT_PATH_PREFIX.
  # REPORT_REPO_TOKEN comes from profile.env (loaded earlier via load_profile_config).
  local _profile_json="$CONFIG_DIR/profiles/$PROFILE/profile.json"
  if [ -f "$_profile_json" ]; then
    REPORT_REPO=$(jq -r '.report_repo // empty' "$_profile_json")          # <-- clobbers
    REPORT_BRANCH=$(jq -r '.report_branch // "main"' "$_profile_json")      # <-- clobbers
    REPORT_PATH_PREFIX=$(jq -r '.report_path_prefix // "reports"' "$_profile_json")
    export REPORT_REPO REPORT_BRANCH REPORT_PATH_PREFIX
  fi
```

### Why the clobber silently breaks publishing

1. `main` dispatch calls `validate_profile` → `load_profile_config` → `resolve_docs_alias` **before** invoking `do_spawn`. This is already exercised by every spawn path.
2. `resolve_docs_alias` at `bin/claude-secure:232-294` reads `.docs_repo` (new) and `.report_repo` (legacy), picks the first non-empty, exports `DOCS_REPO`, and at lines 280-285 **already back-fills** `REPORT_REPO` / `REPORT_BRANCH` from `DOCS_REPO` / `DOCS_BRANCH` when the caller only set the new fields:
   ```bash
   if [ -z "${REPORT_REPO:-}" ] && [ -n "${DOCS_REPO:-}" ]; then
     REPORT_REPO="$DOCS_REPO"
   fi
   ```
3. Control returns to `do_spawn`. Line 2077 does a fresh `jq -r '.report_repo // empty'` read. For a Phase 23-migrated profile (no `.report_repo` key), this returns the empty string. The subsequent `export REPORT_REPO` writes empty into the env, clobbering the back-fill.
4. `publish_report` at `bin/claude-secure:1349-1363` reads `REPORT_REPO` from env and returns `2` when empty:
   ```bash
   local repo_url="${REPORT_REPO:-}"
   ...
   if [ -z "$repo_url" ] || [ -z "$pat" ]; then
     return 2
   fi
   ```
5. The Pattern E wrapper (`bin/claude-secure:2156-2200-ish`) treats `return 2` as "skip publish, audit status=success with empty report_url" (this behavior is intentional for the "no docs repo configured" case — see `test_no_report_repo_skips_push`). So the bug manifests as **silent** report skip, not a loud error.

### Why `REPORT_REPO_TOKEN` is unaffected

`REPORT_REPO_TOKEN` is a **secret**, so it is only ever sourced via `set -a; source .env; set +a` in `load_profile_config` at line 445, then back-filled by `resolve_docs_alias` lines 269-278. It is **never** re-read from `profile.json` (secrets don't live there). So the clobber only affects the three non-secret fields that `do_spawn:2077-2079` tries to re-read.

### Why `test_no_report_repo_skips_push` still passes today

That test installs a profile with `report_repo=""` (empty string) — it tests the opt-out path, not the Phase 23 migration path. It happens to cover the current buggy behavior without distinguishing it from the opt-out, which is exactly how the defect slipped past.

## Standard Stack

No new stack — this is an edit to an existing bash script using `jq`.

### Core (already in use)
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 4.x+ (re-exec guard in place) | `do_spawn` function | Already the wrapper's host language. |
| jq | 1.7+ | JSON field read from `profile.json` | `//` alternative operator is stable since jq 1.5; `.a // .b // empty` chain is idiomatic and used throughout `bin/claude-secure` (see `validate_docs_binding` at line 127 for the same pattern). |

### Supporting
None — the fix is pure jq/bash with no new libraries.

**Installation:** Nothing to install. Both `bash` and `jq` are hard dependencies enforced by `install.sh`.

**Version verification:** Not applicable — no new packages. The `jq -r '.a // .b // default'` syntax is verified working in existing code at `bin/claude-secure:127, 128` (Phase 23).

## Architecture Patterns

### Pattern: The `.new // .legacy // default` fallback (already in use)

**What:** When reading a field from `profile.json` that has both a canonical (Phase 23) and a legacy (Phase 16) name, use jq's `//` alternative operator to prefer the new name and fall back to the legacy name, then to a literal default.

**When to use:** Any time new code reads a field that has an alias. The `resolve_docs_alias` function at `bin/claude-secure:232-294` already does this for the exported-env path; `do_spawn:2077` is the one place that bypassed it.

**Example (already in the codebase, lines 127-129):**
```bash
repo=$(jq -r '.docs_repo // .report_repo // empty' "$pj")
branch=$(jq -r '.docs_branch // .report_branch // "main"' "$pj")
project_dir=$(jq -r '.docs_project_dir // empty' "$pj")
```

The fix for Phase 28 is to apply this same pattern to the three reads at 2077-2079:

```bash
REPORT_REPO=$(jq -r '.report_repo // .docs_repo // empty' "$_profile_json")
REPORT_BRANCH=$(jq -r '.report_branch // .docs_branch // "main"' "$_profile_json")
REPORT_PATH_PREFIX=$(jq -r '.report_path_prefix // "reports"' "$_profile_json")
```

Note the **ordering**: in `validate_docs_binding` at line 127, the new name (`docs_repo`) is listed first because validation prefers the canonical field. In `do_spawn:2077`, the existing code happens to list the legacy name first — either ordering is defensible because `//` skips empty strings, but **preferring the new name** (`.docs_repo // .report_repo`) is consistent with the rest of the Phase 23 code and gives a cleaner deprecation story. The audit's prescribed fix uses `.report_repo // .docs_repo`, which is also correct; the planner should decide and lock one ordering in PLAN.md.

### Alternative Pattern (rejected): Remove the re-read entirely

**What:** Delete lines 2072-2081 and rely on `resolve_docs_alias` (which already exports `REPORT_REPO`, `REPORT_BRANCH`, `REPORT_REPO_TOKEN`).

**Why rejected for this phase:** `resolve_docs_alias` does not back-fill `REPORT_PATH_PREFIX`, so deleting the block would break profiles that customize `report_path_prefix`. It would also be a larger refactor that changes Phase 23's responsibility, expanding blast radius beyond a defect fix. Keep the scope tight — patch the jq expressions, leave the block structure alone.

### Anti-Patterns to Avoid

- **Don't add `.docs_path_prefix` as a new Phase 23 field in this phase.** There is no such alias today; adding one would be scope creep and should be a Phase 29+ discussion if needed.
- **Don't move the export block into `resolve_docs_alias`.** That's a valid refactor but it's architectural, not a fix. Would require re-verifying every call site of `load_profile_config` and every test that depends on the current ordering. Out of scope.
- **Don't change the semantic of `publish_report` returning 2.** The silent-skip-on-empty behavior is intentional and tested (`test_no_report_repo_skips_push`). The fix is upstream — prevent the empty from being injected in the first place.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Alias resolution between new/legacy JSON fields | A bash `if [ -n "$new" ]; then ...; else ...; fi` cascade | `jq -r '.new // .legacy // default'` | Atomic, null-safe, handles empty strings via `//` in jq 1.6+, already used throughout the codebase. |
| Testing that a Phase 23 profile publishes reports | A new mock `publish_report` stub | Reuse `tests/test-phase16.sh::run_spawn_integration` and `tests/test-phase23.sh::_patch_docs_repo` + `setup_bare_repo` (bare file:// remote) | Both fixtures already exist, are in heavy use by Phase 16/23/24/25 tests, and cover the full spawn → audit pipeline without touching docker. |
| Fixture profile with new schema | A new ad-hoc profile JSON | Reuse or clone `tests/fixtures/profile-23-docs/profile.json` | Already the canonical "new schema only" fixture — `docs_repo`, `docs_branch`, `docs_project_dir`, no legacy keys. |

**Key insight:** This phase is mostly a test-writing exercise. The production code change is three jq expressions. The risk is entirely in (a) making sure the new test catches the bug before the fix lands, and (b) making sure the fix doesn't regress any of the 33 Phase 16 tests or the existing Phase 23 tests.

## Runtime State Inventory

> Included because this phase edits a hot-path function. Even though it's a defect fix, it touches an env-var export block that other call sites could conceivably depend on.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — no database, no persisted state. The fix only affects in-memory env var values during a single `claude-secure spawn` invocation. Verified by `grep -rn 'REPORT_REPO' bin/ tests/` showing only in-code reads/writes, no SQLite/filesystem persistence. | none |
| Live service config | None — neither the webhook listener (`webhook/listener.py`) nor the reaper reads `REPORT_REPO`. Verified: `Grep 'REPORT_REPO' webhook/` returns nothing. The env var is consumed only inside `bin/claude-secure` process-locally. | none |
| OS-registered state | None — no systemd unit, LaunchDaemon, or cron job references these variables. They are computed per-spawn. | none |
| Secrets/env vars | `REPORT_REPO_TOKEN` (the secret) is unaffected — it comes from the host `.env` sourcing path, not from `profile.json`, so it is never clobbered by the buggy block. This phase does **not** touch secret handling. Verified at `bin/claude-secure:442-447, 269-278`. | none — verify in plan that `REPORT_REPO_TOKEN` handling is unchanged |
| Build artifacts / installed packages | None — `bin/claude-secure` is a bash script sourced at runtime; no compiled artifacts, no installed packages to reinstall. `install.sh` symlinks or copies `bin/claude-secure` but does not transform it. | none |

**Canonical question answered:** *After the three jq expressions are patched, does any runtime system still have the wrong value cached?* No. The values are computed per-spawn, exported into the `do_spawn` subshell, consumed by `publish_report` within the same shell, and discarded when `do_spawn` returns. No cache layer.

## Common Pitfalls

### Pitfall 1: Clobber-after-backfill (the bug itself)
**What goes wrong:** `resolve_docs_alias` exports a correct value; later code does a fresh `jq` read that returns empty for the new schema; the fresh `export` overwrites the backfill with empty.
**Why it happens:** Two independent code paths reading the same field with different alias policies. `resolve_docs_alias` knows about Phase 23 aliases; `do_spawn:2077` was written in Phase 16 and never learned about them.
**How to avoid:** After the fix, add a comment above the block that explicitly names `resolve_docs_alias` as the upstream exporter, and explains that the re-read here is a *fallback* chain matching the canonical-first ordering used in `validate_docs_binding:127`. This makes the invariant visible to future refactorers.
**Warning signs:** Any new code that does `REPORT_REPO=$(jq -r '.report_repo...')` without a `// .docs_repo` fallback. Consider adding a grep-based lint check to `tests/test-phase23.sh` that greps `bin/claude-secure` for `jq -r '\.report_repo // empty'` and fails if found.

### Pitfall 2: Test that passes on buggy and fixed code
**What goes wrong:** A regression test that patches `.report_repo` **and** `.docs_repo` into the profile passes both before and after the fix because `jq -r '.report_repo // empty'` returns the legacy value in the "before" case.
**Why it happens:** Ambiguous fixture — the test doesn't distinguish "reads from new schema" from "reads from legacy schema".
**How to avoid:** The regression test **must** use a profile.json with `docs_repo` and **no** `report_repo` key. The `tests/fixtures/profile-23-docs/profile.json` fixture is already exactly this. Assert on both the positive (report file appears in the file:// remote) and, optionally, the env-var value directly via a dry-run code path.
**Warning signs:** If the "before" test run (on unpatched code) passes, the test does not actually cover the bug.

### Pitfall 3: Re-reading inside `do_spawn` defeats `resolve_docs_alias` back-fills
**What goes wrong:** More broadly, any time `do_spawn` re-reads a field that `resolve_docs_alias` has already resolved, there's a risk of alias divergence. `report_path_prefix` is currently not aliased in Phase 23, but if Phase 29+ adds a `docs_path_prefix` alias without also updating line 2079, the same bug resurfaces.
**How to avoid:** In PLAN.md, document the invariant "all three read paths must match `resolve_docs_alias`'s alias policy" and put it in an inline code comment above the block. Consider the architectural cleanup (move the block entirely into `resolve_docs_alias`) as a pending todo, not a Phase 28 task.

### Pitfall 4: Ordering: new-first vs legacy-first
**What goes wrong:** The audit's suggested fix uses `.report_repo // .docs_repo // empty` (legacy-first). The rest of the Phase 23 code uses `.docs_repo // .report_repo // empty` (new-first). If a profile accidentally has **both** fields set with different values (hand-edited .json, migration in progress), the two orderings disagree on which one wins.
**Why it happens:** Two fallback chains can diverge when both keys are present.
**How to avoid:** In PLAN.md, lock the ordering to match `validate_docs_binding:127` (**new-first**: `.docs_repo // .report_repo // empty`) so there is one unambiguous precedence rule. This is also more forward-compatible: once the legacy fields are removed (see `.planning/todos/pending/2026-04-14-remove-legacy-report-repo-token-support.md`), the new-first ordering degrades gracefully to `.docs_repo // empty`.
**Warning signs:** `test_legacy_report_repo_alias` in `test-phase23.sh` currently asserts that a legacy-only profile (`report_repo`, no `docs_repo`) resolves correctly. The new-first fix preserves this — jq's `//` skips empty/null values, so `.docs_repo // .report_repo` correctly falls through to `.report_repo` when `.docs_repo` is absent.

### Pitfall 5: REPORT_PATH_PREFIX has no Phase 23 alias
**What goes wrong:** A developer "symmetrizing" the fix writes `.report_path_prefix // .docs_path_prefix // "reports"`, inventing a new field that does not exist anywhere else.
**Why it happens:** Over-eager symmetry.
**How to avoid:** Leave line 2079 alone. If a user ever wants a path prefix alias, that's a Phase 29+ decision. Document this explicitly in PLAN.md.

## Code Examples

### Target code after fix (patch hunk)

```bash
# Phase 16 / D-12 (patched in Phase 28 for OPS-01 forward compat):
# read report_repo fields from profile.json and export as env vars so
# publish_report can consume them via REPORT_REPO / REPORT_BRANCH / REPORT_PATH_PREFIX.
# REPORT_REPO_TOKEN comes from profile.env (loaded earlier via load_profile_config
# → resolve_docs_alias, which also back-fills REPORT_REPO from DOCS_REPO when only
# the new Phase 23 field names are set). The fallback ordering below (docs_* first,
# report_* legacy second) matches validate_docs_binding:127 so Phase 23-migrated
# profiles never silently skip report publishing.
local _profile_json="$CONFIG_DIR/profiles/$PROFILE/profile.json"
if [ -f "$_profile_json" ]; then
  REPORT_REPO=$(jq -r '.docs_repo // .report_repo // empty' "$_profile_json")
  REPORT_BRANCH=$(jq -r '.docs_branch // .report_branch // "main"' "$_profile_json")
  REPORT_PATH_PREFIX=$(jq -r '.report_path_prefix // "reports"' "$_profile_json")
  export REPORT_REPO REPORT_BRANCH REPORT_PATH_PREFIX
fi
```

Source: synthesized from `bin/claude-secure:127-129` (same fallback pattern used in `validate_docs_binding`) and `bin/claude-secure:280-285` (same backfill logic used in `resolve_docs_alias`).

### Regression test pattern (Phase 23 style)

```bash
# tests/test-phase23.sh — new test
test_docs_repo_spawn_publishes_report() {
  # Install the profile-23-docs fixture (docs_repo only, no report_repo).
  _install_profile_23_docs docs-spawn

  # Patch docs_repo to a local bare repo (pattern from _patch_docs_repo at line 262).
  local bare_repo
  bare_repo=$(setup_bare_repo)  # reuses test-phase16.sh helper via sourcing, or inline
  _patch_docs_repo "docs-spawn" "$bare_repo"

  # Seed DOCS_REPO_TOKEN in .env (fake, push_with_retry only needs non-empty).
  echo 'DOCS_REPO_TOKEN=ghp_FAKE_TOKEN_FOR_LOCAL_BARE' >> \
    "$CONFIG_DIR/profiles/docs-spawn/.env"

  # Run a non-docker spawn with CLAUDE_SECURE_FAKE_CLAUDE_STDOUT so no container
  # is started (pattern established in Phase 16 tests — see test-phase16.sh
  # helper run_spawn_integration and the CLAUDE_SECURE_FAKE_CLAUDE_STDOUT escape
  # hatch added in Phase 16-03).
  local envelope="$PROJECT_DIR/tests/fixtures/envelope-success.json"
  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  CLAUDE_SECURE_FAKE_CLAUDE_STDOUT="$envelope" \
    "$PROJECT_DIR/bin/claude-secure" spawn \
      --profile docs-spawn \
      --event-file "$event" \
      > "$TEST_TMPDIR/spawn.out" 2>&1 || return 1

  # Clone the bare remote and assert the report file landed.
  local clone="$TEST_TMPDIR/verify-clone"
  git clone --quiet "$bare_repo" "$clone" >/dev/null 2>&1 || return 1
  local y m
  y=$(date -u +%Y); m=$(date -u +%m)
  find "$clone/reports/$y/$m/" -name 'issues-opened-*.md' 2>/dev/null | grep -q . \
    || { echo "FAIL: no report file landed in bare repo (docs_repo backfill broken)" >&2; return 1; }
  return 0
}
```

Source: composed from existing patterns in `tests/test-phase16.sh:740-760` (`test_no_report_repo_skips_push` / `run_spawn_integration`) and `tests/test-phase23.sh:262-270` (`_patch_docs_repo`). The planner should verify during plan writing that the `run_spawn_integration` helper is importable into `test-phase23.sh` or whether the test should live in `test-phase16.sh` to reuse the helper inline.

### Alternative regression test location

If cross-suite helper sharing is awkward, the test can live in `test-phase16.sh` itself, keyed as a Phase 23 back-compat regression:

```bash
# tests/test-phase16.sh — new test added at Phase 28
test_docs_repo_field_alias_publishes() {
  # Regression for Phase 28 OPS-01 forward-compat fix. Profiles migrated to
  # Phase 23's docs_repo canonical field must still publish reports.
  local tid="docs_alias"
  local repo_url
  repo_url=$(setup_bare_repo)

  # Install test profile but manually rewrite profile.json to remove report_repo
  # and add docs_repo (simulating a Phase 23-migrated profile).
  setup_test_profile
  local pj="$TEST_TMPDIR/home/.claude-secure/profiles/test-profile/profile.json"
  jq --arg r "$repo_url" \
    'del(.report_repo) | del(.report_branch) | .docs_repo = $r | .docs_branch = "main" | .docs_project_dir = "projects/t"' \
    "$pj" > "$pj.new" && mv "$pj.new" "$pj"

  local event="$PROJECT_DIR/tests/fixtures/github-issues-opened.json"
  local stdout
  stdout=$(jq -c '.claude' "$PROJECT_DIR/tests/fixtures/envelope-success.json")
  run_spawn_integration "$tid" "$event" "$stdout" || return 1

  # Assert a report was actually pushed (not silently skipped).
  local audit url
  audit=$(tail -n1 "$(audit_log_path "$tid")") || return 1
  url=$(echo "$audit" | jq -r '.report_url')
  [ -n "$url" ] && [ "$url" != "null" ] && [ "$url" != "" ] \
    || { echo "FAIL: report_url empty, expected a pushed URL — docs_repo backfill broken"; return 1; }
  return 0
}
```

This option is strictly simpler because `run_spawn_integration` is already in scope. The planner should prefer this location.

## State of the Art

| Old Approach (pre-Phase 23) | Current Approach (Phase 23) | When Changed | Impact |
|-----------------------------|-----------------------------|--------------|--------|
| Profile schema used `report_repo` / `report_branch` / `REPORT_REPO_TOKEN` as the canonical names | Profile schema uses `docs_repo` / `docs_branch` / `docs_project_dir` / `DOCS_REPO_TOKEN` as canonical; legacy names are aliases with one-time deprecation warning | Phase 23 (2026-04-13) | Any v2.0 code path that reads `report_repo` directly from `profile.json` without consulting the `docs_repo` alias is a latent bug. Phase 28 fixes the one remaining instance. |
| `do_spawn` re-read profile fields fresh | `load_profile_config` → `resolve_docs_alias` exports them **once**, `do_spawn` should consume the exports | Phase 23 for the new fields; **not retrofitted** into `do_spawn:2077` → this phase | The re-read in `do_spawn:2077` was left in place during Phase 23 because it operated on legacy fields; it was not flagged as needing the alias fallback. Phase 28 closes this gap. |

**Deprecated/outdated:**
- Reading `.report_repo` without a `.docs_repo` fallback is deprecated as of Phase 23. After Phase 28, every such read in `bin/claude-secure` must use the fallback chain. The full legacy removal is tracked in `.planning/todos/pending/2026-04-14-remove-legacy-report-repo-token-support.md`.

## Open Questions

1. **Should the fallback order be new-first or legacy-first?**
   - What we know: The audit suggests `.report_repo // .docs_repo // empty` (legacy-first). The rest of the Phase 23 code (`validate_docs_binding:127`) uses `.docs_repo // .report_repo // empty` (new-first).
   - What's unclear: Only matters when a profile has **both** keys set with different values. In normal migration this shouldn't happen, but a stale copy-paste could create it.
   - Recommendation: **Use new-first** (`.docs_repo // .report_repo // empty`) to match the rest of the codebase and give forward-compat a clear story for the eventual legacy removal. Lock this in PLAN.md.

2. **Should the regression test live in `test-phase16.sh` or `test-phase23.sh`?**
   - What we know: `test-phase16.sh` already has `run_spawn_integration` + `setup_bare_repo` + `setup_test_profile` and the envelope fixtures used for end-to-end audit verification. `test-phase23.sh` has `_patch_docs_repo` and the `profile-23-docs` fixture.
   - What's unclear: Cross-sourcing between test suites is not a pattern the project currently uses.
   - Recommendation: **Put the regression test in `test-phase16.sh`** (it tests Phase 16's publish path), named to make the Phase 23 back-compat linkage explicit (e.g., `test_docs_repo_field_alias_publishes`). Register in `test-map.json` if needed; the `bin/claude-secure` mapping at `tests/test-map.json:67-79` already includes `test-phase16.sh`.

3. **Should the re-read block be removed entirely and consolidated into `resolve_docs_alias`?**
   - What we know: The block at 2072-2081 predates Phase 23 and exists because `resolve_docs_alias` does not back-fill `REPORT_PATH_PREFIX`.
   - What's unclear: Whether moving it is worth the blast radius (need to re-verify every call path that depends on the current ordering, plus the Phase 25/24 test harness assumes `do_spawn` sets these envs).
   - Recommendation: **Out of scope for Phase 28.** Leave the block in place, fix the jq expressions only. Log a pending-todo for the future refactor if the planner thinks it's valuable.

4. **Should the fix also add a grep-based lint to prevent regressions?**
   - What we know: The bug slipped past Phase 23 code review because nobody grepped for `.report_repo //` after adding the alias.
   - What's unclear: Whether a shell-based lint adds more friction than value for a codebase of this size.
   - Recommendation: **Optional.** If the planner wants a belt-and-suspenders approach, add a one-line assertion in `tests/test-phase23.sh` that greps `bin/claude-secure` for `jq -r '\.report_repo // empty'` and fails on match. Low cost, high signal.

## Environment Availability

This phase has no new external dependencies. Every tool used is already required by the project:

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash 4+ | `bin/claude-secure`, `run-tests.sh` | ✓ (WSL2/Linux; Phase 18 re-exec guard handles macOS) | ≥ 4 | — |
| jq 1.6+ | All profile reads | ✓ | 1.6+ (Phase 18 verified) | — |
| git 2.x | `publish_report` / `setup_bare_repo` / `run_spawn_integration` | ✓ | — | — |
| docker compose v2 | Not needed for regression test (uses `CLAUDE_SECURE_FAKE_CLAUDE_STDOUT` escape hatch) | ✓ but unused | — | — |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash shell scripts (custom harness) |
| Config file | `tests/test-map.json` (file→suite mapping); suite runner `run-tests.sh` |
| Quick run command | `./run-tests.sh tests/test-phase16.sh tests/test-phase23.sh` |
| Full suite command | `./run-tests.sh` (discovers via test-map.json) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| OPS-01 | Phase 23-migrated profile (`docs_repo` only, no `report_repo`) successfully publishes a report through `do_spawn` → `publish_report` | integration (shell + file:// bare remote, no docker) | `./run-tests.sh tests/test-phase16.sh` (filter: `test_docs_repo_field_alias_publishes`) | ❌ Wave 0 (new test) |
| OPS-01 | Legacy profile (`report_repo` only) continues to publish reports unchanged | integration | `./run-tests.sh tests/test-phase16.sh` (existing `test_publish_happy_path` or equivalent) | ✅ exists |
| OPS-01 | Profile with neither field continues to silently skip publish (opt-out preserved) | integration | `./run-tests.sh tests/test-phase16.sh::test_no_report_repo_skips_push` | ✅ exists |
| OPS-01 | `resolve_docs_alias` back-fill of `REPORT_REPO` from `DOCS_REPO` survives into `do_spawn` env | unit (dry-run spawn + env inspection) | Derived from new test — assert `REPORT_REPO` env visible in spawn log, optional | ❌ Wave 0 (optional belt-and-suspenders) |

### Sampling Rate
- **Per task commit:** `./run-tests.sh tests/test-phase16.sh tests/test-phase23.sh` (~30 seconds, covers both phases affected by the fix).
- **Per wave merge:** Full `./run-tests.sh` (all phases).
- **Phase gate:** Full suite green, plus explicit re-run of `test-phase23.sh` and `test-phase16.sh` before `/gsd:verify-work`.

### Wave 0 Gaps
- [ ] `tests/test-phase16.sh` — add `test_docs_repo_field_alias_publishes` (Phase 23-migrated profile regression test). Register in the suite's `run_test` dispatch block.
- [ ] *(Optional)* `tests/test-phase23.sh` — add a static grep assertion that `bin/claude-secure` does not contain a bare `jq -r '\.report_repo // empty'` pattern (anti-regression guard).
- [ ] *(Already exists)* `tests/fixtures/profile-23-docs/profile.json` — the canonical new-schema fixture used by Phase 23 tests. No changes needed; the new test clones or reuses it in place.

## Sources

### Primary (HIGH confidence)
- `bin/claude-secure:2072-2081` — direct code read, the exact offending hunk.
- `bin/claude-secure:232-294` — `resolve_docs_alias` function, confirms the back-fill is already in place.
- `bin/claude-secure:416-450` — `load_profile_config`, confirms `resolve_docs_alias` is always called before `do_spawn`.
- `bin/claude-secure:1349-1363` — `publish_report`, confirms `REPORT_REPO=""` triggers silent skip via `return 2`.
- `bin/claude-secure:117-165` — `validate_docs_binding`, provides the canonical `.docs_repo // .report_repo // empty` fallback pattern.
- `.planning/v2.0-MILESTONE-AUDIT.md` — audit finding with prescribed fix.
- `.planning/REQUIREMENTS.md:96` — OPS-01 traceability showing Phase 28 as the fix target.
- `.planning/STATE.md:129-131` — Phase 23 decisions confirming `resolve_docs_alias` semantics.
- `tests/test-phase16.sh:85-155, 740-760` — existing test helpers (`setup_test_profile`, `setup_bare_repo`, `run_spawn_integration`, `test_no_report_repo_skips_push`) that the regression test reuses.
- `tests/test-phase23.sh:187-220, 262-270` — existing `test_legacy_report_repo_alias` and `_patch_docs_repo` helpers.
- `tests/fixtures/profile-23-docs/profile.json` — canonical new-schema fixture.
- `tests/test-map.json:66-79` — confirms `bin/claude-secure` changes trigger both phase-16 and phase-23 suites.

### Secondary (MEDIUM confidence)
- `.planning/phases/23-profile-doc-repo-binding/23-03-SUMMARY.md` — Phase 23 summary confirming the back-fill contract is `resolve_docs_alias`'s single integration point.
- `.planning/todos/pending/2026-04-14-remove-legacy-report-repo-token-support.md` — background on the eventual legacy removal (out of scope for Phase 28 but confirms the fallback-chain ordering should be new-first for forward compat).

### Tertiary (LOW confidence)
- None. This phase is entirely grounded in direct code reads and the audit report; no web search, no Context7 query needed — the fix is prescribed and the surrounding code is locally verifiable.

## Metadata

**Confidence breakdown:**
- Bug localization: **HIGH** — direct code read of all relevant functions; the clobber is reproducible on paper by tracing env var lifetimes.
- Fix semantics: **HIGH** — identical pattern already in use at `bin/claude-secure:127-129` (`validate_docs_binding`).
- Regression test design: **HIGH** — all fixtures and helpers already exist; new test is a composition of existing patterns.
- Ordering decision (new-first vs legacy-first): **MEDIUM** — both are defensible; recommendation is based on code consistency and forward-compat story, not a hard technical gate.
- Scope boundary (do not refactor the block into `resolve_docs_alias`): **HIGH** — blast radius analysis shows other callers depend on current ordering; full refactor is a separate phase.

**Research date:** 2026-04-14
**Valid until:** 2026-05-14 (30 days — the code area is stable and the fix is localized; any change in `bin/claude-secure` touching `do_spawn`, `resolve_docs_alias`, or `load_profile_config` before the fix lands should trigger a re-read of this research)
