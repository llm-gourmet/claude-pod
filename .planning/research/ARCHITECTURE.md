# Architecture: v4.0 Agent Documentation Layer

**Milestone:** v4.0 Agent Documentation Layer
**Researched:** 2026-04-13
**Confidence:** HIGH (based on direct code inspection of shipped Phase 12-17 infrastructure)

---

## TL;DR

Phase 16 already ships a **per-event report pusher** that clones the profile's `report_repo`, writes a single timestamped markdown file, commits, and pushes. v4.0 does **not** replace that — it **extends** it into a richer per-project documentation layout (todo.md, architecture.md, vision.md, ideas.md, specs/) and adds a **bidirectional inbound path**: the webhook listener (or a new polling service) reads tasks from the doc repo and dispatches them as spawns, and every completed spawn writes back a structured agent report plus (optionally) mutates the project's `todo.md`.

**The doc repo becomes the inbox and the outbox for one or more profiles.** The existing Phase 16 pipeline (clone → render → redact → commit → push → audit) is reused wholesale. New code is mostly:

1. A **richer on-disk layout writer** (multi-file commits instead of single-file).
2. A **doc repo ingest loop** — either a GitHub webhook on the doc repo, or an interval poller — that turns inbox items into `do_spawn` invocations.
3. **Profile schema additions** (`docs_repo_*`, plus repo-level config living inside each project directory in the doc repo itself).

Critically: **all git operations continue to run from `bin/claude-secure` on the host**, not from inside the claude container. The claude container stays network-isolated. The PAT never crosses into the isolated container.

---

## Existing Architecture (What Already Works)

### Container Topology (unchanged from v1.0/v2.0)

```
Host (Linux/WSL2/macOS)
├── bin/claude-secure           (host CLI, bash)
├── webhook/listener.py         (systemd/launchd, GitHub webhook inbound)
├── ~/.claude-secure/
│   ├── profiles/<name>/
│   │   ├── profile.json        (repo binding, report_repo, webhook_secret, ...)
│   │   ├── .env                (REPORT_REPO_TOKEN, secrets)
│   │   └── templates/*.md      (per-profile prompt + report overrides)
│   ├── events/                 (persisted webhook payloads)
│   └── logs/
│       ├── webhook.jsonl       (listener audit, Phase 14)
│       └── executions.jsonl    (spawn audit, Phase 16)
└── Docker Compose stack (per-spawn ephemeral, COMPOSE_PROJECT_NAME-isolated)
    ├── claude     (Ubuntu: Claude Code CLI, bash, jq, curl, uuidgen)
    ├── proxy      (node:22-alpine: Anthropic proxy, secret redaction)
    └── validator  (python:3.11-slim: SQLite + iptables enforcement)
```

### Phase 16 Result Channel — Current Behavior (directly verified in `bin/claude-secure`)

Every `do_spawn` execution (webhook-triggered OR `replay` OR manual) runs this sequence after Claude exits:

```
1. build_output_envelope / build_error_envelope     (bin/claude-secure:~343,361)
2. resolve_report_template(event_type)              (:618)   — profile → env → dev → /opt fallback
3. render_report_template                            (awk-from-file substitution)
4. redact_report_file  <report>  <profile/.env>      — D-15 env-value scrub
5. publish_report                                   (:1052)
     a. mktemp clone_dir in $TMPDIR (registered with spawn_cleanup trap)
     b. ephemeral .askpass.sh helper (PAT via env, never argv)
     c. timeout 60 git clone --depth 1 --branch <report_branch> <report_repo>
     d. cp body -> <prefix>/<YYYY>/<MM>/<event_type>-<id8>.md
     e. git add + commit (GIT_AUTHOR_* env, no host config touched)
     f. push_with_retry (up to 3 attempts on non-fast-forward, never force)
     g. stderr piped through sed to scrub PAT on any leak path
     h. return report_url (github blob URL)
6. write_audit_entry                                (:900)
     -> $LOG_DIR/${LOG_PREFIX}executions.jsonl
     -> JSONL, one line per spawn, jq -cn generated (<4KB per line)
```

**Failure semantics (D-17/D-18):** audit is always written. `publish_report` exit code 2 = skipped (no `REPORT_REPO` or `REPORT_REPO_TOKEN`); exit 1 = push failure → audit status becomes `push_error`. Claude's exit code alone drives spawn's exit code; report publish failures never flip it.

**Profile config fields already in use (from `do_spawn`:1273):**

```json
{
  "report_repo": "https://github.com/user/docs.git",
  "report_branch": "main",
  "report_path_prefix": "reports"
}
```

`REPORT_REPO_TOKEN` comes from `~/.claude-secure/profiles/<name>/.env`.

### What Phase 16 Does NOT Do (v4.0 gaps)

| Gap | Why it matters for v4.0 |
|-----|-------------------------|
| Writes **one** report file per spawn, in a flat `<prefix>/YYYY/MM/` layout | v4.0 wants per-project `todo.md`, `architecture.md`, `vision.md`, `ideas.md`, plus `reports/` history |
| No **inbound** read path from the doc repo | v4.0 turns the doc repo into a task queue |
| Report template is keyed only on `event_type` | v4.0 agent reports need "where worked / what changed / what failed / how to test / future findings" — a richer template set |
| No **todo.md mutation** (check off line X, append new line Y) | v4.0 agents need to update task state on completion |
| Doc repo is not **discoverable** by the agent inside the container | Agents cannot currently read vision.md / architecture.md as context before running |
| No interactive-mode hook | Phase 16 only runs in `do_spawn`; interactive `claude-secure run` never publishes |

---

## Recommended v4.0 Architecture

### Component Summary

```
NEW / MODIFIED COMPONENTS

┌────────────────────────────────────────────────────────────────────────┐
│                              HOST                                      │
│                                                                        │
│  [modified] bin/claude-secure                                          │
│    ├── publish_report         → publish_docs_bundle (multi-file commit)│
│    ├── render_report_template → render_agent_report_bundle             │
│    ├── NEW: stage_docs_update  (todo.md / architecture.md mutations)   │
│    ├── NEW: fetch_docs_context (clone on spawn start, mount into claude│
│    │                            container for agent to read)          │
│    └── NEW: close_loop_commit  (single squashed commit: reports/...    │
│                                 + docs/... + todo.md in one push)     │
│                                                                        │
│  [modified] webhook/listener.py                                        │
│    ├── GitHub webhook on source project repo  (existing, unchanged)    │
│    └── NEW: GitHub webhook on docs repo                                │
│           → inbound event type "docs-task" or "docs-push"              │
│           → resolve_profile_by_docs_repo(docs_full_name)               │
│           → spawn_async with synthesized event JSON                    │
│                                                                        │
│  [new, optional] webhook/docs_poller.py                                │
│    Systemd/launchd timer: every N minutes, for each profile with       │
│    docs_repo, git-ls-remote for changes to <project>/inbox/*.md or     │
│    open todo.md unchecked lines; when found, synthesize a docs-task    │
│    event and POST it to listener.py /internal/dispatch                 │
│    (Only needed if we don't want a GitHub webhook on the docs repo.)   │
│                                                                        │
│  [new] webhook/docs-templates/                                         │
│    ├── agent-report.md         (where worked / changes / tests / ...)  │
│    ├── todo-append.md          (how to add new items to todo.md)       │
│    ├── architecture-update.md  (how to propose architecture edits)     │
│    └── docs-task.md            (prompt template: agent receives task   │
│                                 from inbox/<id>.md as input)          │
│                                                                        │
│  [extended] ~/.claude-secure/profiles/<name>/profile.json              │
│    + "docs_repo":        "https://github.com/user/claude-docs.git"     │
│    + "docs_branch":      "main"                                        │
│    + "docs_project_dir": "projects/myapp"   (per-profile scope)        │
│    + "docs_mode":        "report_only" | "report_and_tasks"            │
│    + REPORT_REPO_TOKEN → renamed DOCS_REPO_TOKEN (back-compat alias)   │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘

                                  ▲           ▲
                 git clone/push   │           │ GitHub webhook POST
                                  │           │ (docs repo push event)
                                  ▼           │
┌────────────────────────────────────────────────────────────────────────┐
│                    GitHub: claude-docs (doc repo)                      │
│                                                                        │
│  projects/myapp/                                                       │
│    vision.md            ← hand-authored, read by agent                 │
│    architecture.md      ← agent may propose edits                      │
│    todo.md              ← bidirectional (read tasks, check them off)   │
│    ideas.md             ← append-only from agents                      │
│    specs/<name>.md      ← hand-authored specs                          │
│    inbox/<id>.md        ← dropped in by humans; consumed by poller     │
│    reports/YYYY/MM/     ← Phase 16 flat reports continue here          │
│                                                                        │
│  projects/otherapp/     ← second profile uses same repo, isolated      │
│    ...                                                                 │
│                                                                        │
│  .claude-docs.json      ← repo-level config (project list, schema     │
│                            version, allowed agents)                   │
└────────────────────────────────────────────────────────────────────────┘

                                  ▲
        docker exec with          │
        read-only bind mount      │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    claude container (per-spawn, ephemeral)             │
│                                                                        │
│  /workspace/           (unchanged)                                     │
│  /agent-docs/          NEW: read-only bind mount of shallow clone      │
│                             → /tmp/cs-docs-<uuid>/repo/projects/<name> │
│                             (cleaned by spawn_cleanup trap)            │
│                                                                        │
│  Claude reads vision.md, architecture.md, todo.md as startup context   │
│  via prompt template injection (render_template already supports this) │
└────────────────────────────────────────────────────────────────────────┘
```

### Data Flow 1: Outbound (Agent → Doc Repo) — mostly reuses Phase 16

```
do_spawn
  │
  ├── 1. load_profile_config           (existing, Phase 12)
  │      exports REPORT_REPO, DOCS_REPO (new), REPORT_REPO_TOKEN
  │
  ├── 2. NEW: fetch_docs_context
  │      ├── shallow clone <docs_repo> into $TMPDIR/cs-docs-<uuid>
  │      ├── register with _CLEANUP_FILES
  │      ├── point bind mount at <clone>/projects/<docs_project_dir>
  │      └── export CLAUDE_SECURE_DOCS_CTX=<path> for template rendering
  │
  ├── 3. render prompt template
  │      {{VISION}} {{ARCHITECTURE_SUMMARY}} {{TODO_OPEN_ITEMS}}
  │      variables are slurped from the clone via extract_payload_field
  │      (UTF-8-safe python3 helper, already present)
  │
  ├── 4. docker compose up -d --wait
  │      + bind mount clone dir read-only into claude container
  │
  ├── 5. Claude runs, exits with envelope JSON
  │
  ├── 6. NEW: render_agent_report_bundle
  │      Produces up to three in-memory artifacts:
  │        a. reports/YYYY/MM/<event_type>-<id8>.md   (existing format, unchanged)
  │        b. optional: todo.md.patch                 (close loop: check off items)
  │        c. optional: ideas.md.append               (new findings from agent)
  │
  ├── 7. redact_report_file  (existing D-15 scrub against profile/.env)
  │
  ├── 8. NEW: publish_docs_bundle
  │      Reuses publish_report's clone-commit-push harness, but:
  │        - stages MULTIPLE files in one commit
  │        - still uses GIT_ASKPASS askpass shim + PAT via env var
  │        - commit message: "agent(<event_type>): <repo> <id8>"
  │        - push_with_retry (3-attempt non-ff loop) unchanged
  │
  └── 9. write_audit_entry
         extended fields:
           docs_changed: ["reports/...", "todo.md", "ideas.md"]
           docs_commit_sha: <sha>
```

### Data Flow 2: Inbound (Doc Repo → Agent) — NEW path

Two options; **Option A (webhook on doc repo)** is recommended.

#### Option A (recommended): GitHub webhook on the doc repo

```
Human (or CI) pushes to docs repo:
  projects/myapp/inbox/2026-04-13-refactor-hook.md       [NEW file]
  projects/myapp/todo.md                                  [modified]

GitHub sends `push` webhook to claude-secure webhook listener
  │
  ├── listener.py do_POST                               (existing)
  │      HMAC verify against profile.webhook_secret      (existing)
  │
  ├── NEW: resolve_profile_by_docs_repo
  │      New sibling to resolve_profile_by_repo — scans profiles for
  │      docs_repo match. If repo matches neither source nor docs,
  │      404 unknown_repo (existing path).
  │
  ├── NEW: event_type = "docs-inbox" or "docs-todo"
  │      Derived from which paths changed in the push payload
  │      (payload.commits[].added / modified against docs_project_dir).
  │
  ├── apply_event_filter                                (existing)
  │      New filter key: webhook_event_filter.docs_inbox
  │         { "paths": ["inbox/", "todo.md"] }
  │
  ├── persist_event + spawn_async                       (existing, unchanged)
  │
  └── do_spawn --event-file <path>                      (existing)
         + NEW template resolution picks webhook/docs-templates/docs-task.md
         + NEW step before prompt rendering:
              - If event_type == docs-inbox, shallow-clone docs repo,
                read inbox/<id>.md contents, inject as {{TASK_BODY}}
                into the prompt template.
              - If event_type == docs-todo, diff todo.md vs HEAD~1,
                treat newly-added unchecked items as tasks.
```

**Why Option A:** zero new long-running code; reuses the listener's HMAC verification and semaphore-bounded spawn pool; gets GitHub's push fanout for free; matches the established Phase 14/15 architecture.

#### Option B (fallback): polling daemon

```
webhook/docs_poller.py   (systemd timer: OnUnitActiveSec=5min)
  │
  ├── For each profile with docs_repo:
  │      git ls-remote <docs_repo> refs/heads/<branch>
  │      compare SHA to last-seen SHA in ~/.claude-secure/state/docs-last-sha
  │
  ├── On change:
  │      shallow clone, diff vs last SHA
  │      for each added inbox/*.md or newly-unchecked todo line:
  │          synthesize event JSON → POST to listener /internal/dispatch
  │
  └── Update state file with new SHA
```

Use Option B **only** if the doc repo cannot be configured with GitHub webhooks (private mirror, gitea, etc.) or if the user explicitly wants pull-based control. Option B adds a new daemon (extra launchd/systemd unit) and a new loopback HTTP endpoint on the listener — more surface area.

**Recommendation: ship Option A in v4.0. Defer Option B to a future phase as a feature flag.**

---

## Integration Points — New vs Modified

### Must-modify (existing code)

| File | Lines | What changes | Why |
|------|-------|--------------|-----|
| `bin/claude-secure` | ~618 `resolve_report_template` | Extend to `resolve_docs_template(category, event_type)` with category = report/todo/ideas/task-prompt | Multi-artifact rendering |
| `bin/claude-secure` | ~1052 `publish_report` | Rename internally to `publish_docs_bundle`; accept an array of (rel_path, body_path) pairs; single commit | Multi-file per-spawn commit |
| `bin/claude-secure` | ~1273 profile env export | Add `DOCS_REPO`, `DOCS_BRANCH`, `DOCS_PROJECT_DIR`, `DOCS_MODE`; keep `REPORT_REPO*` as aliases for back-compat | Profile schema extension |
| `bin/claude-secure` | `do_spawn` ~1296 (before `docker compose up`) | Insert `fetch_docs_context` call; add bind mount flag derivation | Agent needs vision/architecture context |
| `bin/claude-secure` | `spawn_cleanup` trap | Already handles `_CLEANUP_FILES`; just register the docs clone dir the same way | Ephemeral cleanup guarantees |
| `bin/claude-secure` | `write_audit_entry` ~900 | Add optional `docs_changed` (array) and `docs_commit_sha` fields; preserve PIPE_BUF 4KB ceiling by making them nullable | Audit fidelity |
| `webhook/listener.py` | `resolve_profile_by_repo` ~212 | Add parallel `resolve_profile_by_docs_repo`; call both in `do_POST`, docs path takes priority only if source repo lookup fails | Bidirectional routing |
| `webhook/listener.py` | `compute_event_type` ~44 | Add docs-specific composite types: `docs-inbox`, `docs-todo` | New event space |
| `webhook/listener.py` | `apply_event_filter` ~66 | Add `docs` branch: path-based filter on `payload.commits[].added/modified` | Quiet the noise from doc-unrelated pushes |
| `install.sh` | Phase 15/16 template installer steps | Add `webhook/docs-templates/` copy step (mirror `report-templates` pattern) | Default templates on install |
| `lib/profile.sh` (wherever profile validation lives) | Schema validator | Add new optional fields; warn on `report_repo` use (deprecation path) | Validation + migration |

### Must-create (new code)

| File | Responsibility | Depends on |
|------|---------------|------------|
| `bin/claude-secure` (functions) `stage_docs_update` | In-memory build of todo.md patch + ideas.md append + architecture.md proposal | Existing `_substitute_token_from_file` awk helper |
| `bin/claude-secure` (functions) `fetch_docs_context` | Startup shallow clone of docs repo, registered with cleanup trap | Existing `timeout 60 git clone` pattern |
| `webhook/docs-templates/agent-report.md` | Richer report template with "where worked / what changed / what failed / how to test / future findings" sections | Phase 15 variable set + new `{{AGENT_WORKED_ON}}`, `{{FILES_CHANGED}}`, `{{TESTS_ADDED}}`, `{{FOLLOWUPS}}` |
| `webhook/docs-templates/docs-task.md` | Prompt template used when an inbox task is dispatched | Claude reads `{{TASK_BODY}}` + `{{VISION}}` + `{{ARCHITECTURE_SUMMARY}}` |
| `webhook/docs-templates/todo-append.md` | Append-only format for new todos generated by agent | — |
| `.claude-docs.json` schema (in doc repo, not claude-secure repo) | Top-level doc repo config: project list, schema version | No code dep; consumed by `fetch_docs_context` validation |
| `tests/phase-N/test-docs-roundtrip.sh` | Integration test: seed inbox file → trigger webhook → assert report + todo.md updates pushed | Phase 16 test scaffolding (reuses fake-claude envelope fixture) |

### Must-NOT touch

| File / Component | Why |
|------------------|-----|
| `proxy/server.js` | Doc repo push traffic never crosses the proxy — git runs on the host, not in the claude container |
| `validator/` (Python service) | No new call-IDs, no iptables rule changes; the docs path uses no containerized network |
| Hook scripts (`hooks/pretooluse.sh`) | The claude container still cannot reach the internet directly; bind-mounted docs are a local filesystem read |
| `compose.yaml` network topology | The isolated `internal: true` network stays isolated |
| Anthropic proxy secret redaction | `DOCS_REPO_TOKEN` goes into profile `.env` and is loaded for redaction automatically by the existing mechanism — no new wiring |

---

## Security Considerations

### External git push from inside Docker — NOT what we do

**Strong recommendation: the PAT must never enter the claude container.** Every v4.0 git operation runs in `bin/claude-secure` on the host, outside the isolated network namespace. This is what Phase 16 already does, and the model must not change.

Why this matters:

1. **Bypass risk:** if git runs inside the claude container and the container has network access to github.com, that's a second egress path that the iptables/validator layer must cover. Today it doesn't — the validator only knows about Anthropic's API endpoint and whitelisted domains. Adding git-over-https to the whitelist widens the attack surface.
2. **PAT exposure:** once `DOCS_REPO_TOKEN` is in the container's env, any agent tool call with shell access can `echo $DOCS_REPO_TOKEN`. The proxy redacts on outbound HTTP, but a malicious agent could just `base64` or `xxd` the token first. The token is a write credential to a repo that may contain vision docs and specs — not catastrophic but not trivial.
3. **Replay surface:** the agent's own report writer becomes attackable. A prompt-injection attack via inbox/*.md could convince the agent to rewrite architecture.md with attacker content and push it.

**Mitigation in the recommended architecture:**

- Docs clone is bind-mounted **read-only** (`ro`) into the claude container.
- Agent never sees `DOCS_REPO_TOKEN`. The token lives in profile `.env` on the host, loaded by `bin/claude-secure`, used only by host-side `git clone` and `git push`.
- Agent writes its proposed changes to its own workspace (e.g. `/workspace/.agent-report.md`, `/workspace/.todo-patch.md`). After Claude exits, `bin/claude-secure` reads those files, runs them through the **existing D-15 redactor**, and commits them to the host-side clone.
- The doc repo push is still subject to `push_with_retry` with 3-attempt non-force semantics.
- GitHub webhook HMAC secret for the docs repo is stored in `profile.webhook_secret` (same field already used for the source repo). No new secret.

### Secret redaction on docs path

The existing `redact_report_file` (bin/claude-secure D-15) iterates profile `.env` values and replaces them with `<REDACTED:KEY>`. This must run on **every** artifact pushed to the docs repo, including:

- the main report
- any todo.md patch (agent could paste a log line containing a secret)
- any ideas.md append
- any architecture.md proposal

**Implementation rule:** `publish_docs_bundle` runs the redactor over every staged file before `git add`, unconditionally. No opt-out flag. No caller-provided pre-redacted bodies. Centralized in one function so we can audit it.

### Prompt injection from inbox files

When an inbox task file is injected as `{{TASK_BODY}}` into the prompt template, it's attacker-controlled input (anyone with push access to the docs repo can create one). The existing mitigation model is:

1. **Claude container isolation:** even a fully compromised prompt cannot exfiltrate secrets — the proxy redacts outbound traffic and the validator blocks non-whitelisted domains.
2. **PreToolUse hook:** any tool call Claude issues is domain-checked against the whitelist.
3. **No write access to docs repo from inside the container:** see above.

**Net:** prompt injection can cause the agent to do the wrong thing within the workspace and produce a bad report, but cannot leak secrets or push rogue commits.

**Residual risk:** the agent's report body lands in `publish_docs_bundle` and gets committed. A clever injection could convince the agent to write a report that tricks the _next_ agent reading it. Mitigation: keep reports under `reports/YYYY/MM/` (not under `architecture.md` / `vision.md`), never auto-consume agent-generated reports as context for subsequent spawns, and surface agent-generated ideas.md entries as diffs on the next `fetch_docs_context` for human review.

### Token rotation

Current Phase 16 treats `REPORT_REPO_TOKEN` as static. v4.0 should:

- Document the rotation path (`claude-secure profile set-token` CLI or direct `.env` edit).
- On 401 from github during clone/push, fail the audit entry with `status: "auth_error"` (new status distinct from `push_error`) so operators can alert on it.

---

## Build Order (dependency-driven)

Any v4.0 phase plan must execute in this order because each step depends on the previous:

1. **Phase A: Profile schema extension + back-compat aliases**
   - Add `docs_repo`, `docs_branch`, `docs_project_dir`, `docs_mode` to profile.json validator.
   - Alias `report_repo` → `docs_repo` when only the old field is set.
   - Add `DOCS_REPO_TOKEN` env var, falling back to `REPORT_REPO_TOKEN`.
   - **Deliverable:** no behavior change; existing Phase 16 path keeps working.

2. **Phase B: Multi-file publish bundle (outbound path)**
   - Refactor `publish_report` internals to accept N files per commit.
   - Add `render_agent_report_bundle` that produces the new richer report template.
   - Ship new `webhook/docs-templates/agent-report.md`.
   - Keep the legacy single-file template path available behind a flag.
   - **Deliverable:** existing profiles see richer reports on their next spawn; nothing else changes.

3. **Phase C: fetch_docs_context + bind mount**
   - Add startup clone step and read-only bind mount.
   - Extend prompt template variable set with `{{VISION}}`, `{{ARCHITECTURE_SUMMARY}}`, `{{TODO_OPEN_ITEMS}}`.
   - Handle missing docs_project_dir gracefully (skip mount).
   - **Deliverable:** agents receive docs context during spawn; no write path yet.

4. **Phase D: todo.md / ideas.md close-loop writer**
   - Agent writes `/workspace/.todo-patch.md` and `/workspace/.ideas-append.md`.
   - Host-side `stage_docs_update` reads them, validates, redacts, includes in the docs bundle commit.
   - **Deliverable:** complete outbound path; doc repo becomes a living project store.

5. **Phase E: Webhook inbound path (Option A)**
   - Add `resolve_profile_by_docs_repo` to listener.
   - Add `docs-inbox` and `docs-todo` event types to `compute_event_type`.
   - Add path-based filter branch.
   - Ship `webhook/docs-templates/docs-task.md` prompt template.
   - **Deliverable:** pushing an inbox file dispatches a spawn.

6. **Phase F: Interactive mode hook (optional)**
   - Extend `bin/claude-secure run` (interactive) to also publish a report on exit.
   - Shares the same `publish_docs_bundle` infrastructure.
   - **Deliverable:** interactive sessions also feed the doc repo.

7. **Phase G: macOS parity + integration tests**
   - Ensure all new code paths work under Docker Desktop on macOS (v3.0 compatibility).
   - Add roundtrip integration test: seed inbox → HMAC-signed webhook POST → assert docs commit SHA delta.
   - Add to pre-push smart-test-selection map.
   - **Deliverable:** v4.0 ready to ship.

**Parallelism:** Phases A and B can be built in parallel. Phase C depends on A. Phase D depends on B and C. Phase E depends on D. Phase F is independent of E but depends on D. Phase G is last.

---

## Decision Matrix: Key Design Choices

| Decision | Option A (chosen) | Option B | Why A |
|----------|-------------------|----------|-------|
| Git operations location | Host (`bin/claude-secure`) | Inside claude container | Keeps PAT out of isolated network; validator surface stays minimal; reuses Phase 16 code |
| Inbound trigger | GitHub webhook on docs repo | Polling daemon | No new long-running process; HMAC already solved; semaphore already built |
| Report layering | Extend Phase 16 pipeline | Replace with new service | 90% of the hard code (askpass, non-ff retry, redaction, audit) already works |
| Multi-file commit granularity | Single commit per spawn, multiple files | One commit per file | Atomic state transitions, single `report_url`, single audit line |
| Docs context delivery to agent | Read-only bind mount of shallow clone | Pre-rendered into prompt only | Agent can `grep` / `ls` — richer context; read-only prevents accidental writes |
| Multi-profile in one docs repo | Per-profile `docs_project_dir` | One repo per profile | Users want one "brain" across several projects |
| Token env var name | `DOCS_REPO_TOKEN` with `REPORT_REPO_TOKEN` alias | Rename hard, break existing | Zero-migration upgrade path for existing v2.0 users |
| todo.md mutation authorship | Agent writes patch file → host applies | Agent writes directly via git | Host-side application allows final redaction + sanity checks |

---

## Open Questions for Roadmap Planning

1. **Interactive mode scope** — does v4.0 ship with `claude-secure run` (interactive) also publishing reports? This doubles the integration test surface. **Recommendation: gated behind `profile.docs_mode = "report_and_tasks"` but on by default for new profiles; defer if Phase F slips.**

2. **todo.md format contract** — do we commit to GFM task list syntax (`- [ ]` / `- [x]`) with stable line-anchor IDs, or introduce a YAML frontmatter schema? GFM is simpler and renders on GitHub; YAML is more robust for mutation. **Recommendation: GFM with a trailing `<!-- id:abc123 -->` marker so the agent can target lines unambiguously.**

3. **Conflict resolution on concurrent agents** — if two profiles (or two events on the same profile) want to update `projects/myapp/todo.md` in the same second, the second `push_with_retry` will rebase-retry. Is 3 attempts enough? **Recommendation: keep 3 for now, add an audit counter for retries, revisit if we see real contention.**

4. **ideas.md deduplication** — should the agent be told what's already in ideas.md to avoid duplicating "findings"? **Recommendation: yes, inject the last N lines of ideas.md into the prompt as `{{IDEAS_RECENT}}`; defer dedup enforcement to the agent.**

5. **Docs repo bootstrapping** — who creates the initial `projects/<name>/` layout? A `claude-secure profile init-docs` subcommand? **Recommendation: yes, one-shot bootstrap writes empty vision/architecture/todo/ideas files, commits, pushes.**

6. **Should existing Phase 16 `reports/YYYY/MM/...` files stay flat, or move under `projects/<name>/reports/`?** Moving breaks existing report_urls in historical audit logs. **Recommendation: new reports go under `projects/<name>/reports/`; leave old ones where they are; document the cutover in the v4.0 release notes.**

---

## Sources

- **Direct code inspection** (HIGH confidence)
  - `bin/claude-secure` lines 343-378 (envelope builders), 475 (awk substitution), 618 (template resolver), 900 (audit writer), 975-1035 (push_with_retry), 1052-1144 (publish_report), 1159-1424 (do_spawn + Pattern E integration)
  - `webhook/listener.py` lines 44-134 (event type + filter), 170-206 (JsonlHandler), 212-244 (resolve_profile_by_repo), 250-277 (persist_event), 283-348 (spawn worker), 384-535 (do_POST)
  - `webhook/report-templates/issues-opened.md` (current template variable set)
- **Phase 16 design context** (HIGH confidence)
  - `.planning/phases/16-result-channel/16-CONTEXT.md` — D-01 through D-18 locked decisions, Pitfalls 1/3/4/6/11/14, canonical references
- **Project invariants** (HIGH confidence)
  - `.planning/PROJECT.md` — v4.0 milestone definition, core value ("no secret leaves uncontrolled")
  - `.planning/ROADMAP.md` — v2.0 complete (Phases 12-17), v3.0 in progress (Phases 18-19 done, 20-22 pending)
  - `CLAUDE.md` — stack constraints, security model, conventions

**No external sources consulted.** All conclusions derive from the shipped codebase and locked decisions. Confidence is HIGH because every integration point was read directly from the current source. The only MEDIUM-confidence section is the inbound webhook path (Option A) — GitHub does support push webhooks on any repo, but the exact filter tuning (`webhook_event_filter.docs`) is a new design and will need the same Wave-0-failing-tests pattern Phase 15/16 used.
