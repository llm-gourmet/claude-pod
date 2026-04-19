## 1. Hook — read domain whitelist from profile.json

- [x] 1.1 Update `domain_in_whitelist()` in `claude/hooks/pre-tool-use.sh` to read `secrets[].domains[]` from `profile.json` instead of `secrets[].allowed_domains[]` from `whitelist.json`
- [x] 1.2 Remove `domain_in_readonly()` function and any reference to `readonly_domains` from the hook
- [x] 1.3 Update `WHITELIST` variable (or equivalent) to point to `profile.json`

## 2. Proxy — read redaction map from profile.json

- [x] 2.1 Update proxy secret-loading code to read `secrets[].{env_var, redacted}` from `profile.json` instead of `secrets[].{env_var, placeholder}` from `whitelist.json`
- [x] 2.2 Remove any reference to `whitelist.json` from proxy source

## 3. CLI — profile create/validate/list

- [x] 3.1 Update `create_profile` in `bin/claude-secure` to write new `profile.json` schema (`workspace`, no `github_token`, no extra fields)
- [x] 3.2 Update `validate_profile` to check new required fields: `workspace`, and each `secrets[]` entry has `env_var`, `redacted`, `domains`
- [x] 3.3 Remove `whitelist.json` copy step from `create_profile`
- [x] 3.4 Update `list_profiles` display if it reads any removed fields

## 4. Installer

- [x] 4.1 Update `install.sh` `setup_workspace()` to write new `profile.json` schema (no `github_token` field)
- [x] 4.2 Remove whitelist copy step from installer (`cp "$app_dir/config/whitelist.json" ...`)
- [x] 4.3 Delete `config/whitelist.json` from the project

## 5. Test fixtures

- [x] 5.1 Update `tests/fixtures/profile-23-docs/` — remove `whitelist.json`, add `secrets[]` to `profile.json`
- [x] 5.2 Update `tests/fixtures/profile-23-legacy/` — remove `whitelist.json`, update `profile.json`
- [x] 5.3 Update `tests/fixtures/profile-25-docs/` — remove `whitelist.json`, update `profile.json`
- [x] 5.4 Update `tests/fixtures/profile-e2e/` — update `profile.json` (remove webhook fields if present)

## 6. Test harnesses

- [x] 6.1 Update `tests/test-phase9.sh` — update `profile.json` writes to use new schema (remove `max_turns`, `system_prompt` via new field if applicable)
- [x] 6.2 Update `tests/test-phase12.sh` — update `create_profile` test assertions and fixture writes for new schema
- [x] 6.3 Update `tests/test-phase13.sh` — remove `max_turns` test, update `profile.json` fixture writes
- [x] 6.4 Update `tests/test-phase14.sh` — update profile fixture writes
- [x] 6.5 Update `tests/test-phase15.sh` — update profile fixture writes
- [x] 6.6 Update `tests/test-phase16.sh` — update profile fixture writes
- [x] 6.7 Update `tests/test-phase17.sh` / `test-phase17-e2e.sh` — update fixture writes and assertions
- [x] 6.8 Run full test suite and fix any remaining failures
