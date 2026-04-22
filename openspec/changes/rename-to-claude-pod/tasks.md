## 1. Rename the CLI binary

- [x] 1.1 Run `git mv bin/claude-secure bin/claude-pod` to rename the binary and preserve history

## 2. Rename systemd unit files

- [x] 2.1 Run `git mv webhook/claude-secure-webhook.service webhook/claude-pod-webhook.service`
- [x] 2.2 Run `git mv webhook/claude-secure-reaper.service webhook/claude-pod-reaper.service`
- [x] 2.3 Run `git mv webhook/claude-secure-reaper.timer webhook/claude-pod-reaper.timer`

## 3. Sed replace all `claude-secure` and `claude_secure` occurrences in source files

Apply two passes across all source files (excluding `.git/` and `openspec/changes/`):

- [x] 3.1 Replace hyphen variant: `find . -not -path './.git/*' -not -path './openspec/changes/*' -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.md' -o -name '*.service' -o -name '*.timer' -o -name '*.conf' \) -exec sed -i 's/claude-secure/claude-pod/g' {} +`
- [x] 3.2 Replace underscore variant: same find command with `s/claude_secure/claude_pod/g`
- [x] 3.3 Replace `ClaudeSecure` (PascalCase) if present: same find with `s/ClaudeSecure/ClaudePod/g`

## 4. Verify no remaining occurrences

- [x] 4.1 Run `grep -r "claude-secure\|claude_secure\|ClaudeSecure" . --exclude-dir=.git --exclude-dir=openspec/changes` and confirm zero results
- [x] 4.2 Confirm `bin/claude-pod` exists and `bin/claude-secure` does not

## 5. Spot-check key files

- [x] 5.1 Review `install.sh`: verify binary install target is `/usr/local/bin/claude-pod`, config dir is `~/.claude-pod/`, and installer sed tokens reference `claude-pod`
- [x] 5.2 Review `uninstall.sh`: verify it removes `/usr/local/bin/claude-pod`, `~/.claude-pod/`, and `claude-pod-*` systemd units
- [x] 5.3 Review `docker-compose.yml`: verify volume mounts use `/etc/claude-pod/` and `/var/log/claude-pod/`
- [x] 5.4 Review `claude/settings.json`: verify hook path references `/etc/claude-pod/hooks/pre-tool-use.sh`
- [x] 5.5 Review `webhook/claude-pod-webhook.service` and `claude-pod-reaper.service`: verify unit names and `ExecStart` paths are correct
- [x] 5.6 Review `validator/validator.py`: verify log path and any string literals use `claude-pod`
- [x] 5.7 Review `webhook/listener.py`: verify string literals and log paths use `claude-pod`
- [x] 5.8 Review `tests/fixtures/*/profile.json`: verify `claude_pod_bin` key and value paths are correct
- [x] 5.9 Review `CLAUDE.md`: verify the project name in the header is `claude-pod`

## 6. Run tests

- [x] 6.1 Run `bash run-tests.sh` (or the appropriate subset) and confirm all tests pass with the new names
