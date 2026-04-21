## 1. listener.py — Filter Logic entfernen

- [x] 1.1 `DEFAULT_FILTER` dict entfernen
- [x] 1.2 `fetch_commit_patch()` Funktion entfernen
- [x] 1.3 `has_meaningful_todo_change()` Funktion entfernen
- [x] 1.4 `apply_event_filter()` Funktion entfernen
- [x] 1.5 Import `fnmatch` und `urllib.request` / `urllib.error` entfernen (falls nicht mehr gebraucht)
- [x] 1.6 `do_POST`: `apply_event_filter()`-Aufruf und den `filtered`-Response-Block entfernen

## 2. listener.py — _spawn_worker verdrahten

- [x] 2.1 `spawn_skipped` log-Event durch `spawn_start` ersetzen
- [x] 2.2 `subprocess.run([config.claude_secure_bin, "spawn", connection_name, "--event-file", str(event_path)], capture_output=True, text=True)` aufrufen
- [x] 2.3 Stdout + Stderr in `<logs_dir>/spawn-<delivery_id[:12]>.log` schreiben
- [x] 2.4 Bei exit_code == 0: `spawn_done` loggen; bei exit_code != 0: `spawn_error` loggen
- [x] 2.5 Bei Exception: `spawn_exception` mit `error`-Feld loggen

## 3. connections.json Schema — Felder entfernen

- [x] 3.1 `resolve_connection_by_repo()` in `listener.py`: `webhook_event_filter`, `webhook_bot_users`, `todo_path_pattern`, `github_token` nicht mehr aus dem Connection-Dict zurückgeben (nur `name`, `repo`, `webhook_secret`)
- [x] 3.2 `cmd_webhook_listener` in `bin/claude-secure`: Keine `--event-filter`-Flags hinzufügen (Doku-Check)

## 4. Tests anpassen

- [x] 4.1 Bestehende Tests die `spawn_skipped` erwarten auf `spawn_done` / `spawn_error` aktualisieren
- [x] 4.2 Tests für `apply_event_filter` und `has_meaningful_todo_change` entfernen
- [x] 4.3 Neuer Test: gültiger Push → `claude-secure spawn` wird mit `--event-file` aufgerufen
- [x] 4.4 Neuer Test: Spawn exit 0 → `spawn_done` in webhook.jsonl
- [x] 4.5 Neuer Test: Spawn exit non-0 → `spawn_error` in webhook.jsonl
- [x] 4.6 Neuer Test: Spawn-Log-Datei existiert nach dem Spawn mit korrektem Inhalt

## 5. VPS — Migration

- [x] 5.1 Aktualisiertes `listener.py` auf VPS deployen (`/opt/claude-secure/webhook/listener.py`)
- [x] 5.2 `claude-secure-webhook` Service neustarten: `sudo systemctl restart claude-secure-webhook`
- [x] 5.3 Router-Profil anlegen: `claude-secure profile create obsidian-router`
- [x] 5.4 System-Prompt für `obsidian-router` schreiben (Filter-Logik in natürlicher Sprache)
- [x] 5.5 Connection auf VPS prüfen: `claude-secure webhook-listener --list-connections`
- [x] 5.6 `github_token` aus `connections.json` in Profil `.env` verschieben (falls vorhanden)
- [x] 5.7 Test-Push durchführen und `webhook.jsonl` auf `spawn_start` / `spawn_done` prüfen
