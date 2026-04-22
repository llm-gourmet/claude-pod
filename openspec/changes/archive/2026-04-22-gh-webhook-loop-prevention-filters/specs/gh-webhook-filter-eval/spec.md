## ADDED Requirements

### Requirement: listener evaluates skip_filters before spawning
After HMAC verification and connection lookup, `webhook/listener.py` SHALL evaluate the connection's `skip_filters` array against the event payload before calling `_spawn_worker`. If any filter value matches the event (per event-type rules below), the listener SHALL return HTTP 200, log a `skipped` event, and NOT call `_spawn_worker`.

#### Scenario: Matching filter skips spawn
- **WHEN** a push event arrives where all commits have messages starting with `[skip-claude]` and `skip_filters` contains `"[skip-claude]"`
- **THEN** `_spawn_worker` is NOT called and `webhook.jsonl` contains a `skipped` entry

#### Scenario: Non-matching filter allows spawn
- **WHEN** a push event arrives where at least one commit message does NOT start with `[skip-claude]`
- **THEN** `_spawn_worker` IS called as normal

#### Scenario: Empty skip_filters allows spawn
- **WHEN** a connection has no `skip_filters` field or an empty array
- **THEN** all events spawn normally

### Requirement: push event filter matches on ALL commits
For `push` events, a filter value SHALL match only if every element of `commits[]` has a `message` that starts with the filter value (case-sensitive prefix match). If `commits` is empty or absent, the filter does NOT match.

#### Scenario: All commits prefixed — skip
- **WHEN** push payload has two commits both with messages starting with `[skip-claude]`
- **THEN** filter matches, spawn skipped

#### Scenario: Mixed commits — no skip
- **WHEN** push payload has one commit prefixed with `[skip-claude]` and one without
- **THEN** filter does not match, spawn proceeds

#### Scenario: Empty commits array — no skip
- **WHEN** push payload has `"commits": []`
- **THEN** filter does not match, spawn proceeds

### Requirement: label-capable events filter matches on label name
For `pull_request`, `issues`, and `discussion` events, a filter value SHALL match if any label in the event's labels array has a `name` exactly equal to the filter value (case-sensitive).

#### Scenario: Matching label — skip
- **WHEN** a `pull_request` event payload contains a label with `"name": "[skip-claude]"` and `skip_filters` contains `"[skip-claude]"`
- **THEN** filter matches, spawn skipped

#### Scenario: No matching label — no skip
- **WHEN** a `pull_request` event has labels but none match the filter value
- **THEN** spawn proceeds

### Requirement: body-prefix events filter matches on body start
For `issue_comment`, `pull_request_review`, and `pull_request_review_comment` events, a filter value SHALL match if the relevant body field (`comment.body` or `review.body`) starts with the filter value (case-sensitive prefix match). A null or absent body does NOT match.

#### Scenario: Comment body prefixed — skip
- **WHEN** an `issue_comment` event has `comment.body` starting with `[skip-claude]`
- **THEN** filter matches, spawn skipped

#### Scenario: Body does not start with filter — no skip
- **WHEN** `comment.body` contains the filter value but not at the start
- **THEN** spawn proceeds

### Requirement: non-applicable events always spawn
For `workflow_run`, `check_run`, `create`, `delete`, `deployment`, and any unrecognized event types, skip_filters SHALL have no effect and the event SHALL always spawn.

#### Scenario: workflow_run always spawns
- **WHEN** a `workflow_run` event arrives and `skip_filters` is non-empty
- **THEN** spawn proceeds regardless of filter values

### Requirement: skipped event logged to webhook.jsonl
When a filter match causes a skip, `webhook/listener.py` SHALL append a JSON log entry to `webhook.jsonl` with `event_type: "skipped"`, `connection`, `delivery_id`, `filter_value`, and `reason` (describing which mechanism matched).

#### Scenario: skipped entry written
- **WHEN** a filter match skips a spawn
- **THEN** `webhook.jsonl` contains an entry with `"event_type": "skipped"` and the matched `filter_value`
