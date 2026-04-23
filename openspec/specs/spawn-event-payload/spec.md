## Requirements

### Requirement: spawn appends full event JSON to the human-turn prompt
When `$EVENT_JSON` is non-empty, `do_spawn` in `bin/claude-pod` SHALL append the full event payload to the rendered task prompt before passing it to `claude -p`. The appended block SHALL be separated from the task content by a `---` line, labeled with the event type, and wrapped in a fenced `json` code block.

#### Scenario: Webhook-triggered spawn includes payload block
- **WHEN** spawn is called with `--event-file` pointing to a valid push event
- **THEN** the prompt sent to Claude ends with a `---` separator followed by a fenced JSON block containing the full event payload

#### Scenario: Manual spawn without event has no payload block
- **WHEN** spawn is called without `--event` or `--event-file` (no EVENT_JSON)
- **THEN** the prompt sent to Claude is the task file content unchanged, with no appended block

#### Scenario: dry-run shows appended payload
- **WHEN** spawn is called with `--dry-run` and a valid event file
- **THEN** stdout includes the payload block at the end of the rendered prompt output

#### Scenario: Payload block format is stable
- **WHEN** a push event with event_type `push` is appended
- **THEN** the appended section starts with `---`, followed by a line containing `Event Payload` and the event type, followed by ` ```json `, the raw JSON, and ` ``` `
