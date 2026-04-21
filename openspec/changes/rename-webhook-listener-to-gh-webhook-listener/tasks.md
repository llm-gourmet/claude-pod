## 1. bin/claude-secure

- [x] 1.1 Rename dispatch entry: `webhook-listener)` → `gh-webhook-listener)` in the main command router
- [x] 1.2 Update skip-superuser-load list: replace `webhook-listener` with `gh-webhook-listener`
- [x] 1.3 Update all flag handler function names and internal references (e.g., `_webhook_listener_*` → `_gh_webhook_listener_*` where user-visible)
- [x] 1.4 Update all help strings and usage examples from `webhook-listener` to `gh-webhook-listener`
- [x] 1.5 Update error messages that reference `webhook-listener` (e.g., "Run claude-secure webhook-listener --help")

## 2. Tests

- [x] 2.1 Update `tests/test-webhook-listener-cli.sh`: rename file to `test-gh-webhook-listener-cli.sh`, update all `claude-secure webhook-listener` invocations to `claude-secure gh-webhook-listener`, update test descriptions
- [x] 2.2 Update `tests/test-webhook-spawn.sh`: replace any `webhook-listener` references with `gh-webhook-listener`

## 3. webhook/listener.py

- [x] 3.1 Update inline comments referencing `webhook-listener` to `gh-webhook-listener`

## 4. README

- [x] 4.1 Search README for `webhook-listener` usage examples and update to `gh-webhook-listener`

## 5. Commit

- [ ] 5.1 Commit all changes with message `[skip-claude] rename(cli): webhook-listener → gh-webhook-listener`
