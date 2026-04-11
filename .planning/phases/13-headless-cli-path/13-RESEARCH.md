# Phase 13: Headless CLI Path - Research

**Researched:** 2026-04-11
**Domain:** Bash CLI, Docker Compose orchestration, Claude Code non-interactive execution
**Confidence:** HIGH

## Summary

Phase 13 adds a `spawn` subcommand to `bin/claude-secure` that runs Claude Code non-interactively inside the existing Docker security stack. The implementation is entirely in bash, building on the profile system from Phase 12. Each spawn creates an ephemeral Docker Compose project (`cs-<profile>-<uuid8>`), executes a prompt built from a template with variable substitution, captures structured JSON output from Claude Code's `--output-format json`, and tears down all containers/volumes automatically via a trap handler.

The Claude Code CLI's `-p` (print/headless) mode is well-documented and stable. Key flags are: `-p "prompt"` for non-interactive execution, `--output-format json` for structured output with `result`, `session_id`, and metadata fields, `--max-turns N` to limit agentic turns, and `--dangerously-skip-permissions` (equivalent to `--permission-mode bypassPermissions`) to skip all permission prompts. The `--bare` flag is recommended for scripted calls as it skips auto-discovery of hooks/MCP/CLAUDE.md, reducing startup time and eliminating environment-dependent behavior.

All work is in `bin/claude-secure` (bash + jq). No new languages, containers, or dependencies are introduced. The existing `load_profile_config()`, `validate_profile()`, and Docker Compose patterns are reused directly. The main new code is: (1) argument parsing for `spawn` and its flags, (2) template resolution and variable substitution, (3) ephemeral compose project lifecycle management, and (4) output envelope construction.

**Primary recommendation:** Implement spawn as a new case in the `bin/claude-secure` case statement, reusing existing profile functions. Use `--bare` flag for all headless execution to ensure reproducible behavior across environments.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** `spawn` is a new subcommand: `claude-secure spawn --profile <name> --event '<json>'`
- **D-02:** `--event` accepts a JSON string directly (webhook listener will pipe it). Also accept `--event-file <path>` for debugging/replay convenience.
- **D-03:** `--prompt-template <name>` optional flag to override automatic event-type-based template resolution.
- **D-04:** `--profile` is required for spawn (no superuser mode for headless execution -- must have a scoped security context).
- **D-05:** Each spawn creates a new Docker Compose project with `COMPOSE_PROJECT_NAME=cs-<profile>-<uuid8>` for true isolation between concurrent runs.
- **D-06:** Lifecycle: `docker compose up -d` -> `docker compose exec -T claude claude -p "..." --output-format json --dangerously-skip-permissions` -> `docker compose down -v` (including volumes).
- **D-07:** Cleanup runs in a bash trap handler that catches EXIT (covers success, failure, timeout, and signals). Cleanup is mandatory -- no orphaned containers.
- **D-08:** `--max-turns` from `profile.json` is passed to Claude Code via `--max-turns` flag. If unset in profile, Claude Code's default applies.
- **D-09:** `docker compose exec -T` pipes stdout directly -- no temp files or log parsing.
- **D-10:** Claude Code's `--output-format json` provides `result`, `cost`, `duration`, `session_id`.
- **D-11:** Wrapper adds metadata envelope: `{ "profile", "event_type", "timestamp", "claude": <claude-output> }`.
- **D-12:** Exit code propagated: 0 = success, non-zero = failure. On failure, stderr captured and included in output JSON as `error` field.
- **D-13:** Templates live at `~/.claude-secure/profiles/<name>/prompts/<event-type>.md` (e.g., `issue-opened.md`, `push.md`, `ci-failure.md`).
- **D-14:** Variables use `{{VAR_NAME}}` double-brace syntax (not shell `$VAR` -- avoids accidental expansion).
- **D-15:** Substitution done in bash via sed before passing to Claude Code `-p` flag.
- **D-16:** Template resolution order: explicit `--prompt-template` flag > event-type derived from `--event` JSON > error if no template found.
- **D-17:** Event payload fields extracted via jq and mapped to template variables. Standard variables: `{{REPO_NAME}}`, `{{EVENT_TYPE}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{COMMIT_SHA}}`, `{{BRANCH}}`.

### Claude's Discretion
- Exact metadata envelope schema (D-11) -- add fields as needed during implementation
- Error message formatting for missing templates, invalid JSON, profile validation failures
- Whether to add `--dry-run` flag for spawn (shows resolved prompt without executing) -- nice-to-have if trivial
- How to handle Claude Code bug #7263 (empty output with large stdin) -- test empirically, add workaround if confirmed

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HEAD-01 | User can spawn a non-interactive Claude Code session via `claude-secure spawn --profile <name> --event <payload>` | Supported by D-01 through D-04. Claude Code `-p` flag confirmed as the correct headless entry point. `docker compose exec -T` removes TTY allocation for non-interactive piping. |
| HEAD-02 | Headless session uses `-p` with `--output-format json` and captures structured result (result, cost, duration, session_id) | Supported by D-09, D-10, D-11. Official docs confirm `--output-format json` returns structured JSON with `result`, `session_id`, and metadata. Output envelope wraps Claude output with spawn metadata. |
| HEAD-03 | User can set per-profile `--max-turns` budget to limit execution scope | Supported by D-08. Official docs confirm `--max-turns N` limits agentic turns (print mode only). Exits with error when limit reached. Profile.json already has `max_turns` field from Phase 12. |
| HEAD-04 | Spawned instance is ephemeral -- containers are created, execute, and tear down automatically | Supported by D-05, D-06, D-07. Unique `COMPOSE_PROJECT_NAME=cs-<profile>-<uuid8>` ensures isolation. `trap cleanup EXIT` ensures `docker compose down -v` runs on all exit paths. |
| HEAD-05 | User can define prompt templates per profile with variable substitution (e.g. `{{ISSUE_TITLE}}`, `{{REPO_NAME}}`) | Supported by D-13 through D-17. Templates in `profiles/<name>/prompts/<event-type>.md`. Variable extraction via jq, substitution via sed. Resolution order: explicit flag > event-type derived > error. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform**: Must work on Linux (native) and WSL2
- **Dependencies**: Docker, Docker Compose, curl, jq, uuidgen must be available on host
- **Security**: Hook scripts, settings, and whitelist must be root-owned and immutable by the Claude process
- **Architecture**: Proxy uses buffered request/response (no streaming)
- **Auth**: OAuth token primary; API key fallback
- **No NFQUEUE**: Validator uses HTTP registration + iptables only
- **No Agent SDK**: Must use CLI `-p` via `docker compose exec` (SDK bypasses Docker security layers)
- **No npm/pip install**: Node.js proxy and Python validator use only stdlib

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Bash | 5.2 | CLI wrapper, spawn logic, template substitution | Already the language of bin/claude-secure. Entire Phase 13 is bash. |
| jq | 1.7 | Parse event JSON, extract template variables, build output envelope | Already a project dependency. Needed for JSON manipulation throughout spawn. |
| Docker Compose | v2 (5.1.1) | Ephemeral container orchestration per spawn | Already used. COMPOSE_PROJECT_NAME + `down -v` provides full lifecycle management. |
| uuidgen | system | Generate UUID8 suffix for compose project names | Already a project dependency. Used in hooks for call-IDs. |
| sed | system | Template variable substitution ({{VAR}} -> value) | Standard tool. Simple string replacement is sufficient for double-brace syntax. |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| curl | system | Not directly needed for Phase 13 | Remains a project dependency; not used in spawn path |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| sed for template substitution | envsubst | envsubst uses `$VAR` syntax which conflicts with shell expansion. `{{VAR}}` with sed is safer. |
| jq for output envelope | bash string concatenation | Error-prone JSON construction. jq guarantees valid JSON output. |
| trap EXIT for cleanup | manual cleanup calls | trap covers all exit paths (success, error, SIGTERM, SIGINT). Manual calls miss edge cases. |

## Architecture Patterns

### Spawn Directory Structure
```
~/.claude-secure/profiles/<name>/
  profile.json          # Has max_turns (optional)
  .env                  # Auth credentials
  whitelist.json        # Domain allowlist
  prompts/              # NEW: template directory
    issue-opened.md     # Template for issue events
    push.md             # Template for push events
    ci-failure.md       # Template for CI failure events
```

### Pattern 1: Spawn Lifecycle
**What:** Complete lifecycle of a headless spawn from invocation to cleanup.
**When to use:** Every `claude-secure spawn` invocation.
**Flow:**
```bash
# 1. Parse spawn-specific flags
#    --profile (required), --event (JSON), --event-file, --prompt-template

# 2. Validate inputs
#    - Profile must exist and pass validate_profile()
#    - Event JSON must be valid (jq empty)
#    - Template must resolve

# 3. Load profile config (reuse load_profile_config)
#    Then override COMPOSE_PROJECT_NAME with ephemeral name

# 4. Resolve and render prompt template
#    - Find template file (explicit flag > event-type derived)
#    - Extract variables from event JSON via jq
#    - Substitute {{VAR}} placeholders via sed

# 5. Start ephemeral containers
#    docker compose up -d
#    (trap cleanup EXIT already set)

# 6. Execute headless Claude Code
#    docker compose exec -T claude claude -p "$rendered_prompt" \
#      --output-format json --dangerously-skip-permissions \
#      [--max-turns N] [--bare]

# 7. Capture output, build envelope
#    Wrap Claude JSON output with metadata

# 8. Cleanup (automatic via trap)
#    docker compose down -v --remove-orphans
```

### Pattern 2: Ephemeral Compose Project Name
**What:** Unique project name per spawn for isolation.
**When to use:** Every spawn creates its own project.
```bash
spawn_project_name() {
  local profile="$1"
  local uuid8
  uuid8=$(uuidgen | tr -d '-' | head -c 8)
  echo "cs-${profile}-${uuid8}"
}
# Result: cs-myservice-a1b2c3d4
```

### Pattern 3: Template Resolution and Substitution
**What:** Find template, extract variables from event JSON, substitute placeholders.
**When to use:** Before passing prompt to Claude Code.
```bash
resolve_template() {
  local profile_dir="$1"
  local event_type="$2"
  local explicit_template="${3:-}"

  if [ -n "$explicit_template" ]; then
    local path="$profile_dir/prompts/${explicit_template}.md"
  else
    local path="$profile_dir/prompts/${event_type}.md"
  fi

  if [ ! -f "$path" ]; then
    echo "ERROR: Template not found: $path" >&2
    return 1
  fi
  echo "$path"
}

render_template() {
  local template_path="$1"
  local event_json="$2"

  local rendered
  rendered=$(cat "$template_path")

  # Extract standard variables from event JSON via jq
  local repo_name event_type issue_title issue_body commit_sha branch
  repo_name=$(echo "$event_json" | jq -r '.repository.full_name // empty')
  event_type=$(echo "$event_json" | jq -r '.event_type // empty')
  issue_title=$(echo "$event_json" | jq -r '.issue.title // empty')
  issue_body=$(echo "$event_json" | jq -r '.issue.body // empty')
  commit_sha=$(echo "$event_json" | jq -r '.after // .head_commit.id // empty')
  branch=$(echo "$event_json" | jq -r '.ref // empty' | sed 's|refs/heads/||')

  # Substitute each variable (sed with | delimiter to handle / in values)
  rendered=$(echo "$rendered" | sed "s|{{REPO_NAME}}|${repo_name}|g")
  rendered=$(echo "$rendered" | sed "s|{{EVENT_TYPE}}|${event_type}|g")
  rendered=$(echo "$rendered" | sed "s|{{ISSUE_TITLE}}|${issue_title}|g")
  rendered=$(echo "$rendered" | sed "s|{{ISSUE_BODY}}|${issue_body}|g")
  rendered=$(echo "$rendered" | sed "s|{{COMMIT_SHA}}|${commit_sha}|g")
  rendered=$(echo "$rendered" | sed "s|{{BRANCH}}|${branch}|g")

  echo "$rendered"
}
```

### Pattern 4: Output Envelope Construction
**What:** Wrap Claude Code JSON output with spawn metadata.
**When to use:** After Claude Code exits successfully.
```bash
build_output_envelope() {
  local profile="$1"
  local event_type="$2"
  local claude_output="$3"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  echo "$claude_output" | jq --arg profile "$profile" \
    --arg event_type "$event_type" \
    --arg timestamp "$timestamp" \
    '{
      profile: $profile,
      event_type: $event_type,
      timestamp: $timestamp,
      claude: .
    }'
}
```

### Pattern 5: Error Handling with Stderr Capture
**What:** Capture stderr from Claude Code separately to include in error output.
**When to use:** When Claude Code exits non-zero.
```bash
# Capture both stdout and stderr separately
local claude_stdout claude_stderr claude_exit
claude_stderr=$(mktemp)
_CLEANUP_FILES+=("$claude_stderr")

claude_stdout=$(docker compose exec -T claude claude -p "$rendered_prompt" \
  --output-format json --dangerously-skip-permissions \
  ${max_turns:+--max-turns "$max_turns"} 2>"$claude_stderr") || claude_exit=$?

if [ "${claude_exit:-0}" -ne 0 ]; then
  local error_msg
  error_msg=$(cat "$claude_stderr")
  jq -n --arg profile "$profile" --arg event_type "$event_type" \
    --arg error "$error_msg" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{profile: $profile, event_type: $event_type, timestamp: $timestamp, error: $error}'
  exit "$claude_exit"
fi
```

### Pattern 6: Trap-Based Cleanup for Ephemeral Containers
**What:** Ensure containers/volumes are always cleaned up.
**When to use:** Set immediately after COMPOSE_PROJECT_NAME is assigned.
```bash
spawn_cleanup() {
  # Remove ephemeral containers and volumes
  docker compose down -v --remove-orphans 2>/dev/null || true
  # Clean up temp files
  for f in "${_CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
}
# Must set trap AFTER COMPOSE_PROJECT_NAME and COMPOSE_FILE are exported
trap spawn_cleanup EXIT
```

### Anti-Patterns to Avoid
- **Using `-it` with spawn:** The `-it` flags allocate a TTY. Non-interactive spawn MUST use `-T` (no TTY). Using `-it` hangs when there's no terminal.
- **Using superuser mode for spawn:** D-04 explicitly prohibits this. Spawn requires `--profile` for scoped security context.
- **Shell variable syntax in templates:** Using `$VAR` or `${VAR}` in templates risks accidental shell expansion. `{{VAR}}` with sed replacement is safe.
- **Temp files for stdout capture:** D-09 says pipe stdout directly. No intermediate temp files for the main output path.
- **Skipping `down -v`:** The `-v` flag removes anonymous volumes. Without it, each spawn leaks a `validator-db` volume. Over time this fills the disk.
- **Using `--bare` without `--dangerously-skip-permissions`:** The `--bare` flag is about context loading, not permissions. Both flags are needed: `--bare` for fast startup, `--dangerously-skip-permissions` for non-interactive tool approval.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON output construction | String concatenation with echo | `jq -n` with `--arg` | Handles escaping, nested objects, special characters |
| Event field extraction | grep/awk on JSON | `jq -r '.path.to.field // empty'` | Reliable nested JSON access with null handling |
| UUID generation | Random number tricks | `uuidgen \| tr -d '-' \| head -c 8` | Proper UUID4 with system entropy |
| Cleanup on all exit paths | Multiple cleanup calls | `trap cleanup EXIT` | Catches success, error, SIGTERM, SIGINT, SIGPIPE |
| JSON validation | Custom checks | `jq empty` | Returns exit code 0/1 for valid/invalid JSON |

## Common Pitfalls

### Pitfall 1: sed Fails on Multiline Template Variables
**What goes wrong:** `{{ISSUE_BODY}}` contains newlines, which breaks single-line sed substitution.
**Why it happens:** GitHub issue bodies are multiline markdown. `sed "s|{{ISSUE_BODY}}|$body|g"` fails with "unmatched" errors when `$body` has newlines.
**How to avoid:** Write the rendered template to a temp file using a different approach for multiline values. Options: (1) Use `awk` instead of sed for multiline substitution, (2) escape newlines in the value before sed (`${body//$'\n'/\\n}`), or (3) write the event context to a file and reference it via `--append-system-prompt-file` instead of inline substitution.
**Warning signs:** "unterminated `s` command" errors from sed during spawn.
**Recommendation:** For ISSUE_BODY specifically, write it to a context file and use `--append-system-prompt-file` or include it as a separate section. Short variables (REPO_NAME, BRANCH, etc.) are safe with sed.

### Pitfall 2: Compose Project Name Collisions
**What goes wrong:** Two concurrent spawns for the same profile get the same UUID prefix.
**Why it happens:** Extremely unlikely with uuidgen (UUID4), but possible if uuidgen falls back to time-based generation.
**How to avoid:** UUID4 from uuidgen provides 128 bits of entropy. Even with 8-character truncation (32 bits), collision probability for concurrent spawns is negligible. No action needed beyond using uuidgen.
**Warning signs:** "network already exists" errors from docker compose.

### Pitfall 3: Orphaned Containers on SIGKILL
**What goes wrong:** `kill -9` (SIGKILL) bypasses trap handlers. Containers remain running.
**Why it happens:** SIGKILL cannot be caught by any process. The trap handler never runs.
**How to avoid:** This is an inherent limitation. Phase 17 (OPS-03) delivers a container reaper for this case. For Phase 13, document that SIGKILL may leave orphans and recommend `docker compose ls | grep cs-` to find them.
**Warning signs:** `docker ps` shows containers with `cs-<profile>-` prefix after spawn should have completed.

### Pitfall 4: Large Prompts Exceeding Shell Argument Limits
**What goes wrong:** Rendered template exceeds shell argument length limit (typically 2MB on Linux, but `docker compose exec` has additional overhead).
**Why it happens:** Large issue bodies or commit diffs injected into templates.
**How to avoid:** For the `-p` flag, the prompt is passed as a command-line argument. If the rendered prompt is very large, write it to a temp file inside the container and use `cat /tmp/prompt.txt | claude -p --input-format text` or use `--append-system-prompt-file`. For Phase 13, document a size check and fallback strategy.
**Warning signs:** "Argument list too long" errors.

### Pitfall 5: Bug #7263 -- Empty Output with Large Stdin
**What goes wrong:** Claude Code returns empty output when large content is piped via stdin (reportedly >7000 chars).
**Why it happens:** Known bug in Claude Code CLI (github.com/anthropics/claude-code/issues/7263).
**How to avoid:** Phase 13 uses `-p "prompt"` (command-line argument) not stdin piping. The bug affects stdin (`cat large_file | claude -p`). If prompts are passed via `-p` flag directly, this bug should not apply. However, if prompt size exceeds argument limits and falls back to stdin, the bug may trigger. Test empirically during implementation.
**Warning signs:** Empty stdout from `docker compose exec -T claude claude -p ...`.

### Pitfall 6: docker compose exec -T Stderr Mixing
**What goes wrong:** Docker Compose's own stderr messages mix with Claude Code's stderr, making error capture unreliable.
**Why it happens:** `docker compose exec -T` writes its own errors (e.g., "service not found", container crash) to stderr alongside Claude Code's stderr.
**How to avoid:** Parse stderr carefully. Docker Compose errors will have distinct patterns. Or: redirect stderr to a file and filter out known Docker Compose prefixes.
**Warning signs:** JSON parsing errors when trying to include stderr in the error output envelope.

### Pitfall 7: Profile prompts/ Directory Not Created by Phase 12
**What goes wrong:** `resolve_template()` fails because `profiles/<name>/prompts/` directory does not exist.
**Why it happens:** Phase 12 created flat profile directories (D-08: "No subdirectories"). Phase 13 adds the `prompts/` subdirectory.
**How to avoid:** `resolve_template()` should check if the prompts directory exists and give a clear error. The spawn command should NOT auto-create it. Users create templates manually.
**Warning signs:** "Template not found" errors even when the user thinks they created a template.

## Code Examples

### Claude Code Headless Execution via Docker
```bash
# Source: Official Claude Code docs (https://code.claude.com/docs/en/headless)
# Combined with project's docker compose exec pattern

# Non-interactive execution with structured JSON output
docker compose exec -T claude claude \
  -p "Review the code in /workspace and fix any bugs" \
  --output-format json \
  --dangerously-skip-permissions \
  --max-turns 10 \
  --bare

# Output format (--output-format json):
# {
#   "result": "I reviewed the code and found...",
#   "session_id": "abc123-...",
#   "cost_usd": 0.15,
#   "duration_ms": 45000,
#   ...metadata fields...
# }
```

### Spawn Argument Parsing
```bash
# Inside the main case statement, before spawn logic
spawn)
  # Require --profile for spawn
  if [ -z "$PROFILE" ]; then
    echo "ERROR: --profile is required for spawn" >&2
    echo "Usage: claude-secure spawn --profile <name> --event '<json>'" >&2
    exit 1
  fi

  # Parse spawn-specific flags from REMAINING_ARGS
  EVENT_JSON=""
  EVENT_FILE=""
  PROMPT_TEMPLATE=""
  DRY_RUN=0
  local i=1
  while [ $i -le ${#REMAINING_ARGS[@]} ]; do
    case "${REMAINING_ARGS[$i]:-}" in
      --event)      EVENT_JSON="${REMAINING_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
      --event-file) EVENT_FILE="${REMAINING_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
      --prompt-template) PROMPT_TEMPLATE="${REMAINING_ARGS[$((i+1))]:-}"; i=$((i+2)) ;;
      --dry-run)    DRY_RUN=1; i=$((i+1)) ;;
      *)            i=$((i+1)) ;;
    esac
  done

  # Load event from file if --event-file used
  if [ -n "$EVENT_FILE" ] && [ -z "$EVENT_JSON" ]; then
    EVENT_JSON=$(cat "$EVENT_FILE")
  fi

  # Validate event JSON
  if [ -z "$EVENT_JSON" ]; then
    echo "ERROR: --event or --event-file is required for spawn" >&2
    exit 1
  fi
  if ! echo "$EVENT_JSON" | jq empty 2>/dev/null; then
    echo "ERROR: Invalid JSON in --event" >&2
    exit 1
  fi
  ;;
```

### Template File Example
```markdown
# prompts/issue-opened.md
You are working on the {{REPO_NAME}} repository.

A new issue has been opened:

**Title:** {{ISSUE_TITLE}}

**Description:**
{{ISSUE_BODY}}

Please analyze this issue and create a plan to address it.
If it's a bug report, try to reproduce and fix it.
If it's a feature request, implement the feature.

Commit your changes with a descriptive commit message.
```

## Claude Code CLI Reference (Headless Flags)

Verified from official documentation at https://code.claude.com/docs/en/cli-reference:

| Flag | Description | Print Mode Only | Notes |
|------|-------------|-----------------|-------|
| `-p`, `--print` | Non-interactive mode; prints response and exits | -- | Core flag for headless |
| `--output-format json` | Returns structured JSON with result, session_id, metadata | Yes | Use with jq to extract fields |
| `--max-turns N` | Limits agentic turns; exits with error at limit | Yes | No default limit |
| `--max-budget-usd N` | Dollar limit on API calls | Yes | Alternative/complement to max-turns |
| `--dangerously-skip-permissions` | Skip all permission prompts | -- | Equivalent to `--permission-mode bypassPermissions` |
| `--bare` | Skip hooks, skills, plugins, MCP, CLAUDE.md | -- | Faster startup; recommended for scripts |
| `--append-system-prompt` | Add text to default system prompt | -- | Useful for additional context |
| `--append-system-prompt-file` | Add file contents to system prompt | -- | Workaround for large context (bug #7263) |
| `--no-session-persistence` | Don't save session to disk | Yes | Reduces disk usage for ephemeral runs |
| `--fallback-model` | Auto-fallback on overload | Yes | Resilience for headless runs |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `--dangerously-skip-permissions` only | `--permission-mode bypassPermissions` (equivalent) | Recent CLI update | Same behavior, new canonical name |
| Headless mode (old name) | Agent SDK / `-p` mode | Docs renamed | No functional change; `-p` still works identically |
| No `--bare` flag | `--bare` recommended for scripts | Recent addition | Skips CLAUDE.md, hooks, MCP -- faster and more reproducible |
| No `--max-budget-usd` | Available in print mode | Recent addition | Alternative budget control alongside --max-turns |

## Open Questions

1. **Bug #7263 status**
   - What we know: Reported empty output with large stdin (>7000 chars). Workaround: use `--append-system-prompt-file`.
   - What's unclear: Whether this is still an issue in current Claude Code versions. Phase 13 uses `-p "prompt"` not stdin, which may not be affected.
   - Recommendation: Test empirically during implementation. If prompt exceeds ~5000 chars, write to temp file and use `--append-system-prompt-file` as fallback.

2. **Exact JSON output schema from `--output-format json`**
   - What we know: Documentation says it includes `result`, `session_id`, and "metadata". Cost and duration fields mentioned in D-10.
   - What's unclear: Exact field names for cost and duration (e.g., `cost_usd` vs `cost`, `duration_ms` vs `duration`).
   - Recommendation: Run a test invocation during implementation to capture the actual schema. Build envelope based on observed output.

3. **`--bare` flag interaction with hooks inside container**
   - What we know: `--bare` skips hooks, CLAUDE.md, MCP servers. The security hooks in claude-secure are critical.
   - What's unclear: Whether `--bare` skips the PreToolUse hooks that enforce security whitelist.
   - Recommendation: Test empirically. If `--bare` skips hooks, do NOT use it -- the security hooks are essential. If hooks are still active with `--bare`, use it for faster startup. The hooks are configured at the system level inside the container, which `--bare` may or may not skip.

4. **Should `--dry-run` be implemented?**
   - What we know: Context says "nice-to-have if trivial". It would show the resolved prompt without starting containers.
   - What's unclear: How much effort it adds.
   - Recommendation: Implement it -- it is trivial. Skip the `docker compose up` and `exec` steps, just print the resolved prompt to stdout. Extremely useful for template debugging.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash integration tests (project convention) |
| Config file | `tests/test-map.json` |
| Quick run command | `bash tests/test-phase13.sh` |
| Full suite command | `for t in tests/test-phase*.sh; do bash "$t"; done` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| HEAD-01 | Spawn subcommand parses flags, requires --profile, validates event JSON | unit (bash) | `bash tests/test-phase13.sh` | No -- Wave 0 |
| HEAD-02 | Output envelope contains profile, event_type, timestamp, claude fields | unit (bash) | `bash tests/test-phase13.sh` | No -- Wave 0 |
| HEAD-03 | max_turns from profile.json passed to Claude Code flag | unit (bash) | `bash tests/test-phase13.sh` | No -- Wave 0 |
| HEAD-04 | Cleanup trap removes containers/volumes on exit | integration | `bash tests/test-phase13.sh` | No -- Wave 0 |
| HEAD-05 | Template resolution, variable substitution, prompts/ directory | unit (bash) | `bash tests/test-phase13.sh` | No -- Wave 0 |

### Suggested Test Cases
| Test ID | What It Tests |
|---------|---------------|
| HEAD-01a | `spawn` without `--profile` produces error |
| HEAD-01b | `spawn` without `--event` or `--event-file` produces error |
| HEAD-01c | `spawn` with invalid event JSON produces error |
| HEAD-01d | `spawn` with valid flags parses correctly (mock execution) |
| HEAD-02a | Output envelope has required fields (profile, event_type, timestamp, claude) |
| HEAD-02b | Error output includes error field on failure |
| HEAD-03a | max_turns read from profile.json and included in claude command |
| HEAD-03b | Missing max_turns in profile.json omits --max-turns flag |
| HEAD-04a | COMPOSE_PROJECT_NAME has cs-<profile>-<uuid8> format |
| HEAD-04b | Cleanup function calls docker compose down -v |
| HEAD-05a | resolve_template finds template by event type |
| HEAD-05b | resolve_template finds template by explicit --prompt-template |
| HEAD-05c | resolve_template fails with clear error when template missing |
| HEAD-05d | render_template substitutes {{VAR_NAME}} variables |
| HEAD-05e | render_template handles missing variables (leaves {{VAR}} or clears) |
| HEAD-05f | render_template handles multiline ISSUE_BODY safely |
| DRY-01  | `--dry-run` prints resolved prompt without starting containers |

### Sampling Rate
- **Per task commit:** `bash tests/test-phase13.sh`
- **Per wave merge:** All test scripts
- **Phase gate:** Full suite green before verification

### Wave 0 Gaps
- [ ] `tests/test-phase13.sh` -- covers HEAD-01 through HEAD-05, dry-run
- [ ] Update `tests/test-map.json` -- add `bin/claude-secure` -> `test-phase13.sh` mapping

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | CLI wrapper | Yes | 5.2 | -- |
| jq | JSON parsing | Yes | 1.7 | -- |
| docker | Container runtime | Yes | 29.3.1 | -- |
| docker compose | Container orchestration | Yes | v5.1.1 | -- |
| uuidgen | Unique project names | Yes | system | -- |
| sed | Template substitution | Yes | system | -- |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None.

## Sources

### Primary (HIGH confidence)
- [Claude Code CLI Reference](https://code.claude.com/docs/en/cli-reference) -- All headless flags verified: `-p`, `--output-format json`, `--max-turns`, `--dangerously-skip-permissions`, `--bare`, `--max-budget-usd`, `--no-session-persistence`
- [Claude Code Headless Docs](https://code.claude.com/docs/en/headless) -- Headless execution patterns, `--bare` mode recommendation, piped content handling
- `bin/claude-secure` (517 lines) -- Full existing implementation analyzed, reusable functions identified
- `docker-compose.yml` -- Container topology, env_file patterns, volume mounts confirmed
- `.planning/phases/13-headless-cli-path/13-CONTEXT.md` -- All 17 locked decisions
- `.planning/phases/12-profile-system/12-RESEARCH.md` -- Profile system patterns, profile.json schema

### Secondary (MEDIUM confidence)
- `.planning/research/PITFALLS.md` -- Bug #7263 documentation and workaround strategy
- `.planning/research/SUMMARY.md` -- Cross-phase research summary

### Tertiary (LOW confidence)
- Bug #7263 status -- unable to verify if fixed in current Claude Code version. Must test empirically.
- Exact `--output-format json` schema field names (cost_usd vs cost, duration_ms vs duration) -- docs say "metadata" without listing exact fields.
- `--bare` flag interaction with container-level hooks -- unclear whether system-level hooks survive `--bare`.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new tools, all existing dependencies
- Architecture: HIGH -- patterns derived from existing code + locked decisions + official docs
- Pitfalls: HIGH -- identified from codebase analysis, official docs, known bug tracker
- Claude Code flags: HIGH -- verified against official documentation (April 2026)
- Output schema details: MEDIUM -- exact field names need empirical verification

**Research date:** 2026-04-11
**Valid until:** 30 days (Claude Code CLI may update; verify flags if implementing after 2026-05-11)
