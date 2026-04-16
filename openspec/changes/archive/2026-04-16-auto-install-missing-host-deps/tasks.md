## 1. Package manager detection

- [x] 1.1 Add `detect_package_manager()` helper in `install.sh` that checks for `apt-get`, `dnf`, `pacman` in order and echoes the found PM name (or empty string if none)

## 2. check_dependencies() refactor

- [x] 2.1 Split the `missing` array into `auto_installable` and `manual_only`: docker/docker-compose always go to `manual_only`; curl/jq/uuidgen/python3 go to `auto_installable` when a PM is detected, else `manual_only`
- [x] 2.2 If `auto_installable` is non-empty: print the list and prompt `"Install missing packages? [y/N]: "`
- [x] 2.3 On user confirmation: build the PM-specific package name list (`uuidgen` → `uuid-runtime` for apt-get, `util-linux` for dnf/pacman) and run the install command
- [x] 2.4 After install: re-verify each auto-installed package with `command -v`; exit on failure
- [x] 2.5 After install: if `python3` was installed, run version check (≥ 3.11); exit with deadsnakes PPA hint if too old
- [x] 2.6 If `manual_only` is non-empty after auto-install step: show existing error listing and exit

## 3. Webhook listener python3 guard

- [x] 3.1 Replace hard `log_error + return 1` at the python3 check (~line 440) with the same auto-install offer pattern: detect PM, prompt, install, re-check version

## 4. Verification

- [x] 4.1 Simulate missing `jq` + `curl` on apt-get system: confirm prompt shown, packages installed, install continues
- [x] 4.2 Simulate no package manager: confirm falls through to original error output
- [x] 4.3 Simulate user declining prompt: confirm exits with missing-deps error
- [x] 4.4 Simulate python3 installed but version 3.10: confirm error with PPA hint
