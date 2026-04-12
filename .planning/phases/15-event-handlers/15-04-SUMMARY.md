---
phase: 15-event-handlers
plan: 04
subsystem: installer
tags: [install, templates, webhook, d-12]
requires:
  - "15-01 (test scaffold with test_install_copies_templates_dir grep contract)"
  - "15-02 (webhook/templates/*.md present in repo)"
provides:
  - "install.sh install_webhook_service() copies webhook/templates/ to /opt/claude-secure/webhook/templates/ with always-refresh semantics"
affects:
  - "Production spawn resolve_template() fallback chain — /opt/claude-secure/webhook/templates/ now exists on installed hosts"
tech-stack:
  added: []
  patterns:
    - "D-12 always-refresh: cp over existing files, never rm -rf (listener-read-safe)"
    - "Idempotent mkdir -p + glob cp *.md (Pitfall 9 guard — no .git copy)"
    - "Defensive log_warn fallback if source dir missing (should never fire in practice)"
key-files:
  created: []
  modified:
    - install.sh
decisions:
  - "Placed template-copy block (step 5b) between listener.py copy (5) and config template copy (6) — matches plan Line 78 guidance and keeps 'code ships fresh' blocks grouped"
  - "Used glob *.md rather than recursive cp of webhook/templates/ directory — prevents accidental inclusion of dotfiles/subdirs and satisfies Pitfall 9 (.git guard) by construction"
  - "chmod 644 on templates — read-only for non-root; templates are consumed by render_template, never written by the listener"
metrics:
  duration: "~3min"
  tasks: 1
  files: 1
  completed: "2026-04-12T10:56:32Z"
---

# Phase 15 Plan 04: Install Default Webhook Templates Summary

**One-liner:** `install.sh install_webhook_service()` now installs `webhook/templates/*.md` to `/opt/claude-secure/webhook/templates/` with always-refresh semantics (D-12), unblocking production spawns that rely on `resolve_template`'s default fallback path.

## What Shipped

### install.sh — install_webhook_service() step 5b

Added a new block (10 lines) immediately after the listener.py copy (step 5) and before the config template copy (step 6):

```bash
# 5b. Copy default prompt templates (D-12: always refresh -- latest templates ship)
sudo mkdir -p /opt/claude-secure/webhook/templates
if [ -d "$app_dir/webhook/templates" ]; then
  sudo cp "$app_dir/webhook/templates/"*.md /opt/claude-secure/webhook/templates/
  sudo chmod 644 /opt/claude-secure/webhook/templates/*.md
  log_info "Copied default templates to /opt/claude-secure/webhook/templates/"
else
  log_warn "Source directory $app_dir/webhook/templates not found -- skipping template copy"
fi
```

**Key behaviors confirmed:**
1. Idempotent — `mkdir -p` on reinstall is a no-op; `cp` overwrites cleanly so no rm-before-copy race against a running listener.
2. Glob `*.md` (not `-r`) — excludes `.git`, dotfiles, subdirs by construction (Pitfall 9 guard).
3. chmod 644 — read-only for non-root; templates are consumed by render_template at spawn time, never written.
4. Defensive `log_warn` branch fires only if repo is missing the templates dir, which Plan 15-02 prevents.
5. Profile-level templates under `~/.claude-secure/profiles/<name>/prompts/` remain untouched — D-13 fallback chain still prefers them.

## Verification

### Grep contracts (plan Line 123)
- `bash -n install.sh` — syntax OK
- `grep -q 'mkdir -p /opt/claude-secure/webhook/templates' install.sh` — OK
- `grep -q 'cp "\$app_dir/webhook/templates/"' install.sh` — OK
- `grep -q 'chmod 644 /opt/claude-secure/webhook/templates/\*.md' install.sh` — OK
- `grep -c '/opt/claude-secure/webhook/templates' install.sh` → 4 (≥2 required)
- No `rm -rf /opt/claude-secure/webhook/templates` present (D-12 idempotent refresh via cp overwrite)

### Test-suite acceptance
- `bash tests/test-phase15.sh test_install_copies_templates_dir` → **PASS** (was FAIL before this plan)
- `bash tests/test-phase15.sh` → **28/28 PASS, 0 FAIL** — all of Phase 15 green
- `bash tests/test-phase13.sh` → **16/16 PASS** — no regression
- `bash tests/test-phase14.sh` → **15/16 PASS** — same as pre-edit state (the one failing test, `test_unit_file_lint`, is already documented in `.planning/phases/15-event-handlers/deferred-items.md` as a pre-existing Phase 14 issue unrelated to this plan)

### Deviations from Plan

None — plan executed exactly as written.

### Authentication Gates

None.

## Success Criteria

- [x] `install.sh` has `sudo mkdir -p /opt/claude-secure/webhook/templates` inside install_webhook_service
- [x] `install.sh` has `sudo cp "$app_dir/webhook/templates/"*.md /opt/claude-secure/webhook/templates/`
- [x] `install.sh` has `sudo chmod 644 /opt/claude-secure/webhook/templates/*.md`
- [x] `install.sh` does NOT contain `rm -rf /opt/claude-secure/webhook/templates` (D-12 compliant)
- [x] `install.sh` passes `bash -n` syntax check
- [x] Phase 14 test suite remains at 15/16 (pre-existing failure, no new regression)
- [x] `test_install_copies_templates_dir` from Phase 15 suite is now green
- [x] Full Phase 15 suite: 28/28 green

## Manual Verification Reserved

Per `15-VALIDATION.md`, the end-to-end smoke test on a real VM
(`sudo bash install.sh --with-webhook` followed by `ls /opt/claude-secure/webhook/templates/` and `find /opt/claude-secure -name .git`) is a manual-only check and was not executed in this sandbox. The automated grep + Phase 15 scaffold test provides structural coverage of the contract.

## Commit

- `98c2e2a` — `feat(15-04): install default webhook templates to /opt/claude-secure`

## Self-Check: PASSED
- install.sh modification FOUND (grep contracts 4/4)
- Commit 98c2e2a FOUND in git log
- Phase 15 suite 28/28 verified
