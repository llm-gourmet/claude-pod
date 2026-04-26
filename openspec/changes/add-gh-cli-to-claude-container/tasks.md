## 1. Dockerfile Changes

- [x] 1.1 Add GitHub CLI apt keyring fetch to `claude/Dockerfile` (curl + gpg dearmor step before apt-get install)
- [x] 1.2 Add GitHub CLI apt source list entry to `claude/Dockerfile`
- [x] 1.3 Add `gh` to the existing `apt-get install` package list in `claude/Dockerfile`

## 2. Build & Verify

- [x] 2.1 Build claude container image: `docker compose build claude`
- [x] 2.2 Verify `gh` is on PATH: `docker compose exec claude which gh`
- [x] 2.3 Verify `gh --version` exits 0 inside the container
- [ ] 2.4 Smoke test: run `GITHUB_TOKEN=<token> gh issue list --repo <repo>` inside container with a whitelisted profile
