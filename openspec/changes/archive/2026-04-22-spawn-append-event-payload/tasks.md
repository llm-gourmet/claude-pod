## 1. do_spawn — append payload block

- [x] 1.1 After `rendered_prompt=$(cat "$task_file")` (line 1406), add: if `$EVENT_JSON` is non-empty, append `---`, the labeled header, and a fenced `json` block containing `$EVENT_JSON` to `rendered_prompt`
- [x] 1.2 Verify `--dry-run` output includes the appended block (no separate change needed — dry-run prints `$rendered_prompt` which now contains it; add assertion to confirm)

## 2. create_profile() — update task stubs

- [x] 2.1 Replace `tasks/default.md` stub with content that explains the payload block is always appended by spawn and shows how to reference event fields
- [x] 2.2 Replace `tasks/push.md` stub with a practical starting point that references `commits[]` from the payload
- [x] 2.3 Replace `tasks/issues-opened.md` stub with a practical starting point that references `issue.title` and `issue.body`
- [x] 2.4 Replace `tasks/issues-labeled.md` stub with a starting point referencing the label name from the payload
- [x] 2.5 Replace `tasks/pull-request-opened.md` stub with a starting point referencing PR title, body, and diff
- [x] 2.6 Replace `tasks/pull-request-merged.md` stub with a starting point referencing merged PR details
- [x] 2.7 Replace `tasks/workflow-run-completed.md` stub with a starting point referencing workflow name and conclusion

## 3. Tests

- [x] 3.1 Add test to `tests/test-profile-task-prompts.sh` (or new file): spawn with `--event-file` produces a prompt ending with the payload block
- [x] 3.2 Add test: spawn without `--event` / `--event-file` produces prompt with no payload block appended
- [x] 3.3 Add test: `--dry-run` with event file shows payload block in stdout

## 4. Commit

- [x] 4.1 Commit with message `[skip-claude] feat(spawn): append full event payload to prompt`
