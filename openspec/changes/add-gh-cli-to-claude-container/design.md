## Context

The claude container (based on `node:22-slim`, Debian) currently installs `git`, `curl`, `jq`, and other tools but omits the GitHub CLI (`gh`). Users configure GitHub tokens as secrets in profiles and whitelist `github.com` / `api.github.com` — but `gh` is unavailable, so any `gh ...` command fails with `command not found` inside the container.

## Goals / Non-Goals

**Goals:**
- `gh` binary available at `/usr/bin/gh` inside the claude container
- Works for the `claude` user without sudo
- Installed from the official GitHub CLI apt repository (verifiable, signed)

**Non-Goals:**
- GitHub authentication setup (handled by `GITHUB_TOKEN` env var from profile secrets)
- Adding `github.com` to any default whitelist (already user-configured per profile)
- `gh` extensions or plugins
- Changes to proxy, validator, hooks, or profile schema

## Decisions

### Install via official GitHub CLI apt repository (not binary download)

Add the GitHub CLI apt repo to the Dockerfile before the main `apt-get install` run:

```dockerfile
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
```

Then add `gh` to the existing `apt-get install` line.

**Why over direct binary download:** Apt repo is signed, pinned to `stable`, and upgradeable via normal Debian tooling. Binary downloads from GitHub releases require manual version pinning and checksum validation — more maintenance surface for a security-sensitive project.

**Why over `npm install -g gh`:** No npm package exists for `gh`.

**Why not `brew`:** Homebrew not available in Debian-slim base image; adds significant complexity.

### Keep in the same RUN layer as other apt installs

Merge into the existing `apt-get install` RUN command (add `gh` to the package list after adding the repo). Keeps layer count minimal and ensures `apt-get update` sees the new source before installing.

## Risks / Trade-offs

- **Build-time network access to `cli.github.com`** → Build must run with external network access (standard Docker build behavior; already required for existing apt/npm installs). The container's runtime network remains isolated.
- **Image size increase (~30–50 MB)** → Acceptable; `gh` is a single Go binary. No transitive apt dependencies beyond what's already installed.
- **Repo key rotation** → If GitHub rotates the signing key, builds break. Mitigation: the `stable` channel has a long track record; monitor GitHub CLI release announcements.
- **`gh` version pinned to apt `stable` latest** → Users get the latest `gh` on each build, not a pinned version. Acceptable for a dev tool; security patches are applied automatically.

## Migration Plan

1. Update `claude/Dockerfile` — add apt keyring fetch + repo, add `gh` to install list
2. `docker compose build claude`
3. Restart stack (`docker compose up -d`)
4. Verify: `docker compose exec claude gh --version`

Rollback: revert Dockerfile change and rebuild.

## Open Questions

- None — approach is straightforward.
