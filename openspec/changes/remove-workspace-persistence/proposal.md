## Why

Claude-pod instances never need to write anything persistent to the host filesystem — the container is ephemeral by design and workspace bind-mounts only create operational friction (host directories must exist before the container can start, paths must be maintained across reinstalls). Removing the workspace mount eliminates an entire class of startup failures and simplifies both installation and profile management.

## What Changes

- Remove the `workspace` named volume from `docker-compose.yml` (bind-mount into container at `/workspace`)
- Remove `LOG_DIR` bind-mounts from all three services (claude, proxy, validator) — container logs are available via `docker logs`
- Remove `workspace` field from `profile.json` schema (field was required; it becomes absent)
- Remove `setup_workspace()` from `install.sh` and its call from the main install flow
- Remove workspace path prompt from `claude-pod profile create`
- Remove `WORKSPACE_PATH` and `LOG_DIR` exports from `load_profile_config()` and `load_superuser_config()`
- Remove WORKSPACE column from `claude-pod profile list` output
- Remove `validate_profile` check for `workspace` field existence

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `profile-schema`: Remove `workspace` field — it is no longer a required (or accepted) field in `profile.json`. `validate_profile` no longer checks for it.

## Impact

- `docker-compose.yml`: two volume sections simplified, one volume definition removed
- `install.sh`: `setup_workspace()` removed; `config.sh` initial creation moved into `setup_directories()`
- `bin/claude-pod`: `create_profile`, `load_profile_config`, `load_superuser_config`, `list_profiles`, spawn setup block
- Existing profiles with a `workspace` field continue to work — unknown fields are already ignored on read per the spec
- No Docker image changes required
