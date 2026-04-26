## 1. Create index.md

- [x] 1.1 Create `index.md` at the repo root with a title and maintenance note
- [x] 1.2 Add "Orchestration Scripts" section listing `install.sh`, `uninstall.sh`, `run-tests.sh`, and `docker-compose.yml` with one-line descriptions and relative links
- [x] 1.3 Add "CLI" section listing `bin/claude-pod` with its description and link
- [x] 1.4 Add "Container Definitions" section listing `claude/Dockerfile`, `proxy/Dockerfile`, and `validator/Dockerfile`
- [x] 1.5 Add "Security Services" section listing `proxy/proxy.js`, `validator/validator.py`, and `webhook/listener.py`
- [x] 1.6 Add "Hooks" section listing `claude/hooks/pre-tool-use.sh`
- [x] 1.7 Add "Library & Utilities" section listing `lib/platform.sh`, `scripts/migrate-profile-prompts.sh`, and `scripts/new-project.sh`
- [x] 1.8 Add "Tests" section listing every file under `tests/` with one-line descriptions

## 2. Verify

- [x] 2.1 Confirm all relative links resolve to actual files (no broken links)
- [x] 2.2 Confirm every source file found by `find . -name "*.sh" -o -name "*.js" -o -name "*.py" -o -name "Dockerfile*"` (excluding `openspec/`) is covered in the index
