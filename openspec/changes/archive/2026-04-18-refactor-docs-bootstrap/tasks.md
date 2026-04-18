## 1. Templates ablegen

- [x] 1.1 `scripts/templates/VISION.md` anlegen (aus `openspec/changes/refactor-docs-bootstrap/templates/VISION.md`)
- [x] 1.2 `scripts/templates/GOALS.md` anlegen
- [x] 1.3 `scripts/templates/AGREEMENTS.md` anlegen
- [x] 1.4 `scripts/templates/TODOS.md` anlegen
- [x] 1.5 `scripts/templates/TASKS.md` anlegen
- [x] 1.6 `scripts/templates/ideas/idea-template.md` anlegen
- [x] 1.7 `scripts/templates/decisions/decision-template.md` anlegen
- [x] 1.8 `scripts/templates/done/done-template.md` anlegen

## 2. Bootstrap-Script

- [x] 2.1 `scripts/new-project.sh` erstellen mit Argument-Validierung (kein Arg → Usage-Fehler, Verzeichnis existiert → Fehler)
- [x] 2.2 Ordnerstruktur anlegen: `projects/<name>/`, `decisions/`, `ideas/`, `done/`
- [x] 2.3 Top-Level-Dateien kopieren: `VISION.md`, `GOALS.md`, `AGREEMENTS.md`, `TODOS.md`, `TASKS.md` aus `scripts/templates/`
- [x] 2.4 Template-Dateien in Unterordner kopieren: `decisions/_template.md`, `ideas/_template.md`, `done/_template.md`
- [x] 2.5 Script ausführbar machen (`chmod +x scripts/new-project.sh`)

## 3. TODO-Scanner aktualisieren

- [x] 3.1 Push-Prompt-Template des Obsidian-Profils aktualisieren: Pfadmuster von `projects/*/todo.md` auf `projects/*/TODOS.md` ändern
- [x] 3.2 Ausgabemeldungen im Scanner-Prompt prüfen — müssen `TODOS.md` referenzieren (nicht `todo.md`)

## 4. Verifikation

- [x] 4.1 `scripts/new-project.sh test-projekt` ausführen — alle Dateien und Ordner mit korrektem Inhalt prüfen
- [x] 4.2 Script erneut ausführen — Fehler-Exit und korrekte Fehlermeldung bestätigen
- [x] 4.3 Script ohne Argument ausführen — Usage-Fehler bestätigen
- [x] 4.4 Scanner mit Mock-`COMMITS_JSON` testen: Pfad `projects/test-projekt/TODOS.md` → Match erwartet
- [x] 4.5 Scanner mit `projects/test-projekt/todo.md` testen → kein Match erwartet
