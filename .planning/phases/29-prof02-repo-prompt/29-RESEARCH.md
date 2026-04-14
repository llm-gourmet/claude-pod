# Phase 29: PROF-02 create_profile Repo Prompt - Research

**Researched:** 2026-04-14
**Domain:** Interactive bash CLI prompting + jq JSON construction (already-owned project territory)
**Confidence:** HIGH

## Summary

This is a tiny UX patch in well-understood project territory. The production `create_profile` function at `bin/claude-secure:296-343` already prompts for workspace and auth but never prompts for the `.repo` field — users must manually edit `profile.json` after creation to get webhook auto-routing. The audit surfaces this as a low-priority UX gap (PROF-02 from v2.0-MILESTONE-AUDIT.md line 138).

The fix is a 3-line addition: a `read -rp` prompt between the workspace prompt and the `jq -n` invocation, plus a conditional that chooses between the two-field and three-field jq expression depending on whether the user entered a value. The pattern already exists in `tests/test-phase12.sh:82-89` (the test-local `create_test_profile` shows the exact jq branch we need).

No new dependencies, no new files, no architectural decisions. The only real questions are (1) optional vs required, (2) validation format, and (3) test coverage strategy — all answered below.

**Primary recommendation:** Add an optional `GitHub repository (owner/repo) [skip]:` prompt to `create_profile`, store it as `.repo` via the existing `jq -n` pattern, leave empty when skipped so the `.repo // empty` callers continue to work, and add one new `test_prof_02d` test to `tests/test-phase12.sh` that exercises the actual `create_profile` function (not `create_test_profile`) via piped stdin.

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase. All decisions below fall under Claude's discretion subject to planner review.

### Locked Decisions
(None — no discuss-phase run for Phase 29)

### Claude's Discretion
- Optional vs required `.repo` prompt — research recommends **optional** (see Architecture Patterns §Decision 1)
- Validation format — research recommends **light format check** with `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` warning, not a hard block (see §Decision 2)
- Test strategy — research recommends **pipe stdin into real `create_profile`** (see §Decision 3)
- Default value (Enter = skip vs Enter = prompt-again) — research recommends **Enter = skip** to preserve existing single-profile-no-routing workflow

### Deferred Ideas (OUT OF SCOPE)
- Doc-repo binding (`docs_repo`, `docs_branch`, `docs_project_dir`) — those belong to Phase 23, already implemented, separate prompts
- Migration/backfill for existing profiles — out of scope; PROF-02 is about onboarding friction for *new* profiles only
- Multi-repo-per-profile — v2.0 model is one profile = one repo (see REQUIREMENTS.md Out of Scope)
- Interactive editing of existing profile's `.repo` — no roadmap requirement; can be added later as `claude-secure profile set-repo`

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROF-02 | User can map a GitHub repository URL to a profile so events route correctly | The repo field already exists in the schema and is already consumed by `resolve_profile_by_repo` (bin/claude-secure:369-385), `list_profiles` (line 506), `do_spawn`'s D-21 auto-resolve path (line 2323), and `validate_docs_binding` (line 127 `.docs_repo // .report_repo // empty`). The gap is purely that `create_profile` never writes the field, forcing manual edits. This phase closes that gap by teaching `create_profile` to write the field interactively. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| bash | 5.x / 3.2-compatible | Interactive prompt via `read -rp` | Already the language of `bin/claude-secure`. Phase 18 PORT-02 confirmed we re-exec into brew bash 5 on macOS, so bash 4+ features are allowed but we should stay POSIX-friendly since `create_profile` runs at spawn-time |
| jq | 1.7+ | Build profile.json with optional `.repo` field | Already the standard for profile.json construction — the exact three-field jq pattern we need is already in `tests/test-phase12.sh:84` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| (none) | — | — | No new dependencies — the feature is a 3–5 line diff in an existing function |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `read -rp` with single-line prompt | `select` menu (bash builtin) | Overkill for a free-form text field. `select` is for enumerated choices (like the existing auth method selector on lines 347-351), not repo URLs. |
| Optional prompt (Enter to skip) | Required prompt (must supply or abort) | Required would break existing superuser / single-profile workflows where users don't run the webhook listener. Optional preserves back-compat. |
| Prompt immediately | Defer to a separate `claude-secure profile set-repo` subcommand | Separate subcommand moves friction rather than removes it. The whole point of PROF-02 is to eliminate the manual edit step during onboarding. |
| Free-form text | Regex-validated `owner/repo` hard block | Regex validation is good but should warn-and-accept, not hard-block — users may legitimately want to leave it blank now and edit later, and we shouldn't surprise them. |

**Installation:**
```bash
# No installation needed — pure code edit to bin/claude-secure
```

**Version verification:** No new packages; existing bash/jq dependencies already pinned by the install flow.

## Architecture Patterns

### Recommended Project Structure
```
bin/claude-secure              # edit create_profile() at lines 296-343
tests/test-phase12.sh          # add test_prof_02d exercising real create_profile via piped stdin
```

No new files. No new modules.

### Pattern 1: Optional Interactive Prompt With Empty Skip
**What:** Read a line from stdin, treat empty input as "user skipped," branch the downstream jq invocation.
**When to use:** Any optional profile field that has a meaningful default-absent behavior.
**Example:**
```bash
# Source: tests/test-phase12.sh:82-89 (already in the project — exact pattern to mirror)
# Build profile.json
if [ -n "$repo" ]; then
  jq -n --arg ws "$ws_path" --arg repo "$repo" '{"workspace": $ws, "repo": $repo}' \
    > "$config_dir/profiles/$name/profile.json"
else
  jq -n --arg ws "$ws_path" '{"workspace": $ws}' \
    > "$config_dir/profiles/$name/profile.json"
fi
```

### Pattern 2: Prompt Placement In create_profile
**What:** The prompt goes *between* the workspace prompt (line 305-308) and the `jq -n` (line 311), before whitelist copy and auth setup.
**When to use:** Follow the existing natural order — workspace first (filesystem), repo next (metadata), then auth (secrets).
**Example:**
```bash
# Target: bin/claude-secure:296-343, after line 308 (mkdir -p "$ws_path")
# ... existing workspace prompt ...
mkdir -p "$ws_path"

# NEW: repo prompt (optional)
read -rp "GitHub repository for webhook routing (owner/repo) [skip]: " repo
repo="${repo:-}"
if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Warning: '$repo' does not look like owner/repo format — saved anyway. Edit profile.json if wrong." >&2
fi

# Build profile.json
if [ -n "$repo" ]; then
  jq -n --arg ws "$ws_path" --arg repo "$repo" '{"workspace": $ws, "repo": $repo}' > "$tmpdir/profile.json"
else
  jq -n --arg ws "$ws_path" '{"workspace": $ws}' > "$tmpdir/profile.json"
fi
```

### Anti-Patterns to Avoid
- **Hard-blocking on regex mismatch:** Users may paste a full URL (`https://github.com/owner/repo`) or a repo with dots/underscores. Warn-and-accept is correct; abort-on-mismatch will surprise users and force them to manually edit after the "interactive" flow anyway, defeating the UX goal.
- **Making the field required:** Superuser mode and single-profile setups don't need webhook routing. Required would break `create_profile`'s auto-invocation from the `--profile` dispatch at line 2624.
- **Prompting for doc-repo fields here:** Phase 23 already owns `docs_repo`, `docs_branch`, `docs_project_dir`, and its own `init-docs` flow. Mixing them into `create_profile` bloats the prompt and duplicates Phase 23 logic.
- **Using `jq --argjson` to splice the field post-hoc:** Two-branch `jq -n` is cleaner and already idiomatic in the project. Don't reinvent.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Prompt parsing | Custom stdin scanner | `read -rp "prompt: " var` | Built-in bash, already used 4 times in `create_profile` |
| JSON emission | `echo "{...}" > profile.json` | `jq -n --arg ...` | jq handles escaping; raw echo breaks on `"` in repo names |
| Default-skip logic | Sentinel string like `<skip>` | `repo="${repo:-}"` + `[ -n "$repo" ]` | Empty-string idiom is standard bash, grep-friendly, matches existing `.repo // empty` jq callers |
| Regex validation | `grep -E` subshell | Bash `[[ =~ ]]` | Built-in, no subshell, same semantics |

**Key insight:** Everything needed for this phase is already present in the codebase. The only real work is mirroring `tests/test-phase12.sh:82-89` into production code.

## Runtime State Inventory

This phase is NOT a rename/refactor/migration — it adds a new optional prompt to an existing function. Runtime state inventory is not applicable.

**Stored data:** None — new profiles created after the patch will get the field; existing profiles remain untouched (and were already being edited manually per PROF-02).

**Live service config:** None — no services configured outside git.

**OS-registered state:** None — webhook/reaper services don't consume `.repo` by profile-name; they read it at dispatch time from `profile.json` via `resolve_profile_by_repo`.

**Secrets/env vars:** None — `.repo` is public metadata, not a secret.

**Build artifacts:** None — `bin/claude-secure` is a single-file script, no build step.

## Common Pitfalls

### Pitfall 1: Breaking the Test Contract of test-phase12.sh
**What goes wrong:** Phase 12's existing tests use a test-local `create_test_profile` helper (tests/test-phase12.sh:60-97). If we only patch production `create_profile` and don't add a test that calls it directly, we'll ship a UX fix with no regression guard.
**Why it happens:** Bash unit testing of interactive functions is awkward; the original Phase 12 author worked around this by duplicating the logic in-test.
**How to avoid:** Add `test_prof_02d` (or similar) that sources `bin/claude-secure`, pipes canned answers into real `create_profile` via `echo -e "$ws\n$repo\n1\n$token\n" | create_profile`, then asserts the output profile.json has the expected `.repo` value.
**Warning signs:** Test file continues to only exercise `create_test_profile` — that's the duplicate, not production code.

### Pitfall 2: Breaking Non-Interactive Auto-Creation From CLI Dispatch
**What goes wrong:** Line 2624 auto-invokes `create_profile "$PROFILE"` when the profile dir doesn't exist. If the new prompt blocks indefinitely on EOF (e.g., invoked from a non-TTY wrapper), it breaks every `claude-secure --profile new-name` first-run path.
**Why it happens:** `read -rp` without a default reads forever on closed stdin.
**How to avoid:** `read -rp` already returns non-zero on EOF; because the field is optional and we coalesce with `${repo:-}`, EOF becomes empty becomes skip. Verify this works by running `echo '' | claude-secure --profile foo` (or equivalent) in tests.
**Warning signs:** Manual test hangs when stdin is redirected from `/dev/null`.

### Pitfall 3: Regex Rejecting Legitimate Repo Names
**What goes wrong:** GitHub repo names allow dots (`org.github.io`), underscores (`my_repo`), and numeric prefixes. A strict `^[a-z][a-z0-9-]+/[a-z][a-z0-9-]+$` would reject real repos.
**Why it happens:** Copy-pasting the `validate_profile_name` regex (line 63) without thinking — profile names are DNS-safe but GitHub repos are not.
**How to avoid:** Use a permissive regex `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` and warn-don't-block. Reference GitHub's actual character set: letters, digits, hyphen, underscore, dot.
**Warning signs:** A test with `owner/my.repo` or `1-Proj/my_lib` fails.

### Pitfall 4: Clobbering The Phase 23 / Phase 28 Schema Drift Path
**What goes wrong:** Phase 23 added `docs_repo` as an alias for `report_repo`; Phase 28 fixed the OPS-01 fallback order (`.docs_repo // .report_repo // empty`). None of those touch `.repo` — that's an *independent* GitHub-event-routing field. If a planner confuses `.repo` (GitHub full_name for routing) with `.docs_repo` (git URL for reports), they'll add the wrong prompt.
**Why it happens:** Similar-sounding field names, all living in the same profile.json.
**How to avoid:** Be explicit in prompt text: `"GitHub repository for webhook routing (owner/repo) [skip]: "` — the phrase "webhook routing" disambiguates from doc-repo binding. `.repo` stores GitHub `repository.full_name` format (e.g., `owner/repo`), not a URL; `.docs_repo` is a full git URL (e.g., `https://github.com/owner/repo.git`).
**Warning signs:** Prompt text says "URL" or the diff touches any `docs_*` field.

### Pitfall 5: Forgetting the Test-Only Helper Is a Duplicate
**What goes wrong:** The planner updates `create_test_profile` in tests/test-phase12.sh but not the real `create_profile` in bin/claude-secure (or vice versa).
**Why it happens:** Grep for `create_profile` returns both; the test-local one is at test-phase12.sh:60 and looks like "the implementation."
**How to avoid:** Production code lives at `bin/claude-secure:296-343`. Test helper lives at `tests/test-phase12.sh:60-97`. Planner MUST edit both — production for the feature, test helper only if new test cases need a third arg (the tests at line 84 already accept `$repo` so likely no helper edit needed).
**Warning signs:** Diff touches only one file when it should touch both.

## Code Examples

### Example 1: The Full Proposed Diff (bin/claude-secure)
```bash
# Source: bin/claude-secure:296-343 (current) — target shape after patch
create_profile() {
  local name="$1"
  local pdir="$CONFIG_DIR/profiles/$name"
  local tmpdir
  tmpdir=$(mktemp -d)

  echo "Creating profile '$name'..."

  # Workspace
  read -rp "Workspace path [$HOME/claude-workspace-$name]: " ws_path
  ws_path="${ws_path:-$HOME/claude-workspace-$name}"
  ws_path="$(realpath -m "$ws_path")"
  mkdir -p "$ws_path"

  # NEW: repo prompt (optional — enables webhook routing via resolve_profile_by_repo)
  read -rp "GitHub repository for webhook routing (owner/repo) [skip]: " repo
  repo="${repo:-}"
  if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Warning: '$repo' does not look like owner/repo format — saved anyway." >&2
  fi

  # Build profile.json (two-branch jq mirrors tests/test-phase12.sh:82-89)
  if [ -n "$repo" ]; then
    jq -n --arg ws "$ws_path" --arg repo "$repo" \
      '{"workspace": $ws, "repo": $repo}' > "$tmpdir/profile.json"
  else
    jq -n --arg ws "$ws_path" '{"workspace": $ws}' > "$tmpdir/profile.json"
  fi

  # ... rest unchanged (whitelist copy, auth setup, atomic move) ...
}
```

### Example 2: Test Exercising Real create_profile
```bash
# Source: new test_prof_02d in tests/test-phase12.sh
# Exercises the ACTUAL bin/claude-secure create_profile function (not create_test_profile helper)
test_prof_02d_create_profile_prompts_for_repo() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  _source_functions "$tmpdir"

  # Canned answers: workspace (default), repo, auth choice (2=API key), API key, then blank
  printf '\nowner/my-repo\n2\ntest-key\n' | create_profile "myproj"

  local pdir="$CONFIG_DIR/profiles/myproj"
  [ -f "$pdir/profile.json" ] || return 1
  local repo
  repo=$(jq -r '.repo // empty' "$pdir/profile.json")
  [ "$repo" = "owner/my-repo" ] || return 1
  return 0
}
run_test "PROF-02d: create_profile prompts for and persists .repo field" test_prof_02d_create_profile_prompts_for_repo
```

### Example 3: Skip-Path Test
```bash
# Source: new test_prof_02e in tests/test-phase12.sh
# Verifies Enter-to-skip produces a profile.json with no .repo key (back-compat)
test_prof_02e_create_profile_skip_repo() {
  local tmpdir
  tmpdir=$(mktemp -d -p "$TEST_TMPDIR")
  _setup_source_env "$tmpdir"
  _source_functions "$tmpdir"

  # Canned: workspace default, repo BLANK (skip), auth=2, key
  printf '\n\n2\ntest-key\n' | create_profile "myproj2"

  local pdir="$CONFIG_DIR/profiles/myproj2"
  local repo
  repo=$(jq -r '.repo // empty' "$pdir/profile.json")
  [ -z "$repo" ] || return 1
  return 0
}
run_test "PROF-02e: create_profile allows skipping .repo (empty input)" test_prof_02e_create_profile_skip_repo
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manually edit profile.json after create | Interactive prompt during create | This phase | Eliminates the "silent onboarding gotcha" where users created a profile, wondered why webhooks didn't route, discovered the audit note, and hand-edited the file |
| `create_test_profile` in tests-only | Tests call real `create_profile` | Partially this phase | Closes the gap where PROF-02 tests only exercised a duplicate helper, not production code |

**Deprecated/outdated:** None — this is additive.

## Open Questions

1. **Should the superuser auto-create path (line 2624) suppress the new prompt?**
   - What we know: Line 2618-2625 auto-creates missing profiles when `--profile` is used. The new prompt adds one more question to first-run UX.
   - What's unclear: Whether a `CLAUDE_SECURE_NONINTERACTIVE=1` env escape hatch should be honored to skip the prompt in CI-style flows.
   - Recommendation: **Don't add an escape hatch in this phase.** The whole function is interactive (it already prompts for workspace and auth). If someone needs non-interactive creation, they need a broader `claude-secure profile create --name foo --workspace X --repo Y --auth ...` subcommand, which is out of scope. Empty input already acts as skip, which is sufficient for piped-stdin tests.

2. **Should we backfill the prompt hint with existing `.repo` values for profiles being re-run through `create_profile`?**
   - What we know: `create_profile` is not called on existing profiles; line 2618 guards `if ! -d pdir`. There is no "edit profile" flow.
   - What's unclear: Nothing — this is definitely out of scope.
   - Recommendation: **Ignore.** File a future `profile edit` subcommand request if needed.

3. **Should the prompt accept full GitHub URLs and strip them?**
   - What we know: `resolve_profile_by_repo` compares against `.repository.full_name` from webhook payloads, which is always `owner/repo` format.
   - What's unclear: User habit — some users will paste `https://github.com/owner/repo` or `git@github.com:owner/repo.git`.
   - Recommendation: **Warn but don't auto-transform.** Auto-stripping is magic and can silently corrupt non-GitHub repo strings. A clear warning message tells users what format is expected. If user pain emerges, add a helper in a follow-up.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | Interactive prompt | ✓ | 5.x (host) / re-exec on macOS | — |
| jq | profile.json construction | ✓ | 1.7+ | — (already required by project) |
| realpath | Workspace normalization | ✓ | (coreutils) | — (already used) |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

All dependencies are already present in the project — this phase adds no new requirements.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash test harness (`run_test` helper in tests/test-phase12.sh) |
| Config file | None — scripts self-contained, invoked via `tests/run-tests.sh` |
| Quick run command | `bash tests/test-phase12.sh` |
| Full suite command | `bash tests/run-tests.sh` (runs all test-phase*.sh) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROF-02 | `create_profile` prompts for `.repo` and persists the value | unit | `bash tests/test-phase12.sh` (new `test_prof_02d`) | ❌ Wave 0 |
| PROF-02 | Empty input skips the field (back-compat) | unit | `bash tests/test-phase12.sh` (new `test_prof_02e`) | ❌ Wave 0 |
| PROF-02 | Invalid format emits warning but still saves | unit | `bash tests/test-phase12.sh` (new `test_prof_02f`, optional) | ❌ Wave 0 |
| PROF-02 | Downstream `resolve_profile_by_repo` finds profiles created via the new flow end-to-end | integration | `bash tests/test-phase12.sh` (reuse existing `test_prof_02b` logic but seed via real `create_profile`, optional) | ✅ (seeding path new) |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase12.sh` (≈1s, fast enough for every commit)
- **Per wave merge:** `bash tests/test-phase12.sh && bash tests/run-tests.sh` (full suite — regression guard against accidental interaction with Phase 23 binding logic)
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test-phase12.sh` — add `test_prof_02d` (happy path: prompt, provide, persist)
- [ ] `tests/test-phase12.sh` — add `test_prof_02e` (skip path: empty input = no `.repo` key)
- [ ] `tests/test-phase12.sh` — (optional) `test_prof_02f` for warning-on-bad-format path
- [ ] Verify piped-stdin invocation pattern works against real `create_profile` (prove the `printf '\n...\n' | create_profile foo` harness before writing assertions)

*(No new test file needed — extending the existing Phase 12 test file is correct because PROF-02 is a Phase 12 requirement.)*

## Project Constraints (from CLAUDE.md)

The project CLAUDE.md defines the claude-secure stack (Docker + Node proxy + Python validator + bash CLI) and enforces the GSD workflow. Relevant directives for Phase 29:

- **Platform:** Bash code must work on Linux native, WSL2, and macOS (via Phase 18 PORT-02 re-exec). The new prompt uses `read -rp` and `[[ =~ ]]` — both bash-3.2+ safe. ✅
- **Dependencies:** No new host dependencies — reuses bash, jq, read, realpath all already required.
- **Security:** `.repo` is not a secret (it's public GitHub metadata). Does not affect whitelist, env_file projection, or redaction pipeline.
- **Conventions:** "Conventions not yet established" — follow local patterns in `bin/claude-secure` (e.g., `read -rp` with `${var:-default}`, `jq -n --arg`, warn-to-stderr with `>&2`).
- **Workflow:** Must enter through a GSD command. This phase is already scoped via roadmap entry — planner will produce 29-01-PLAN.md.
- **Testing rule (implicit from tests/TEST-SPEC.md pattern):** Every requirement needs a failing test first, then code to green it — matches the Wave 0 gap list above.

No CLAUDE.md directive conflicts with the recommended approach.

## Sources

### Primary (HIGH confidence)
- `bin/claude-secure:296-343` (current `create_profile`) — direct read, confirms prompt absence and jq construction pattern
- `bin/claude-secure:61-71` (`validate_profile_name`) — confirms DNS-safe regex is for profile NAMES, not repos
- `bin/claude-secure:369-385` (`resolve_profile_by_repo`) — confirms `.repo` is matched verbatim against `.repository.full_name` from webhook payloads
- `bin/claude-secure:855, 2067, 2323` — confirms downstream consumers use `owner/repo` format (GitHub `full_name`)
- `bin/claude-secure:506` — confirms `list_profiles` already displays `.repo // "-"`, so the field is already part of the user-visible schema
- `bin/claude-secure:2618-2625` — confirms CLI dispatch auto-invokes `create_profile` on missing profile; new prompt must handle stdin-closed gracefully
- `tests/test-phase12.sh:60-97` — existing `create_test_profile` helper with the **exact** two-branch jq pattern to mirror in production
- `tests/test-phase12.sh:172-202` — existing `test_prof_02a`/`test_prof_02b`/`test_prof_02c` — confirms `.repo` resolution is already tested, only the write path is missing coverage
- `.planning/v2.0-MILESTONE-AUDIT.md:17, 138` — the audit entries that define PROF-02's scope as "create_profile does not prompt for .repo field; users must add it manually"
- `.planning/REQUIREMENTS.md:13-14` — PROF-02 definition: "User can map a GitHub repository URL to a profile so events route correctly"
- `.planning/ROADMAP.md:194-198` — Phase 29 definition confirming PROF-02 as the sole requirement

### Secondary (MEDIUM confidence)
- (None — no external docs needed; this is an in-project patch)

### Tertiary (LOW confidence)
- (None)

No Context7 or WebSearch lookups were needed. The entire design space lives inside `bin/claude-secure` and one test file; training-data familiarity with bash `read`, jq, and regex is sufficient and has been cross-checked against actual project source.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new libraries; 100% existing project stack
- Architecture: HIGH — pattern already exists in `tests/test-phase12.sh:82-89`, directly mirrorable
- Pitfalls: HIGH — pitfalls enumerated from actual call sites (grep-verified) and the audit notes

**Research date:** 2026-04-14
**Valid until:** 2026-05-14 (30 days — patch is tiny and in stable territory; only invalidated if `create_profile` itself is refactored by another phase)
