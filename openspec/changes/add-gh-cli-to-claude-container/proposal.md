## Why

The `gh` CLI is not installed in the claude container, so Claude Code cannot perform GitHub operations (create issues, open PRs, comment, etc.) even when a `GITHUB_TOKEN` secret is correctly configured in the profile with `github.com` domains whitelisted. This blocks a core use case: running `gh` commands as part of agentic workflows inside the isolated environment.

## What Changes

- Add `gh` (GitHub CLI) to the claude container Dockerfile via the official GitHub CLI apt repository
- `gh` will be available to the `claude` user alongside existing tools (`git`, `curl`, `jq`)

## Capabilities

### New Capabilities

- `gh-cli-in-container`: GitHub CLI available inside the claude container, enabling `gh` commands for issues, PRs, releases, etc.

### Modified Capabilities

<!-- No existing spec-level behavior changes -->

## Impact

- `claude/Dockerfile`: add `gh` installation step (GitHub CLI apt repo + package)
- Image rebuild required after change (`docker compose build claude`)
- No changes to proxy, validator, hooks, or profile schema
- Image size increase: ~30–50 MB for `gh` binary
