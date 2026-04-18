## 1. bin/claude-secure — COMMITS_JSON Token

- [x] 1.1 In `render_template` (~line 830, after push-token block): extract `commits` array via `jq -c '.commits // []'` from `$event_json`, write to tempfile, call `_substitute_token_from_file "{{COMMITS_JSON}}" "$commits_file"`, append file to `_CLEANUP_FILES`
- [x] 1.2 Verify backward compatibility: run an existing dry-run spawn (e.g. `--dry-run` with a jad event file) and confirm output is unchanged

## 2. Profile obsidian — Config Files

- [x] 2.1 Create directory `~/.claude-secure/profiles/obsidian/`
- [x] 2.2 Generate webhook secret: `openssl rand -hex 16` → store in `profile.json` as `webhook_secret`
- [x] 2.3 Write `~/.claude-secure/profiles/obsidian/profile.json` with `repo`, `webhook_secret`, `webhook_event_filter` (push branches: master, main), `workspace`
- [x] 2.4 Copy `.env` from `profiles/jad/.env` to `profiles/obsidian/.env`

## 3. Profile obsidian — Prompt Template

- [x] 3.1 Create directory `~/.claude-secure/profiles/obsidian/prompts/`
- [x] 3.2 Write `prompts/push.md`: instructs Claude to parse `{{COMMITS_JSON}}`, match `projects/*/todo.md` pattern across `added`+`modified`, output one-line result (found or not found), no shell commands

## 4. Caddy — Reverse Proxy

- [x] 4.1 Install Caddy on VPS (apt or official Caddy repo)
- [x] 4.2 Write `/etc/caddy/Caddyfile` block: forward `<host>/webhook` → `localhost:9000`, preserve `X-Hub-Signature-256` and `X-GitHub-Event` headers
- [x] 4.3 Enable and start Caddy: `systemctl enable --now caddy`
- [x] 4.4 Smoke-test: `curl -v http://localhost/webhook` should reach listener (expect 400 empty_body, not connection refused)

## 5. GitHub — Webhook Configuration

- [x] 5.1 In `llm-gourmet/obsidian` → Settings → Webhooks → Add webhook: set Payload URL, Content-Type `application/json`, Secret (from step 2.2), select "Just the push event"
- [x] 5.2 Confirm GitHub shows green checkmark on the ping delivery

## 6. Verification

- [x] 6.1 Restart webhook service: `systemctl restart claude-secure-webhook && systemctl status claude-secure-webhook`
- [x] 6.2 Check health: `curl http://localhost:9000/health` → `{"status":"ok"}`
- [x] 6.3 Push a test commit to `llm-gourmet/obsidian` master that does NOT touch any `projects/*/todo.md` → verify spawn log contains `TODO-Scanner: keine Änderungen erkannt.`
- [x] 6.4 Push a test commit that adds or modifies `projects/test/todo.md` → verify spawn log contains `TODO-Scanner: neue TODOs erkannt in: projects/test/todo.md`
- [x] 6.5 Confirm webhook JSONL log: `tail ~/.claude-secure/logs/webhook.jsonl | jq .` shows `event: "spawn_completed"` with `exit_code: 0`
