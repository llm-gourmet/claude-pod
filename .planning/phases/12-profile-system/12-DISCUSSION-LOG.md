# Phase 12: Profile System - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md -- this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 12-profile-system
**Areas discussed:** Profile vs Instance, Repo-to-profile mapping, Directory layout, CLI interface changes, Superuser mode

---

## Profile vs Instance

| Option | Description | Selected |
|--------|-------------|----------|
| Rename instances to profiles | Clean break -- one concept, not two. Migration handles rename. | ✓ |
| Profiles wrap instances | Profile as higher-level concept containing instance config. | |
| Profiles are separate | Two parallel systems for interactive vs headless. | |

**User's choice:** Rename instances to profiles
**Notes:** None

### Follow-up: Migration strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Auto-migrate on first run | Same pattern as existing single-to-multi migration. | |
| Explicit command | User runs 'claude-secure migrate'. | |

**User's choice:** Neither -- remove instances entirely. Only test data exists, no migration needed.
**Notes:** User stated instances contain only test data, can be dropped.

### Follow-up: Old code cleanup

| Option | Description | Selected |
|--------|-------------|----------|
| Remove entirely | Delete all --instance code and migration logic. | ✓ |
| Keep as deprecated alias | --instance silently maps to --profile with warning. | |

**User's choice:** Remove entirely
**Notes:** None

---

## Repo-to-Profile Mapping

| Option | Description | Selected |
|--------|-------------|----------|
| Config field in profile | 'repo' field in profile.json. Explicit, simple. | ✓ |
| Convention: profile name = repo name | Zero config but breaks with same-name repos across orgs. | |
| Separate mapping file | Global repos.json. Centralized but another file. | |

**User's choice:** Config field in profile
**Notes:** None

### Follow-up: Repo format

| Option | Description | Selected |
|--------|-------------|----------|
| owner/repo shorthand | Matches GitHub webhook repository.full_name. Compact. | ✓ |
| Full URL | More explicit but verbose, needs URL parsing. | |

**User's choice:** owner/repo shorthand
**Notes:** None

### Follow-up: Multi-repo per profile

| Option | Description | Selected |
|--------|-------------|----------|
| One profile = one repo | Matches Out of Scope constraint. Clean. | ✓ |
| One profile = multiple repos | More flexible but conflicts with constraints. | |

**User's choice:** One profile = one repo
**Notes:** None

---

## Directory Layout

### Config format

| Option | Description | Selected |
|--------|-------------|----------|
| profile.json | Structured JSON. Parseable by all services. | ✓ |
| Keep config.sh + add fields | Shell format. Hard for Node/Python to parse. | |
| YAML config | Readable but needs parser. Not available in bash. | |

**User's choice:** profile.json
**Notes:** None

### Directory structure

| Option | Description | Selected |
|--------|-------------|----------|
| Flat structure | All files in profile root. Templates discovered by glob. | ✓ |
| Subdirectories | templates/ subdirectory for prompt files. | |
| Minimal + references | Only profile.json with external paths. | |

**User's choice:** Flat structure
**Notes:** None

---

## CLI Interface Changes

### Profile creation

| Option | Description | Selected |
|--------|-------------|----------|
| Keep interactive auto-create | Same pattern as instances. First use triggers setup. | ✓ |
| Explicit create command | 'claude-secure create-profile NAME'. No auto-create. | |
| Template-based | Pre-built templates for common setups. | |

**User's choice:** Keep interactive auto-create
**Notes:** None

### Repo field during creation

| Option | Description | Selected |
|--------|-------------|----------|
| Optional during creation | Users add repo to profile.json when they want webhooks. | ✓ |
| Always prompt for repo | Every profile has repo from start. More friction. | |

**User's choice:** Optional during creation
**Notes:** None

### List output

| Option | Description | Selected |
|--------|-------------|----------|
| Table with details | Name, repo, workspace. Like 'docker ps' format. | ✓ |
| Names only | One per line. Simpler, scriptable. | |

**User's choice:** Table with details
**Notes:** None

---

## Superuser Mode (user-initiated gray area)

User proposed: `claude-secure` without `--profile` should start a persistent instance with merged access to ALL profiles.

### Workspace for superuser mode

| Option | Description | Selected |
|--------|-------------|----------|
| Prompt on first run, save globally | Ask once, store in ~/.claude-secure/config.sh. | ✓ |
| Current directory | Mount $PWD as workspace. | |
| Dedicated default workspace | Fixed path like ~/claude-workspace/. | |

**User's choice:** Prompt on first run, save globally
**Notes:** None

### Merge strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Runtime merge on every start | Read all profiles, merge each time. Always current. | ✓ |
| Cached merged config | Generate on profile create/update. Can go stale. | |

**User's choice:** Runtime merge on every start
**Notes:** None

### Flag policy

| Option | Description | Selected |
|--------|-------------|----------|
| Optional everywhere | No flag = superuser. --profile = scoped. Both for interactive and headless. | ✓ |
| Required for headless only | --profile only required for 'spawn' command. | |

**User's choice:** Optional everywhere
**Notes:** None

---

## Claude's Discretion

- Profile validation specifics (PROF-03) -- what checks run, what errors look like
- profile.json exact schema -- required vs optional fields, types
- Auth credential handling during creation -- follow existing copy-from-existing pattern

## Deferred Ideas

None -- discussion stayed within phase scope
