# Technology Stack — v4.0 Agent Documentation Layer

**Project:** claude-secure (milestone v4.0)
**Researched:** 2026-04-13
**Scope:** Additions/changes only. The v1.0–v3.0 stack (Docker Compose, Node 22 proxy, Python 3.11 validator, Bash hooks, Python webhook listener) is **already validated** and NOT re-researched here.

---

## TL;DR

| Decision | Recommendation | Confidence |
|---|---|---|
| Remote write transport | **`git` CLI over HTTPS + fine-grained PAT** (extend Phase 16's existing `git push` path, NOT introduce `gh` or the REST API) | HIGH |
| Token type | **GitHub Fine-Grained PAT**, single-repo scope, `Contents: read/write` + `Metadata: read` | HIGH |
| Token storage | **Per-profile `.env` as `DOCS_REPO_TOKEN`**, loaded by existing profile loader, redacted by existing proxy redaction list | HIGH |
| Clone strategy for writes | **`git clone --depth 1 --filter=blob:none --sparse` + `git sparse-checkout set <project>/`** (partial + shallow + sparse) | HIGH |
| Clone strategy for reads (webhook ingest) | **Same sparse+shallow pattern** reused inside `do_spawn`, no separate cache | MEDIUM |
| Read path for "what changed in the doc repo" | **Existing Phase 14 webhook listener + GitHub `push` / `issues` webhooks** — do NOT poll, do NOT use GraphQL | HIGH |
| Conflict resolution on concurrent writes | **`git pull --rebase && git push` retry**, extend Phase 16 D-14 from 1 to 3 attempts with jittered backoff | HIGH |
| Commit signing | **Not required** for v4.0. Defer to a hardening phase. PAT + HTTPS + TLS is the trust anchor | MEDIUM |
| Webhook → task dispatch | **Reuse Phase 14 listener**; add an `issues.labeled` (label: `agent-task`) handler in Phase-15-style templates → `claude-secure spawn` with the issue body as the task prompt | HIGH |
| What NOT to add | `gh` CLI, Octokit / PyGithub / ghapi, `libgit2` / `pygit2` / `dulwich`, ssh deploy keys, git-lfs, GPG signing, polling daemons, indexing DB, sidecar doc-writer container | HIGH |

---

## What Phase 16 Already Gives Us (Reuse, Don't Rebuild)

**v4.0's doc layer is ~70% already built**. Phase 16 shipped a complete report-push pipeline. Everything below is either **reused from Phase 16** or **extended incrementally** — not replaced.

| Existing capability (Phase 16) | Reused as-is for v4.0 |
|---|---|
| `git clone --depth 1 --branch` into `$TMPDIR/<spawn-uuid>` | YES — add `--filter=blob:none --sparse` to reduce bandwidth on large doc repos |
| HTTPS + PAT transport, PAT in profile `.env` | YES — rename var from `REPORT_REPO_TOKEN` to `DOCS_REPO_TOKEN` (keep old name as deprecated alias) |
| `profile.json` fields `report_repo`, `report_branch`, `report_path_prefix` | YES — add `docs_repo` alias and a new `docs_project_path` field for the per-project subtree |
| Bash-level secret redaction of staged files via `_substitute_token_from_file` (Pitfall-1-safe awk) | YES — extend the redaction loop to run over **all** staged files, not just the single report file |
| Ephemeral clone directory registered with `_CLEANUP_FILES` / `spawn_cleanup` trap | YES — no change |
| `git push` with non-forced retry-on-rebase | YES — extend retry count from 1 → 3 with jittered backoff |
| Audit log JSONL (`executions.jsonl`) with `report_url` field | YES — add `docs_touched[]` array listing every path written |
| Proxy redaction (Anthropic path) scrubs any `.env` value that appears in request bodies | YES — `DOCS_REPO_TOKEN` inherits redaction for free via the Phase 7 env-file strategy |

**Implication:** this milestone is a thin layer on top of Phase 16. The research below focuses strictly on the *gaps* — multi-file atomic commits, structured project docs, and bidirectional read path via webhooks.

---

## New / Changed Stack Components

### 1. Git client — `git` CLI stays, with new flags

| Attribute | Value |
|---|---|
| Tool | `git` (already a host dependency) |
| Version | `>= 2.34` required for `--filter=blob:none --sparse` on clone. Debian bookworm and Ubuntu 22.04+ ship 2.34+. Dev box currently runs **2.43.0**. |
| Purpose | Shallow + partial + sparse clone of the docs repo for both write (report push) and read (webhook-dispatched task ingest) |
| New flags to add | `--filter=blob:none` (partial clone — defers blob fetch until checkout), `--sparse` (initializes empty sparse-checkout so `set` can narrow), then `git sparse-checkout set <profile.docs_project_path>` |
| Confidence | HIGH — Phase 16 already runs `git clone` successfully; sparse-checkout is stable since Git 2.25 |

**Why not `libgit2` / `pygit2` / `dulwich`:** Adds a C build dep (libgit2) or pure-python re-implementation (dulwich) to the security path. Any git-operation bug becomes a library compat problem. `git` CLI is boring, widely audited, and already present. No change.

---

### 2. Transport: `git push` over HTTPS — NOT `gh` CLI, NOT the REST API

This is the load-bearing decision. Three candidates were evaluated.

#### Option A (RECOMMENDED): `git` CLI + HTTPS + fine-grained PAT

```bash
# Phase 16 form — token in URL, avoids argv leakage by passing through env
git -c credential.helper= \
    -c "http.extraheader=AUTHORIZATION: bearer $DOCS_REPO_TOKEN" \
    push origin main
```

| Pros | Cons |
|---|---|
| Already proven in Phase 16 — zero new code to add a dep | Requires local clone (bandwidth, disk) |
| No new host dependency, no new container layer | Token must be handled carefully to avoid argv exposure (already handled in Phase 16) |
| **Atomic multi-file commits**: report.md, todo.md append, architecture.md patch land in **one commit** | |
| `git rebase` handles concurrent writes correctly | |
| Works identically inside the claude container AND on the host listener | |
| Inherits all Phase 3 + Phase 16 redaction paths for free | |

#### Option B (REJECTED): `gh` CLI (`gh api`, `gh repo`, `gh issue`)

`gh` v2.89 (March 2026) is stable and authoritative for human use. But as an automation primitive:

| Pros | Cons |
|---|---|
| Ergonomic for issues/PRs | **Adds a new ~30MB host dependency** (Go binary) |
| Built-in auth flow | Writes to its own `~/.config/gh/` — conflicts with per-profile auth isolation |
| Handles rate limits automatically | `gh auth login` is interactive — bad for systemd/container contexts |
| | **No atomic multi-file commit path** — `gh api` uses the Contents REST API, one file per call |
| | Adds a new secret-store surface (`gh` keyring) that Phase 3 redaction doesn't cover |
| | Recent regression: v2.88.0 broke `pr` commands for scope reasons (reverted in v2.88.1) |

**Decision:** Do NOT add `gh`. The only scenario where `gh` would win is pull-request creation, and Phase 16 D-14 already decided on direct-to-branch commits. Keep that decision.

#### Option C (REJECTED): GitHub REST API / GraphQL over `curl`

Directly `PUT /repos/{owner}/{repo}/contents/{path}` with base64-encoded content.

| Pros | Cons |
|---|---|
| No local clone needed | **No atomic multi-file commit** — 3 files = 3 API calls = 3 separate commits. A mid-sequence failure leaves the repo inconsistent |
| Smaller bandwidth for tiny updates | Must GET current file SHA before PUT (2 API calls per file) |
| No disk footprint | Rate-limited — 5000/hr shared across all profiles on the same token |
| | No `git rebase`-style conflict repair — must re-read SHA and retry on 409 |
| | Base64 payload bloats large reports ~33% |
| | Requires a hand-rolled REST client in bash that can't use standard git semantics |

**Decision:** Rejected. The atomicity gap alone disqualifies it. A v4.0 agent writing report.md + todo.md + architecture.md must commit those together or not at all.

**Summary:** `git push` over HTTPS is the only viable transport. Same decision as Phase 16, re-validated under v4.0's multi-file write requirements.

---

### 3. Authentication: Fine-Grained PAT, per profile

| Field | Value |
|---|---|
| Token type | **GitHub Fine-Grained Personal Access Token** (NOT classic PAT) |
| Scope | Repository access → single repository (the docs repo for this profile) |
| Permissions | `Contents: Read and write`, `Metadata: Read` (metadata is implicit/required) |
| Storage | Profile `.env` as `DOCS_REPO_TOKEN=github_pat_...` — loaded by existing Phase 12 profile loader, mounted via existing `env_file` directive |
| Redaction | **Automatic** — Phase 3 proxy redaction scrubs every `.env` value from Anthropic request bodies. Phase 16's `_substitute_token_from_file` already redacts `.env` values from staged report content. New token inherits both paths **for free**. |
| Rotation | Manual. User edits `~/.claude-secure/profiles/<name>/.env` and re-spawns (Phase 12 loads per-spawn). |
| Expiration | Enforced by GitHub (fine-grained PATs cannot be "no expiration"). Recommend 90-day rotation with calendar reminder. |

**Why fine-grained over classic PAT:**
- Classic PAT `repo` scope grants access to **every repo the user owns** — a leak is catastrophic.
- Fine-grained PAT is scoped to **one repository**.
- Expiration is enforced.
- GitHub's own recommendation since 2023.

**Why not GitHub App:** Adds significant ops surface — app registration, private key management, JWT generation, installation token exchange. Fine-grained PAT is the right point on the complexity curve for a solo-dev tool. Revisit in v5.0 if org-wide multi-repo coordination emerges.

**Why not SSH deploy keys:** Already deferred in Phase 16. Key management adds surface, no meaningful security win over scoped+expiring HTTPS PAT, and HTTPS traverses corporate proxies more reliably.

**Confidence:** HIGH. Sources: GitHub fine-grained PAT docs, Phase 16 precedent.

---

### 4. Read path: webhook-driven, NOT polling

The milestone says the webhook "reads from" the doc repo. Two interpretations:

**Interpretation A (CORRECT): Tasks arrive via webhooks from the doc repo itself.**

The docs repo is just another GitHub repo — it fires `issues`, `issue_comment`, `push`, and `pull_request` events to the exact same Phase 14 listener endpoint. A new Phase-15-style template routes `issues.labeled` (label = `agent-task`) → `claude-secure spawn --profile <profile> --event-file <persisted>` with the issue body as the prompt.

| Required changes | Size |
|---|---|
| Register docs repo as a webhook target in GitHub settings | User-side config, no code |
| Add `docs_repo_full_name` to `profile.json` for reverse routing | 1 schema line |
| New prompt template `webhook/templates/issues-labeled-agent-task.md` + handler wiring | Follows Phase 15 pattern, ~50 LOC |
| Payload sanitization for issue body injected into prompt | **MUST reuse Phase 15's sanitization pass** — no shortcuts |

**Interpretation B (REJECTED): Poll the docs repo.**

Would add a new systemd timer `git fetch`ing every N seconds. Reasons to reject:
- Duplicates the Phase 14 webhook listener.
- Webhooks are push-based, ~0 latency, cost nothing when idle.
- Timer adds a new scheduled-job surface already avoided in Phase 14.

**Reading files FROM the doc repo at spawn time** (e.g., "give the agent current architecture.md so it has context"): handled by the **same shallow+sparse clone the agent already does for writing**. One clone, both directions. Read → mutate locally → commit → push → cleanup trap.

**Confidence:** HIGH — all primitives exist.

---

### 5. Doc repo directory layout (pure convention, no new tool)

```
docs-repo/
├── <project-slug>/                    # one per bound profile
│   ├── todo.md
│   ├── architecture.md
│   ├── vision.md
│   ├── ideas.md
│   ├── specs/
│   │   └── <feature>.md
│   └── reports/                       # Phase 16 already writes here
│       └── YYYY/MM/<event>-<id>.md
└── README.md
```

**Requires zero new tooling.** Path convention enforced by `profile.json:docs_project_path` (default: slugified profile name). Sparse-checkout narrows to `<project-slug>/` per clone so unrelated profiles' histories don't transfer.

---

### 6. Multi-file commit & conflict handling

Phase 16 writes **one** file per push. v4.0 writes **many** (report + todo append + architecture patch + new spec). Same primitive:

```bash
git add <project>/reports/2026/04/issues-labeled-a1b2c3d4.md \
        <project>/todo.md \
        <project>/specs/new-feature.md
git commit -m "agent(<profile>): <event> <delivery_id_short>"

# Extended retry loop with jittered backoff
for attempt in 1 2 3; do
  git push origin main && break
  git pull --rebase origin main || { audit_status="docs_push_failed"; break; }
  sleep $(( (RANDOM % 3) + 1 ))
done
```

**Changes vs Phase 16:**
- Retry count: 1 → 3 (concurrent-write probability increases when multiple profiles share one docs repo)
- Add jittered backoff
- Commit message `agent(<profile>): <event> <id>` so `git log --grep` is useful for humans

**Why not `--force-with-lease`:** Never force-push to the docs repo. If rebase conflicts can't auto-resolve, audit as `status: "docs_push_failed"` and surface to stderr (Phase 16 D-17/D-18 pattern).

---

## Version Matrix (new / bumped only)

| Component | Version | Notes |
|---|---|---|
| `git` CLI (host) | `>= 2.34` | Required for `--filter=blob:none --sparse` on clone. Dev box at 2.43. Bump installer dep check. |
| Fine-grained PAT | n/a (GitHub feature) | Must expire. Recommend 90-day rotation. |
| `jq` | `>= 1.6` | Already a dep. No bump. |
| Python | `3.11+` | No bump. Webhook handler additions are pure stdlib. |
| Node.js | `22 LTS` | No change. Proxy untouched. |
| Docker Compose | `v2.24+` | No change. |
| `gh` CLI | **NOT ADDED** | Explicit rejection — see Option B. |

---

## Installer Changes

Minimal. Add to `install.sh`:

1. **Dependency check:** `git --version` ≥ 2.34 (already installed; just bump the minimum check).
2. **Profile schema doc:** Update `PROFILE_JSON_EXAMPLE` to include `docs_repo`, `docs_branch`, `docs_project_path`, and reference `DOCS_REPO_TOKEN` in the `.env` example.
3. **New templates directory:** `webhook/agent-task-templates/` with a starter template for `issues-labeled` events. Copied to `/opt/claude-secure/webhook/agent-task-templates/` using the Phase 15 D-12 always-refresh pattern.
4. **No new systemd units, no new daemons, no new containers.**

---

## What NOT to Add (Security-Surface Discipline)

This is a **security** tool. The smallest viable addition wins.

| Avoid | Why | Use Instead |
|---|---|---|
| `gh` CLI | New ~30MB binary, conflicts with per-profile auth isolation, interactive auth flow, v2.88.0 scope regression, no atomic multi-file commit | `git` CLI already installed |
| GitHub REST/GraphQL client libraries (`PyGithub`, `ghapi`, `octokit`) | Pip/npm supply chain on the security path. None offer atomic multi-file commits. | `git` CLI |
| `libgit2` / `pygit2` / `dulwich` | C-ABI pin (libgit2) or pure-python re-implementation (dulwich). `git` CLI is battle-tested. | `git` CLI |
| SSH deploy keys (this milestone) | Key management overhead, already deferred in Phase 16 | Fine-grained PAT |
| GPG / Sigstore commit signing (this milestone) | Whole key-management surface; PAT+TLS is already the trust anchor; revisit in hardening | Plain commits authored as `claude-secure@localhost` |
| `git-lfs` | Docs are markdown — kilobytes, not megabytes | Regular git blobs |
| Polling daemon for docs repo | Duplicates the webhook listener; wasted bandwidth; timer surface | Webhook `push`/`issues` events |
| Indexing DB for reports | `git log` + directory listing already indexes the repo. No search feature is in-scope. | Filesystem + `git log` |
| Go/Rust microservice for git operations | We already have working bash. Rewrite-in-Rust is not a feature. | Bash + `git` CLI |
| Webhook secret rotation daemon | Manual rotation is acceptable at solo-dev scale | Manual edit of profile `.env` |
| `pre-commit` framework inside the agent clone | Adds install complexity inside an ephemeral clone | Manual redaction pass (already exists from Phase 16 D-15) |
| A `docs-writer` sidecar container | Adds a 4th container to a deliberately 3-container stack; agent container already has `git` | Agent writes directly; ephemeral clone cleaned by existing trap |

---

## Integration Points with Existing Stack

| Existing component | v4.0 additive change |
|---|---|
| `bin/claude-secure` `do_spawn()` | Extend Phase 16's report-push section to support multi-file commits (not a new function — widen the `git add` scope). Back-compat: if only `report_url` is produced, behavior is identical to Phase 16. |
| `profile.json` | Add `docs_repo`, `docs_branch` (default `main`), `docs_project_path` (default slugify(profile_name)). `report_repo`/`report_branch`/`report_path_prefix` become deprecated aliases. |
| Proxy secret redaction (Phase 3) | **No code change** — `DOCS_REPO_TOKEN` is a regular profile `.env` var and enters redaction automatically via Phase 7's env-file strategy. |
| PreToolUse hook (Phase 2) | **No code change** — `github.com` is already in most whitelists for git operations. If not, it's a whitelist edit, no hook logic change. |
| Validator iptables rules | **No code change** — outbound to `github.com:443` flows through existing git operations. Call-ID registered by the hook before each `git push` invocation. |
| Webhook listener (Phase 14) | Add 1 new template + handler wiring for `issues.labeled` events from the docs repo. Pattern is copy-paste from Phase 15. No listener core changes. |
| Audit log `executions.jsonl` | Extend schema with `docs_touched: string[]` alongside existing `report_url`. Downward-compat: old readers ignore the new field. |
| `spawn_cleanup` trap | **No change** — docs clone directory is already cleaned by `_CLEANUP_FILES`. |
| `install.sh` | One new dir to copy into `/opt/claude-secure/webhook/agent-task-templates/`. No new systemd unit, no new container. |

---

## Security Implications (the only section that matters)

1. **Token leak surface grows by 1 new secret per profile.** Mitigation: the new token flows through the exact same redaction path as every other secret (env_file → proxy redaction → report redaction). **No new redaction code needed.** This is the single biggest argument for reusing the Phase 16 transport.

2. **Multi-file commits can leak more secrets than single-file commits** if redaction is incomplete. Mitigation: Phase 16's `_substitute_token_from_file` runs on every staged file before `git add`, iterating over `.env` values. Extend the loop to **all** staged paths, not just `report.md`. ~3-line bash change.

3. **Webhook-dispatched tasks from the docs repo become a new prompt-injection vector.** Issue bodies can contain adversarial prompts. Mitigation: Phase 15 already sanitizes webhook payloads before prompt injection. The new `issues.labeled` handler **must** reuse that same sanitization pass. Additionally, gate dispatch on `sender.permissions` in the payload (only act when the labeling user has push access) or on a `profile.json:docs_task_senders` allowlist.

4. **Docs repo visibility.** If the docs repo is public, reports are public — a data exposure risk if Claude accidentally leaks project context. Mitigation: **strongly recommend docs repo be private**. Add a best-effort warning in the installer when `docs_repo` matches a public-repo URL pattern (cannot be fully verified without a GitHub API call we want to avoid).

5. **Commit authorship.** Commits authored as `claude-secure <claude-secure@localhost>` (Phase 16 D-13, set via env vars, not host git config). Preserves the principle that the agent never touches user-level git identity.

6. **No new inbound ports.** Phase 14 listener already bound to `127.0.0.1:9000`. Docs-repo webhooks point at the same endpoint. Zero new attack surface.

7. **No new outbound hosts.** `github.com` is almost certainly already in the hook whitelist for existing git operations. If `api.github.com` ends up needed (it should NOT, given the "no REST API" decision), it's one whitelist line.

---

## Sources

- [Permissions required for fine-grained personal access tokens — GitHub Docs](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens) — HIGH confidence (official)
- [Introducing fine-grained personal access tokens for GitHub — The GitHub Blog](https://github.blog/security/application-security/introducing-fine-grained-personal-access-tokens-for-github/) — HIGH confidence
- [Webhook events and payloads — GitHub Docs](https://docs.github.com/en/webhooks/webhook-events-and-payloads) — HIGH confidence
- [git-clone documentation](https://git-scm.com/docs/git-clone) — HIGH confidence
- [git-sparse-checkout documentation](https://git-scm.com/docs/git-sparse-checkout) — HIGH confidence
- [Get up to speed with partial clone and shallow clone — The GitHub Blog](https://github.blog/open-source/git/get-up-to-speed-with-partial-clone-and-shallow-clone/) — HIGH confidence
- [GitHub CLI Releases (gh 2.89.0, March 2026)](https://github.com/cli/cli/releases) — HIGH confidence (used to justify REJECTION of `gh`)
- `.planning/phases/16-result-channel/16-CONTEXT.md` — MANDATORY reference; defines the existing transport this work extends
- `.planning/phases/14-webhook-listener/14-CONTEXT.md` — defines the inbound webhook substrate to be reused
- `.planning/phases/15-event-handlers/15-CONTEXT.md` — defines the Phase 15 template fallback chain + payload sanitization pattern that the new `issues.labeled` handler must reuse
- Local verification: `git --version` = 2.43.0, `gh --version` = 2.45.0 on dev host (confirms host already has both; only `git` is on the dependency list)
