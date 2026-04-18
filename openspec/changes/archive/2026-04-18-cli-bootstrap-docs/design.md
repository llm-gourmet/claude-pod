## Context

`claude-secure` hat bereits ein bewährtes Muster für authentifizierten Git-Zugriff: Clone mit ephemerem ASKPASS-Helper, PAT aus Env-Var, scrubbed error output. Das gleiche Muster nutzt der Report-Repo-Publisher (Phase 16). `bootstrap-docs` ist konzeptuell dasselbe: Clone → Dateien anlegen → Commit → Push.

Die Templates liegen bereits in `scripts/templates/` (aus `refactor-docs-bootstrap`). Der neue Command muss sie nur kennen.

## Goals / Non-Goals

**Goals:**
- `claude-secure bootstrap-docs <path>` clont ein konfiguriertes Ziel-Repo, legt die Ordnerstruktur + Templates am angegebenen Pfad an, und pusht
- Einmalige Konfiguration via `claude-secure bootstrap-docs --set-repo <url>` und `--set-token <token>` (schreibt in `~/.claude-secure/docs-bootstrap.env`)
- Fehler wenn Pfad im Repo bereits existiert

**Non-Goals:**
- Kein interaktiver Modus (Felder abfragen)
- Kein Merge/Update bestehender Projekte
- Kein neuer Docker-Container — läuft auf dem Host wie alle anderen CLI-Subcommands

## Decisions

### Config-Speicherort: `~/.claude-secure/docs-bootstrap.env`

Separate Datei statt `config.sh`, damit sie klar gescoped ist und einfach zurückgesetzt werden kann.

Format:
```
DOCS_BOOTSTRAP_REPO=https://github.com/user/vault.git
DOCS_BOOTSTRAP_TOKEN=ghp_...
DOCS_BOOTSTRAP_BRANCH=main
```

**Rationale**: Gleiche Konvention wie Profile-`.env`-Dateien. `config.sh` ist für globale Laufzeit-Config gedacht, nicht für Credentials.

**Alternative**: In Default-Profil `.env` ablegen. Abgelehnt — `bootstrap-docs` ist kein Profil-Feature.

### Token-Handling: ASKPASS-Pattern (wie Report-Repo)

Gleicher ephemerer ASKPASS-Helper wie in `publish_report_to_repo`. Kein `git credential store`.

**Rationale**: PAT landet nicht in `.git/config`, kein Leak in Shell-History. Bereits battle-tested im Code.

### Templates-Pfad: relativ zum Script-Verzeichnis

`bootstrap-docs` sucht Templates in `$(dirname $0)/../scripts/templates/` (dev-Layout) bzw. `/usr/local/share/claude-secure/scripts/templates/` (installed). Gleiche Auflösungslogik wie `lib/platform.sh`.

**Rationale**: Kein hardcodierter Pfad, funktioniert in beiden Layouts (Repo und installiert).

### Git-Workflow: shallow clone → scaffold → commit → push

1. `git clone --depth 1 <repo> <tmpdir>`
2. Prüfe ob `<path>` bereits existiert → Fehler
3. `scripts/new-project.sh`-Logik direkt ausführen (kein Subshell-Aufruf, Template-Pfad bekannt)
4. `git add`, `git commit -m "bootstrap: <path>"`, `git push`
5. Cleanup `<tmpdir>`

**Alternative**: Kein Clone, User zeigt auf lokalen Checkout. Abgelehnt — erfordert Zustand auf dem Host, weniger portabel.

## Risks / Trade-offs

- [Clone-Latenz bei großen Repos] → Mitigation: `--depth 1` + Timeout analog Report-Repo (60s)
- [Token in `docs-bootstrap.env` world-readable] → Mitigation: `chmod 600` beim Schreiben, Warnung bei falschem Mode
- [Push-Fehler bei Concurrent Edits] → Mitigation: Klarer Fehler, kein Auto-Retry
- [Templates im installierten Layout nicht gefunden] → Mitigation: `install.sh` kopiert `scripts/templates/` mit; Fehler mit klarer Meldung wenn nicht gefunden
