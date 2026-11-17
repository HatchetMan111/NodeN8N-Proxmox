# LocalDash – Proxmox-Einzeiler-Installation (Design-Spec)

Datum: 2026-11-17
Status: Entwurf, vom Nutzer freigegeben (Ansatz A, LXC + VM)

## 1. Ziel und Kontext

Der Nutzer möchte eine vollständig lokale Anwendung, die auf einem Proxmox-Host
mit einem Einzeiler im Stil der Proxmox VE Community Scripts installiert wird.
Die Anwendung heißt **LocalDash** und ist ein lokales System-/Service-Dashboard
(CPU, RAM, Disk, Uptime, systemd-Dienste im Container). Es werden keine
externen Cloud-Dienste benötigt.

Deliverables: Install-Script, App-Code inkl. Web-UI, systemd-Unit, README mit
Einzeiler sowie ein testbarer Verifikationsdurchlauf.

## 2. Annahmen und Randbedingungen

- App-Name: `LocalDash` (Anzeige), `localdash` (Hostname, Service, User, DB-/Datenpfade).
- Zweck: System-/Service-Dashboard (aus der Beispielauswahl des Nutzers abgeleitet).
- Backend: Python/FastAPI, Frontend: React 18 + Vite + TypeScript.
- Web-UI-Port: `8080`, Bind `0.0.0.0`.
- GitHub-Repo: `https://github.com/HatchetMan111/NodeN8N-Proxmox` (Branch `main`).
- Standard-Ressourcen: LXC 1 vCPU / 1024 MB RAM / 4 GB Disk; VM 2 vCPU / 2048 MB RAM / 8 GB Disk.
- CT-/VM-ID: immer die nächste freie ID (`pvesh get /cluster/nextid`), außer explizit gesetzt.
- Namensgebung: LXC-Hostname und VM-Name `localdash`.
- LXC: unprivilegiert (`--unprivileged 1`), `nesting=1`, `onboot=1`.
- Script läuft auf dem Proxmox-Host als root, nicht im Container.

## 3. Nicht-Ziele

- Keine Authentifizierung / kein Login (lokales Dashboard im vertrauten Netz).
- Keine Datenbank, keine Persistenz außer Logs.
- Kein Docker, kein Nginx, kein separater Node-Prozess zur Laufzeit.
- Keine Steuerung von Host-Diensten; `/api/services` zeigt nur Dienste im Container.

## 4. Architektur (Ansatz A)

```
Proxmox-Host
  └─ install/localdash.sh        (outer: host checks, ID, storage, template, create LXC/VM, push inner, verify)
       └─ install/localdash-inner.sh  (inner: apt, user, venv, pip, node/npm build, systemd unit, start)
            └─ systemd/localdash.service
                 └─ uvicorn app.localdash.main:app --host 0.0.0.0 --port 8080
                      ├─ /api/health, /api/system, /api/services
                      └─ statisch: web/dist (React SPA, SPA-Fallback auf index.html)
```

VM-Modus: `--type vm` erzeugt eine VM via `qm create` aus einem Debian-Cloud-Image,
cloud-init (`user-data`) installiert curl + ruft `localdash-inner.sh` ab und führt sie aus.
Beide Modi teilen sich den Inner-Installer und die Verifikationslogik.

## 5. Komponenten

### 5.1 Backend (`app/localdash/`)

- `main.py`: FastAPI-App, CORS nicht nötig (gleiche Origin), StaticFiles-Mount am Ende,
  SPA-Fallback `GET /{full_path:path}` → `web/dist/index.html`.
- `metrics.py`: `psutil`-basierte Metriken (CPU %, RAM, Disk `/`, Uptime, Load, Hostname).
- `services.py`: `systemctl list-units --type=service --all --no-pager --plain` →
  Name, Active, Sub; gegen Fehler robust (Timeout, leere Liste).
- Endpoints:
  - `GET /api/health` → `{"status":"ok","version":"1.0.0"}`
  - `GET /api/system` → Metrikenobjekt
  - `GET /api/services` → `{"services":[...]}`

### 5.2 Frontend (`web/`)

- React 18 + Vite 6 + TypeScript, `package-lock.json` commitet.
- Dashboard: Kopfzeile, Metrik-Karten (CPU/RAM/Disk/Uptime), SVG-Sparklines,
  Service-Tabelle, 5-Sekunden-Polling, Statusanzeige.
- `vite.config.ts`: `base: './'` oder `/` (Auslieferung durch FastAPI unter `/`).
- Build im Container: `npm ci --no-audit --no-fund && npm run build` → `web/dist/index.html`.

### 5.3 Installer (`install/localdash.sh`, `install/localdash-inner.sh`)

Outer-Script:
- Variablenblock oben: `APP`, `APP_PORT`, `REPO_URL`, Defaults, Pfade, Template, Features.
- `set -euo pipefail`, `umask 077`, `trap ERR` (Befehl, Zeile, Exit-Code, Log-Auszug),
  `trap EXIT` (cleanup temp files), `--debug` → `set -x`.
- Argumente: `--ctid`, `--hostname`, `--type lxc|vm`, `--cores`, `--memory`, `--disk`,
  `--bridge`, `--storage`, `--template-store`, `--password`, `--ssh-key`, `--debug`, `-h`.
- Umgebungs-Overrides: `CT_ID`, `CORES`, `RAM`, `DISK`.
- Host-Checks: root, `pct`/`pvesh`/`pvesm`/`pveam`/`qm` vorhanden.
- Storage: `local-lvm` bevorzugt, sonst erstes `rootdir`.
- Template: neuestes `debian-12-standard` (`.tar.zst|.tar.xz|.tar.gz`), Download falls nötig.
- Idempotenz: vorhandene ID → Update-Modus, keine Neuerstellung; Inner-Script erneut laufen.
- LXC: `pct create … --hostname localdash --cores --memory --swap --rootfs --net0
  name=eth0,bridge=…,ip=dhcp --unprivileged 1 --features nesting=1 --onboot 1 --start 0 --password …`.
- VM: `qm create … --name localdash --cores --memory --net0 virtio,bridge=… --onboot 1`,
  Cloud-Image import, cloud-init user-data ruft Inner-Script per curl ab; `qm start`.
- Inner-Script-Push: `pct push` (LXC) bzw. cloud-init (VM).
- Verifikation nach Installation (siehe §7).

Inner-Script:
- `set -euo pipefail`, `DEBIAN_FRONTEND=noninteractive`.
- apt: `python3 python3-venv python3-pip nodejs npm curl ca-certificates git`.
- User `localdash`, Verzeichnisse `/opt/localdash`, `/var/lib/localdash`.
- Repo-Klon (GitHub-first, `REPO_URL`), `pip install -r requirements.txt` in venv.
- `npm ci && npm run build` in `web/`, Guard: `web/dist/index.html` muss existieren.
- systemd-Unit aus `REPO_URL` laden (Fallback Inline-Unit mit `pct push /dev/stdin`).
- `systemctl daemon-reload && systemctl enable --now localdash`.

### 5.4 systemd-Unit (`systemd/localdash.service`)

`After=network-online.target`, `Wants=network-online.target`, `Type=simple`,
`User/Group=localdash`, `WorkingDirectory=/opt/localdash/app`, `EnvironmentFile=
/etc/localdash/config.env`, `ExecStart=/opt/localdash/venv/bin/uvicorn localdash.main:app
--host 0.0.0.0 --port 8080 --proxy-headers`, `Restart=always`, `RestartSec=2`,
`TimeoutStopSec=20`, `UMask=0027`, `NoNewPrivileges=true`, `PrivateTmp=true`,
`ProtectSystem=strict`, `ProtectHome=true`, `StateDirectory=localdash`,
`ReadWritePaths=/var/lib/localdash`, `WantedBy=multi-user.target`.

## 6. Datenfluss

Browser → `http://<IP>:8080` → uvicorn → React-`dist` (statisch) → `fetch('/api/...')`
→ FastAPI → psutil / systemctl (subshell im Container). Keine externen Requests.

## 7. Fehlerbehandlung und Logging

- Jeder Fehler: vollständige Kette (Befehl, Zeile, Exit-Code, relevanter Log-Auszug,
  `systemctl status`, `journalctl -u localdash -n 100`), nie nur die letzte Zeile.
- Voll-Log `/var/log/localdash-install.log`; `--debug` aktiviert `bash -x`.
- Guard-Checks nach kritischen Schritten (Checkout, Build, Unit) verhindern
  Geister-Installationen.
- Bei Fehlern Hinweis: erneut mit `--debug` laufen lassen.

## 8. Verifikation

Im Installer:
1. `pct exec <id> -- systemctl is-active localdash` = `active`.
2. `pct exec <id> -- curl -fs http://localhost:8080/api/health` → HTTP 200.
3. Ausgabe:finale URL `http://<CT-IP>:8080`, Container-IP, Ressourcen, Log-Pfad,
   Update-/Deinstall-/Reboot-Befehle.

Im Repo (hier ausführbar):
- `bash -n install/*.sh`
- `pytest app/tests -q` (TestClient gegen `/api/health`, `/api/system`, `/api/services`,
  Static-Fallback)
- `cd web && npm ci && npm run build`
- `tests/mock_proxmox.sh`: stubbt `pct`, `pvesh`, `pveam`, `pvesm`, `qm` in einem
  temporären PATH, führt den Outer-Installer offline durch und protokolliert
  Install → simulierten Reboot → erneuten `/api/health`-Check.

Auf echtem Proxmox-Host (Anleitung in README):
`pct reboot <id>`, `sleep 60`, `systemctl is-active localdash`, `curl http://<IP>:8080/api/health`.

## 9. Repo-Struktur

```
localdash-proxmox/
├── app/
│   ├── localdash/{__init__.py,main.py,metrics.py,services.py}
│   ├── tests/{test_health.py,test_system.py,test_services.py}
│   ├── requirements.txt
│   └── requirements-dev.txt
├── web/
│   ├── index.html
│   ├── package.json
│   ├── package-lock.json
│   ├── vite.config.ts
│   ├── tsconfig.json
│   └── src/{main.tsx,App.tsx,api.ts,types.ts,styles.css,components/…}
├── install/{localdash.sh,localdash-inner.sh}
├── systemd/localdash.service
├── tests/mock_proxmox.sh
├── README.md
└── .gitignore
```

## 10. Einzeiler

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/localdash.sh)"
```

Das Repo ist als `REPO_URL` im Variablenblock aller Skripte hinterlegt.

## 11. Selbstreview

- Keine TBD/TODO-Platzhalter im Spec.
- Architektur konsistent mit Endpoints, Installer und systemd-Unit.
- Scope: ein Dashboard, ein Installer, eine UI – in einem Plan umsetzbar.
- Ambiguitäten aufgelöst: VM via cloud-init, Dienste nur im Container,
  kein Login, kein Nginx.
