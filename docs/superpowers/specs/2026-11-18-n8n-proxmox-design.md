# n8n – Proxmox-Einzeiler-Installation (Design-Spec)

Datum: 2026-11-18
Status: Entwurf, vom Nutzer freigegeben (Ansatz A: Docker CE + Compose, SQLite, HTTP :5678)
Löst ab: `2026-11-17-localdash-proxmox-design.md` (LocalDash wird nicht weiterverfolgt)

## 1. Ziel und Kontext

Der Nutzer betreibt einen Proxmox-Host im Heimnetz. Ein Einzeiler im Stil der
Proxmox VE Community Scripts soll **n8n** (Workflow-Automation) als LXC-Container
oder VM installieren:

- n8n läuft als Docker-Container (offizielles Image) unter Docker Compose.
- Datenbank: SQLite (n8n-Default), Daten in einem Docker-Volume.
- UI: `http://<gast-ip>:5678`, kein TLS, kein Reverse Proxy.
- Autostart nach Reboot, idempotente Wiederholung, saubere Deinstallation.

Das Repo heißt `NodeN8N-Proxmox`, der Gast `NodN8N`. Das bisher installierte
LocalDash (FastAPI/React, Port 8080) wird vollständig entfernt.

## 2. Annahmen und Randbedingungen

- App: `n8n`, Container-Name `n8n`, Ablage `/opt/n8n`, Volume `n8n_data`.
- Gast-Name (LXC-Hostname und VM-Name): `NodN8N`; CT-/VM-ID = nächste freie ID
  via `pvesh get /cluster/nextid`, außer `CT_ID`/`--ctid` ist gesetzt.
- Standard-Ressourcen: **2 vCPU / 2048 MB RAM / 8 GB Disk** (LXC und VM).
- LXC: unprivilegiert, `nesting=1` **und `keyctl=1`** (Voraussetzung für Docker),
  `onboot=1`.
- Script läuft als root auf dem Proxmox-Host, nicht im Gast.
- Debian-12-Template `debian-12-standard` (LXC) bzw. Debian-12-Genericcloud (VM).
- Image-Referenz: `docker.n8n.io/n8nio/n8n` (Default-Tag `latest`, übersteuerbar
  mit `N8N_VERSION`).
- Zeitzone Default `Europe/Berlin`, übersteuerbar mit `TZ`.

## 3. Nicht-Ziele

- Kein TLS, kein Reverse Proxy, keine Domain, keine Authentifizierungs-Proxy-Schicht
  (n8n bringt eigene Benutzerverwaltung mit; Owner-Account entsteht beim ersten Aufruf).
- Keine Postgres-Datenbank (SQLite; Compose bleibt aber erweiterbar).
- Keine Steuerung oder Überwachung des Proxmox-Hosts.
- Kein Dashboard, keine Metriken-API, kein LocalDash-Code.
- Keine automatischen n8n-Upgrades im Hintergrund (nur `--update` auf Zuruf).

## 4. Architektur

```
Proxmox-Host
  └─ install/n8n.sh                       (outer: Checks, ID, Storage, Template,
  │                                        LXC/VM anlegen, DNS-Pins, Inner pushen,
  │                                        Health-Verifikation, Summary)
  └─ install/n8n-inner.sh                 (inner, im Gast: LocalDash-Cleanup, DNS,
  │                                        apt+Docker-Repo, Docker CE + Compose,
  │                                        /opt/n8n anlegen, .env, pull, up -d,
  │                                        Health-Wait, --uninstall/--update)
  └─ docker/docker-compose.yml            (Quelle, wird nach /opt/n8n kopiert)
        └─ Container n8n  (Image docker.n8n.io/n8nio/n8n)
             ├─ Port 5678 → Host
             ├─ Volume n8n_data → /home/node/.n8n (SQLite, Credentials, Keys)
             └─ restart: unless-stopped
```

VM-Modus: `--type vm` erzeugt eine VM aus dem Debian-Cloud-Image, cloud-init
installiert curl, lädt `n8n-inner.sh` (mit Cache-Buster) und führt sie aus.
LXC und VM teilen Inner-Installer und Verifikationslogik.

## 5. Komponenten

### 5.1 Outer-Installer (`install/n8n.sh`)

1. Host-Checks (`pveversion`, root, `pct`/`qm`, Storage, Bridge), Logdatei
   `/var/log/n8n-install-<zeitstempel>.log`, `trap ERR` mit Befehl/Zeile/Exit
   und Log-Auszug.
2. Host-DNS aus `/etc/resolv.conf` (ohne Loopback) → `DNS_SERVERS`.
3. DNS-Pins: pro Host 3 Versuche `getent ahostsv4`, danach bekannte
   Fallback-IPv4. Gepinnte Hosts: `deb.debian.org`, `security.debian.org`,
   `download.docker.com`, `docker.n8n.io`, `registry-1.docker.io`,
   `auth.docker.io`, `production.cloudflare.docker.com`, `github.com`,
   `raw.githubusercontent.com`.
4. Template sicherstellen (`pveam`), LXC mit `--features nesting=1,keyctl=1`
   anlegen und starten; bei bestehender ID nur aktualisieren.
5. Pin-Datei per `pct push` in den Gast, `sed -i '/# n8n-pins/d'` + append
   (Format `IP host`), `chmod 0644 /etc/hosts`.
6. Inner-Script host-seitig laden (`?cb=<epoch>`) und per `pct push` in den Gast,
   dann `pct exec … bash /tmp/n8n-inner.sh` mit `DNS_SERVERS`, `DNS_PINS`,
   `TZ`, `N8N_VERSION`.
7. Verifikation: `systemctl is-active docker`, `docker inspect -f
   '{{.State.Health.Status}}'`/`docker ps` und `curl -fs http://127.0.0.1:5678/healthz`.
8. Summary: UI-URL `http://<ip>:5678`, Update/Uninstall/Log-Befehle.

Optionen: `--ctid <id>`, `--type lxc|vm`, `--cores`, `--ram`, `--disk`,
`--bridge`, `--template-store`, `--uninstall`, `--update`, `--debug`.

### 5.2 Inner-Installer (`install/n8n-inner.sh`)

1. **Migration:** falls `localdash` vorhanden → `systemctl disable --now localdash`,
   Unit-Datei, `/opt/localdash`, `/var/lib/localdash` löschen, User `localdash`
   entfernen. Idempotent (Fehlen ist kein Fehler).
2. **DNS:** `fix_dns` (Nameserver aus `DNS_SERVERS`, Fallback-Reihenfolge,
   `options single-request-reopen timeout:2 attempts:2`), `apply_dns_pins`
   (`/etc/hosts`), `chmod 0644` für `/etc/hosts` und `/etc/resolv.conf`,
   `ForceIPv4` nur wenn `getent ahostsv4 deb.debian.org` erfolgreich ist.
3. **apt:** `ca-certificates curl gnupg openssl` mit Retry-Loop, Listen-Reset
   beim zweiten Versuch.
4. **Docker:** Keyring `/etc/apt/keyrings/docker.asc`, Repo
   `download.docker.com/linux/debian` (bookworm), Installation von
   `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.
   `/etc/docker/daemon.json` mit Log-Rotation (10m × 3) und `dns` = `DNS_SERVERS`.
   `systemctl enable --now docker`.
5. **Stack:** `/opt/n8n` (0755), Compose-Datei aus Repo (Fallback: inline),
   `/opt/n8n/.env` (0600) mit `N8N_ENCRYPTION_KEY` (einmalig, 64 Hex-Zeichen,
   bei Wiederholung unverändert übernommen), `N8N_HOST`/`WEBHOOK_URL` aus der
   Gast-IP, `GENERIC_TIMEZONE`/`TZ`, `N8N_IMAGE`.
6. **Start:** `docker compose pull` (5 Versuche), `docker compose up -d`.
7. **Health:** Schleife bis 120 s auf `http://127.0.0.1:5678/healthz`; bei
   Timeout `docker compose logs --tail=50` ausgeben und mit Exit 1 abbrechen.
8. **Modi:** `--update` (`pull` + `up -d`), `--uninstall`
   (`compose down -v`, `/opt/n8n` löschen, Image entfernen; Container bleibt).

### 5.3 Compose-Datei (`docker/docker-compose.yml`)

```yaml
services:
  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: "5678"
      N8N_PROTOCOL: http
      N8N_SECURE_COOKIE: "false"
      WEBHOOK_URL: ${WEBHOOK_URL}
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${TZ}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_RUNNERS_ENABLED: "true"
    volumes:
      - n8n_data:/home/node/.n8n
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
volumes:
  n8n_data:
```

Der Container läuft als Image-User `node`; das Volume bleibt damit unabhängig
von Host-UIDs. `/opt/n8n/.env` ist die einzige Quelle für Secrets.

### 5.4 Repo-Aufräumen

- Löschen: `app/`, `web/`, `systemd/localdash.service`.
- Ersetzen: `install/localdash*.sh` → `install/n8n*.sh`; README auf n8n umschreiben.
- Alte Spec/Plan bleiben als Historie, erhalten im Kopf den Hinweis
  „Abgelöst durch 2026-11-18-n8n-proxmox-design.md“.
- Neue Doku-Abschnitte im README: Einzeiler, Ressourcen, Update, Backup,
  Uninstall, „Encryption-Key sichern“.

## 6. Sicherheit und Betrieb

- `.env` 0600 root, enthält `N8N_ENCRYPTION_KEY`; ohne diesen Key sind
  gespeicherte Credentials nach einem Restore unbrauchbar → im README als
  Pflicht-Backup dokumentiert.
- Kein Port nach außen außer 5678 im LAN; keine Cloud-Dienste
  (`N8N_DIAGNOSTICS_ENABLED=false`).
- Log-Rotation auf Docker-Ebene (json-file 10m × 3).
- Backup: Tar des Volumes `n8n_n8n_data` plus `.env`; Restore dokumentiert.
- Update: `--update` bzw. `docker compose pull && docker compose up -d` in `/opt/n8n`.

## 7. Fehlerbehandlung

- `set -euo pipefail`, `trap ERR` in Outer und Inner mit Befehl, Zeile, Exitcode
  und Log-Auszug.
- Netzwerk/DNS: Pins + Retries (apt, pull, health) statt Einmalversuch;
  `ForceIPv4` nur bei vorhandenen A-Records, sonst IPv6-Fallback.
- Docker-Startprobleme im LXC: bei Fehlschlag werden `systemctl status docker`,
  `journalctl -u docker` und `docker info` (Storage-Treiber) ausgegeben;
  `vfs`-Fallback wird als Warnung geloggt.
- Bestehender Container/Stack: idempotent, kein Datenverlust (Volume bleibt bei
  erneutem Lauf erhalten; `--uninstall` löscht es nur explizit).

## 8. Tests

Mock-Harness (`tests/mock_proxmox.sh`) mit Stubs für `pct`, `qm`, `pvesh`,
`pvesm`, `pveam`, `curl`, `id`, `getent` (IPv4-los → Fallback-Pfad):

1. Einzeiler-Modus läuft durch und endet mit `INSTALLATION ERFOLGREICH`.
2. `pct create/set` enthält `nesting=1,keyctl=1` und Standardwerte 2/2048/8.
3. Pins für `deb.debian.org`, `download.docker.com`, `docker.n8n.io` im Log,
   Format `^IP host`, `chmod 0644 /etc/hosts` vorhanden.
4. Kein LocalDash-Payload mehr installiert (`uvicorn`, `npm run build`,
   `localdash.service` fehlen), aber Cleanup-Aufruf vorhanden.
5. Compose-Datei wird nach `/opt/n8n/docker-compose.yml` gepusht und enthält
   `n8n_data`, `5678:5678`, `restart: unless-stopped`.
6. Inner enthält `N8N_ENCRYPTION_KEY`-Erzeugung, `docker compose pull`,
   `docker compose up -d` und die `/healthz`-Warteschleife.
7. `bash -n` für alle Skripte, ShellCheck ohne Fehler.
8. Idempotenz: zweiter Lauf erzeugt keinen neuen CT und behält die `.env`.

## 9. Abnahmekriterien

- Frischer LXC (`CT_ID=110`-Fall) endet mit `INSTALLATION ERFOLGREICH` und
  `http://<ip>:5678/healthz` liefert HTTP 200.
- LocalDash ist danach restlos entfernt (kein Service, keine Verzeichnisse, kein User).
- `pct reboot 110 && sleep 60 && curl -fs http://<ip>:5678/healthz` erfolgreich
  (Docker-Autostart).
- `--update` und `--uninstall` laufen ohne manuelle Schritte.
- Repo enthält keinen LocalDash-App-Code mehr.
