# Phase 15: Event Handlers - Research

**Researched:** 2026-04-12
**Domain:** GitHub webhook payload schemas, event-type composite routing, per-profile filtering, safe variable substitution, default prompt template design
**Confidence:** HIGH

## Summary

Phase 15 is a small, surgical upgrade to two already-shipping files: `webhook/listener.py` (Phase 14) and `bin/claude-secure` (Phase 13). The listener gains a sub-millisecond filter hop between HMAC verification and persistence; the CLI gains an expanded variable set, a template-fallback chain, and a thin `replay` subcommand. The default templates shipped in `webhook/templates/` are the *only* net-new creative output — everything else extends an existing proven shape.

Three things drive the plan:

1. **Payload schemas are stable and well-documented** (verified against octokit/webhooks reference payloads). `issues` always has `action` + `issue.labels[].name` + `issue.user.login` + `issue.html_url`. `push` has **no `action` field** — composite type is just `push`. `workflow_run` has actions `requested`/`in_progress`/`completed` plus `workflow_run.conclusion` ∈ {success, failure, neutral, cancelled, skipped, timed_out, action_required}, and a top-level `workflow.name` distinct from `workflow_run.name` (the run name, often empty).

2. **Phase 13's `render_template` has a real sed-escaping bug** that Phase 15 will trip over as soon as it adds `ISSUE_TITLE`, `COMMIT_MESSAGE`, or any label/author string that contains `|`, `&`, `\`, or newlines. The current `sed "s|{{X}}|${var}|g"` pattern is unsafe for arbitrary payload content — commit messages with pipes, issue titles with backslashes, and multiline content all break substitution silently. Phase 15 **must** switch to the `awk`-style file-based substitution already proven inside the existing `ISSUE_BODY` branch, or the equivalent bash-native pattern that is agnostic to delimiter characters.

3. **UTF-8-safe truncation at 8192 bytes is trivial with `python3 -c`** — every other bash-only approach (character-by-character loops with `LC_ALL=C wc -c`, awk, iconv tricks) is either slow, brittle, or wrong on grapheme clusters. `python3` is already a hard dependency of the listener and of the installer (`install.sh` gate line 296). A single subshell per variable is acceptable — even 12 variables × ~3ms each = sub-50ms overhead per spawn, well under the 10-second GitHub timeout budget (and the filter check runs in the listener, not the spawn path, so truncation overhead is entirely host-side during a command the user is already waiting on).

**Primary recommendation:** Ship one shared bash helper `extract_payload_field()` that (a) runs a jq expression against the event JSON, (b) pipes through `python3 -c` for length/control-char hygiene, (c) writes the cleaned value into a temp file, and (d) returns the temp file path. Then teach `render_template` to substitute each `{{VAR}}` by reading that file — no sed, no escaping, no multiline fragility. Reuse the existing awk-file pattern (lines 432–439 of `bin/claude-secure`) for every new variable, not just `ISSUE_BODY`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Event Type Derivation (D-01 through D-04)**
- **D-01:** Composite event type is computed as `<X-GitHub-Event>` + optional `-<action>` suffix when the payload has an `action` field. Examples: `issues-opened`, `issues-labeled`, `push` (no action field), `workflow_run-completed`. Workflow runs are further qualified by conclusion when filtering (see D-12).
- **D-02:** The webhook listener (`webhook/listener.py`) computes the composite event type at request time and writes it to the event file at TOP LEVEL as `event_type` — alongside (not replacing) the existing `_meta.event_type` from Phase 14. The top-level field is the canonical contract spawn reads from.
- **D-03:** `bin/claude-secure spawn` is updated so its event-type extraction prefers `.event_type` (top-level) over `._meta.event_type` (Phase 14 fallback) over `.action` (older fallback). This keeps Phase 13's tests green while letting Phase 15's enriched events drive routing.
- **D-04:** Unknown composite types (no template, no filter rule) are logged but NOT spawned. Listener returns 202 to GitHub regardless (idempotent ack — GitHub never retries because we accepted the delivery).

**Per-Profile Event Filtering (D-05 through D-10)**
- **D-05:** New optional field in `profile.json`: `webhook_event_filter`. Schema:
  ```json
  {
    "webhook_event_filter": {
      "issues": { "actions": ["opened", "labeled"], "labels": [] },
      "push": { "branches": ["main", "master"] },
      "workflow_run": { "conclusions": ["failure"], "workflows": [] }
    }
  }
  ```
- **D-06:** Filter omitted = sane defaults: issues opened+labeled, push to main+master, workflow_run failures (any workflow). Empty arrays for `labels` / `workflows` mean "match anything in that category" — explicit values narrow the filter.
- **D-07:** Filter evaluation happens AFTER HMAC verification but BEFORE persisting the event file or invoking spawn. Filtered events are logged to `webhook.jsonl` with `event=filtered` and `reason=<filter-name>`, return 202, do not persist, do not spawn.
- **D-08:** Push-to-main branch matching is exact-string match on `ref` minus `refs/heads/` prefix. No glob/regex in this phase.
- **D-09:** Loop prevention for HOOK-04: profile may set `webhook_bot_users` (array of GitHub usernames). If `pusher.name` is in that list, the push is filtered with `reason=loop_prevention`. Default is empty (no loop protection). User documents this in README.
- **D-10:** Workflow run filter requires BOTH `action == completed` AND `workflow_run.conclusion in profile.workflow_run.conclusions`. The composite event type stays `workflow_run-completed` (action-based) so spawn template lookup is consistent — conclusion is a filter input, not a type discriminator.

**Default Templates & Resolution (D-11 through D-15)**
- **D-11:** Default templates ship in source tree at `webhook/templates/{issues-opened,issues-labeled,push,workflow_run-completed}.md`.
- **D-12:** `install.sh --with-webhook` copies `webhook/templates/` to `/opt/claude-secure/webhook/templates/` (always refresh — latest templates ship). Profile-level templates in `~/.claude-secure/profiles/<name>/prompts/` take precedence.
- **D-13:** `bin/claude-secure resolve_template()` is extended with a fallback chain:
  1. Explicit `--prompt-template <name>` flag → `~/.claude-secure/profiles/<name>/prompts/<name>.md`
  2. Composite event type → `~/.claude-secure/profiles/<name>/prompts/<event-type>.md`
  3. Fallback to default → `$WEBHOOK_TEMPLATES_DIR/<event-type>.md`
  4. Hard fail: log error, exit non-zero, no spawn.
- **D-14:** Default templates use only the variables defined per event type (D-16). Minimal — a few sentences of context plus a clear instruction.
- **D-15:** Template lookup fallback path resolved via `WEBHOOK_TEMPLATES_DIR` env var that defaults to `/opt/claude-secure/webhook/templates` when running under systemd, or `<repo>/webhook/templates` when running from a dev checkout (detected by presence of `.git` near the script).

**Variable Substitution per Event Type (D-16)**
- **D-16:** `bin/claude-secure render_template()` is extended with the full per-event-type variable map:

  | Event Type | Variables Available |
  |------------|---------------------|
  | issues-opened, issues-labeled | `{{REPO_NAME}}`, `{{ISSUE_NUMBER}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{ISSUE_LABELS}}` (comma-joined), `{{ISSUE_AUTHOR}}`, `{{ISSUE_URL}}` |
  | push | `{{REPO_NAME}}`, `{{BRANCH}}`, `{{COMMIT_SHA}}`, `{{COMMIT_MESSAGE}}`, `{{COMMIT_AUTHOR}}`, `{{PUSHER}}`, `{{COMPARE_URL}}` |
  | workflow_run-completed | `{{REPO_NAME}}`, `{{WORKFLOW_NAME}}`, `{{WORKFLOW_RUN_ID}}`, `{{WORKFLOW_CONCLUSION}}`, `{{BRANCH}}`, `{{COMMIT_SHA}}`, `{{WORKFLOW_RUN_URL}}` |
  | (any) | `{{REPO_NAME}}`, `{{EVENT_TYPE}}` (always available) |

  Phase 13 variables remain compatible — Phase 15 only ADDS, never removes.

**Minimal Sanitization (D-17 through D-19)**
- **D-17:** Every string variable extracted from the payload is truncated to 8192 bytes (UTF-8 safe — no mid-codepoint cuts). Truncated values get a `... [truncated N more bytes]` suffix.
- **D-18:** Null bytes (`\x00`) and ASCII control characters except `\n`, `\r`, `\t` are stripped from extracted variables before substitution. Hygiene step — not a security claim.
- **D-19:** Phase 15 explicitly does NOT implement: prompt-injection escaping, instruction-override detection, content-based sanitization, allow-list filtering of payload fields. SEC-02 is in Future Requirements.

**HOOK-07 Replay Convenience (D-20 through D-22)**
- **D-20:** `claude-secure replay <delivery-id>` finds the matching event file under `~/.claude-secure/events/` and calls `claude-secure spawn --profile <auto-resolved> --event-file <path>`.
- **D-21:** Profile auto-resolution for replay: parse the event file, extract `repository.full_name`, look up the matching profile (same logic as Phase 14 listener). User can override with `--profile`.
- **D-22:** Replay finds the event by substring match on the filename. Multiple matches → error listing candidates. Zero matches → error.

**Listener Changes Summary (D-23)**
- **D-23:** `webhook/listener.py` gains: `compute_event_type()`, `apply_event_filter()`, filter check between HMAC and persistence, top-level `event_type` field, new log events `filtered` and `routed`.

**Spawn Changes Summary (D-24)**
- **D-24:** `bin/claude-secure` gains: updated event-type extraction priority, extended `render_template()`, extended `resolve_template()` with fallback, new `replay` subcommand, new helper `extract_payload_field(json, jq_path, default)` with truncation + strip baked in.

### Claude's Discretion

- Exact wording of default templates in `webhook/templates/*.md` — planner picks tone (recommend brief, action-oriented, English).
- Whether to add `--dry-run` to `replay` subcommand (nice-to-have).
- Whether `extract_payload_field` is a sourceable bash function or a small Python helper invoked via subprocess (bash + jq preferred for consistency).
- Test naming convention for the new event-type tests in `tests/test-phase15.sh`.
- Whether to break out a `webhook/filter.py` module from `listener.py` or keep filtering inline (single-file precedent says inline).
- Exact JSON schema validation for `webhook_event_filter` in profile.json — strict vs lenient.

### Deferred Ideas (OUT OF SCOPE)

- **SEC-02 prompt injection sanitization** — Future Requirements.
- **Branch glob/regex matching for push filter** — Phase 17 hardening if needed.
- **Auto-detection of bot loop commits** — cannot safely infer; user opts in.
- **Per-event-type rate limiting** — out of scope.
- **Webhook payload diff against last event of same type** — defer or skip.
- **Replay UI with payload preview** — CLI-only, permanently out of scope per PROJECT.md.
- **Template hot-reload without restart** — already stateless, nothing to do.
- **Custom variable extraction via jq expressions in profile.json** — defer until requested.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HOOK-03 | Listener handles Issue events (opened, labeled) and dispatches to correct profile | Supported by "Event Schema Reference" (issues path verified), "Composite Event Type" pattern, and "Filter Chain Skeleton". `issues.opened` and `issues.labeled` both carry `action` + full `issue` object. `issue.labels[].name` is stable. `issues-labeled` payload additionally carries a top-level `label` object with the just-added label. Template can iterate `issue.labels[].name` for the full label set via jq. |
| HOOK-04 | Listener handles Push-to-Main events and dispatches to correct profile | Supported by "Event Schema Reference" (push has NO action field), "Push Filter" skeleton, and "Loop Prevention" pattern. `ref` strips to branch name via `sub("^refs/heads/"; "")` jq expression. `pusher.name` is the canonical loop-check field. `compare` is top-level URL. `head_commit.{id,message,author.name}` are stable. |
| HOOK-05 | Listener handles CI Failure events (workflow_run completed with failure) and dispatches to correct profile | Supported by "Workflow Run Filter" skeleton. `action==completed` + `workflow_run.conclusion in ["failure"]` is the exact filter predicate. `workflow_run.name` is usually empty; use top-level `workflow.name` as the human-readable workflow name. `workflow_run.head_branch` is the branch name (not a ref). `workflow_run.head_sha` is the commit SHA. `workflow_run.html_url` is the GitHub UI link. |
| HOOK-07 | User can replay a stored webhook payload for debugging via CLI command | Supported by "Replay Subcommand Skeleton" — thin wrapper around Phase 13's `do_spawn --event-file`. Profile auto-resolution reuses Python listener's `resolve_profile_by_repo()` algorithm (glob + jq parse). Filename substring match is trivial bash. |

</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform:** Linux + WSL2. No macOS.
- **Host dependencies:** Docker, Docker Compose, curl, jq, uuidgen, bash, python3 (already installed for listener).
- **Security:** hook scripts, settings, whitelist root-owned and immutable.
- **Stdlib only:** Python listener + Node proxy + Python validator. **No pip, no npm for any new service.** Phase 15 does not add any package.
- **No Agent SDK:** template rendering happens host-side before piping into `docker compose exec -T claude claude -p`.
- **Bash + jq for shell helpers:** Phase 15 keeps all CLI extensions in bash.

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Python 3.11+ | already required by Phase 14 | Listener `compute_event_type`, `apply_event_filter` helpers | Phase 14 listener uses only stdlib. No new deps. |
| Bash 5.x | system | `resolve_template`, `render_template`, `replay`, new helper | Already the language of `bin/claude-secure`. |
| jq 1.7+ | system | Payload field extraction, filter dispatch | Already used throughout; zero risk. |
| python3 (stdlib) via one-liner | same | UTF-8-safe truncation + control-char strip helper | Bash-only UTF-8 truncation is error-prone; `python3 -c` is reliable and already available. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Inline filter check in `do_POST` | Separate `webhook/filter.py` module | Precedent is single-file services (validator, proxy, listener). Factor out only if `do_POST` exceeds ~200 lines after addition. |
| `python3 -c` truncation subshell | Pure bash byte-loop | bash solution is slow (subshell per character) and brittle on multi-byte; `python3 -c` is ~3ms per call and correct. |
| sed for variable substitution | awk with file-read pattern | sed fails on values containing the delimiter (`|`), newlines, backslashes. awk-file pattern already proven in `render_template` for `ISSUE_BODY` (lines 432-439). Use it for every variable, not just `ISSUE_BODY`. |
| In-memory profile cache for filter | Re-parse profile.json per request | Filter lookup is one extra jq read per request (~1ms) — insignificant vs the rest of the pipeline. Cache invalidation complexity is not worth it at webhook volume. |

**Installation:** Nothing new. All dependencies already satisfied by Phase 14.

**Version verification:** `python3 --version` already gated in `install.sh` line 296 (`>= 3.11`). No new binary requirements.

## Architecture Patterns

### Canonical Data Flow (Phase 15 additions in bold)

```
GitHub POST /webhook
    → read raw body                      [Phase 14, unchanged]
    → parse JSON                         [Phase 14, unchanged]
    → resolve profile by repo            [Phase 14, unchanged]
    → verify HMAC                        [Phase 14, unchanged]
    → **compute_event_type(headers, payload)**                  [NEW]
    → **apply_event_filter(profile, event_type, payload)**      [NEW]
    → if filtered: log 'filtered' + return 202 (NO persist)     [NEW]
    → persist_event(...)  (now writes top-level event_type)     [MODIFIED]
    → **log 'routed'**                                          [NEW]
    → spawn_async(profile, event_path, delivery_id)             [Phase 14, unchanged]
    → return 202
```

### Pattern 1: Composite Event Type Derivation
**What:** Collapse GitHub's (event, action) tuple into a single dash-joined string.
**When to use:** At listener request time, once per request, after HMAC verification.
**Example:**
```python
def compute_event_type(headers: dict, payload: dict) -> str:
    """Collapse (X-GitHub-Event, payload.action) into composite type.

    Examples:
        ('issues', 'opened')         -> 'issues-opened'
        ('issues', 'labeled')        -> 'issues-labeled'
        ('push', None)               -> 'push'
        ('workflow_run', 'completed')-> 'workflow_run-completed'
        ('ping', None)               -> 'ping'
    """
    base = (headers.get("X-GitHub-Event") or "").strip()
    if not base:
        return "unknown"
    action = payload.get("action") if isinstance(payload, dict) else None
    if isinstance(action, str) and action:
        return f"{base}-{action}"
    return base
```
**Verification:** `push` payload confirmed to have no `action` field. `issues` always has one. `workflow_run` has `requested`/`in_progress`/`completed`. `ping` (GitHub sends on webhook setup) has no action — treated as `ping`, fails filter, returns 202 cleanly.

### Pattern 2: Filter Predicate (Python dict-driven)
**What:** One function, one dispatch table keyed on the X-GitHub-Event base type. Returns `(allowed, reason)`.
**When to use:** Between HMAC verification and payload persistence. Must be sub-millisecond (no I/O beyond the profile read already done upstream).
**Example:**
```python
# Defaults when profile.webhook_event_filter is omitted (D-06)
DEFAULT_FILTER = {
    "issues": {"actions": ["opened", "labeled"], "labels": []},
    "push": {"branches": ["main", "master"]},
    "workflow_run": {"conclusions": ["failure"], "workflows": []},
}

def apply_event_filter(profile: dict, event_type: str, payload: dict) -> tuple:
    """Return (allowed: bool, reason: str). `reason` is empty when allowed."""
    base = event_type.split("-", 1)[0]
    fcfg = (profile.get("webhook_event_filter") or {}).get(base)
    if fcfg is None:
        fcfg = DEFAULT_FILTER.get(base)
    if fcfg is None:
        # Unknown base event type -- not an error, just filter out (D-04)
        return (False, f"unsupported_event:{base}")

    if base == "issues":
        action = payload.get("action", "")
        if fcfg.get("actions") and action not in fcfg["actions"]:
            return (False, f"issue_action_not_matched:{action}")
        required_labels = fcfg.get("labels") or []
        if required_labels:
            issue = payload.get("issue") or {}
            labels = {lbl.get("name", "") for lbl in issue.get("labels", []) if isinstance(lbl, dict)}
            if not labels.intersection(required_labels):
                return (False, "issue_labels_not_matched")
        return (True, "")

    if base == "push":
        # Loop prevention FIRST (D-09)
        bot_users = profile.get("webhook_bot_users") or []
        pusher = ((payload.get("pusher") or {}).get("name") or "")
        if pusher and pusher in bot_users:
            return (False, "loop_prevention")
        ref = payload.get("ref", "")
        branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
        allowed_branches = fcfg.get("branches") or []
        if allowed_branches and branch not in allowed_branches:
            return (False, f"branch_not_matched:{branch}")
        return (True, "")

    if base == "workflow_run":
        if payload.get("action") != "completed":
            return (False, f"workflow_action_not_completed:{payload.get('action')}")
        wr = payload.get("workflow_run") or {}
        conclusion = wr.get("conclusion") or ""
        allowed_conclusions = fcfg.get("conclusions") or []
        if allowed_conclusions and conclusion not in allowed_conclusions:
            return (False, f"workflow_conclusion_not_matched:{conclusion}")
        allowed_workflows = fcfg.get("workflows") or []
        if allowed_workflows:
            wf_name = (payload.get("workflow") or {}).get("name") or wr.get("name") or ""
            if wf_name not in allowed_workflows:
                return (False, f"workflow_name_not_matched:{wf_name}")
        return (True, "")

    return (False, f"unsupported_event:{base}")
```
**Key insight:** `base = event_type.split("-", 1)[0]` re-derives the X-GitHub-Event from the composite type so callers only need to pass the composite string. Loop prevention comes **before** branch matching so a bot push to `main` is still filtered.

### Pattern 3: Top-Level event_type Injection
**What:** Write `event_type` at the payload root alongside (not instead of) the existing `_meta.event_type`.
**When to use:** In `persist_event()`, right where `_meta` is already being injected.
**Modification to `webhook/listener.py` line 157:**
```python
payload = json.loads(raw_body)
payload["event_type"] = event_type           # NEW (D-02)
payload["_meta"] = {                          # existing
    "received_at": now.isoformat().replace("+00:00", "Z"),
    "profile": profile_name,
    "event_type": event_type,                # kept for backward compat (D-02)
    "delivery_id": delivery_id,
}
```

### Pattern 4: Template Fallback Chain (bash)
**What:** Extend `resolve_template()` with a third lookup level that falls back to `$WEBHOOK_TEMPLATES_DIR`.
**When to use:** After the existing explicit-flag and profile-level lookups fail but BEFORE the hard-fail error.
**Example (replaces `resolve_template` at `bin/claude-secure` lines 369-398):**
```bash
# Default fallback directory, detected once per spawn.
# $APP_DIR is already exported by $CONFIG_DIR/config.sh (see line 588 of bin/claude-secure).
_resolve_default_templates_dir() {
  if [ -n "${WEBHOOK_TEMPLATES_DIR:-}" ]; then
    echo "$WEBHOOK_TEMPLATES_DIR"
    return
  fi
  # Dev checkout: prefer repo templates if .git is present
  if [ -n "${APP_DIR:-}" ] && [ -d "$APP_DIR/.git" ] && [ -d "$APP_DIR/webhook/templates" ]; then
    echo "$APP_DIR/webhook/templates"
    return
  fi
  # Installed location (D-12)
  echo "/opt/claude-secure/webhook/templates"
}

resolve_template() {
  local event_type="$1"
  local explicit_template="${2:-}"

  local profile_dir="$CONFIG_DIR/profiles/$PROFILE"
  local prompts_dir="$profile_dir/prompts"

  # 1. Explicit flag -> profile prompts only (no fallback to defaults for explicit overrides)
  if [ -n "$explicit_template" ]; then
    local path="$prompts_dir/${explicit_template}.md"
    if [ -f "$path" ]; then echo "$path"; return 0; fi
    echo "ERROR: Template not found: $path (from --prompt-template)" >&2
    return 1
  fi

  # 2. Profile override
  if [ -d "$prompts_dir" ]; then
    local path="$prompts_dir/${event_type}.md"
    if [ -f "$path" ]; then echo "$path"; return 0; fi
  fi

  # 3. Default fallback (D-13 step 3)
  local default_dir
  default_dir=$(_resolve_default_templates_dir)
  if [ -d "$default_dir" ]; then
    local path="$default_dir/${event_type}.md"
    if [ -f "$path" ]; then echo "$path"; return 0; fi
  fi

  # 4. Hard fail (D-13 step 4)
  echo "ERROR: No template found for event_type '$event_type'" >&2
  echo "  Checked: $prompts_dir/${event_type}.md" >&2
  echo "  Checked: $default_dir/${event_type}.md" >&2
  echo "  Use --prompt-template to override, or create one of the above." >&2
  return 1
}
```
**Key behavior:** Explicit `--prompt-template <name>` **does NOT fall back to defaults**. The reasoning: an explicit override is a user assertion that a specific file exists; falling back silently would hide a typo. Profile-level resolution DOES fall back because auto-routing expects default templates to exist for unclaimed event types.

### Pattern 5: Safe Variable Substitution (the important one)
**What:** Replace `{{VAR}}` tokens in a rendered template without being vulnerable to delimiter characters in the replacement.
**Why sed is unsafe here:** The current `render_template` uses `sed "s|{{X}}|${var}|g"`. This breaks when the variable contains `|` (common in commit messages: `fix(api): wire up foo | refactor bar`), `\` (Windows paths, escape sequences in titles), or newlines (multiline commit messages, issue bodies).
**Reuse existing awk-file pattern:** `bin/claude-secure` lines 432-439 already proves the correct pattern for `ISSUE_BODY`. Phase 15 generalizes it.
**Example helper (new function):**
```bash
# Substitute a single {{TOKEN}} in a rendered template with the contents of a file.
# Works for arbitrary values including newlines, pipes, backslashes, ampersands.
_substitute_token_from_file() {
  local rendered="$1"
  local token="$2"         # e.g. ISSUE_TITLE (without the braces)
  local value_file="$3"    # path to a file containing the substitution value
  echo "$rendered" | awk -v token="{{${token}}}" -v vfile="$value_file" '
    index($0, token) > 0 {
      # Read value file once per match; print value where token appears.
      # For simplicity (and because templates rarely have the same token twice
      # on one line), do the substitution character-by-character via a helper.
      value = ""
      while ((getline line < vfile) > 0) {
        if (value == "") value = line
        else value = value "\n" line
      }
      close(vfile)
      # Split the line on the token and rejoin with the value
      n = split($0, parts, token)
      out = parts[1]
      for (i = 2; i <= n; i++) out = out value parts[i]
      print out
      next
    }
    { print }
  '
}
```
**Usage inside `render_template`:**
```bash
# Extract value, write to temp file, substitute via awk
local v_file
v_file=$(extract_payload_field "$event_json" '.issue.title // empty' "")
rendered=$(_substitute_token_from_file "$rendered" "ISSUE_TITLE" "$v_file")
```
**Caveat:** awk solution above assumes the token appears on a single line and the replacement is inlined there. For very large multiline values (like an 8KB issue body), the existing `/\{\{ISSUE_BODY\}\}/` pattern at lines 432-439 which emits the file contents line-by-line is actually better. **Recommendation:** keep both patterns — `_substitute_token_from_file` for short variables (titles, authors, URLs), `_substitute_multiline_token_from_file` (existing ISSUE_BODY branch) for `{{ISSUE_BODY}}`, `{{COMMIT_MESSAGE}}`, and any other variable known to be multiline.

### Pattern 6: Extract Payload Field Helper
**What:** One helper that (a) runs jq, (b) enforces length + control-char hygiene via `python3 -c`, (c) writes to a temp file, (d) returns the file path for awk-substitution.
**When to use:** Called once per template variable during `render_template`.
**Example:**
```bash
# Returns: path to a temp file containing the cleaned, truncated value.
# Side effect: appends the temp file path to $_CLEANUP_FILES (existing cleanup trap).
extract_payload_field() {
  local event_json="$1"
  local jq_path="$2"
  local default_value="${3:-}"

  local raw
  raw=$(echo "$event_json" | jq -r "$jq_path // empty" 2>/dev/null)
  if [ -z "$raw" ]; then
    raw="$default_value"
  fi

  local out_file
  out_file=$(mktemp)
  _CLEANUP_FILES+=("$out_file")

  # Hygiene via python3:
  #   1. Strip null bytes + ASCII control chars except \n \r \t   (D-18)
  #   2. Truncate to 8192 bytes UTF-8-safe; append ... [truncated N more bytes]   (D-17)
  #
  # python3 is already a hard dependency (install.sh:296). Input comes via stdin
  # to avoid argv size limits and shell escaping issues.
  printf '%s' "$raw" | python3 - "$out_file" <<'PY'
import sys
data = sys.stdin.buffer.read()
# 1. Strip control chars except \n \r \t
keep = {0x09, 0x0A, 0x0D}
cleaned = bytes(b for b in data if b >= 0x20 or b in keep)
# 2. UTF-8 safe truncation at 8192 bytes
LIMIT = 8192
if len(cleaned) > LIMIT:
    # Decode as UTF-8 with 'ignore' which drops incomplete trailing multi-byte
    # sequences rather than raising. Re-encode to get the true byte length.
    truncated = cleaned[:LIMIT].decode("utf-8", errors="ignore").encode("utf-8")
    dropped = len(cleaned) - len(truncated)
    suffix = f"... [truncated {dropped} more bytes]".encode("utf-8")
    cleaned = truncated + suffix
with open(sys.argv[1], "wb") as f:
    f.write(cleaned)
PY

  echo "$out_file"
}
```
**Performance:** ~3ms per call (python3 startup + trivial work). 12 variables × 3ms = ~36ms per spawn. Acceptable — the subsequent `docker compose up -d --wait` dwarfs this.

**UTF-8 truncation correctness proof:** `bytes[:LIMIT].decode("utf-8", errors="ignore")` at a mid-codepoint boundary drops the incomplete trailing bytes (ignore mode), then `.encode("utf-8")` round-trips to valid bytes. This is equivalent to the pattern used by `parshap/truncate-utf8-bytes` and is the canonical Python approach. No character-by-character iteration needed.

### Pattern 7: Extended render_template (new variables)

```bash
render_template() {
  local template_path="$1"
  local event_json="$2"

  local rendered
  rendered=$(cat "$template_path")

  # --- Common variables (all event types) ---
  local f
  f=$(extract_payload_field "$event_json" '.repository.full_name' "")
  rendered=$(_substitute_token_from_file "$rendered" "REPO_NAME" "$f")

  f=$(extract_payload_field "$event_json" '.event_type // ._meta.event_type // .action' "unknown")
  rendered=$(_substitute_token_from_file "$rendered" "EVENT_TYPE" "$f")

  # --- Issues variables ---
  f=$(extract_payload_field "$event_json" '.issue.number | tostring' "")
  rendered=$(_substitute_token_from_file "$rendered" "ISSUE_NUMBER" "$f")

  f=$(extract_payload_field "$event_json" '.issue.title' "")
  rendered=$(_substitute_token_from_file "$rendered" "ISSUE_TITLE" "$f")

  # ISSUE_LABELS: comma-join issue.labels[].name
  f=$(extract_payload_field "$event_json" '[.issue.labels[]?.name] | join(", ")' "")
  rendered=$(_substitute_token_from_file "$rendered" "ISSUE_LABELS" "$f")

  f=$(extract_payload_field "$event_json" '.issue.user.login' "")
  rendered=$(_substitute_token_from_file "$rendered" "ISSUE_AUTHOR" "$f")

  f=$(extract_payload_field "$event_json" '.issue.html_url' "")
  rendered=$(_substitute_token_from_file "$rendered" "ISSUE_URL" "$f")

  # --- Push variables ---
  f=$(extract_payload_field "$event_json" '.ref | sub("^refs/heads/"; "")' "")
  rendered=$(_substitute_token_from_file "$rendered" "BRANCH" "$f")

  f=$(extract_payload_field "$event_json" '.after // .head_commit.id' "")
  rendered=$(_substitute_token_from_file "$rendered" "COMMIT_SHA" "$f")

  f=$(extract_payload_field "$event_json" '.head_commit.author.name' "")
  rendered=$(_substitute_token_from_file "$rendered" "COMMIT_AUTHOR" "$f")

  f=$(extract_payload_field "$event_json" '.pusher.name' "")
  rendered=$(_substitute_token_from_file "$rendered" "PUSHER" "$f")

  f=$(extract_payload_field "$event_json" '.compare' "")
  rendered=$(_substitute_token_from_file "$rendered" "COMPARE_URL" "$f")

  # --- Workflow run variables ---
  # Prefer top-level workflow.name (human readable); fall back to workflow_run.name
  f=$(extract_payload_field "$event_json" '.workflow.name // .workflow_run.name' "")
  rendered=$(_substitute_token_from_file "$rendered" "WORKFLOW_NAME" "$f")

  f=$(extract_payload_field "$event_json" '.workflow_run.id | tostring' "")
  rendered=$(_substitute_token_from_file "$rendered" "WORKFLOW_RUN_ID" "$f")

  f=$(extract_payload_field "$event_json" '.workflow_run.conclusion' "")
  rendered=$(_substitute_token_from_file "$rendered" "WORKFLOW_CONCLUSION" "$f")

  f=$(extract_payload_field "$event_json" '.workflow_run.html_url' "")
  rendered=$(_substitute_token_from_file "$rendered" "WORKFLOW_RUN_URL" "$f")

  # --- BRANCH/COMMIT_SHA fallbacks for workflow_run (when .ref is absent) ---
  # If BRANCH is still literal {{BRANCH}}, try workflow_run.head_branch
  if echo "$rendered" | grep -q '{{BRANCH}}'; then
    f=$(extract_payload_field "$event_json" '.workflow_run.head_branch' "")
    rendered=$(_substitute_token_from_file "$rendered" "BRANCH" "$f")
  fi
  if echo "$rendered" | grep -q '{{COMMIT_SHA}}'; then
    f=$(extract_payload_field "$event_json" '.workflow_run.head_sha' "")
    rendered=$(_substitute_token_from_file "$rendered" "COMMIT_SHA" "$f")
  fi

  # --- Multiline values: ISSUE_BODY, COMMIT_MESSAGE (use existing awk pattern) ---
  # See Pattern 5 caveat: use line-by-line emission from file for long multiline values.
  # Reuse the existing ISSUE_BODY branch (lines 432-439) as the template, then add
  # COMMIT_MESSAGE via the same pattern.
  local issue_body commit_msg
  issue_body=$(echo "$event_json" | jq -r '.issue.body // empty')
  if [ -n "$issue_body" ]; then
    local body_file
    body_file=$(mktemp)
    _CLEANUP_FILES+=("$body_file")
    # Apply hygiene via python3 (same helper)
    printf '%s' "$issue_body" | python3 - "$body_file" <<'PY'
# (same hygiene script as extract_payload_field)
import sys
data = sys.stdin.buffer.read()
keep = {0x09, 0x0A, 0x0D}
cleaned = bytes(b for b in data if b >= 0x20 or b in keep)
LIMIT = 8192
if len(cleaned) > LIMIT:
    truncated = cleaned[:LIMIT].decode("utf-8", errors="ignore").encode("utf-8")
    dropped = len(cleaned) - len(truncated)
    cleaned = truncated + f"... [truncated {dropped} more bytes]".encode("utf-8")
with open(sys.argv[1], "wb") as f:
    f.write(cleaned)
PY
    rendered=$(echo "$rendered" | awk -v bodyfile="$body_file" '
      /\{\{ISSUE_BODY\}\}/ { while ((getline line < bodyfile) > 0) print line; close(bodyfile); next }
      { print }
    ')
  else
    rendered=$(echo "$rendered" | sed "s|{{ISSUE_BODY}}||g")
  fi

  # COMMIT_MESSAGE: same pattern as ISSUE_BODY
  commit_msg=$(echo "$event_json" | jq -r '.head_commit.message // empty')
  if [ -n "$commit_msg" ]; then
    local msg_file
    msg_file=$(mktemp)
    _CLEANUP_FILES+=("$msg_file")
    printf '%s' "$commit_msg" | python3 - "$msg_file" <<'PY'
import sys
data = sys.stdin.buffer.read()
keep = {0x09, 0x0A, 0x0D}
cleaned = bytes(b for b in data if b >= 0x20 or b in keep)
LIMIT = 8192
if len(cleaned) > LIMIT:
    truncated = cleaned[:LIMIT].decode("utf-8", errors="ignore").encode("utf-8")
    dropped = len(cleaned) - len(truncated)
    cleaned = truncated + f"... [truncated {dropped} more bytes]".encode("utf-8")
with open(sys.argv[1], "wb") as f:
    f.write(cleaned)
PY
    rendered=$(echo "$rendered" | awk -v msgfile="$msg_file" '
      /\{\{COMMIT_MESSAGE\}\}/ { while ((getline line < msgfile) > 0) print line; close(msgfile); next }
      { print }
    ')
  else
    rendered=$(echo "$rendered" | sed "s|{{COMMIT_MESSAGE}}||g")
  fi

  echo "$rendered"
}
```
**Refactor note:** the duplicated hygiene python3 block inside `render_template` for `ISSUE_BODY` and `COMMIT_MESSAGE` is ugly but follows the bash-heredoc precedent. The planner may extract a `_hygiene_to_file <tempfile>` helper that reads stdin; keeping the pattern in one place is cleaner.

### Pattern 8: event_type Extraction Priority (spawn entry)
**Modification to `bin/claude-secure` line 502:**
```bash
# Extract event_type from event JSON for envelope
# Priority (D-03): top-level .event_type (Phase 15) > ._meta.event_type (Phase 14) > .action (older)
local event_type
event_type=$(echo "$EVENT_JSON" | jq -r '.event_type // ._meta.event_type // .action // "unknown"')
```

### Pattern 9: Replay Subcommand (HOOK-07)
**New case in the CLI dispatcher (after `spawn)` at line 769):**
```bash
  replay)
    do_replay
    ;;
```
**New function:**
```bash
do_replay() {
  # Parse flags from REMAINING_ARGS (first is "replay")
  local delivery_substring=""
  local explicit_profile="${PROFILE:-}"
  local dry_run=0
  local i=1
  while [ $i -lt ${#REMAINING_ARGS[@]} ]; do
    case "${REMAINING_ARGS[$i]:-}" in
      --profile)  explicit_profile="${REMAINING_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
      --dry-run)  dry_run=1; i=$((i+1)) ;;
      *)
        if [ -z "$delivery_substring" ]; then
          delivery_substring="${REMAINING_ARGS[$i]}"
        fi
        i=$((i+1))
        ;;
    esac
  done

  if [ -z "$delivery_substring" ]; then
    echo "ERROR: replay requires a delivery-id substring" >&2
    echo "Usage: claude-secure replay <delivery-id> [--profile NAME] [--dry-run]" >&2
    return 1
  fi

  local events_dir="$CONFIG_DIR/events"
  if [ ! -d "$events_dir" ]; then
    echo "ERROR: events directory not found: $events_dir" >&2
    return 1
  fi

  # Find event files matching the substring (D-22)
  local matches=()
  shopt -s nullglob
  for f in "$events_dir"/*"${delivery_substring}"*.json; do
    matches+=("$f")
  done
  shopt -u nullglob

  if [ ${#matches[@]} -eq 0 ]; then
    echo "ERROR: no event file matching '$delivery_substring' in $events_dir" >&2
    return 1
  fi
  if [ ${#matches[@]} -gt 1 ]; then
    echo "ERROR: multiple event files match '$delivery_substring':" >&2
    for m in "${matches[@]}"; do echo "  $m" >&2; done
    echo "Narrow the substring and retry." >&2
    return 1
  fi

  local event_file="${matches[0]}"

  # Auto-resolve profile from repository.full_name if not explicit (D-21)
  if [ -z "$explicit_profile" ]; then
    local repo
    repo=$(jq -r '.repository.full_name // empty' "$event_file")
    if [ -z "$repo" ]; then
      echo "ERROR: cannot determine repository from $event_file -- pass --profile" >&2
      return 1
    fi
    explicit_profile=$(resolve_profile_by_repo "$repo") || return 1
  fi

  echo "Replaying $event_file as profile '$explicit_profile'..."

  # Delegate to spawn via a sub-invocation (keeps do_spawn untouched)
  # Note: REMAINING_ARGS is manipulated here because we are already inside the dispatcher.
  # Cleaner path: exec the CLI recursively.
  local args=(--profile "$explicit_profile" spawn --event-file "$event_file")
  [ "$dry_run" = 1 ] && args+=(--dry-run)
  exec "$0" "${args[@]}"
}
```
**Key insight:** `exec "$0" --profile X spawn --event-file Y` avoids reimplementing any `do_spawn` logic. It's a clean re-entry into the CLI. The `exec` replaces the shell, so no cleanup trap duplication.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UTF-8-safe byte truncation in bash | Character-iteration loop with `LC_ALL=C wc -c` | `python3 -c` one-liner with `bytes[:N].decode(errors='ignore').encode()` | Bash solutions are slow (subshell per char), brittle (grapheme clusters, combining characters), and hard to maintain. python3 is already a hard dep. |
| Variable substitution with arbitrary values | `sed "s|{{X}}|$val|g"` | `awk -v token -v value_file` reading from temp file | sed breaks on `\`, `|`, `&`, newlines. awk reading from a file is delimiter-agnostic and already proven in `render_template` for `ISSUE_BODY`. |
| GitHub payload schema inference | Grep through random blog examples | Use verified paths from octokit/webhooks reference payloads (documented in Event Schema Reference below) | Schemas are stable; octokit/webhooks is the canonical JSON reference. |
| JSON filter predicate | Python regex | Python stdlib dict lookups + simple `in` checks | O(1) dict access, zero deps, trivial to unit-test. |
| Multi-match filename search | find + filter pipelines | bash glob `"$events_dir"/*"$substring"*.json` | A single glob with `nullglob` is fewer lines and faster. |
| Profile-by-repo lookup in bash | Reimplement the Python listener's scan | Reuse `resolve_profile_by_repo()` already in `bin/claude-secure` at line 152 | Phase 12 shipped this; don't duplicate. |

**Key insight:** Every new capability in Phase 15 has a precedent either in existing bin/claude-secure code, in webhook/listener.py, or in Python stdlib. The phase is composition, not invention.

## Common Pitfalls

### Pitfall 1: The sed Substitution Bug
**What goes wrong:** Commit messages like `fix(api): handle | in header` or titles containing backslashes break the current `sed "s|{{X}}|$val|g"` pattern. The delimiter `|` inside the replacement terminates the sed expression early; `\n` in values is interpreted as a newline escape in sed's replacement context.
**Why it happens:** sed's substitute command interprets `&`, `\`, `/`, and any chosen delimiter character within the replacement string. There is no way to "escape all metacharacters safely" in sed without a pre-pass that itself has escaping bugs.
**How to avoid:** Use the awk-file pattern (Pattern 5) for **every** variable. Do not trust sed with any payload-derived string.
**Warning signs:** Tests pass with the example fixtures but fail when a real GitHub payload contains a commit message with a pipe or a multiline body. Unit tests **must** include a fixture with a pipe character in at least one substituted variable.

### Pitfall 2: `compare_digest` Timing Safety (unrelated to Phase 15 but retain)
**What goes wrong:** N/A — Phase 14 already uses `hmac.compare_digest`. Phase 15 does not touch HMAC logic. Retained as a reminder: filter changes must be inserted **after** HMAC verification, never before.
**Warning signs:** If a Phase 15 patch adds filter logic that reads the payload before the HMAC check, that is a regression — revert.

### Pitfall 3: Filter Logic Performance Regression
**What goes wrong:** Filter check does a profile.json re-read or unbounded regex match, pushing request handling over GitHub's 10-second delivery timeout.
**Why it happens:** Naive implementation re-parses profile.json from disk inside the filter call. The profile is already loaded upstream (`resolve_profile_by_repo`) and can be passed into the filter function by reference.
**How to avoid:** `apply_event_filter(profile: dict, ...)` takes the already-loaded profile dict. Zero I/O. Dict lookups only. Verify with a benchmark test that filter evaluation is <1ms.
**Warning signs:** `webhook.jsonl` timestamps show >100ms between `received` and `routed`/`filtered` for simple payloads. Profile in memory but filter still slow → look for accidental `json.loads` inside the filter.

### Pitfall 4: The `ping` Event
**What goes wrong:** GitHub sends a `ping` webhook event immediately after webhook creation. It has no `action` field and no `issue`/`push`/`workflow_run` content, but it **does** have a valid `repository.full_name` and a valid HMAC. Phase 14's listener happily forwards it to spawn, which hard-fails template resolution.
**Why it happens:** Phase 14 did not filter on event type — it spawned for anything with a valid signature and a known repo.
**How to avoid:** Phase 15's filter naturally catches this: `base = "ping"` is not in `DEFAULT_FILTER`, so `apply_event_filter` returns `(False, "unsupported_event:ping")`. The event is logged as filtered and NOT spawned. Verify with a fixture `tests/fixtures/github-ping.json`.
**Warning signs:** fresh webhook setup in GitHub UI triggers an immediate failed spawn. After Phase 15, it should produce a single `filtered` log line and zero spawns.

### Pitfall 5: `issue.labels[]` Iteration Gotcha (labeled action)
**What goes wrong:** `issues.labeled` payload has BOTH the full `issue.labels[]` array (all labels currently on the issue after this action) AND a top-level `label` object (the single label that was just added). Template authors may want one or the other.
**Why it happens:** GitHub's semantics. For HOOK-03, the `ISSUE_LABELS` variable should be the full label set (`issue.labels[].name` comma-joined) — that is what the template recipient wants to reason about. Phase 15 does not expose the "just-added" label as a separate variable; if users want it, they override the template and use `--prompt-template` with a custom renderer (future enhancement).
**How to avoid:** Document in the default `issues-labeled.md` template that `{{ISSUE_LABELS}}` is the full current label set. If the user cares about the triggering label specifically, Phase 17+ can add `{{TRIGGERING_LABEL}}` sourced from top-level `.label.name`.
**Warning signs:** Default template sounds like "a label was just added: X" but shows all labels. Fix by rewording to "current labels on this issue: {{ISSUE_LABELS}}".

### Pitfall 6: `workflow_run.name` Is Usually Empty
**What goes wrong:** Template shows a blank workflow name.
**Why it happens:** GitHub populates the human-readable workflow name at top-level `workflow.name`, not `workflow_run.name`. `workflow_run.name` is the **run** name (often empty or auto-generated).
**How to avoid:** Always prefer `.workflow.name` and fall back to `.workflow_run.name`. See Pattern 7 jq expression: `'.workflow.name // .workflow_run.name'`. Document this in the template comment.
**Warning signs:** `{{WORKFLOW_NAME}}` renders as an empty string even though the GitHub Actions page shows "CI". Fix by adding the `.workflow.name` fallback.

### Pitfall 7: Push-from-Branch-Delete Has Null head_commit
**What goes wrong:** A push that deletes a branch (force-push of no-commits) has `head_commit: null`. Any jq expression that dereferences `.head_commit.message` raises a null error.
**Why it happens:** GitHub's push payload schema explicitly allows `head_commit` to be null when `deleted: true`.
**How to avoid:** Use `jq -r` with `// empty` fallbacks (already the pattern in render_template). The filter also naturally rejects deletions if the branch matches (a branch delete still carries `ref: refs/heads/X`), so the filter alone does not protect us — render_template must handle null.
**Warning signs:** Spawn fails with `jq: error: Cannot index null` on rare push events. Add a regression test fixture `tests/fixtures/github-push-branch-delete.json` with `head_commit: null`.

### Pitfall 8: Branch Rename or `ref: refs/tags/X`
**What goes wrong:** Push of a tag has `ref: refs/tags/v1.0`, not `refs/heads/*`. The filter's branch prefix-strip leaves `refs/tags/v1.0` as the "branch" and the exact-match check against `["main", "master"]` fails — correctly filtered. But the `BRANCH` template variable then becomes `refs/tags/v1.0` which is weird.
**How to avoid:** The filter rejects this case before render_template runs, so template variables are moot. Document it: "push filter matches refs/heads/* only; tag pushes are silently filtered."
**Warning signs:** User expects a tag push to trigger a spawn. Explain the filter scope.

### Pitfall 9: WEBHOOK_TEMPLATES_DIR Not Set Under systemd
**What goes wrong:** systemd-launched listener does NOT set `WEBHOOK_TEMPLATES_DIR` by default, but the listener doesn't need it — the listener never renders templates. However, `bin/claude-secure spawn` inherits the systemd environment only through the subprocess chain from `listener.py`, which runs as root with an almost-empty environment. When the subprocess invokes `resolve_template`, `$WEBHOOK_TEMPLATES_DIR` is unset, and the dev-fallback `.git` check may falsely match if `/opt/claude-secure` has any git metadata.
**How to avoid:** `_resolve_default_templates_dir` defaults to `/opt/claude-secure/webhook/templates` when `$APP_DIR/.git` is absent (production) and only falls back to `$APP_DIR/webhook/templates` in dev checkouts where the repo's .git directory is visible. `install.sh` does NOT copy .git into `/opt/claude-secure`, so the production check is unambiguous. Verify with an install smoke test: `grep -r '.git' /opt/claude-secure` should be empty.
**Warning signs:** Templates resolve to the repo copy even in production. Root cause: `.git` found somewhere under `$APP_DIR`. Fix by tightening the check.

### Pitfall 10: Duplicate Substitution from `--prompt-template` + Auto-Routing
**What goes wrong:** User passes `--prompt-template issues-opened` at the same time the event has composite type `issues-opened`. Both lookups succeed. The code path uses the explicit one (correct per D-13 step 1).
**Why it happens:** Not a bug — documenting so planner doesn't "optimize" by removing the explicit branch.
**How to avoid:** Keep the explicit branch strictly before the event-type branch. Tests verify that `--prompt-template foo` looks for `foo.md` **only** in the profile's `prompts/` directory, never falling back to defaults.
**Warning signs:** A `--prompt-template` test that expects a hard-fail passes because it accidentally resolved via the fallback. Re-check ordering.

## Event Schema Reference

**Source:** octokit/webhooks reference payloads (verified HIGH confidence).

### `issues` (actions: opened, labeled, closed, reopened, ...)
```json
{
  "action": "opened",
  "issue": {
    "number": 1,
    "title": "Spelling error in the README file",
    "body": "It looks like you accidentally spelled 'commit' with two 't's.",
    "html_url": "https://github.com/Codertocat/Hello-World/issues/1",
    "user": { "login": "Codertocat", ... },
    "labels": [
      {
        "id": 1362934389,
        "node_id": "...",
        "url": "...",
        "name": "bug",
        "color": "d73a4a",
        "default": true,
        "description": "Something isn't working"
      }
    ]
  },
  "label": { /* only on action=labeled: the label that was just added */ },
  "repository": { "full_name": "Codertocat/Hello-World", ... },
  "sender": { ... }
}
```
**Variables jq paths:**
- `ISSUE_NUMBER`: `.issue.number | tostring`
- `ISSUE_TITLE`: `.issue.title`
- `ISSUE_BODY`: `.issue.body`
- `ISSUE_LABELS`: `[.issue.labels[]?.name] | join(", ")`
- `ISSUE_AUTHOR`: `.issue.user.login`
- `ISSUE_URL`: `.issue.html_url`

### `push` (NO action field)
```json
{
  "ref": "refs/heads/main",
  "before": "0000000000000000000000000000000000000000",
  "after": "abc123...",
  "created": false,
  "deleted": false,
  "forced": false,
  "compare": "https://github.com/.../compare/abc...def",
  "head_commit": {
    "id": "def456...",
    "message": "Fix the thing",
    "author": { "name": "Jane Doe", "email": "jane@example.com" },
    ...
  },
  "pusher": { "name": "janedoe", "email": "jane@example.com" },
  "repository": { "full_name": "org/repo", ... },
  "sender": { ... }
}
```
**Variables jq paths:**
- `BRANCH`: `.ref | sub("^refs/heads/"; "")`
- `COMMIT_SHA`: `.after // .head_commit.id`
- `COMMIT_MESSAGE`: `.head_commit.message` (handle null on branch delete)
- `COMMIT_AUTHOR`: `.head_commit.author.name`
- `PUSHER`: `.pusher.name`
- `COMPARE_URL`: `.compare`

### `workflow_run` (actions: requested, in_progress, completed)
```json
{
  "action": "completed",
  "workflow_run": {
    "id": 289782451,
    "name": "",
    "head_branch": "master",
    "head_sha": "3484a3fb816e0859fd6e1cea078d76385ff50625",
    "conclusion": "success",
    "status": "completed",
    "html_url": "https://github.com/.../actions/runs/289782451",
    ...
  },
  "workflow": {
    "id": 123,
    "name": "test",
    "path": ".github/workflows/test.yml",
    ...
  },
  "repository": { "full_name": "org/repo", ... },
  "sender": { ... }
}
```
**Conclusion values (HIGH confidence, official GitHub docs):**
- `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`, `action_required`

**Variables jq paths:**
- `WORKFLOW_NAME`: `.workflow.name // .workflow_run.name` (prefer top-level)
- `WORKFLOW_RUN_ID`: `.workflow_run.id | tostring`
- `WORKFLOW_CONCLUSION`: `.workflow_run.conclusion`
- `BRANCH`: `.workflow_run.head_branch`
- `COMMIT_SHA`: `.workflow_run.head_sha`
- `WORKFLOW_RUN_URL`: `.workflow_run.html_url`

## Default Template Content (webhook/templates/)

These are the actual shipped templates. Tone: brief, action-oriented, English. Each is designed to work on its own without profile overrides.

### `webhook/templates/issues-opened.md`
```markdown
A new GitHub issue was opened in {{REPO_NAME}}.

**Issue #{{ISSUE_NUMBER}}:** {{ISSUE_TITLE}}
**Author:** {{ISSUE_AUTHOR}}
**URL:** {{ISSUE_URL}}
**Labels:** {{ISSUE_LABELS}}

**Body:**
{{ISSUE_BODY}}

---

Please:
1. Read the issue carefully and check the repository README and any contributing guidelines.
2. If the issue is a bug report with a reproducible failure, investigate the cause in the codebase.
3. If it is a feature request, evaluate feasibility and scope.
4. Post a substantive comment on the issue using `gh issue comment {{ISSUE_NUMBER}} --repo {{REPO_NAME}} --body "..."` that acknowledges the report, asks any clarifying questions, and outlines next steps.

Do not make code changes in this session. Your output is a comment on the issue, not a patch.
```

### `webhook/templates/issues-labeled.md`
```markdown
An issue in {{REPO_NAME}} was labeled.

**Issue #{{ISSUE_NUMBER}}:** {{ISSUE_TITLE}}
**Author:** {{ISSUE_AUTHOR}}
**URL:** {{ISSUE_URL}}
**Current labels:** {{ISSUE_LABELS}}

**Body:**
{{ISSUE_BODY}}

---

A label change occurred on this issue. Inspect the current label set and determine whether any automated action is appropriate:
- If a label like `good-first-issue` or `help-wanted` is now present, post a welcome comment on the issue.
- If a label like `bug` or `regression` is newly present, triage the issue: check if it reproduces on main.
- If none of the labels match an automation you recognize, exit without action.

Use `gh issue view {{ISSUE_NUMBER}} --repo {{REPO_NAME}}` to read the full issue context. Post comments via `gh issue comment`. Do not modify code.
```

### `webhook/templates/push.md`
```markdown
A push landed on branch `{{BRANCH}}` of {{REPO_NAME}}.

**Commit:** {{COMMIT_SHA}}
**Author:** {{COMMIT_AUTHOR}}
**Pusher:** {{PUSHER}}
**Compare:** {{COMPARE_URL}}

**Message:**
{{COMMIT_MESSAGE}}

---

Please investigate this push:
1. Fetch the latest state with `git fetch` and `git checkout {{BRANCH}}`.
2. Review the diff introduced by this commit: `git show {{COMMIT_SHA}}`.
3. If the change touches documentation, verify links and TOC.
4. If the change touches code, run the test suite (find the test command in README, Makefile, or package.json).
5. Post a short summary of what you found as a comment on the most recently-opened related PR if one exists, otherwise log your findings to a local file.

Do not push any new commits in this session.
```

### `webhook/templates/workflow_run-completed.md`
```markdown
A CI workflow failed on {{REPO_NAME}}.

**Workflow:** {{WORKFLOW_NAME}}
**Run ID:** {{WORKFLOW_RUN_ID}}
**Branch:** {{BRANCH}}
**Commit:** {{COMMIT_SHA}}
**Conclusion:** {{WORKFLOW_CONCLUSION}}
**Run URL:** {{WORKFLOW_RUN_URL}}

---

Please diagnose the failure:
1. Fetch the run logs with `gh run view {{WORKFLOW_RUN_ID}} --repo {{REPO_NAME}} --log-failed`.
2. Identify the specific step and command that failed.
3. Check out the failing commit: `git fetch && git checkout {{COMMIT_SHA}}`.
4. Reproduce the failure locally if possible.
5. Propose a fix in a comment on the commit: `gh api repos/{{REPO_NAME}}/commits/{{COMMIT_SHA}}/comments -f body="..."`, or open an issue with the diagnosis.

Do not push a fix directly to `{{BRANCH}}`. Your deliverable is a diagnosis comment, not a patch.
```

**Template authoring principles:**
1. Lead with the facts (what, where, who).
2. One imperative instruction block with numbered steps.
3. Explicitly tell Claude what NOT to do (do not push, do not merge) because `--dangerously-skip-permissions` is on.
4. Use `gh` CLI commands with full flags so the spawned session knows the exact invocation.
5. Never assume any single repo layout — always instruct Claude to check README/Makefile/package.json first.

## Test Fixtures Needed

Phase 15 needs these new fixtures in addition to the two existing ones. All must be well-formed GitHub webhook payloads with `repository.full_name = "test-org/test-repo"` so they match the existing test profile.

| Fixture | Purpose | Key Fields |
|---------|---------|------------|
| `tests/fixtures/github-issues-opened.json` | **Existing** — reuse for HOOK-03 routing tests | `action=opened`, `issue.labels=[]` |
| `tests/fixtures/github-issues-labeled.json` | **NEW** — HOOK-03 labeled routing + labels array | `action=labeled`, `issue.labels=[{name:"bug"}]`, top-level `label` |
| `tests/fixtures/github-push.json` | **Existing** — reuse for HOOK-04 routing tests (push to main) | `ref=refs/heads/main`, full `head_commit` |
| `tests/fixtures/github-push-feature-branch.json` | **NEW** — HOOK-04 filter rejection test | `ref=refs/heads/feature/xyz`, otherwise identical to `push.json` |
| `tests/fixtures/github-push-bot-loop.json` | **NEW** — HOOK-04 loop prevention test | `ref=refs/heads/main`, `pusher.name="claude-bot"` |
| `tests/fixtures/github-push-branch-delete.json` | **NEW** — regression for Pitfall 7 (null head_commit) | `ref=refs/heads/old`, `deleted=true`, `head_commit=null` |
| `tests/fixtures/github-workflow-run-failure.json` | **NEW** — HOOK-05 primary test | `action=completed`, `workflow_run.conclusion="failure"`, `workflow.name="CI"` |
| `tests/fixtures/github-workflow-run-success.json` | **NEW** — HOOK-05 filter rejection test | `action=completed`, `workflow_run.conclusion="success"` |
| `tests/fixtures/github-workflow-run-in-progress.json` | **NEW** — filter rejection on non-completed action | `action=in_progress`, `workflow_run.conclusion=null` |
| `tests/fixtures/github-ping.json` | **NEW** — regression for Pitfall 4 | `zen="..."`, `hook_id=123`, `repository.full_name="test-org/test-repo"` (no action, no issue) |
| `tests/fixtures/github-issues-opened-with-pipe.json` | **NEW** — regression for Pitfall 1 (sed bug) | `issue.title="fix(api): handle | in header"`, `issue.body` with `|` and `\` |

Each fixture should be the minimum valid payload — don't paste GitHub's full response. Follow the style of existing `github-issues-opened.json` (17 lines).

## Runtime State Inventory

> Phase 15 is an extension phase — not a rename/refactor. Runtime state is limited to new directories and new profile.json fields.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — Phase 15 adds no new stored state beyond continuing to write to `~/.claude-secure/events/` (Phase 14 location). Existing events with only `_meta.event_type` remain readable because Pattern 8 falls back to `._meta.event_type`. | None — backward compat preserved. |
| Live service config | None — no long-running services register the composite event type anywhere. | None. |
| OS-registered state | None — systemd unit unchanged, no new timers or services. | None. |
| Secrets/env vars | New env var `WEBHOOK_TEMPLATES_DIR` is read by `bin/claude-secure resolve_template`. Default is `/opt/claude-secure/webhook/templates`. No secret. | Documented in README + config.example.json comment. |
| Build artifacts | `/opt/claude-secure/webhook/templates/` is a **new directory** populated by `install.sh install_webhook_service()`. | Installer must `mkdir -p` and `cp webhook/templates/*.md` on every run. |

**Backward compat check:** Phase 14 event files written under `~/.claude-secure/events/` have only `_meta.event_type`, not top-level `event_type`. Phase 15's extraction priority (`.event_type // ._meta.event_type // .action`) handles this. HOOK-07 replay of pre-Phase-15 event files continues to work.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.11+ | Listener (extend) + `extract_payload_field` helper | Verified by install.sh line 296 gate | 3.11+ | — (hard required) |
| jq 1.7+ | render_template, resolve_profile_by_repo, filter fixture inspection | Already required by project | 1.7+ | — |
| awk (POSIX) | `_substitute_token_from_file` | System default (gawk or mawk both work) | any POSIX | — |
| bash 5.x | bin/claude-secure | Required by Phase 13 | 5.x | — |
| GitHub webhook payloads (network) | N/A — tests use fixtures | N/A | N/A | N/A |

**Missing dependencies with no fallback:** None. Every new capability uses an already-installed dep.

**Missing dependencies with fallback:** None.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash integration tests with stub `claude-secure` on `$PATH` (inherits Phase 14's `test-phase14.sh` harness pattern) |
| Config file | none — test config generated inline per `tests/test-phase15.sh` invocation |
| Quick run command | `bash tests/test-phase15.sh <test_name>` (single-test invocation) |
| Full suite command | `bash tests/test-phase15.sh` |
| Phase 13 regression | `bash tests/test-phase13.sh` — must stay green |
| Phase 14 regression | `bash tests/test-phase14.sh` — must stay green |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| HOOK-03 | `issues-opened` on known repo persists event with top-level `event_type=issues-opened` and spawns | integration | `bash tests/test-phase15.sh test_issues_opened_routes` | ❌ Wave 0 |
| HOOK-03 | `issues-labeled` with matching label filter persists + spawns | integration | `bash tests/test-phase15.sh test_issues_labeled_routes` | ❌ Wave 0 |
| HOOK-03 | `issues-closed` (filtered out by default actions list) → 202 but NO event file, NO spawn, log `event=filtered reason=issue_action_not_matched` | integration | `bash tests/test-phase15.sh test_issues_closed_filtered` | ❌ Wave 0 |
| HOOK-03 | Default template `webhook/templates/issues-opened.md` exists and contains required variables | file | `bash tests/test-phase15.sh test_default_template_issues_opened_exists` | ❌ Wave 0 |
| HOOK-04 | Push to `refs/heads/main` with valid repo → 202, event persisted, spawn fires | integration | `bash tests/test-phase15.sh test_push_main_routes` | ❌ Wave 0 |
| HOOK-04 | Push to `refs/heads/feature/xyz` → 202 but filtered (`reason=branch_not_matched`) | integration | `bash tests/test-phase15.sh test_push_feature_branch_filtered` | ❌ Wave 0 |
| HOOK-04 | Push from bot in `webhook_bot_users` → filtered (`reason=loop_prevention`) | integration | `bash tests/test-phase15.sh test_push_bot_loop_filtered` | ❌ Wave 0 |
| HOOK-04 | Push with `head_commit=null` (branch delete) → regression for Pitfall 7 | integration | `bash tests/test-phase15.sh test_push_branch_delete_no_crash` | ❌ Wave 0 |
| HOOK-05 | workflow_run `action=completed`, `conclusion=failure` → routes | integration | `bash tests/test-phase15.sh test_workflow_run_failure_routes` | ❌ Wave 0 |
| HOOK-05 | workflow_run `action=completed`, `conclusion=success` → filtered | integration | `bash tests/test-phase15.sh test_workflow_run_success_filtered` | ❌ Wave 0 |
| HOOK-05 | workflow_run `action=in_progress` → filtered (wrong action) | integration | `bash tests/test-phase15.sh test_workflow_run_in_progress_filtered` | ❌ Wave 0 |
| HOOK-05 | Default template `webhook/templates/workflow_run-completed.md` exists and renders with all required variables | unit (spawn --dry-run) | `bash tests/test-phase15.sh test_workflow_template_dry_run` | ❌ Wave 0 |
| HOOK-07 | `claude-secure replay <substring>` finds matching event file and invokes spawn via `exec` | integration | `bash tests/test-phase15.sh test_replay_finds_single_match` | ❌ Wave 0 |
| HOOK-07 | `replay` with ambiguous substring → error listing candidates | integration | `bash tests/test-phase15.sh test_replay_ambiguous_errors` | ❌ Wave 0 |
| HOOK-07 | `replay` with no matches → error | integration | `bash tests/test-phase15.sh test_replay_no_match_errors` | ❌ Wave 0 |
| HOOK-07 | `replay` auto-resolves profile from `repository.full_name` | integration | `bash tests/test-phase15.sh test_replay_auto_profile` | ❌ Wave 0 |
| D-01/D-02 | `compute_event_type` unit: `(issues, opened) -> issues-opened`, `(push, None) -> push`, `(ping, None) -> ping` | unit (python -c) | `bash tests/test-phase15.sh test_compute_event_type_cases` | ❌ Wave 0 |
| D-04 | `ping` event (unsupported) → 202, filtered, no spawn — regression for Pitfall 4 | integration | `bash tests/test-phase15.sh test_ping_event_filtered` | ❌ Wave 0 |
| D-17/D-18 | `extract_payload_field` truncates oversized strings to 8192 bytes with suffix and strips NUL bytes | unit (bash function test) | `bash tests/test-phase15.sh test_extract_field_truncates` | ❌ Wave 0 |
| D-17 | UTF-8 truncation does not split a multi-byte codepoint at the boundary | unit | `bash tests/test-phase15.sh test_extract_field_utf8_safe` | ❌ Wave 0 |
| Pitfall 1 | `render_template` with `{{ISSUE_TITLE}}` = `fix(api): handle \| in header` substitutes correctly (no sed escape bug) | unit | `bash tests/test-phase15.sh test_render_handles_pipe_in_value` | ❌ Wave 0 |
| Pitfall 1 | `render_template` with `{{COMMIT_MESSAGE}}` containing a backslash substitutes correctly | unit | `bash tests/test-phase15.sh test_render_handles_backslash_in_value` | ❌ Wave 0 |
| D-13 | Template resolution order: explicit flag → profile prompts → default fallback → hard fail | unit | `bash tests/test-phase15.sh test_resolve_template_fallback_chain` | ❌ Wave 0 |
| D-13 | `--prompt-template` does NOT fall back to defaults (by design) | unit | `bash tests/test-phase15.sh test_explicit_template_no_default_fallback` | ❌ Wave 0 |
| D-15 | `WEBHOOK_TEMPLATES_DIR` override wins over auto-detection | unit | `bash tests/test-phase15.sh test_webhook_templates_dir_env_var` | ❌ Wave 0 |
| D-12 | `install.sh --with-webhook` copies `webhook/templates/` to `/opt/claude-secure/webhook/templates/` | grep contract | `bash tests/test-phase15.sh test_install_copies_templates_dir` | ❌ Wave 0 |
| D-02 | Persisted event file has top-level `event_type` field alongside `_meta.event_type` | integration | `bash tests/test-phase15.sh test_event_file_has_top_level_event_type` | ❌ Wave 0 |
| D-03 | Spawn's event_type extraction prefers `.event_type` over `._meta.event_type` over `.action` | unit | `bash tests/test-phase15.sh test_spawn_event_type_priority` | ❌ Wave 0 |
| Regression | Phase 13 test suite still green after bin/claude-secure edits | integration | `bash tests/test-phase13.sh` | ✅ |
| Regression | Phase 14 test suite still green after listener.py edits | integration | `bash tests/test-phase14.sh` | ✅ |

### Sampling Rate

- **Per task commit:** `bash tests/test-phase15.sh <single_test_name>` (fast, ~2s per test case)
- **Per wave merge:** `bash tests/test-phase15.sh` (full Phase 15 suite, ~30s with listener startup)
- **Phase gate (before `/gsd:verify-work`):** All three suites green:
  ```
  bash tests/test-phase13.sh && \
  bash tests/test-phase14.sh && \
  bash tests/test-phase15.sh
  ```

### Wave 0 Gaps

- [ ] `tests/test-phase15.sh` — does not exist. Must be created by Wave 0 (stub tests per sampling map above, many FAIL until implementation lands).
- [ ] `tests/fixtures/github-issues-labeled.json` — new fixture
- [ ] `tests/fixtures/github-push-feature-branch.json` — new fixture
- [ ] `tests/fixtures/github-push-bot-loop.json` — new fixture
- [ ] `tests/fixtures/github-push-branch-delete.json` — new fixture (Pitfall 7 regression)
- [ ] `tests/fixtures/github-workflow-run-failure.json` — new fixture
- [ ] `tests/fixtures/github-workflow-run-success.json` — new fixture
- [ ] `tests/fixtures/github-workflow-run-in-progress.json` — new fixture
- [ ] `tests/fixtures/github-ping.json` — new fixture (Pitfall 4 regression)
- [ ] `tests/fixtures/github-issues-opened-with-pipe.json` — new fixture (Pitfall 1 regression)
- [ ] `webhook/templates/issues-opened.md` — source file
- [ ] `webhook/templates/issues-labeled.md` — source file
- [ ] `webhook/templates/push.md` — source file
- [ ] `webhook/templates/workflow_run-completed.md` — source file

**Framework install:** None needed. Uses bash + curl + jq + uuidgen + python3, all already required.

**Stub harness reuse:** `tests/test-phase15.sh` should source `tests/test-phase14.sh`'s `install_stub`, `setup_test_profile`, `start_listener`, `gen_sig` functions via `source`, OR copy them. Recommend: copy (tests should be self-contained for isolation).

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `sed` for template substitution | `awk` with file-based token replacement | Phase 15 | Safe against arbitrary payload content. No regression in Phase 13 because `ISSUE_BODY` was already handled this way. |
| Bash byte-loop for UTF-8 truncation | `python3 -c` one-liner using `bytes[:N].decode(errors='ignore').encode()` | Phase 15 | Correct, fast enough, one dep (already required). |
| Event type as raw `X-GitHub-Event` header | Composite `<event>-<action>` string | Phase 15 | Enables human-readable template names (`issues-opened.md`) and filter dispatch. |

## Open Questions

1. **Should `extract_payload_field` be a sourceable helper or a sibling python3 script?**
   - What we know: CONTEXT marks this as Claude's Discretion. Bash + jq + python3 subshell is the path of least resistance.
   - What's unclear: If the subshell overhead ever becomes measurable (it will not, but just in case), is there value in rewriting render_template as a single python3 script?
   - Recommendation: ship the bash helper now. If render_template ever grows past ~300 lines, revisit.

2. **Should the `replay` subcommand support `--event <json>` for testing without a persisted file?**
   - What we know: CONTEXT says replay is "intentionally thin" — just a file finder + spawn wrapper.
   - What's unclear: Nothing — this is a deferred convenience. Phase 13's `spawn --event` already handles JSON strings directly.
   - Recommendation: do NOT add `--event` to replay. Keep the separation clean.

3. **Should the filter module live in `webhook/filter.py` or inline in `listener.py`?**
   - What we know: single-file precedent (validator, proxy, current listener).
   - What's unclear: After adding `compute_event_type` + `apply_event_filter` + DEFAULT_FILTER dict + the new log events, listener.py will be ~500 lines. Still single-file-viable but getting dense.
   - Recommendation: keep inline. Extract only if a future phase needs filter logic elsewhere.

## Sources

### Primary (HIGH confidence)
- `.planning/phases/15-event-handlers/15-CONTEXT.md` — all locked decisions (D-01 through D-24)
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — listener architecture, persistence path, webhook.jsonl schema
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` — spawn contract, template resolution, variable substitution
- `webhook/listener.py` (current shipped Phase 14 file) — insertion points at lines 157 (_meta injection), 341 (post-HMAC), 380 (persistence), 359 (event_type header extraction)
- `bin/claude-secure` (current shipped Phase 13 file) — resolve_template at line 369, render_template at line 400, spawn entry at line 447, event_type extraction at line 502, case statement at line 646
- GitHub webhook event docs (https://docs.github.com/en/webhooks/webhook-events-and-payloads) — action values, required fields, 10-second delivery window
- octokit/webhooks reference payloads (https://github.com/octokit/webhooks) — verified shape of `issues.opened`, `push`, `workflow_run.completed`

### Secondary (MEDIUM confidence)
- WebSearch on bash UTF-8 truncation — confirmed the problem is well-known and Python is the canonical fix. Multiple sources (Wikipedia UTF-8, openillumi.com, joernhees.de) agree that byte-level truncation on a boundary requires special handling.
- GitHub Actions workflow_run conclusion enum — confirmed via GitHub docs page for workflow_run: `success, failure, neutral, cancelled, skipped, timed_out, action_required`.

### Tertiary (LOW confidence)
- None — all load-bearing claims verified against at least two sources or first-party code.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all tools already installed, no version drift risk
- Architecture: HIGH — composition of Phase 13 and 14 proven patterns, insertion points are one-line changes
- Pitfalls: HIGH — Pitfall 1 (sed bug) is observable in the current code at lines 418-421 of bin/claude-secure, Pitfall 4 (ping event) is reproducible, Pitfall 6 (workflow_run.name empty) confirmed against reference payload
- Template content: HIGH — four template files specified in full
- Test map: HIGH — 28 automated tests mapped to 4 requirements + 24 design assertions + 2 regression suites

**Research date:** 2026-04-12
**Valid until:** 2026-05-12 (30 days — GitHub webhook schemas are stable, one-month window is safe)
