## Context

Claude-pod's docker-compose currently mounts two categories of host paths into containers:

1. **Workspace volume** — a named volume backed by a host bind-mount (`WORKSPACE_PATH`) into the claude container at `/workspace`. This was intended as a persistent scratch area for Claude Code. It requires the host directory to exist before `docker compose up` can run, creating startup failures when the directory is absent (e.g., after migrating to a new machine).

2. **Log volume** (`LOG_DIR`) — `~/.claude-pod/logs/` bind-mounted into all three containers at `/var/log/claude-pod`. Container logs land on the host with `chmod 777` to accommodate different UIDs. Docker's `docker logs` provides equivalent access without the bind-mount.

Neither mount provides value that outweighs the operational cost. Container filesystem is ephemeral by design; anything Claude Code produces during a session is discarded on container stop, which is the correct behavior for a security sandbox.

## Goals / Non-Goals

**Goals:**
- Remove `workspace` named volume from docker-compose.yml
- Remove `LOG_DIR` bind-mounts from all three services
- Remove `workspace` field from `profile.json` schema and all code that reads/writes it
- Remove workspace path prompts from install and profile creation flows
- Keep `validator-db` named volume (ephemeral SQLite, needed within a single session)

**Non-Goals:**
- Updating tests (tracked separately)
- Removing the profile directory structure (`~/.claude-pod/profiles/<name>/`) — profiles still exist, they just no longer reference a workspace path
- Adding any alternative persistence mechanism

## Decisions

**Remove logs bind-mount entirely rather than redirecting to a different location.**
Rationale: `docker logs <container>` already captures all stdout/stderr. Adding a second log sink creates confusion about which is authoritative. The existing `LOG_HOOK` and `LOG_PREFIX` env vars remain and still control per-line structured logging to stdout.

**Move `config.sh` initial creation from `setup_workspace()` into `setup_directories()`.**
Rationale: `setup_workspace()` was the only place `config.sh` was created with the `PLATFORM=` entry. `copy_app_files()` appends `APP_DIR=` to it. Removing `setup_workspace()` without moving the initial creation would break the append. Placing it in `setup_directories()` keeps the file lifecycle clear: created during directory setup, extended by file copy.

**Drop `DEFAULT_WORKSPACE` from `load_superuser_config()` without replacement.**
Rationale: Superuser mode merges all profiles; there is no per-run workspace path to configure. The interactive prompt for `DEFAULT_WORKSPACE` and its persistence in `config.sh` are removed entirely.

**Existing `profile.json` files with a `workspace` field are silently ignored.**
Rationale: The spec already states unknown fields are ignored on read. No migration script is needed — old profiles continue to work, the field is just never used.

## Risks / Trade-offs

**Users who relied on `/workspace` inside the container as a persistent area will lose that data between sessions.**
→ Mitigation: The workspace was always ephemeral in practice (container stop destroys it). No user-visible data path guaranteed persistence.

**`docker logs` requires knowing the container name.**
→ Mitigation: `claude-pod logs <profile>` can be added later if needed. Out of scope for this change.

**Removing `validate_profile`'s workspace check changes validation behavior.**
→ Mitigation: The check verified the path exists on disk — a check that caused false failures on new machines. Removing it makes validation more portable, not less safe.
