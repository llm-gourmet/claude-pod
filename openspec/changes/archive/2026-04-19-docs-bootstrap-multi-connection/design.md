## Context

`bootstrap-docs` uses three helper functions in `bin/claude-secure`:
- `_bootstrap_docs_set_config_key`: writes key=value to `~/.claude-secure/docs-bootstrap.env`
- `_bootstrap_docs_load_config`: sources the `.env` and exports `DOCS_BOOTSTRAP_REPO/TOKEN/BRANCH`
- `cmd_bootstrap_docs`: dispatches `--set-*` setters and the main scaffold action

All three are replaced. The `.env` file and its shell-variable convention are dropped in favour of a JSON array in a dedicated directory.

## Goals / Non-Goals

**Goals:**
- Support N named connections, each independently addressable by name
- Connections stored in one file (`connections.json`), `chmod 600`, dir `chmod 700`
- `--connection <name>` required at bootstrap time — no implicit default
- Full CRUD via CLI: `--add-connection`, `--remove-connection`, `--list-connections`
- Duplicate name → error on add; unknown name → error on remove/use
- `--list-connections` shows name, repo, branch — token never printed

**Non-Goals:**
- Migration from `docs-bootstrap.env` (user edits manually if needed)
- `--update-connection` / editing individual fields of an existing connection
- Multiple connections used in a single `bootstrap-docs` invocation

## Decisions

### JSON array in a dedicated directory

`~/.claude-secure/docs-bootstrap/connections.json` — array of objects:

```json
[
  { "name": "work-docs", "repo": "https://github.com/org/docs", "token": "ghp_xxx", "branch": "main" },
  { "name": "personal",  "repo": "https://github.com/user/kb",  "token": "ghp_yyy", "branch": "dev"  }
]
```

Alternatives considered:
- **Keep `.env`, add per-connection prefix** (`WORK_DOCS_TOKEN=...`): harder to enumerate, awkward naming conventions.
- **One file per connection**: more files to manage, no atomic list operation.
- **`connections.json` at root of `~/.claude-secure/`**: no isolation, pollutes the root config dir.

### `branch` optional, default `main`

Omitting `branch` in `--add-connection` writes no `branch` key. Reader defaults to `main` when key absent. This keeps the common case terse.

### Token stored in JSON (not split `.env`)

Both the old `.env` and the new JSON are `chmod 600`. Storing the token in the same file as the connection metadata simplifies the data model with no security regression for a local dev tool. A separate secrets store would add complexity with no benefit given the existing security posture.

### Name uniqueness enforced on write

`--add-connection` reads the current array, checks for name collision, and fails before writing. Case-sensitive match (consistent with how `--connection` resolves at use time).

### Remove by name, not by index

Index-based removal is fragile (indices shift). Name is stable and user-visible.

## Risks / Trade-offs

- **Token in JSON** → anyone with read access to the file can extract tokens. Mitigated by `chmod 600` on the file and `chmod 700` on the directory. Same risk existed with `.env`.
- **No migration** → users with existing `.env` must re-enter connections. Acceptable: the old format is a single connection and the user already knows the values.
- **Atomic write** → `connections.json` is read, modified in memory, written back. A crash mid-write corrupts the file. Mitigation: write to a temp file in the same directory, then `mv` (atomic on POSIX).
