## 1. docker-compose.yml

- [x] 1.1 Remove `- workspace:/workspace` from claude service volumes
- [x] 1.2 Remove `- ${LOG_DIR:-./logs}:/var/log/claude-pod` from claude service volumes
- [x] 1.3 Remove `- ${LOG_DIR:-./logs}:/var/log/claude-pod` from proxy service volumes
- [x] 1.4 Remove `- ${LOG_DIR:-./logs}:/var/log/claude-pod` from validator service volumes
- [x] 1.5 Remove the `workspace` named volume definition (keep `validator-db`)

## 2. install.sh

- [x] 2.1 Move `cat > "$CONFIG_DIR/config.sh"` (PLATFORM write) from `setup_workspace()` into `setup_directories()`
- [x] 2.2 Remove `setup_workspace()` function entirely
- [x] 2.3 Remove `setup_workspace` call from the main install flow
- [x] 2.4 Remove logs directory creation (`mkdir -p "$CONFIG_DIR/logs"` + `chmod 777`) from `setup_directories()`
- [x] 2.5 Remove `chmod 777 "$CONFIG_DIR/logs"` from the post-install ownership block

## 3. bin/claude-pod — profile creation

- [x] 3.1 Remove workspace path prompt and `mkdir -p` from `create_profile()`
- [x] 3.2 Change `profile.json` creation in `create_profile()` from `{"workspace": $ws, "secrets": []}` to `{"secrets": []}`

## 4. bin/claude-pod — config loading

- [x] 4.1 Remove `WORKSPACE_PATH=$(jq -r '.workspace' ...)` and `export WORKSPACE_PATH` from `load_profile_config()`
- [x] 4.2 Remove `export LOG_DIR="$CONFIG_DIR/logs"` from `load_profile_config()`
- [x] 4.3 Remove the `default_ws` block (prompt + `mkdir -p` + `config.sh` write) from `load_superuser_config()`
- [x] 4.4 Remove `export WORKSPACE_PATH="$default_ws"` from `load_superuser_config()`
- [x] 4.5 Remove `export LOG_DIR="$CONFIG_DIR/logs"` from `load_superuser_config()`

## 5. bin/claude-pod — other references

- [x] 5.1 Remove WORKSPACE column header and `ws=` variable from `list_profiles()`
- [x] 5.2 Remove LOG_DIR setup block (`LOG_DIR="${LOG_DIR:-...}"`, `mkdir -p`, `chmod 777`) from spawn function

## 6. validate_profile

- [x] 6.1 Remove the `workspace` field existence check from `validate_profile` in `bin/claude-pod`
- [x] 6.2 Remove the workspace path-exists-on-disk check from `validate_profile`
