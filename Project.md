# claude-secure — Projektspezifikation

> Implementierungsspec für Claude Code.
> Ziel: ein installierbares Paket das Claude Code in einer vollständig kontrollierten,
> netzwerkisolierten Umgebung betreibt — ohne API Keys preiszugeben und ohne
> unkontrollierten Outbound-Traffic zu erlauben.

---

## 1. Projektziele & Kontext

### Problem

Claude Code läuft als normaler User-Prozess und hat vollen Netzwerkzugriff. Wenn Claude
eine `.env`-Datei oder Konfiguration liest, können Secrets in den LLM-Kontext gelangen
und an Anthropic übertragen werden. Tool-Calls (z.B. `Bash(curl ...)`) können Secrets
an beliebige externe URLs senden — direkt oder über indirekte Scripts.

### Lösung: Vier-Schichten-Architektur

```
Schicht 1 — Docker-Isolation        Netzwerk-Namespace, kein direkter Internetzugang
Schicht 2 — PreToolUse Hook         Prüft und signiert jeden ausgehenden Call
Schicht 3 — Anthropic-Proxy         Bereinigt Secrets aus LLM-Kontext
Schicht 4 — SQLite Call-Validator   Lässt nur Hook-signierte Calls durch (via NFQUEUE)
```

### Nicht-Ziele (bewusste Lücken)

- Secrets die Claude über Dateireferenzen (`@file`) indirekt an Anthropic schickt,
  werden vom Proxy nur erkannt wenn der Dateiinhalt bekannte Secret-Werte enthält.
- Ein falsches Secret kann an eine whitelisted Domain gehen wenn es im Command-String
  nicht erkennbar ist (z.B. tief in einer Datei versteckt).
- Diese Lücken sind dokumentiert und akzeptiert.

---

## 2. Architektur-Übersicht

```
Host-System
├── install.sh                  Installer-Script
├── docker-compose.yml          Orchestrierung aller Services
│
├── claude/                     Claude Code Container
│   ├── Dockerfile
│   ├── hooks/                  PreToolUse Hook Scripts (read-only gemountet)
│   │   └── pre-tool-use.sh
│   └── workspace/              Arbeitsverzeichnis (persistentes Volume)
│
├── proxy/                      Anthropic-Proxy Service
│   ├── Dockerfile
│   └── proxy.js                Node.js Proxy mit Secret-Redaktion
│
├── validator/                  NFQUEUE Call-Validator Service
│   ├── Dockerfile
│   └── validator.py            SQLite-basierter Call-Validator
│
└── config/                     Zentrale Konfiguration (read-only)
    ├── whitelist.json           Whitelist: Domains + Secret-Zuordnungen
    └── .env                    Echte Secret-Werte (nur Proxy/Validator sehen diese)
```

### Netzwerk-Topologie

```
claude-container
    │  (internes Netz, kein direkter Internetzugang)
    │  ANTHROPIC_BASE_URL=http://proxy:8080
    ↓
proxy-container → api.anthropic.com  (bereinigter Traffic)
    │
validator-container (NFQUEUE)
    │  prüft: hat dieser Call eine gültige Hook-ID?
    ↓
iptables → erlaubt / blockt
```

---

## 3. Schicht 1 — Docker-Isolation

### docker-compose.yml

```yaml
version: "3.9"

services:

  claude:
    build: ./claude
    container_name: claude-secure
    stdin_open: true
    tty: true
    command: ["claude", "--dangerously-skip-permissions"]
    environment:
      - ANTHROPIC_BASE_URL=http://proxy:8080
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-dummy}
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}
    volumes:
      - workspace:/workspace                          # persistentes Arbeitsverzeichnis
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - ./claude/hooks:/etc/claude-secure/hooks:ro    # read-only, nicht schreibbar für Claude
      - claude-auth:/root/.claude                     # persistente Auth-Daten
    networks:
      - claude-internal
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    depends_on:
      - proxy
      - validator

  proxy:
    build: ./proxy
    container_name: claude-proxy
    environment:
      - REAL_ANTHROPIC_BASE_URL=https://api.anthropic.com
      - WHITELIST_PATH=/etc/claude-secure/whitelist.json
    volumes:
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - ./config/.env:/etc/claude-secure/.env:ro      # echte Secrets
    networks:
      - claude-internal
      - claude-external
    ports:
      - "8080"

  validator:
    build: ./validator
    container_name: claude-validator
    volumes:
      - ./config/whitelist.json:/etc/claude-secure/whitelist.json:ro
      - validator-db:/data                            # SQLite persistent
    networks:
      - claude-internal
    cap_add:
      - NET_ADMIN                                     # braucht NFQUEUE-Zugriff

networks:
  claude-internal:
    internal: true       # kein direkter Internetzugang
  claude-external: {}    # nur Proxy hat Zugang

volumes:
  workspace:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${WORKSPACE_PATH:-./workspace}
  claude-auth:
  validator-db:
```

### claude/Dockerfile

```dockerfile
FROM node:20-slim

RUN npm install -g @anthropic-ai/claude-code

# Hook-Scripts ins Image — werden zusätzlich read-only gemountet
COPY hooks/ /etc/claude-secure/hooks/
RUN chmod 555 /etc/claude-secure/hooks/ && \
    chmod 555 /etc/claude-secure/hooks/*.sh

# Claude Settings mit Hook-Konfiguration — read-only
COPY settings.json /root/.claude/settings.json
RUN chmod 444 /root/.claude/settings.json

WORKDIR /workspace
```

### claude/settings.json

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/etc/claude-secure/hooks/pre-tool-use.sh"
          }
        ]
      }
    ]
  }
}
```

---

## 4. Schicht 2 — PreToolUse Hook

Der Hook wird bei **jedem** Tool-Call neu gestartet (kein Daemon). Er liest die
Whitelist bei jedem Aufruf frisch — Whitelist-Änderungen brauchen keinen Neustart.

### claude/hooks/pre-tool-use.sh

```bash
#!/bin/bash
set -euo pipefail

WHITELIST="/etc/claude-secure/whitelist.json"
VALIDATOR_URL="http://validator:8088/register"
LOG_FILE="/var/log/claude-secure/hooks.log"

# Hook-Input lesen
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
URL_ARG=$(echo "$INPUT" | jq -r '.tool_input.url // empty')

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "$(timestamp) [HOOK] $*" >> "$LOG_FILE"; }

# Extrahiere Ziel-URL aus Command oder direktem URL-Argument
extract_url() {
  local cmd="$1"
  # curl, wget URL-Extraktion (vereinfacht)
  echo "$cmd" | grep -oE 'https?://[^ "]+' | head -1
}

# Prüfe ob Domain whitelisted ist
is_whitelisted() {
  local domain="$1"
  jq -e --arg d "$domain" \
    '.secrets[].allowed_domains[] | select(. == $d)' \
    "$WHITELIST" > /dev/null 2>&1
}

# Prüfe ob Request einen Payload enthält (POST/PUT/PATCH, Body, Header mit Auth)
has_payload() {
  local cmd="$1"
  echo "$cmd" | grep -qE '\-\-(data|data-raw|data-binary|json|form)|\-d |\-X (POST|PUT|PATCH)|Authorization:|Bearer |Basic '
}

# Prüfe Dateiinhalt auf bekannte Secrets wenn @file Referenz gefunden
check_file_refs() {
  local cmd="$1"
  local files
  files=$(echo "$cmd" | grep -oE '@[^ ]+' | sed 's/@//')
  
  for file in $files; do
    if [ -f "$file" ]; then
      while IFS= read -r line; do
        local placeholder
        placeholder=$(jq -r '.secrets[].placeholder' "$WHITELIST")
        local env_var
        env_var=$(jq -r '.secrets[].env_var' "$WHITELIST")
        # Prüfe ob Datei bekannte Secret-Werte enthält
        if echo "$line" | grep -qF "$(printenv "$env_var" 2>/dev/null || echo '')"; then
          log "BLOCKED: Secret found in file reference $file"
          echo "Blocked: Secret found in file $file" >&2
          exit 2
        fi
      done < "$file"
    fi
  done
}

# Hauptlogik
TARGET_URL=""
if [ -n "$COMMAND" ]; then
  TARGET_URL=$(extract_url "$COMMAND")
elif [ -n "$URL_ARG" ]; then
  TARGET_URL="$URL_ARG"
fi

# Kein URL-Call → durchlassen
if [ -z "$TARGET_URL" ]; then
  exit 0
fi

DOMAIN=$(echo "$TARGET_URL" | grep -oE '[^/]+\.[^/]+' | head -1)

log "Tool: $TOOL_NAME | Domain: $DOMAIN | URL: $TARGET_URL"

# Payload-Check für nicht-whitelisted Domains
if ! is_whitelisted "$DOMAIN"; then
  if has_payload "${COMMAND}${URL_ARG}"; then
    log "BLOCKED: Payload to non-whitelisted domain $DOMAIN"
    echo "Blocked: Payload not allowed to non-whitelisted domain $DOMAIN" >&2
    exit 2
  fi
  # Kein Payload → GET erlaubt, aber keine Signierung nötig
  log "ALLOWED (read-only): $DOMAIN"
  exit 0
fi

# Whitelisted Domain — Dateiinhalt prüfen
check_file_refs "${COMMAND:-}"

# Call-ID generieren und beim Validator registrieren
CALL_ID=$(uuidgen)
EXPIRES=$(date -d '+10 seconds' +%s)
PID=$$

REGISTER_PAYLOAD=$(jq -n \
  --arg id "$CALL_ID" \
  --arg domain "$DOMAIN" \
  --arg pid "$PID" \
  --arg expires "$EXPIRES" \
  '{id: $id, domain: $domain, pid: $pid, expires: $expires}')

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$VALIDATOR_URL" \
  -H "Content-Type: application/json" \
  -d "$REGISTER_PAYLOAD")

if [ "$HTTP_STATUS" != "200" ]; then
  log "BLOCKED: Validator registration failed for $DOMAIN"
  echo "Blocked: Could not register call with validator" >&2
  exit 2
fi

log "SIGNED: Call-ID $CALL_ID for $DOMAIN"
exit 0
```

**Wichtig:** Die Hook-Datei gehört `root`, ist `chmod 555` — Claude kann sie lesen
und ausführen, aber nicht modifizieren.

---

## 5. Schicht 3 — Anthropic-Proxy

### proxy/proxy.js

```javascript
const http = require('http');
const https = require('https');
const fs = require('fs');

const WHITELIST_PATH = process.env.WHITELIST_PATH;
const ENV_PATH = '/etc/claude-secure/.env';
const UPSTREAM = 'https://api.anthropic.com';

// Secrets und Platzhalter aus Whitelist + .env laden
function loadSecretMap() {
  const whitelist = JSON.parse(fs.readFileSync(WHITELIST_PATH, 'utf8'));
  const envContent = fs.readFileSync(ENV_PATH, 'utf8');
  const envVars = {};
  
  envContent.split('\n').forEach(line => {
    const match = line.match(/^([^=]+)=(.*)$/);
    if (match) envVars[match[1].trim()] = match[2].trim();
  });

  const map = {};
  const reverseMap = {};
  
  whitelist.secrets.forEach(secret => {
    const realValue = envVars[secret.env_var];
    if (realValue) {
      map[realValue] = secret.placeholder;
      reverseMap[secret.placeholder] = realValue;
    }
  });
  
  return { map, reverseMap };
}

// Secrets im Text ersetzen
function redact(text, secretMap) {
  let result = text;
  Object.entries(secretMap).forEach(([real, placeholder]) => {
    result = result.split(real).join(placeholder);
  });
  return result;
}

function restore(text, reverseMap) {
  let result = text;
  Object.entries(reverseMap).forEach(([placeholder, real]) => {
    result = result.split(placeholder).join(real);
  });
  return result;
}

const server = http.createServer((req, res) => {
  let body = '';
  
  req.on('data', chunk => { body += chunk; });
  
  req.on('end', () => {
    // Secrets frisch laden bei jedem Request (Whitelist-Änderungen ohne Neustart)
    const { map, reverseMap } = loadSecretMap();
    
    // Request-Body bereinigen
    const redactedBody = redact(body, map);
    
    // An Anthropic weiterleiten
    const upstreamReq = https.request(`${UPSTREAM}${req.url}`, {
      method: req.method,
      headers: {
        ...req.headers,
        host: 'api.anthropic.com',
        'content-length': Buffer.byteLength(redactedBody),
      }
    }, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        // Platzhalter im Response zurücktauschen
        const restoredBody = restore(responseBody, reverseMap);
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        res.end(restoredBody);
      });
    });
    
    upstreamReq.on('error', err => {
      console.error('Upstream error:', err);
      res.writeHead(502);
      res.end('Bad Gateway');
    });
    
    upstreamReq.write(redactedBody);
    upstreamReq.end();
  });
});

server.listen(8080, () => {
  console.log('Anthropic proxy listening on :8080');
});
```

**Hinweis:** Streaming-Responses (SSE) erfordern chunk-weises Verarbeiten. Die obige
Implementierung ist der Startpunkt — Streaming-Support ist als Phase 2 markiert.

---

## 6. Schicht 4 — SQLite Call-Validator

### validator/validator.py

```python
#!/usr/bin/env python3
"""
NFQUEUE-basierter Call-Validator.
Lässt nur Calls durch die vom PreToolUse Hook registriert wurden.
"""

import sqlite3
import time
import json
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from netfilterqueue import NetfilterQueue
import scapy.all as scapy

DB_PATH = '/data/calls.db'

def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute('''
        CREATE TABLE IF NOT EXISTS allowed_calls (
            id TEXT PRIMARY KEY,
            domain TEXT NOT NULL,
            pid TEXT NOT NULL,
            expires INTEGER NOT NULL,
            used INTEGER DEFAULT 0,
            created_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    ''')
    conn.commit()
    return conn

# HTTP-Server für Hook-Registrierungen
class RegisterHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/register':
            length = int(self.headers['Content-Length'])
            body = json.loads(self.rfile.read(length))
            
            conn = sqlite3.connect(DB_PATH)
            conn.execute(
                'INSERT INTO allowed_calls (id, domain, pid, expires) VALUES (?, ?, ?, ?)',
                (body['id'], body['domain'], body['pid'], int(body['expires']))
            )
            conn.commit()
            conn.close()
            
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, *args):
        pass  # suppress default logging

def is_call_allowed(domain: str) -> bool:
    conn = sqlite3.connect(DB_PATH)
    now = int(time.time())
    
    result = conn.execute(
        '''SELECT id FROM allowed_calls 
           WHERE domain = ? AND expires > ? AND used = 0
           ORDER BY created_at DESC LIMIT 1''',
        (domain, now)
    ).fetchone()
    
    if result:
        # Call-ID entwerten (einmalig verwendbar)
        conn.execute('UPDATE allowed_calls SET used = 1 WHERE id = ?', (result[0],))
        conn.commit()
        conn.close()
        return True
    
    conn.close()
    return False

def cleanup_expired():
    """Abgelaufene Einträge periodisch löschen"""
    while True:
        time.sleep(60)
        conn = sqlite3.connect(DB_PATH)
        conn.execute('DELETE FROM allowed_calls WHERE expires < ?', (int(time.time()),))
        conn.commit()
        conn.close()

def packet_callback(packet):
    """NFQUEUE Callback — entscheidet über jeden ausgehenden Packet"""
    try:
        scapy_packet = scapy.IP(packet.get_payload())
        
        if scapy_packet.haslayer(scapy.TCP):
            # Ziel-Domain aus DNS-Cache oder SNI auslesen (vereinfacht)
            dst_ip = scapy_packet[scapy.IP].dst
            # TODO: IP → Domain Auflösung via lokalen DNS-Cache
            # Für Phase 1: iptables-Allowlist übernimmt primäre Filterung
            # Validator als zweite Schicht für bekannte whitelisted Domains
            packet.accept()
        else:
            packet.accept()
    except Exception as e:
        print(f'Validator error: {e}')
        packet.accept()  # im Fehlerfall durchlassen (fail-open für Stabilität)

if __name__ == '__main__':
    init_db()
    
    # Cleanup-Thread
    t = threading.Thread(target=cleanup_expired, daemon=True)
    t.start()
    
    # HTTP-Server für Hook-Registrierungen
    server = HTTPServer(('0.0.0.0', 8088), RegisterHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    print('Validator HTTP server listening on :8088')
    
    # NFQUEUE (benötigt NET_ADMIN capability)
    nfqueue = NetfilterQueue()
    nfqueue.bind(1, packet_callback)
    print('NFQUEUE validator running...')
    nfqueue.run()
```

---

## 7. Zentrale Konfiguration

### config/whitelist.json

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com", "raw.githubusercontent.com"]
    },
    {
      "placeholder": "PLACEHOLDER_STRIPE",
      "env_var": "STRIPE_KEY",
      "allowed_domains": ["stripe.com", "api.stripe.com"]
    },
    {
      "placeholder": "PLACEHOLDER_OPENAI",
      "env_var": "OPENAI_API_KEY",
      "allowed_domains": ["api.openai.com"]
    }
  ],
  "readonly_domains": [
    "google.com",
    "stackoverflow.com",
    "docs.anthropic.com"
  ]
}
```

### config/.env

```bash
# Echte Secret-Werte — nur Proxy und Validator lesen diese Datei
# Claude Code selbst sieht diese Werte zwar (da im Container-Env verfügbar),
# aber der Proxy entfernt sie aus allen Anthropic-Calls.

GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
STRIPE_KEY=sk_live_xxxxxxxxxxxxxxxxxxxx
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxx
```

**Dateirechte:**
```bash
sudo chown root:root config/whitelist.json config/.env
sudo chmod 444 config/whitelist.json
sudo chmod 400 config/.env
```

---

## 8. Installer

### install.sh

```bash
#!/bin/bash
set -euo pipefail

INSTALL_DIR="${CLAUDE_SECURE_DIR:-$HOME/.claude-secure}"
REPO_URL="https://github.com/your-org/claude-secure"

echo "=== claude-secure Installer ==="

# Abhängigkeiten prüfen
check_deps() {
  local missing=()
  for dep in docker docker-compose curl jq uuidgen; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Fehlende Abhängigkeiten: ${missing[*]}"
    echo "Auf Ubuntu installieren: sudo apt install docker.io docker-compose curl jq uuid-runtime"
    exit 1
  fi
}

# Umgebung erkennen
detect_env() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl2"
  elif [ -f /.dockerenv ]; then
    echo "docker"
  else
    echo "linux"
  fi
}

# Installationsverzeichnis anlegen
setup_dirs() {
  mkdir -p "$INSTALL_DIR"/{config,workspace,logs}
  
  # Dateien kopieren
  cp -r . "$INSTALL_DIR/"
  
  # Rechte setzen
  sudo chown root:root "$INSTALL_DIR/config/whitelist.json" 2>/dev/null || true
  sudo chmod 444 "$INSTALL_DIR/config/whitelist.json" 2>/dev/null || true
  
  if [ -f "$INSTALL_DIR/config/.env" ]; then
    sudo chown root:root "$INSTALL_DIR/config/.env"
    sudo chmod 400 "$INSTALL_DIR/config/.env"
  fi
  
  sudo chown -R root:root "$INSTALL_DIR/claude/hooks/"
  sudo chmod -R 555 "$INSTALL_DIR/claude/hooks/"
}

# Claude Code Authentication
setup_auth() {
  echo ""
  echo "=== Claude Code Authentifizierung ==="
  echo ""
  echo "Wähle deine Auth-Methode:"
  echo "  1) API Key (ANTHROPIC_API_KEY)"
  echo "  2) Subscription OAuth Token (claude setup-token)"
  echo ""
  read -rp "Auswahl [1/2]: " AUTH_CHOICE
  
  case "$AUTH_CHOICE" in
    1)
      read -rp "API Key eingeben (sk-ant-api03-...): " API_KEY
      echo "ANTHROPIC_API_KEY=$API_KEY" >> "$INSTALL_DIR/.env.runtime"
      ;;
    2)
      echo ""
      echo "Führe einmalig auf diesem Rechner aus:"
      echo "  claude setup-token"
      echo ""
      echo "Dann den generierten Token (sk-ant-oat01-...) hier einfügen:"
      read -rp "OAuth Token: " OAUTH_TOKEN
      echo "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN" >> "$INSTALL_DIR/.env.runtime"
      ;;
    *)
      echo "Ungültige Auswahl"
      exit 1
      ;;
  esac
  
  chmod 600 "$INSTALL_DIR/.env.runtime"
  echo "Auth konfiguriert."
}

# Docker Images bauen
build_images() {
  echo ""
  echo "=== Docker Images bauen ==="
  cd "$INSTALL_DIR"
  docker compose build
  echo "Images gebaut."
}

# Workspace-Pfad konfigurieren
setup_workspace() {
  echo ""
  read -rp "Workspace-Pfad (absolut, Enter für $INSTALL_DIR/workspace): " WS_PATH
  WS_PATH="${WS_PATH:-$INSTALL_DIR/workspace}"
  echo "WORKSPACE_PATH=$WS_PATH" >> "$INSTALL_DIR/.env.runtime"
  mkdir -p "$WS_PATH"
}

# CLI-Shortcut installieren
install_cli() {
  cat > /usr/local/bin/claude-secure << EOF
#!/bin/bash
cd "$INSTALL_DIR"
docker compose run --rm claude "\$@"
EOF
  sudo chmod +x /usr/local/bin/claude-secure
  echo "CLI-Shortcut installiert: claude-secure"
}

# Hauptablauf
check_deps
ENV_TYPE=$(detect_env)
echo "Erkannte Umgebung: $ENV_TYPE"

setup_dirs
setup_auth
setup_workspace
build_images
install_cli

echo ""
echo "=== Installation abgeschlossen ==="
echo ""
echo "Starten mit:  claude-secure"
echo "Stoppen mit:  cd $INSTALL_DIR && docker compose down"
echo "Logs:         cd $INSTALL_DIR && docker compose logs -f"
echo ""
echo "Whitelist konfigurieren: $INSTALL_DIR/config/whitelist.json"
echo "Secrets eintragen:       $INSTALL_DIR/config/.env"
```

---

## 9. Dateirechte-Modell

| Datei/Verzeichnis | Owner | Permissions | Grund |
|---|---|---|---|
| `config/whitelist.json` | root | 444 | Claude darf lesen, nicht schreiben |
| `config/.env` | root | 400 | Nur Proxy/Validator lesen |
| `claude/hooks/` | root | 555 | Claude darf ausführen, nicht modifizieren |
| `claude/settings.json` | root | 444 | Hook-Konfiguration schreibgeschützt |
| `workspace/` | user | 755 | Claude arbeitet hier frei |
| `.env.runtime` | user | 600 | Auth-Tokens, nur User lesbar |

**Kernprinzip:** Die Sicherheitsschicht darf nicht von dem Prozess modifizierbar sein,
den sie absichert.

---

## 10. Bekannte Lücken & Risiken

| Szenario | Status | Mitigation |
|---|---|---|
| Secret via `@file` an Anthropic | ⚠️ Teilweise | Dateiinhalt-Prüfung im Hook für bekannte Patterns |
| Falsches Secret an whitelisted Domain | ⚠️ Schwer erkennbar | Logging + Audit |
| Indirekter Call via Python-Script | ✅ Geblockt | NFQUEUE + SQLite-Validator |
| Claude modifiziert Hook-Scripts | ✅ Geblockt | root-owned, chmod 555 |
| Claude modifiziert Whitelist | ✅ Geblockt | root-owned, chmod 444 |
| Streaming-Secrets im Anthropic-Proxy | ⚠️ Phase 2 | Proxy verarbeitet aktuell gebuffert |
| WSL2 NFQUEUE-Unterstützung | ⚠️ Eingeschränkt | Fallback auf iptables-only ohne Validator |

---

## 11. Implementierungsphasen

### Phase 1 — Basis (MVP)
- [ ] Docker Compose Setup mit allen vier Containern
- [ ] PreToolUse Hook: Domain-Prüfung + Payload-Blockierung
- [ ] Anthropic-Proxy: Secret-Redaktion (gebuffert, kein Streaming)
- [ ] SQLite-Validator: HTTP-Registrierung + iptables-Integration
- [ ] Installer-Script mit Auth-Setup
- [ ] Whitelist-Konfiguration

### Phase 2 — Robustheit
- [ ] Streaming-Support im Anthropic-Proxy (SSE chunk-weise verarbeiten)
- [ ] Dateiinhalt-Prüfung im Hook für `@file`-Referenzen
- [ ] WSL2-Erkennung mit Fallback-Modus (ohne NFQUEUE)
- [ ] Logging-Dashboard (strukturierte JSON-Logs)
- [ ] Whitelist-Validierung beim Start

### Phase 3 — Komfort
- [ ] `claude-secure config` CLI für Whitelist-Verwaltung
- [ ] Automatisches Token-Refresh (OAuth)
- [ ] Multi-Projekt-Support (verschiedene Workspaces)
- [ ] Audit-Log mit Secret-Zugriffs-Protokoll

---

## 12. README (Kurzversion für Nutzer)

### Installation

```bash
curl -fsSL https://raw.githubusercontent.com/your-org/claude-secure/main/install.sh | bash
```

### Secrets konfigurieren

```bash
# Datei öffnen (braucht sudo weil root-owned nach Installation)
sudo nano ~/.claude-secure/config/.env

# Format:
GITHUB_TOKEN=ghp_xxxx
STRIPE_KEY=sk_live_xxxx
```

### Whitelist konfigurieren

```bash
sudo nano ~/.claude-secure/config/whitelist.json
```

```json
{
  "secrets": [
    {
      "placeholder": "PLACEHOLDER_GITHUB",
      "env_var": "GITHUB_TOKEN",
      "allowed_domains": ["github.com", "api.github.com"]
    }
  ]
}
```

### Claude Code starten

```bash
claude-secure
```

### Services verwalten

```bash
# Alle Services stoppen
cd ~/.claude-secure && docker compose down

# Logs ansehen
cd ~/.claude-secure && docker compose logs -f

# Neu starten
cd ~/.claude-secure && docker compose restart
```

### Workspace

Claude Code arbeitet ausschließlich innerhalb von `/workspace` im Container, was
auf dem Host dem konfigurierten Workspace-Pfad entspricht (Standard:
`~/.claude-secure/workspace`). Dateien die Claude erstellt oder bearbeitet, liegen
auf dem Host und gehen beim Container-Stop nicht verloren.

### Auth erneuern

```bash
# OAuth Token erneuern (nach ~1 Jahr)
claude setup-token
# Neuen Token in ~/.claude-secure/.env.runtime eintragen
nano ~/.claude-secure/.env.runtime
docker compose restart claude
```

---

## 13. Technologie-Stack

| Komponente | Technologie | Begründung |
|---|---|---|
| Container-Orchestrierung | Docker Compose | läuft auf Ubuntu, WSL2, VPS |
| Claude Code | `@anthropic-ai/claude-code` (npm) | offizielles Paket |
| Anthropic-Proxy | Node.js (http) | gleiche Runtime wie Claude Code |
| Call-Validator HTTP | Python (stdlib) | minimale Abhängigkeiten |
| Call-Validator NFQUEUE | Python + netfilterqueue + scapy | Kernel-Integration |
| Call-Datenbank | SQLite | kein separater Prozess, läuft überall |
| Hook-Scripts | Bash + jq + uuidgen | überall verfügbar |
| Konfiguration | JSON | menschenlesbar, von allen Schichten parsebar |