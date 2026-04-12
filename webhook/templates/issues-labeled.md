An issue in {{REPO_NAME}} was labeled.

**Issue #{{ISSUE_NUMBER}}:** {{ISSUE_TITLE}}
**Author:** {{ISSUE_AUTHOR}}
**URL:** {{ISSUE_URL}}
**Current labels:** {{ISSUE_LABELS}}

**Body:**
{{ISSUE_BODY}}

---

A label change occurred on this issue. Inspect the current label set and determine whether any automated action is appropriate:
- If a label like `good-first-issue` or `help-wanted` is now present, post a welcome comment on the issue.
- If a label like `bug` or `regression` is newly present, triage the issue: check if it reproduces on main.
- If none of the labels match an automation you recognize, exit without action.

Use `gh issue view {{ISSUE_NUMBER}} --repo {{REPO_NAME}}` to read the full issue context. Post comments via `gh issue comment`. Do not modify code.
