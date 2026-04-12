# Phase 16: Result Channel - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 16-result-channel
**Mode:** User-delegated auto-chain — user said "1" (continue auto-chain) so Claude selected all gray areas and chose recommended options with rationale, same pattern as Phases 14/15.

---

## Report Push Transport

| Option | Description | Selected |
|--------|-------------|----------|
| HTTPS + GitHub PAT via `git push` | PAT in profile `.env`. Reuses existing secret-loading pattern. Works in any environment. | ✓ |
| SSH deploy key | Requires new key management path (profile-level keys, known_hosts). Adds install.sh complexity. | |
| GitHub REST API (Contents endpoint) | No git operations. Simpler but can't batch multiple files, rate-limited, requires base64 encoding. | |

**Rationale:** HTTPS + PAT is the zero-new-infrastructure choice. Phase 12 profile `.env` already exists and loads secrets. Redaction pipeline already covers PAT so it can never leak into reports.

---

## Report Repo Configuration Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Global config (one doc repo for all profiles) | Single place to configure. Cross-contamination between projects. | |
| Per-profile (report_repo + report_branch + report_path_prefix in profile.json) | Matches Phase 12 profile isolation model. One profile → one doc repo. Optional: unset means no push. | ✓ |
| Per-event-type | Massive configuration surface. Not justified. | |

**Rationale:** Phase 12's core decision was per-profile isolation. Reports inherit that.

---

## Clone Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Cached bare repo per profile, fetch+worktree per spawn | Fast. State can corrupt. Requires cache directory management. | |
| Fresh shallow clone per spawn into $TMPDIR | Zero state leakage. Matches ephemeral spawn model. Slightly slower (one HTTPS clone per event). | ✓ |
| Worktree on a persistent bare repo | Middle ground. Adds complexity for no clear win. | |

**Rationale:** Ephemeral matches spawn's core design. No cache corruption possible. Slowdown is tens of milliseconds for a shallow clone.

---

## Audit Log Location

| Option | Description | Selected |
|--------|-------------|----------|
| Global `~/.claude-secure/executions.jsonl` | Single file. Mixes profiles and instances. Hard to rotate per-tenant. | |
| Per-profile, per-instance: `$LOG_DIR/${LOG_PREFIX}executions.jsonl` | Honors v1.0 multi-instance LOG_PREFIX convention. Test instance gets its own file. | ✓ |
| Per-event-type files | Overly fragmented. jq queries span multiple files. | |

**Rationale:** v1.0 established LOG_PREFIX convention. Reusing it means test runs don't pollute prod audit.

---

## Audit Writer Location

| Option | Description | Selected |
|--------|-------------|----------|
| `webhook/listener.py` after dispatch | Listener already has JsonlHandler. But doesn't know cost/duration/session_id (those come back from spawn later). Would need a roundtrip. | |
| `bin/claude-secure` inside `do_spawn` | Envelope already lives here. Covers webhook spawns AND replay spawns with one writer. | ✓ |
| Separate `claude-secure audit` helper command | Adds an unnecessary intermediate. | |

**Rationale:** do_spawn is where cost/duration/session_id exist. Single writer, both code paths.

---

## Report Template Source

| Option | Description | Selected |
|--------|-------------|----------|
| Hardcoded bash heredoc in bin/claude-secure | Simple. Impossible to customize without editing the script. | |
| Template files with Phase 13/15 fallback chain (profile override → env var → dev → /opt) | Mirrors prompt template system. Profile owners can customize. | ✓ |
| Single template with conditionals | Hard to maintain, hard to test. | |

**Rationale:** Consistency with Phases 13/15. Users already know how to customize templates.

---

## Secret Redaction Pre-Commit

| Option | Description | Selected |
|--------|-------------|----------|
| None (trust Claude output) | Report may echo secrets from prompt context. Violates core value. | |
| grep/sed pass over `.env` values | Exactly what proxy does. Phase 15 proved sed is unsafe for user data → use awk-from-file. | ✓ (awk-from-file) |
| Reuse Anthropic proxy redaction | Proxy is HTTP-only, not file-level. Out of scope. | |

**Rationale:** Core value mandates redaction on any egress. Reuses Phase 15 Pitfall 1 fix (awk-from-file) to avoid sed-escape bug.

---

## Push Failure Handling

| Option | Description | Selected |
|--------|-------------|----------|
| Hard-fail spawn on push failure | Webhook retries cost real $ and have no security benefit. | |
| Audit-always, push best-effort (warn on failure, exit 0) | Audit is source of truth. Push is visibility. Degrades gracefully. | ✓ |
| Retry push 3× with backoff | Over-engineering for rare event. | |

**Rationale:** Fail-closed on security, degrade on UX. Matches the rest of the project's failure philosophy.

---

## Claude's Discretion

Areas where Claude has implementation flexibility:
- Exact prose of default report templates
- Whether report push runs inline in `do_spawn` or in a separate `spawn_publish_report` helper
- Whether to add a `--skip-report` flag for testing (recommended yes, mirrors `--dry-run`)
- Audit entry written before or after push (recommended: after, to populate `report_url`)
- JSON key ordering in audit entries
- Test fixture reuse from Phase 15

## Deferred Ideas

- SSH deploy key support (Phase 17 hardening)
- Health webhook on push failure (HEALTH-02, future)
- Cost dashboards (COST-01, future)
- In-repo audit mirror
- Report template hot-reload
- Report PR creation vs direct commit
- Encrypted reports (gpg/age)
- Cross-repo mirroring
