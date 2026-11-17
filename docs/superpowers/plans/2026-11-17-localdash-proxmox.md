# LocalDash Proxmox Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein GitHub-first-Repo bauen, das LocalDash (FastAPI + React/Vite-Dashboard, Port 8080) per Einzeiler als LXC oder VM auf Proxmox installiert, boot-sicher macht und selbst verifiziert.

**Architecture:** FastAPI-Single-Prozess served die vorgebaute React-SPA direkt; der äußere Installer läuft auf dem Host, der innere im Container; beide Modi (LXC/VM) teilen sich den Inner-Installer und die Verifikation.

**Tech Stack:** Python 3.11, FastAPI, uvicorn, psutil, pytest/httpx; React 18, Vite 6, TypeScript; Bash (`set -euo pipefail`), systemd, Proxmox `pct`/`qm`/`pvesh`.

**Spec:** `docs/superpowers/specs/2026-11-17-localdash-proxmox-design.md`

## Global Constraints

- App-Name `LocalDash`, Hostname/Service/User `localdash`, Port `8080`, Bind `0.0.0.0`.
- Repo: `https://github.com/HatchetMan111/NodeN8N-Proxmox`, Default-Branch `main`.
- CT-ID immer nächste freie ID (`pvesh get /cluster/nextid`), außer `--ctid`.
- LXC: unprivilegiert, `nesting=1`, `onboot=1`, 1 vCPU/1024 MB/4 GB.
- VM: 2 vCPU/2048 MB/8 GB, `onboot=1`, Debian-Cloud-Image + cloud-init.
- Installer: `set -euo pipefail`, idempotent, `trap ERR` mit voller Kette, `--debug`=`bash -x`, Log `/var/log/localdash-install.log`.
- Keine externen Cloud-Dienste, kein Docker, kein Nginx zur Laufzeit.
- Keine Kommentare im Code (Projektstil), außer Header-Kommentaren in Shell-Skripten (Community-Scripts-Konvention).

## Review Focus

- Fehlende/nicht erreichbare `/api/*` → Frontend darf nicht blank bleiben: SPA-Fallback + Health-Check im Installer (Task 2, 8).
- `systemctl list-units` nicht verfügbar/timeout → `/api/services` gibt leere Liste statt 500 (Task 1).
- Container-IP nicht verfügbar nach DHCP → Installer bricht mit voller Fehlerkette ab (Task 6).
- Template nicht gefunden / Storage fehlt → Installer bricht mit verständlicher Meldung ab (Task 6).
- VM-Cloud-Image nicht erreichbar → klarer Fehler statt halb konfigurierter VM (Task 7).
- React-Build fehlt (`dist/index.html`) → Inner-Installer bricht ab statt Geister-Installation (Task 5).

---

### Task 1: Backend-Metriken und Service-Listing (TDD)

**Files:**
- Create: `app/localdash/__init__.py`, `app/localdash/metrics.py`, `app/localdash/services.py`
- Create: `app/requirements.txt`, `app/requirements-dev.txt`
- Test: `app/tests/test_metrics.py`, `app/tests/test_services.py`

**Interfaces:**
- Produces: `collect_metrics() -> dict` mit Keys `cpu_percent`, `memory_percent`, `memory_used_mb`, `memory_total_mb`, `disk_percent`, `disk_used_gb`, `disk_total_gb`, `uptime_seconds`, `load_1m`, `hostname`.
- Produces: `list_services() -> list[dict]` mit Keys `name`, `active`, `sub`.

Steps: pytest-Tests schreiben (Metriken keys/types, Service-Listing robust bei subprocess-Fehler via monkeypatch), rot sehen, `metrics.py` mit psutil implementieren, `services.py` mit `subprocess.run(["systemctl", ...], timeout=10, capture_output=True, text=True)` implementieren (Bei Fehler `[]`), grün sehen, `requirements*.txt` anlegen, `PYTHONPATH=app pytest app/tests -q`.

### Task 2: FastAPI-App mit Endpoints und SPA-Fallback (TDD)

**Files:**
- Create: `app/localdash/main.py`
- Test: `app/tests/test_main.py`

**Interfaces:**
- Consumes: `collect_metrics`, `list_services` aus Task 1.
- Produces: `app` (FastAPI-Instanz), `VERSION = "1.0.0"`, `STATIC_DIR` (Pfad `web/dist`, override via Env `LOCALDASH_STATIC_DIR`).

Steps: Tests mit `TestClient`: `/api/health` → `{"status":"ok","version":"1.0.0"}`; `/api/system` → 200 + Keys; `/api/services` → `{"services": []}` bei leerem Listing; `GET /` → `index.html` aus temporärem Static-Dir; unbekannter Pfad → SPA-Fallback. Implementierung: `FastAPI()`, drei Routes, `StaticFiles(directory=STATIC_DIR, html=True)` gemountet unter `/` am Ende, `GET /{full_path:path}` Fallback auf `index.html`, `FileResponse`. `pytest app/tests -q` grün.

### Task 3: React/Vite-Frontend

**Files:**
- Create: `web/package.json`, `web/package-lock.json`, `web/vite.config.ts`, `web/tsconfig.json`, `web/index.html`, `web/src/{main.tsx,App.tsx,api.ts,types.ts,styles.css}`, `web/src/components/{MetricCard.tsx,Sparkline.tsx,ServiceTable.tsx}`

**Interfaces:**
- Consumes: `/api/health`, `/api/system`, `/api/services` aus Task 2.
- Produces: `web/dist/index.html` + Assets nach `npm run build`.

Steps: `npm init`-Äquivalent als `package.json` (React 18.3.1, Vite 6.0.7, TS 5.7.2, @vitejs/plugin-react 4.3.4, vitest 2.1.8), `npm install` erzeugt lockfile, `vite.config.ts` mit `base:"/"`, `server.proxy` für Dev `/api` → `:8080`. `api.ts` mit `fetchJSON<T>(path)`. `App.tsx` mit 5s-Polling (`setInterval`), Metrik-Karten, SVG-Sparkline (History im State), Service-Tabelle. Dark-Theme-CSS ohne externe Libraries. `npm run build` muss `web/dist/index.html` erzeugen; `npm run test` (Vitest Smoke-Test für `api.ts` mit gemocktem fetch) grün.

### Task 4: systemd-Unit und Environment

**Files:**
- Create: `systemd/localdash.service`

Steps: Unit mit `After/Wants=network-online.target`, `Type=simple`, `User=localdash`, `WorkingDirectory=/opt/localdash/app`, `EnvironmentFile=/etc/localdash/config.env`, `ExecStart=/opt/localdash/venv/bin/uvicorn localdash.main:app --host 0.0.0.0 --port 8080 --proxy-headers`, `Restart=always`, `RestartSec=2`, Security-Härtung wie Spec. `systemd-analyze verify systemd/localdash.service` (falls verfügbar) bzw. Syntax-Check.

### Task 5: Inner-Installer (Container)

**Files:**
- Create: `install/localdash-inner.sh`

**Interfaces:**
- Consumes: `REPO_URL`, `APP`, `APP_PORT`, `APP_DIR=/opt/localdash` via Environment/Argumente.
- Produces: funktionierender systemd-Service `localdash`, `web/dist/index.html`.

Steps: `set -euo pipefail`, Variablen mit Defaults, `msg_*`-Helper, apt-Install, User/Verzeichnisse, Repo-Klon/Pull nach `/opt/localdash`, venv + pip, `npm ci && npm run build`, Guard `test -f web/dist/index.html`, Unit per curl von `REPO_URL/systemd/localdash.service` mit Inline-Fallback, `config.env` schreiben, `daemon-reload && enable --now`. `bash -n install/localdash-inner.sh`.

### Task 6: Outer-Installer LXC-Modus

**Files:**
- Create: `install/localdash.sh`

**Interfaces:**
- Consumes: `REPO_URL`, Defaults aus Spec.
- Produces: LXC `localdash`, Verifikation + URL-Ausgabe.

Steps: Header + Variablenblock, `set -euo pipefail`/`umask`, Logging (`tee`), `trap ERR` (Befehl, Zeile, Exit, `tail -n 80 LOG_FILE`), `trap EXIT` cleanup, Args (`--ctid`, `--hostname`, `--type`, `--cores`, `--memory`, `--disk`, `--bridge`, `--storage`, `--template-store`, `--password`, `--ssh-key`, `--debug`, `-h`), Host-Checks, Storage-Erkennung, Template-Download, `pct create` (idempotent), `pct start`, IP-Poll, Inner-Script via `pct push` + `pct exec`, Verifikation (`systemctl is-active`, `curl /api/health`), Final-Output, `bash -n`.

### Task 7: VM-Modus im Outer-Installer

**Files:**
- Modify: `install/localdash.sh`

Steps: `--type vm`: `qm create` mit `name=localdash`, `onboot=1`; Debian-12-cloud-image auf `local:` importieren, `qm set --ide2 …media=cdrom`, `--boot order=scsi0`, `--scsi0 …size=8G`, cloud-init `user-data` (YAML) schreibt `/etc/localdash-install.sh` (Inner-Script per curl) und führt es aus; `qm start`; Verifikation via `qm guest exec` (falls verfügbar) oder Hinweis auf IP via `qm guest cmd network-get-interfaces`. Fehlerpfad: Image-Download-Fehler → volle Kette, keine halbe VM. `bash -n`.

### Task 8: Mock-Proxmox-Harness, README, Gesamtverifikation

**Files:**
- Create: `tests/mock_proxmox.sh`, `README.md`, `.gitignore`

Steps: `tests/mock_proxmox.sh` legt temp-bin mit Stubs für `pct/pvesh/pveam/pvesm/qm` an (simulieren: nextid, status, create, start, exec, push, reboot), setzt PATH, ruft `install/localdash.sh --ctid 900 --debug`, prüft Log auf `INSTALLATION ERFOLGREICH`, simuliert Reboot und erneuten Health-Check. README mit Einzeiler, Flags, Tabellen, Update/Deinstall, Reboot-Test, Debugging. Final: `bash -n install/*.sh tests/*.sh`, `PYTHONPATH=app pytest app/tests -q`, `cd web && npm run build && npm run test`, `bash tests/mock_proxmox.sh`. Alle Logs ausgeben.

## Self-Review

- Spec §2–§10 durch Tasks 1–8 abgedeckt; keine Lücke.
- Keine Platzhalter/TBD im Plan.
- Typen konsistent: `collect_metrics`/`list_services` (T1) → `main.py` (T2) → `api.ts` (T3).
- Review-Focus-Punkte haben Tests/Guards in T1, T2, T5, T6, T7, T8.
