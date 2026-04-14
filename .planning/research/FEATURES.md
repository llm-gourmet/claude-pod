# Feature Landscape: Agent Documentation Layer

**Domain:** Agent coordination via dedicated documentation repo (doc-first agent system)
**Milestone:** v4.0 — subsequent milestone on top of existing v2.0 (headless + webhook + profile) infrastructure
**Researched:** 2026-04-13
**Overall confidence:** MEDIUM-HIGH

## Scope Note — What Is NEW vs Already Built

This milestone adds a **documentation layer** on top of infrastructure that already exists. Do not re-research or re-plan these pre-existing Phase 13-17 capabilities:

| Already Built (v2.0) | Phase | Status |
|----------------------|-------|--------|
| Headless CLI spawn (`claude-secure spawn`) | 13 | Done |
| Webhook listener with HMAC-SHA256 verification | 14 | Done |
| Event handlers (Issues, Push, CI Failure) with profile-scoped filtering | 15 | Done |
| Result channel — reports to separate doc repo + audit log (basic) | 16 | Done (foundation) |
| Profile system with `profile.json` | 12 | Done |
| Operational hardening, container reaper, E2E tests | 17 | Done |

**What v4.0 adds on top:**
1. A **standardized report template** (shape of the report, not the write mechanism)
2. A **dedicated doc repo structure** (per-project layout, rolling files, timestamped reports directory)
3. **Agent mandatory last-step reporting** (enforced via Stop hook, not just "optional best effort")
4. **Bidirectional webhook** (doc repo becomes a task *source* via Issues/TASKS.md, not just a sink)
5. **Profile ↔ doc repo binding** (each profile knows its target doc repo + credentials)
6. **Report indexing** (discoverability for humans + future agents)

Everything below is scoped to these six areas.

---

## Table Stakes

Features users expect — missing any of these and the documentation layer feels incomplete, untrustworthy, or unusable. These are the non-negotiable minimum for a doc-first agent system in 2026.

### T1. Standardized Agent Report Template
**Why expected:** Every modern multi-agent workflow (Claude Code HANDOFF.md, CodeSignal handoff schema, agent-context/handoff-notes) converges on roughly the same fields: goal, what was done, what failed, next steps. Users skimming 20 reports need a predictable shape. Without it, each agent invents its own format and reports become un-greppable.
**Complexity:** Low
**Shape (evidence-based from HANDOFF.md / handoff-notes / /handoff slash command pattern):**

```
---
profile: research-bot
task_id: issue-1234
started: 2026-04-13T14:02:00Z
finished: 2026-04-13T14:41:00Z
exit_status: success | partial | failed
---

## Goal
One-sentence statement of what this invocation was asked to do.

## Where I Worked
- src/proxy/redaction.js (L42-L98)
- tests/integration/test-proxy.sh

## What Changed (Thematically)
High-level: "Tightened placeholder matching to handle prefix collisions."
Not a commit log — the *shape* of the change.

## What Failed / What I Couldn't Do
- Could not reproduce the race on WSL2 (only Linux native)
- Skipped migrating whitelist.json schema — needs human decision

## How to Test / Verify
Commands a human or next agent can copy-paste:
  ./tests/integration/test-proxy.sh

## Future Findings / Scout Notes
Bugs/gaps/ideas discovered *while* working, that are out of scope for this task.
(Feeds back into TASKS.md / Issues per the TASKS.md scout pattern.)
```

**Dependencies:** None new — template is rendered by the Stop hook (see T3).
**Sources:** Claude Code /handoff command pattern, agent-context/handoff-notes convention, CodeSignal handoff schema.

### T2. Dedicated Documentation Repo with Per-Project Structure
**Why expected:** RepoSwarm, Zencoder Repo-Info Agent, and the broader "agent context repo" pattern all use a dedicated git repo as the source of truth. Users expect one repo they can clone, grep, and review — not reports scattered across each source repo. Per-project subdirs are table stakes because one doc repo typically serves many source projects.
**Complexity:** Low (structure) / Medium (tooling)
**Expected structure:**

```
docs-repo/
├── projects/
│   ├── claude-secure/
│   │   ├── todo.md              # rolling, agent-editable
│   │   ├── architecture.md      # rolling, thematic
│   │   ├── vision.md            # human-primary, agent-read-mostly
│   │   ├── ideas.md             # scratch pad
│   │   ├── specs/               # long-form specs
│   │   └── reports/
│   │       ├── 2026-04-13T14-41-00Z_research-bot_issue-1234.md
│   │       └── 2026-04-13T09-12-00Z_fix-bot_push-main.md
│   └── other-project/...
└── README.md
```

**Key design choices (from research):**
- **Rolling files** (todo.md, architecture.md) live next to **append-only timestamped reports** (reports/). The rolling files are "current state"; the reports are "audit trail."
- **One report per invocation**, filename `{iso8601}_{profile}_{task-id}.md`. Timestamped filenames are sortable, greppable, never conflict under parallel spawns.
- **todo.md follows TASKS.md spec** (see T4) — P0/P1/P2/P3 priority headings with checkbox tasks.

**Dependencies:** Phase 16 already writes *something* to a separate doc repo. v4.0 formalizes the layout and per-project subdirs.
**Sources:** TASKS.md / AGENTS.md spec, RepoSwarm architecture-wiki pattern, Zencoder `.zencoder/rules/repo.md` persistent project memory.

### T3. Mandatory Last-Step Reporting (Stop Hook Enforcement)
**Why expected:** "Write a report before you exit" as a soft instruction in the system prompt is unreliable — agents forget, time out, or skip it under token pressure. The 2026 consensus (confirmed by Claude Code Stop hook docs) is to enforce mandatory last-step actions via the **Stop hook**, which fires when the main agent finishes responding and receives `last_assistant_message` on stdin. The hook is the only way to guarantee "no session exits without a report."
**Complexity:** Medium
**Behavior:**
1. Stop hook fires on agent completion (headless and interactive)
2. Hook reads `stop_hook_active`, `last_assistant_message`, session metadata
3. Hook either (a) expects a report file already written by the agent at a known path, or (b) synthesizes a minimal report from `last_assistant_message` + git diff + session metadata if the agent forgot
4. Hook commits + pushes the report to the doc repo (or queues it for the host-side result channel)
5. Non-zero exit from the hook does NOT block the session from ending (Stop hook semantics) — but failures log loudly

**Design decision needed:** Does the Stop hook *generate* the report from session state, or does it *validate* that the agent already wrote one? Hybrid (validate-or-synthesize) is the robust default.
**Dependencies:** Claude Code Stop hook (already available), existing Phase 16 result channel, profile.json (for doc repo target).
**Sources:** Claude Code hooks reference (code.claude.com/docs/en/hooks), 2026 Stop hook pattern articles.

### T4. Bidirectional Task Flow: Doc Repo → Agent
**Why expected:** Writing reports back is half the value. The other half — and the one users will miss most if absent — is *reading tasks from the doc repo and dispatching them to agents*. This is the entire premise of TASKS.md and GitHub Agentic Workflows (launched technical preview Feb 2026). Once users have a doc repo, they expect "edit todo.md → agent picks it up."
**Complexity:** Medium
**Two input surfaces (pick one or both):**

**4a. GitHub Issues in the doc repo as task queue**
- Existing webhook listener (Phase 14/15) already handles Issues events
- v4.0 wires it so Issues *on the doc repo itself* get labeled → dispatched to the right profile → spawned against the right source project
- Profile binding (T5) provides the routing: issue label `project:claude-secure` + label `profile:research-bot` → spawn research-bot in claude-secure workspace
- Report is written back as an issue comment AND as a reports/ file

**4b. TASKS.md polling (lighter-weight alternative or supplement)**
- Webhook listener (or a timer) periodically clones/pulls the doc repo
- Parses `projects/{project}/todo.md` for unclaimed P0-P3 checkboxes
- Claims by appending `(@profile-name)`, commits, spawns agent
- On completion, agent removes the task block and commits (per TASKS.md spec)

**Recommended:** Start with 4a (Issues) — reuses existing webhook infrastructure entirely, just points it at the doc repo. Add 4b later if users want file-driven workflows.
**Dependencies:** Existing webhook listener (Phase 14), Issues event handler (Phase 15), profile.json.
**Sources:** TASKS.md spec (tasksmd.github.io), GitHub Agentic Workflows (Feb 2026 technical preview), github.com/tasksmd/tasks.md.

### T5. Profile ↔ Doc Repo Binding
**Why expected:** Phase 12 introduced profile.json. The moment you have multiple profiles (research-bot, fix-bot, triage-bot) and multiple source projects, "which doc repo does this profile write to?" becomes the obvious next question. Users expect each profile to declare its doc repo up front so spawns are self-contained.
**Complexity:** Low
**Shape:**

```json
{
  "name": "research-bot",
  "docs_repo": {
    "url": "git@github.com:user/agent-docs.git",
    "project_dir": "projects/claude-secure",
    "credential_key": "DOCS_REPO_KEY",
    "branch": "main"
  }
}
```

- `DOCS_REPO_KEY` is an env var holding a deploy key / PAT scoped to the doc repo only
- Every spawn mounts the credential via the existing env_file pattern (same mechanism as Phase 16 result channel)
- Whitelist.json must allow the doc repo's git host (github.com is almost certainly already whitelisted)

**Dependencies:** profile.json (Phase 12), whitelist.json, env_file (already established pattern).
**Sources:** Phase 12-16 internal design; standard git-credentials-per-profile pattern.

### T6. Report Indexing / Discoverability
**Why expected:** Once you have 100+ timestamped reports, "what did we do yesterday?" and "has anyone touched the proxy this week?" become impossible without an index. Every mature doc-first system (GitHub Agentic Workflows daily status reports, RepoSwarm architecture wiki) has *some* form of aggregation.
**Complexity:** Low
**Minimum viable:**
- `projects/{project}/reports/INDEX.md` — auto-appended one-line entry per report: `- 2026-04-13 14:41 [research-bot] issue-1234: Tightened placeholder matching → [report](2026-04-13T14-41-00Z_research-bot_issue-1234.md)`
- Append happens in the same Stop hook commit as the report itself
- Grep-friendly; no database, no search index, no build step

**Anti-requirement:** Do NOT build a search UI, daily digest generator, or database-backed dashboard in v4.0. The project explicitly lists "Audit log dashboard" as out of scope.
**Dependencies:** T3 (Stop hook already commits reports).
**Sources:** Convention from AGENTS.md ecosystem + TASKS.md git-log-as-history philosophy.

---

## Differentiators

Features that set this system apart. Not expected, but high-value given claude-secure's existing security posture and the fact that this is the only Claude Code wrapper running in a fully network-isolated container.

### D1. Security-Preserving Report Pipeline
**Value proposition:** Reports are written *inside* the isolated container by the agent, but the push to the doc repo goes through the same whitelist validator + anthropic proxy redaction path as every other outbound call. A report accidentally containing a secret would be caught by the proxy's placeholder redaction before it ever reaches GitHub. No other agent-doc system can claim this because no other system puts the agent behind a redacting proxy.
**Complexity:** Low (the machinery exists; just needs the doc repo git push to traverse it)
**Why it matters:** Turns the doc repo from "accidental secret leak vector" into "audited security channel."
**Dependencies:** Existing proxy + validator + whitelist (v1.0). Just add the doc repo git host to whitelist if not present.

### D2. Scout-Mode Findings Feed Back Into TASKS.md
**Value proposition:** The TASKS.md spec highlights a "Scout" pattern — while working a task, the agent actively identifies bugs, missing tests, stale docs, and adds them as new tasks to the queue. Combining this with the standardized report template's "Future Findings" section creates a self-improving backlog: every completed task grows the task pool for future agents. This is what makes doc-first systems compound over time.
**Complexity:** Low (just template convention + Stop hook wiring)
**How it works:** The "Future Findings" section of the report (T1) isn't just free text — each bullet becomes a proposed entry that the Stop hook appends to `projects/{project}/todo.md` under P3 (or opens as a draft Issue). Humans triage later.
**Dependencies:** T1, T3.
**Sources:** TASKS.md scout pattern (tasksmd.github.io).

### D3. Per-Profile Report Conventions via Template Inheritance
**Value proposition:** A research-bot's report shouldn't look identical to a fix-bot's. A research agent's "What Changed" is mostly findings; a fix agent's is mostly files touched. Allowing profile.json to declare a report template override (while inheriting the base shape from T1) keeps reports comparable within a profile type but meaningful across profile types.
**Complexity:** Medium
**Shape:** `profile.json` → `report_template: "research" | "fix" | "triage" | "custom:path/to/template.md"`
**Caveat:** Ship T1 (single template) first. Add this only if users have 3+ profile types and request it. YAGNI applies.
**Dependencies:** T1, profile.json.

### D4. Deterministic Report Filenames Enable Lock-Free Parallel Spawns
**Value proposition:** `{iso8601}_{profile}_{task-id}.md` cannot collide across parallel spawns because ISO8601 includes milliseconds and task-id is unique per invocation. No file locks, no coordination, no race conditions — just git auto-merging non-adjacent writes. This is a direct benefit of the TASKS.md "delete the whole block, git handles merges" philosophy applied to reports. Worth calling out because it preserves the "multiple agents simultaneously" property Phase 17 already delivers.
**Complexity:** Zero additional (just filename convention)
**Dependencies:** T2, existing Phase 17 parallel spawn support.

---

## Anti-Features

Features that sound good but actively harm the system. Do NOT build these in v4.0.

### A1. Streaming / Live Agent Dashboards
**Why avoid:** Violates "buffered, not streaming" architectural constraint of the proxy (project-wide decision). Also adds massive ops surface (websockets, SSE, frontend). Reports are post-completion artifacts — humans read them later, not in real-time. Live dashboards are the thing every doc-first system wishes it hadn't built.
**What to do instead:** Timestamped reports + INDEX.md. If a human wants to watch an agent work, they tail the container log directly.

### A2. Agent-Editable Architecture / Vision Docs Without Gates
**Why avoid:** If the agent can freely rewrite `architecture.md` and `vision.md`, two problems appear: (1) drift — the docs become "what the last agent thought" instead of ground truth, and (2) accidental deletion of human-authored intent. The TASKS.md convention is explicit: some files are human-primary, agents only append.
**What to do instead:** Convention by file type. `reports/` = agent write (append-only by filename). `todo.md`, `ideas.md` = agent read/write (but under explicit task instruction). `architecture.md`, `vision.md` = agent read-mostly; writes require a specific task with human-in-the-loop review before push.

### A3. Verbose Per-Tool-Call Report Entries
**Why avoid:** Allen Chan's 2026 anti-patterns work (and the U-shaped context accuracy curve from Liu et al. 2023) makes it clear: dumping every tool invocation into a report destroys signal. "Found 1,247 records, top 5: …" beats full dumps. A report listing every file read, every grep, every bash command is unreadable by humans and harmful to the next agent that has to load it as context.
**What to do instead:** Thematic summaries ("Where I Worked" = file list, not tool trace). Keep tool traces in container logs where they belong.

### A4. Auto-Close Issues on Report Write
**Why avoid:** Agents are wrong sometimes. Auto-closing a GitHub Issue the moment a report lands removes the human-review checkpoint that catches agent mistakes. The 2026 consensus from Stack Overflow + Anthropic's Agentic Coding Trends report is "layered review: self-review → peer review → human review."
**What to do instead:** Report as issue comment + label `agent:awaiting-review`. Human closes after reading.

### A5. Custom Markdown Parser / DSL for Report Sections
**Why avoid:** LLMs parse markdown natively (the entire TASKS.md philosophy). Inventing a YAML DSL, JSON schema, or TOML format for reports adds parser bugs, schema migrations, and "my format is better" bikeshedding — while losing the free superpower that every agent already reads markdown fluently.
**What to do instead:** Plain markdown with frontmatter. Section headers ARE the schema.

### A6. Cross-Project Report Aggregation / Search Service
**Why avoid:** Adds a service to maintain, an index to rebuild, a database to back up. Git + grep + the per-project INDEX.md cover 95% of real queries. The remaining 5% is a user-specific concern, not a v4.0 requirement. "Audit log dashboard" is already explicitly out of scope in PROJECT.md.
**What to do instead:** `git grep "proxy redaction" projects/*/reports/` — works today, needs nothing built.

### A7. Agent-Authored Profile Changes
**Why avoid:** Profiles hold security-critical config (DOCS_REPO_KEY, credential mounts, whitelist scope). An agent that can rewrite its own profile can exfiltrate its credentials or broaden its whitelist. This is the same class of concern that motivated root-ownership of hooks in v1.0.
**What to do instead:** Profile files remain root-owned, agent-read-only. Any profile change requires human action outside the container.

---

## Feature Dependencies

```
T5 (Profile ↔ doc repo binding)
  │
  ├──> T3 (Stop hook uses profile.docs_repo to know where to write)
  │      │
  │      ├──> T1 (Stop hook renders the template)
  │      ├──> T2 (Stop hook knows the per-project directory)
  │      └──> T6 (Stop hook appends to INDEX.md)
  │
  └──> T4 (Webhook dispatch uses profile to route doc-repo events to spawns)
         │
         └── reuses existing Phase 14/15 webhook + issues event handler

D1 (Security-preserving pipeline) — cross-cuts all T1-T6, no new code, just routing
D2 (Scout findings) — requires T1 (template section) + T3 (Stop hook append)
D3 (Per-profile templates) — layered on T1 after v4.0 ships
D4 (Deterministic filenames) — folded into T2
```

**Minimum build order:**
1. T5 — Profile schema update (unblocks everything)
2. T2 — Doc repo directory conventions (unblocks writes)
3. T1 — Report template (defines output shape)
4. T3 — Stop hook enforcement (guarantees reports exist)
5. T6 — Index append (trivial once T3 works)
6. T4 — Bidirectional webhook routing (depends on T5 for routing, reuses Phase 14/15)
7. D1 — Verify security path (should be free)
8. D2 — Scout findings append (small template + hook addition)

## MVP Recommendation

**Must ship in v4.0:**
1. T5 (profile binding) — 1 phase
2. T2 + T1 + T3 (template + structure + Stop hook enforcement) — 1-2 phases, this is the core
3. T4 (bidirectional via Issues, reusing Phase 14/15) — 1 phase
4. T6 (INDEX.md append) — folds into T3's phase
5. D1 (security path verification) — smoke test, folds into T3

**Defer to v4.1 or later:**
- D2 (scout findings auto-append) — nice-to-have, add after real usage reveals whether humans actually triage the findings
- D3 (per-profile templates) — premature until 3+ profile types exist and users ask
- TASKS.md file-polling (T4b) — ship Issues-based routing first; file-polling only if users prefer file-driven workflows

**Never ship (anti-features):** A1-A7 above.

## Dependencies on Existing Phase 13-17 Infrastructure

This feature set is explicitly a layer on top of already-shipped work. Call out the reuse:

| New Feature | Reuses / Requires |
|-------------|-------------------|
| T1 report template | Nothing (pure convention) |
| T2 doc repo structure | Phase 16 result channel (already writes to a separate doc repo — v4.0 formalizes the layout) |
| T3 Stop hook enforcement | Phase 13 headless spawn (Stop hook fires in both headless and interactive), profile mount pattern from Phase 12 |
| T4 bidirectional webhook | **Entirely reuses Phase 14 webhook listener + Phase 15 Issues event handler + HMAC verification.** No new listener, no new event types — just re-targeting the doc repo as an event source and adding doc-repo-specific routing. |
| T5 profile binding | Phase 12 profile.json schema extension (backward-compatible field addition) |
| T6 INDEX.md append | Nothing new — uses git commit in the same Stop hook as T3 |
| D1 security pipeline | Phase 1 proxy + validator + whitelist (v1.0) — just add doc repo host to whitelist |
| D2 scout findings | T1 + T3; no new infrastructure |

**No new long-running services required.** No new containers. No new listeners. The entire v4.0 layer is: one Stop hook, one profile schema field, one event routing rule, and a directory convention.

## Confidence Assessment

| Area | Confidence | Reason |
|------|------------|--------|
| Standardized report template shape | HIGH | Multiple independent sources converge on same fields (Claude Code /handoff, agent-context/handoff-notes, CodeSignal handoff schema) |
| Doc repo structure / TASKS.md conventions | HIGH | TASKS.md spec is published, stable, has ecosystem adoption |
| Stop hook as enforcement mechanism | HIGH | Documented in Claude Code hooks reference, widely used in 2026 automation articles |
| Bidirectional via GitHub Issues | HIGH | GitHub Agentic Workflows in technical preview Feb 2026 confirms this is industry direction |
| Anti-pattern list (A1-A7) | MEDIUM | Some directly sourced (A1 from buffered proxy constraint, A3 from Allen Chan anti-patterns 2026); others inferred from security posture |
| Dependency graph / MVP ordering | MEDIUM | Based on stated Phase 13-17 infrastructure; actual file paths and integration points need verification against existing code during planning |

## Sources

- [TASKS.md spec — tasksmd.github.io](https://tasksmd.github.io/tasks.md/) — HIGH, primary source
- [tasksmd/tasks.md GitHub](https://github.com/tasksmd/tasks.md) — HIGH, primary source
- [AGENTS.md](https://agents.md/) — HIGH, companion spec
- [GitHub Agentic Workflows technical preview (Feb 2026)](https://github.blog/changelog/2026-02-13-github-agentic-workflows-are-now-in-technical-preview/) — HIGH, industry direction
- [GitHub Agentic Workflows overview — github.github.com/gh-aw](https://github.github.com/gh-aw/) — HIGH
- [Automate repository tasks with GitHub Agentic Workflows](https://github.blog/ai-and-ml/automate-repository-tasks-with-github-agentic-workflows/) — HIGH
- [Claude Code hooks reference — code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) — HIGH, primary Stop hook source
- [Claude Code Hooks: All 12 Events with Examples (2026) — Pixelmojo](https://www.pixelmojo.io/blogs/claude-code-hooks-production-quality-ci-cd-patterns) — MEDIUM
- [Delegating Work with Handoffs — CodeSignal](https://codesignal.com/learn/courses/mastering-agentic-patterns-with-claude/lessons/delegating-work-with-handoffs-1) — MEDIUM
- [AI Agent Anti-Patterns Part 2 — Allen Chan, Mar 2026](https://achan2013.medium.com/ai-agent-anti-patterns-part-2-tooling-observability-and-scale-traps-in-enterprise-agents-42a451ea84ec) — MEDIUM, source for A3
- [2026 Agentic Coding Trends Report — Anthropic](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf?hsLang=en) — HIGH, layered-review anti-pattern source
- [RepoSwarm architecture wiki pattern](https://robotpaper.ai/reposwarm-give-ai-agents-context-across-all-your-repos/) — MEDIUM, dedicated doc repo precedent
- [The Case for Markdown as Your Agent's Task Format — dev.to](https://dev.to/battyterm/the-case-for-markdown-as-your-agents-task-format-6mp) — MEDIUM
- [How to Build an AI Command Center for Managing Multiple Claude Code Agents — MindStudio](https://www.mindstudio.ai/blog/ai-command-center-managing-multiple-claude-code-agents) — MEDIUM
