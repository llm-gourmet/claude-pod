## 1. Config Layer

- [x] 1.1 Add `_bootstrap_docs_connections_file` helper that returns `$CONFIG_DIR/docs-bootstrap/connections.json`
- [x] 1.2 Add `_bootstrap_docs_read_connections` that reads and validates `connections.json`; returns empty array if file absent
- [x] 1.3 Add `_bootstrap_docs_write_connections` that writes array atomically via temp file + mv
- [x] 1.4 Add `_bootstrap_docs_find_connection` that looks up a connection by name; exits 1 with error if not found

## 2. Management Subcommands

- [x] 2.1 Implement `--add-connection --name <n> --repo <u> --token <t> [--branch <b>]`: validate required args, check duplicate name, append, write
- [x] 2.2 Implement `--remove-connection <name>`: find by name, filter out, write; error if not found
- [x] 2.3 Implement `--list-connections`: print name, repo, branch per connection (no token); handle empty state

## 3. Bootstrap Command Update

- [x] 3.1 Add `--connection <name>` flag parsing to `cmd_bootstrap_docs`
- [x] 3.2 Replace `_bootstrap_docs_load_config` call with `_bootstrap_docs_find_connection`; extract repo/token/branch from connection object
- [x] 3.3 Enforce `--connection` required: exit 1 with error + list-connections hint when omitted
- [x] 3.4 Remove `--set-repo`, `--set-token`, `--set-branch` flag handling and their helper functions

## 4. Help & Error Messages

- [x] 4.1 Update `--help` output to reflect new flags; remove `--set-*`, add `--add-connection`, `--remove-connection`, `--list-connections`, `--connection`
- [x] 4.2 Verify all error messages match spec exactly (duplicate name, unknown name, missing flag)

## 5. Tests

- [x] 5.1 Update existing bootstrap-docs config tests that reference `--set-repo`/`--set-token`/`--set-branch`/`docs-bootstrap.env`
- [x] 5.2 Add tests for `--add-connection` (success, duplicate, missing args)
- [x] 5.3 Add tests for `--remove-connection` (success, unknown name)
- [x] 5.4 Add tests for `--list-connections` (with connections, empty)
- [x] 5.5 Add tests for `bootstrap-docs --connection` (missing flag, unknown name, success path)
