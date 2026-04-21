## ADDED Requirements

### Requirement: filter add stores value in connection's skip_filters
`claude-secure gh-webhook-listener filter add "<value>" --name <connection>` SHALL append the filter value to the `skip_filters` array in the named connection's entry in `connections.json`. If `skip_filters` does not exist it SHALL be created. Duplicate values SHALL be rejected with a non-zero exit and error message. After writing, the command SHALL print a summary showing which event types and mechanisms the filter applies to.

#### Scenario: Filter added to existing connection
- **WHEN** `claude-secure gh-webhook-listener filter add "[skip-claude]" --name myrepo` is run and `myrepo` exists with no existing filters
- **THEN** `connections.json` contains `"skip_filters": ["[skip-claude]"]` in the `myrepo` entry

#### Scenario: Duplicate filter value rejected
- **WHEN** `filter add "[skip-claude]" --name myrepo` is run and `[skip-claude]` is already in `skip_filters`
- **THEN** command exits non-zero with `Error: filter '[skip-claude]' already exists on connection 'myrepo'`

#### Scenario: Unknown connection name rejected
- **WHEN** `filter add "[skip-claude]" --name nonexistent` is run
- **THEN** command exits non-zero with `Error: connection 'nonexistent' not found`

#### Scenario: filter add prints event-type coverage
- **WHEN** `filter add "[skip-claude]" --name myrepo` succeeds
- **THEN** stdout shows a coverage table like:
  ```
  Filter "[skip-claude]" added to connection "myrepo":
    push events          → commit message prefix
    pr/issues/discussion → label match
    comments/reviews     → body prefix
    workflow/check/etc   → not applicable (no free-text field)
  ```

### Requirement: filter list shows active filters with coverage
`claude-secure gh-webhook-listener filter list --name <connection>` SHALL print each filter value and the event types it applies to. If no filters are configured it SHALL print a message and exit 0.

#### Scenario: Filters listed with coverage
- **WHEN** `filter list --name myrepo` is run and `skip_filters` contains one value
- **THEN** output shows the filter value and its applicable event types

#### Scenario: No filters configured
- **WHEN** `filter list --name myrepo` is run and `skip_filters` is absent or empty
- **THEN** output shows `No filters configured for connection 'myrepo'.`

#### Scenario: Unknown connection name rejected
- **WHEN** `filter list --name nonexistent` is run
- **THEN** command exits non-zero with `Error: connection 'nonexistent' not found`

### Requirement: filter remove deletes value from skip_filters
`claude-secure gh-webhook-listener filter remove "<value>" --name <connection>` SHALL remove the exact filter value from `skip_filters`. If the value is not present the command SHALL exit non-zero with an error.

#### Scenario: Filter removed
- **WHEN** `filter remove "[skip-claude]" --name myrepo` is run and the value exists
- **THEN** `connections.json` no longer contains `[skip-claude]` in `myrepo`'s `skip_filters`

#### Scenario: Nonexistent filter value rejected
- **WHEN** `filter remove "[skip-claude]" --name myrepo` is run and the value is not in `skip_filters`
- **THEN** command exits non-zero with `Error: filter '[skip-claude]' not found on connection 'myrepo'`
