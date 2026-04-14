# Phase 27: v2.0 Verification Backfill - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning
**Mode:** Auto (--auto flag active — all decisions selected by recommended defaults)

<domain>
## Phase Boundary

Bring v2.0 audit artifacts up to standard. Three mechanical tasks — no new code, no behavior changes:

1. **Create 3 missing VERIFICATION.md files** — phases 12, 13, 16 (never had formal verification run post-execute-phase)
2. **Update 6 stale VALIDATION.md files** — phases 12–17 (all show `nyquist_compliant: false` despite passing test suites)
3. **Fix stale traceability** — REQUIREMENTS.md checkboxes (PROF-01/02/03 unchecked) and status strings (OPS-01/02 show "In Progress")

The milestone audit (v2.0-MILESTONE-AUDIT.md) is the authoritative source for what needs fixing. All code was delivered — this phase closes the documentation gap.

</domain>

<decisions>
## Implementation Decisions

### Verification Creation Method (phases 12, 13, 16)

- **D-01:** Spawn gsd-verifier per phase as separate agents — each agent gets a fresh context window to inspect the phase's code, test scripts, and SUMMARY.md evidence, then creates a VERIFICATION.md that reflects actual delivered state.
- **D-02:** Verifier agents should cross-reference SUMMARY.md frontmatter `requirements_completed` with actual test results in REQUIREMENTS.md. Evidence basis: SUMMARY.md + passing test suite (not re-running tests from scratch).
- **D-03:** VERIFICATION.md `status` should be `passed` if SUMMARY.md confirms delivery and test script shows passing tests. Do not set `gaps_found` just because verification was late.

### VALIDATION.md Update Strategy (phases 12–17)

- **D-04:** Update frontmatter flags to reflect actual delivered state:
  - `nyquist_compliant: true` — all phases shipped Wave 0 test scaffolds per SUMMARY evidence
  - `wave_0_complete: true` — Wave 0 was executed (tests shipped)
  - `updated:` — set to today's date (2026-04-14)
- **D-05:** Do NOT alter the body content of VALIDATION.md files beyond frontmatter — body content may have phase-specific notes worth preserving.
- **D-06:** All 6 VALIDATION.md files need updating: phases 12, 13, 14, 15, 16, 17.

### Traceability Fix Scope (REQUIREMENTS.md)

- **D-07:** Fix REQUIREMENTS.md checkboxes: `PROF-01 [ ]` → `[x]`, `PROF-03 [ ]` → `[x]`.
- **D-08:** Fix traceability table status strings: OPS-01/OPS-02 entries showing "In Progress" → "Complete". Update phase reference column to include Phase 27 as the backfill verifier.
- **D-09:** Scope is limited to REQUIREMENTS.md traceability section — do not alter requirement definitions or add new requirements.

### Claude's Discretion

- Wave structure for plans: executor may use a single wave (all tasks are independent documentation edits) or multi-wave (verifier agents → VALIDATION fixes → traceability fix). Planner decides.
- Whether to use one gsd-verifier agent per phase or batch multiple phases per agent. Separate agents recommended for context isolation but planner may optimize.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Audit Source (authoritative gap list)
- `.planning/v2.0-MILESTONE-AUDIT.md` — Full list of tech debt items, per-phase gap descriptions, and traceability table showing what's stale. Primary source for what to fix.

### Phase Directories (phases needing VERIFICATION.md)
- `.planning/phases/12-profile-system/` — SUMMARY.md confirms PROF-01/02/03; test script: `tests/test-phase12.sh`
- `.planning/phases/13-headless-cli-path/` — SUMMARY.md confirms HEAD-01..05; test script: `tests/test-phase13.sh`
- `.planning/phases/16-result-channel/` — SUMMARY.md confirms OPS-01 (15/15) + OPS-02 (13/13); test script: `tests/test-phase16.sh`

### Phase Directories (phases needing VALIDATION.md update)
- `.planning/phases/12-profile-system/12-VALIDATION.md`
- `.planning/phases/13-headless-cli-path/13-VALIDATION.md`
- `.planning/phases/14-webhook-listener/14-VALIDATION.md`
- `.planning/phases/15-event-handlers/15-VALIDATION.md`
- `.planning/phases/16-result-channel/16-VALIDATION.md`
- `.planning/phases/17-operational-hardening/17-VALIDATION.md`

### Traceability Target
- `.planning/REQUIREMENTS.md` — Fix PROF-01/03 checkboxes and OPS-01/02 status strings in traceability section

### Evidence Basis
- `tests/test-phase12.sh`, `tests/test-phase13.sh`, `tests/test-phase16.sh` — Test scripts confirming delivery (do not re-run; use SUMMARY evidence)
- `.planning/phases/12-profile-system/12-01-SUMMARY.md`, `12-02-SUMMARY.md` etc. — SUMMARY frontmatter `requirements_completed` fields are the primary evidence for VERIFICATION.md content

</canonical_refs>
