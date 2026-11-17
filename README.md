# LocalDash auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

**LocalDash** ist ein vollständig lokales System- und Service-Dashboard: CPU, RAM,
Festplatte, Uptime, Load und die systemd-Dienste im Container. Backend: Python/FastAPI,
Frontend: React 18 + Vite + TypeScript. Keine Cloud-Dienste, kein Docker, kein Nginx.

> Repo: `https://github.com/HatchetMan111/NodeN8N-Proxmox` (Branch `main`).
> Der Einzeiler lädt Installer, Inner-Script und systemd-Unit direkt von dort.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/localdash.sh)"
```

Standardmäßig wird die **nächste freie ID** verwendet und der Container/VM heißt
`NodN8N` (1 vCPU / 1024 MB RAM / 4 GB Disk, unprivilegiert, `onboot=1`).
Der systemd-Service und das Web-UI bleiben `localdash` / Port `8080`.

### Optionen

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/localdash.sh)"

bash localdash.sh --ctid 150 --hostname NodN8N --cores 2 --memory 2048 --disk 8 \
  --bridge vmbr0 --storage local-lvm

bash localdash.sh --type vm --ctid 151          # VM statt LXC (2 vCPU / 2 GB / 8 GB)
bash localdash.sh --debug                       # bash -x + komplette Fehlerkette
bash localdash.sh --help
```

| Option | Bedeutung | Default |
|---|---|---|
| `--ctid ID` | Container-/VM-ID | nächste freie ID (`pvesh get /cluster/nextid`) |
| `--hostname NAME` | Hostname / VM-Name | `NodN8N` |
| `--type lxc\|vm` | LXC oder VM (cloud-init) | `lxc` |
| `--cores`, `--memory`, `--disk` | Ressourcen | LXC 1/1024/4, VM 2/2048/8 |
| `--storage`, `--template-store`, `--bridge` | Proxmox-Ziele | auto / `local` / `vmbr0` |
| `--password`, `--ssh-key` | Zugang zum Gast | zufällig / keiner |
| `--debug` | `bash -x`, volle Fehlerkette | aus |

Umgebungsvariablen: `CT_ID`, `CORES`, `RAM`, `DISK`, `DEBUG=1`.

## Was das Script macht

1. Prüft Host/Tools (`pct`, `qm`, `pvesh`, `pvesm`, `pveam`), nimmt die nächste freie ID.
2. Erkennt RootFS-Storage (`local-lvm` bevorzugt), lädt das neueste
   `debian-12-standard`-Template (oder das Debian-Cloud-Image für VM-Modus).
3. Erstellt den Gast `NodN8N` mit `onboot=1`; vorhandene IDs werden aktualisiert
   (**idempotent**, kein Neuaufbau).
4. Installiert im Gast Python/venv + Node/npm, klont das Repo, baut die React-UI,
   schreibt `systemd/localdash.service` und startet `systemctl enable --now localdash`.
5. Verifiziert `systemctl is-active localdash` und `GET /api/health` auf
   `localhost:8080`; gibt am Ende `http://<IP>:8080` aus.

## Dateien

| Pfad | Zweck |
|---|---|
| `install/localdash.sh` | Outer-Installer (Host, Community-Scripts-Stil, LXC + VM) |
| `install/localdash-inner.sh` | Inner-Installer (Gast: Pakete, Build, systemd) |
| `systemd/localdash.service` | Service-Unit (`Restart=always`, `After=network-online.target`) |
| `app/localdash/` | FastAPI-App: `/api/health`, `/api/system`, `/api/services`, SPA-Fallback |
| `web/` | React/Vite/TypeScript-Dashboard (5s-Polling, SVG-Sparklines) |
| `tests/mock_proxmox.sh` | Offline-Test mit gemockten `pct`/`qm`/`pvesh`/`pveam` |

## Nach der Installation

```text
[OK]    Service läuft (systemctl is-active localdash = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8080/api/health).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : LocalDash – lokales System-/Service-Dashboard
  Typ          : LXC (ID 100, Name NodN8N, onboot=1)
  Ressourcen   : 1 vCPU / 1024 MB RAM / 4 GB Disk
  Web UI       : http://192.168.1.100:8080
  Health       : http://192.168.1.100:8080/api/health
  ...
  Log          : /var/log/localdash-install-2026-....log
══════════════════════════════════════════════════════════
```

## API

| Endpoint | Antwort |
|---|---|
| `GET /api/health` | `{"status":"ok","version":"1.0.0"}` |
| `GET /api/system` | CPU/RAM/Disk/Uptime/Load/Hostname |
| `GET /api/services` | `{"services":[{"name":…,"active":…,"sub":…}]}` |

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot "$CT"
sleep 60
pct exec "$CT" -- systemctl is-active localdash
curl -fs "http://<LXC-IP>:8080/api/health" && echo WEB_UI_OK
```

Erwartung: `active` und `{"status":"ok",…}` – der Service startet automatisch
(`systemctl enable`, `Restart=always`, `After=network-online.target`), der Container
bootet mit (`onboot: 1`).

## Update / Deinstall

```bash
bash localdash.sh --ctid 100            # Update (idempotent: git reset, pip, npm build, restart)
pct stop 100 && pct destroy 100         # Deinstall LXC
qm stop 100 && qm destroy 100           # Deinstall VM
```

## Debugging

- Jeder Fehler liefert **Befehl + Zeile + Exit-Code + Log-Auszug + Journal**, nie nur die letzte Zeile.
- Voll-Log: `/var/log/localdash-install-<zeit>.log` (inneres Log: `/var/log/localdash-install-inner.log`).
- `bash localdash.sh --debug` aktiviert `bash -x`.
- Im Gast: `pct exec 100 -- journalctl -u localdash -n 100 --no-pager`.

## Lokale Entwicklung / Tests

```bash
python3 -m venv .venv
.venv/bin/pip install -r app/requirements-dev.txt
PYTHONPATH=app .venv/bin/python -m pytest app/tests -q

cd web && npm ci && npm run build && npm run test

bash -n install/*.sh tests/*.sh
bash tests/mock_proxmox.sh
```

## VM-Modus – Voraussetzungen

- `--type vm` benötigt `qm`, einen Storage mit `rootdir` und **`snippets`** auf
  `local` (Standard bei Proxmox). Bei abweichendem Storage: `--template-store <name>`.
- cloud-init installiert `curl`, lädt das Inner-Script und aktiviert den
  `qemu-guest-agent`; die Verifikation läuft über `qm guest exec`.
- Das Debian-Cloud-Image wird einmalig nach `/var/lib/vz/images/` geladen.
