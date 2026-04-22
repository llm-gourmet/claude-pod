## MODIFIED Requirements

### Requirement: profile create scaffolds task files with payload documentation
`create_profile()` SHALL scaffold `tasks/` stub files that document the event payload block available at runtime. Each stub SHALL include a comment explaining that the full webhook event JSON is appended automatically by spawn, and SHALL show the relevant event-type fields a task author would typically reference (e.g., `commits[]` for push, `issue` for issues events).

#### Scenario: push.md stub references commit payload
- **WHEN** a new profile is created
- **THEN** `tasks/push.md` contains a comment or example referencing `commits` from the appended event payload

#### Scenario: issues-opened.md stub references issue payload
- **WHEN** a new profile is created
- **THEN** `tasks/issues-opened.md` contains a comment or example referencing `issue.title` or `issue.body` from the appended event payload

#### Scenario: default.md stub explains payload availability
- **WHEN** a new profile is created
- **THEN** `tasks/default.md` explains that the full event JSON is appended to the prompt by spawn and can be used for any event type
