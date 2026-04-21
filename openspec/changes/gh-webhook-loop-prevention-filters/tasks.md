## 1. listener.py — filter evaluation

- [x] 1.1 Add `evaluate_skip_filters(event_type, payload, skip_filters)` helper: implements push (all-commits prefix), label-capable (label name match), body-prefix (comment.body/review.body), and non-applicable (always False) dispatch
- [x] 1.2 In `WebhookHandler.do_POST`, after connection lookup, read `skip_filters` from connection entry (default `[]`)
- [x] 1.3 Call `evaluate_skip_filters`; if True, log `skipped` entry to `webhook.jsonl` with `connection`, `delivery_id`, `filter_value`, `reason`, then return HTTP 200 without calling `_spawn_worker`
- [x] 1.4 Verify non-matching events still reach `_spawn_worker` unchanged

## 2. bin/claude-secure — filter CLI

- [x] 2.1 Add `filter` subcommand dispatch under `gh-webhook-listener` (after rename change is applied)
- [x] 2.2 Implement `filter add "<value>" --name <connection>`: read connections.json, find connection, append to `skip_filters`, write atomically, print coverage table
- [x] 2.3 Implement `filter list --name <connection>`: read connections.json, print each filter value with coverage columns
- [x] 2.4 Implement `filter remove "<value>" --name <connection>`: read connections.json, remove value from `skip_filters`, write atomically
- [x] 2.5 Add `_gh_webhook_filter_coverage()` helper that prints the standard coverage table given a filter value (reused by add and list)

## 3. Tests — CLI

- [x] 3.1 Create `tests/test-gh-webhook-listener-filter-cli.sh` with scenarios: filter add success, filter add duplicate rejected, filter add unknown connection, filter list with filters, filter list empty, filter remove success, filter remove unknown value
- [x] 3.2 Verify coverage table output in `filter add` test

## 4. Tests — spawn skip behavior

- [x] 4.1 Update `tests/test-webhook-spawn.sh`: add scenario where push with all `[skip-claude]`-prefixed commits is skipped (no spawn_start in webhook.jsonl)
- [x] 4.2 Add scenario where mixed push (one prefixed, one not) still spawns
- [x] 4.3 Add scenario where `skip_filters` is empty — all events spawn

## 5. README

- [x] 5.1 Add "Loop prevention / skip filters" section with `filter add`, `filter list`, `filter remove` usage examples and explanation of the two mechanisms (commit prefix, label, body prefix)

## 6. Commit

- [x] 6.1 Commit all changes with message `[skip-claude] feat(gh-webhook): add loop-prevention skip filters`
