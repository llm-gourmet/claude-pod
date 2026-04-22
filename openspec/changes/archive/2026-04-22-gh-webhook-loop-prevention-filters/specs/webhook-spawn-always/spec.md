## MODIFIED Requirements

### Requirement: listener spawns after HMAC, repo lookup, and filter evaluation
After HMAC verification succeeds and a matching connection is found in `connections.json`, the listener SHALL evaluate `skip_filters` (see `gh-webhook-filter-eval` spec). If no filter matches, the listener SHALL call `claude-secure spawn <connection_name> --event-file <path>`. No branch filtering, diff inspection, or label gating SHALL occur beyond skip_filters evaluation.

#### Scenario: Push to any branch triggers spawn when no filter matches
- **WHEN** a push event arrives for a registered repo, HMAC is valid, and no filter matches
- **THEN** `claude-secure spawn` is called with the persisted event file

#### Scenario: Push to non-main branch also triggers spawn
- **WHEN** a push event targets `refs/heads/feature-x` for a registered repo and no filter matches
- **THEN** the listener spawns — branch filtering is the system prompt's responsibility

#### Scenario: Unsupported event type still spawns when not filtered
- **WHEN** a `ping` or `create` event arrives for a registered repo with valid HMAC
- **THEN** the listener persists the event and spawns (Claude exits cleanly for irrelevant types)

#### Scenario: Matching filter prevents spawn
- **WHEN** a push event arrives and all commits match a configured skip_filter
- **THEN** `claude-secure spawn` is NOT called
