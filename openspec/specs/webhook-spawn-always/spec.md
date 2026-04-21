## Requirements

### Requirement: listener spawns unconditionally after HMAC and repo lookup
After HMAC verification succeeds and a matching connection is found in `connections.json`, the listener SHALL call `claude-secure spawn <connection_name> --event-file <path>` for every incoming event. No event-type filtering, branch filtering, diff inspection, or label gating SHALL occur in Python.

#### Scenario: Push to any branch triggers spawn
- **WHEN** a push event arrives for a registered repo and HMAC is valid
- **THEN** `claude-secure spawn` is called with the persisted event file

#### Scenario: Push to non-main branch also triggers spawn
- **WHEN** a push event targets `refs/heads/feature-x` for a registered repo
- **THEN** the listener spawns — branch filtering is the system prompt's responsibility

#### Scenario: Unsupported event type still spawns
- **WHEN** a `ping` or `create` event arrives for a registered repo with valid HMAC
- **THEN** the listener persists the event and spawns (Claude exits cleanly for irrelevant types)

### Requirement: _spawn_worker calls claude-secure spawn via subprocess
`_spawn_worker` SHALL invoke `subprocess.run([claude_secure_bin, "spawn", connection_name, "--event-file", str(event_path)], capture_output=True, text=True)`. The call is blocking within the worker thread. The semaphore is released after the subprocess exits.

#### Scenario: Successful spawn logs spawn_done
- **WHEN** `claude-secure spawn` exits with code 0
- **THEN** `webhook.jsonl` contains a `spawn_done` entry with `connection`, `delivery_id`, and `exit_code: 0`

#### Scenario: Failed spawn logs spawn_error
- **WHEN** `claude-secure spawn` exits with a non-zero code
- **THEN** `webhook.jsonl` contains a `spawn_error` entry with `exit_code` matching the actual exit code

#### Scenario: Spawn exception logs spawn_exception
- **WHEN** `subprocess.run` raises an exception (e.g., binary not found)
- **THEN** `webhook.jsonl` contains a `spawn_exception` entry with an `error` field

### Requirement: spawn output written to per-delivery log file
`_spawn_worker` SHALL write the combined stdout and stderr of the `claude-secure spawn` subprocess to `<logs_dir>/spawn-<delivery_id[:12]>.log`.

#### Scenario: Log file created after spawn
- **WHEN** a spawn completes (success or failure)
- **THEN** a file `spawn-<first-12-chars-of-delivery-id>.log` exists in the configured logs directory

#### Scenario: Log file contains subprocess output
- **WHEN** `claude-secure spawn` writes to stdout or stderr
- **THEN** that output appears verbatim in the spawn log file

### Requirement: spawn_skipped log event removed
The `spawn_skipped` log event SHALL no longer be emitted. It is replaced by `spawn_start`, `spawn_done`, `spawn_error`, and `spawn_exception`.

#### Scenario: No spawn_skipped in webhook.jsonl
- **WHEN** a valid event is processed
- **THEN** `webhook.jsonl` does not contain a `spawn_skipped` entry
