## Why

Projekt-Dokumentation bootstrappen erfordert aktuell manuelles Navigieren ins claude-secure Repo und direkten Script-Aufruf — kein globaler Befehl, kein Repo-Targeting. Mit `claude-secure bootstrap-docs <path>` kann man von jedem Terminal-Kontext aus ein Ziel-Repo (z.B. Obsidian-Vault) ansprechen und den Pfad frei wählen.

## What Changes

- Neuer `claude-secure`-Subcommand `bootstrap-docs <path>`
- Einmalige Konfiguration von Ziel-Repo-URL + Auth-Token in `~/.claude-secure/config.sh` (oder separater Config-Datei)
- Command clont das Repo in ein temporäres Verzeichnis (oder nutzt vorhandenen lokalen Clone), legt die Ordnerstruktur + Templates am angegebenen Pfad an, committet und pusht
- `<path>` ist relativ zum Repo-Root, z.B. `projects/JAD` oder `custom`
- Fehler wenn Pfad bereits existiert

## Capabilities

### New Capabilities

- `bootstrap-docs-command`: Der `claude-secure bootstrap-docs <path>` Subcommand inkl. Repo-Config und Git-Workflow

### Modified Capabilities

- `docs-bootstrap`: Bestehende Bootstrap-Logik (Script + Templates) wird vom neuen Command genutzt — keine Requirement-Änderung, nur Nutzung als Bibliothek

## Impact

- `bin/claude-secure` (oder äquivalentes CLI-Entry-Script): neuer `bootstrap-docs` Subcommand
- `install.sh`: ggf. Config-Slot für Repo-URL + Token anlegen
- `scripts/new-project.sh`: bleibt bestehen, wird intern vom Command aufgerufen oder dessen Logik wird übernommen
- Abhängigkeit: `git` auf dem Host (bereits vorausgesetzt)
- Kein neuer Docker-Container — Command läuft direkt auf dem Host
