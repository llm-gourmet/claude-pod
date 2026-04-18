## 1. Listener: Diff Filter Core

- [x] 1.1 Add `fetch_commit_patch(repo, sha, token)` to `listener.py` using `urllib.request`; returns raw unified diff string or raises on error
- [x] 1.2 Add `has_meaningful_todo_change(patch, path_pattern)` to `listener.py`; implements D-05 three-rule heuristic (new open item, edited open item, not just checkbox-off)
- [x] 1.3 Extend `apply_event_filter` to call diff filter when profile has `todo_path_pattern` and global config has `github_token`; fail-open on API errors (log warning, return allow)
- [x] 1.4 Add `github_token` field reading in `load_config` / `Config` dataclass
- [x] 1.5 Update `config.example.json` with `github_token` field and inline comment

## 2. Profile Config

- [x] 2.1 Add `todo_path_pattern: "projects/*/TODOS.md"` to obsidian `profile.json` on VPS (or document in install notes)
- [x] 2.2 Delete `profiles/obsidian/prompts/push.md` (LLM scanner prompt); replace with minimal task-oriented prompt or leave absent so spawn uses default

## 3. CLI: webhook-listener Subcommand

- [x] 3.1 Add `_webhook_listener_set_config_key()` helper to `bin/claude-secure` (mirrors `_bootstrap_docs_set_config_key`, writes to `~/.claude-secure/webhook-listener.env` at mode 600)
- [x] 3.2 Add `_webhook_listener_load_config()` helper; exports `WEBHOOK_GITHUB_TOKEN`, `WEBHOOK_BIND`, `WEBHOOK_PORT`
- [x] 3.3 Implement `cmd_webhook_listener()` with `--set-token`, `--set-bind`, `--set-port` setters
- [x] 3.4 Implement `status` subcommand: read config, call `GET http://<bind>:<port>/health`, call `systemctl is-active claude-secure-webhook`, print table
- [x] 3.5 Add `webhook-listener` to skip-superuser-load list in dispatch switch
- [x] 3.6 Add `webhook-listener` to `help` output

## 4. Cleanup: Report-Repo-Token Removal

- [x] 4.1 Remove `REPORT_REPO_TOKEN` references from `bin/claude-secure` (`publish_report` function and callers)
- [x] 4.2 Remove Report-Repo-Token section from `README.md`
- [x] 4.3 Search and remove any remaining references in prompt templates or docs

## 5. Tests

- [x] 5.1 Delete old LLM-scanner test cases from `tests/TEST-SPEC.md` (BOOT scanner section) and `tests/test-map.json`
- [x] 5.2 Add `tests/test-webhook-diff-filter.sh`: unit-style tests for `has_meaningful_todo_change` (new item → spawn, checkbox-off → filter, edited open item → spawn, non-matching path → no-op); uses local Python, no Docker
- [x] 5.3 Add `tests/test-webhook-listener-cli.sh`: tests for `--set-token`, `--set-bind`, `--set-port`, key preservation, token redaction in output, status with mock health endpoint
- [x] 5.4 Update `tests/TEST-SPEC.md`: add DIFF-FILTER and WLCLI test suites, update total count
- [x] 5.5 Update `tests/test-map.json`: map `webhook/listener.py` → `test-webhook-diff-filter.sh`; map `bin/claude-secure` → `test-webhook-listener-cli.sh`

## 6. Ship

- [x] 6.1 Deploy updated `listener.py` to VPS (`claude-secure update` or manual copy)
- [x] 6.2 Run `claude-secure webhook-listener --set-token <pat>` on VPS to write token
- [x] 6.3 Add `todo_path_pattern` to obsidian profile.json on VPS
- [x] 6.4 Restart `claude-secure-webhook.service` on VPS
- [x] 6.5 Push a new open TODO to obsidian repo; verify spawn fires
- [x] 6.6 Push a checkbox-only change; verify HTTP 202 filtered response in webhook.jsonl
