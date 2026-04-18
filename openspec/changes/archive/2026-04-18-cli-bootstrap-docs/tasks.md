## 1. Config-Verwaltung

- [x] 1.1 `cmd_bootstrap_docs_set_config()` implementieren: liest `~/.claude-secure/docs-bootstrap.env`, updated einzelnen Key, schreibt zurück mit `chmod 600`
- [x] 1.2 `--set-repo`, `--set-token`, `--set-branch` Flags im Argument-Parser des Subcommands verdrahten
- [x] 1.3 Config-Lese-Funktion: sourced `docs-bootstrap.env` und prüft ob `DOCS_BOOTSTRAP_REPO` gesetzt ist

## 2. Git-Workflow

- [x] 2.1 Ephemeren ASKPASS-Helper implementieren (analog `publish_report_to_repo`): schreibt `.askpass.sh` in tmpdir, setzt `GIT_ASKPASS`
- [x] 2.2 Shallow Clone mit Timeout: `git clone --depth 1 --branch $branch $repo $tmpdir/repo`
- [x] 2.3 Token aus Error-Output scrubben: `sed "s|${token}|<REDACTED:DOCS_BOOTSTRAP_TOKEN>|g"`
- [x] 2.4 Pfad-Existenz-Check: `[[ -d "$tmpdir/repo/$path" ]]` → Fehler mit Meldung
- [x] 2.5 Template-Pfad auflösen: dev-Layout (`../scripts/templates/`) und installed-Layout (`/usr/local/share/claude-secure/scripts/templates/`)
- [x] 2.6 Ordnerstruktur + Templates in `$tmpdir/repo/$path` anlegen (Logik aus `scripts/new-project.sh`)
- [x] 2.7 `git add`, `git commit -m "bootstrap: $path"`, `git push` ausführen
- [x] 2.8 Cleanup: tmpdir in `_CLEANUP_FILES` registrieren (nutzt bestehenden `cleanup()`-Trap)

## 3. CLI-Integration

- [x] 3.1 `bootstrap-docs` Case zum `case "$1" in`-Dispatcher in `bin/claude-secure` hinzufügen
- [x] 3.2 Usage-Text für `bootstrap-docs` in die Hilfe-Ausgabe des CLI aufnehmen
- [x] 3.3 Argument-Validierung: kein Pfad-Arg → Usage-Fehler

## 4. Installer

- [x] 4.1 `install.sh`: `scripts/templates/` in installierten Share-Pfad kopieren (z.B. `/usr/local/share/claude-secure/scripts/templates/`)
- [x] 4.2 `install.sh`: `scripts/new-project.sh` ebenfalls in Share-Pfad kopieren

## 5. Verifikation

- [x] 5.1 `--set-repo` / `--set-token` / `--set-branch` testen: `docs-bootstrap.env` korrekt geschrieben, mode `600`
- [x] 5.2 Kein Repo konfiguriert → Fehler-Meldung bestätigen
- [x] 5.3 Kein Pfad-Argument → Usage-Fehler bestätigen
- [x] 5.4 Pfad existiert bereits im Repo → Fehler-Meldung bestätigen
- [x] 5.5 Erfolgreicher End-to-End-Test gegen ein Test-Repo: alle Dateien und Ordner korrekt gepusht
- [x] 5.6 Kein tmpdir nach Ausführung auf dem Host
