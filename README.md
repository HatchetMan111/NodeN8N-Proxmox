# NodeN8N – n8n für Proxmox (Einzeiler)

Installiert **n8n** (Workflow-Automation) als LXC-Container oder VM auf Proxmox VE –
Docker Compose, SQLite, Web-UI auf Port **5678**. Keine Cloud-Dienste, keine
Telemetrie (`N8N_DIAGNOSTICS_ENABLED=false`), kein Reverse Proxy.

> Repo: `https://github.com/HatchetMan111/NodeN8N-Proxmox` (Branch `main`).
> Der Einzeiler lädt Outer- und Inner-Installer sowie die Compose-Datei direkt von dort.

## Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/n8n.sh)"
```

Standardmäßig wird die **nächste freie ID** verwendet und der Gast heißt `NodN8N`
(2 vCPU / 2048 MB RAM / 8 GB Disk, unprivilegiert, `nesting=1,keyctl=1`, `onboot=1`).

Bestehenden Container aktualisieren (z. B. ID 110):

```bash
CT_ID=110 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/n8n.sh)"
```

### Optionen

```bash
bash n8n.sh --ctid 150 --hostname NodN8N --cores 2 --memory 2048 --disk 8 \
  --bridge vmbr0 --storage local-lvm

bash n8n.sh --type vm --ctid 151    # VM statt LXC (cloud-init)
bash n8n.sh --ctid 150 --update     # n8n-Image im bestehenden Gast aktualisieren
bash n8n.sh --ctid 150 --uninstall  # n8n-Stack im Gast entfernen (Docker bleibt)
bash n8n.sh --debug                 # bash -x + komplette Fehlerkette
bash n8n.sh --help
```

| Option | Bedeutung | Default |
|---|---|---|
| `--ctid ID` | Container-/VM-ID | nächste freie ID (`pvesh get /cluster/nextid`) |
| `--hostname NAME` | Hostname / VM-Name | `NodN8N` |
| `--type lxc\|vm` | LXC oder VM (cloud-init) | `lxc` |
| `--cores`, `--memory`, `--disk` | Ressourcen | 2 / 2048 MB / 8 GB |
| `--storage`, `--template-store`, `--bridge` | Proxmox-Ziele | auto / `local` / `vmbr0` |
| `--password`, `--ssh-key` | Zugang zum Gast | zufällig (Datei unter `/root/`) / keiner |
| `--update` | `docker compose pull && up -d` im Gast | – |
| `--uninstall` | Container + Volume + `/opt/n8n` löschen | – |
| `--debug` | `bash -x`, volle Fehlerkette | aus |

Umgebungsvariablen: `CT_ID`, `CORES`, `RAM`, `DISK`, `TZ` (Default `Europe/Berlin`),
`N8N_VERSION` (Default `latest`), `DEBUG=1`.

## Was das Script macht

1. Prüft Host/Tools (`pct`, `qm`, `pvesh`, `pvesm`, `pveam`), nimmt die nächste freie ID.
2. Löst die Download-Hosts (Debian, Docker, n8n-Registry) auf dem **Proxmox-Host** auf
   und pinnt sie per `pct push` in die `/etc/hosts` des Gastes – der Gast hängt damit
   nicht an flakigem DNS. Fallback-IPs sind eingebaut.
3. Lädt das neueste `debian-12-standard`-Template (bzw. Debian-Cloud-Image für VMs)
   und erstellt den Gast `NodN8N`; **vorhandene IDs werden aktualisiert, nicht neu gebaut**.
4. Der Inner-Installer im Gast: entfernt evtl. vorhandenes **LocalDash** restlos
   (Service, Verzeichnisse, User), richtet Docker CE + Compose ein und startet den
   n8n-Stack unter `/opt/n8n` (Volume `n8n_data` für SQLite, Credentials, Keys).
5. Verifiziert `systemctl is-active docker` und `GET /healthz` auf Port 5678 und
   gibt am Ende `http://<IP>:5678` aus.

## Nach der Installation

- **UI:** `http://<gast-ip>:5678` – beim ersten Aufruf den **Owner-Account anlegen**
  (n8n bringt eigene Benutzerverwaltung mit).
- **Stack:** `/opt/n8n/docker-compose.yml`, `/opt/n8n/.env` (0600, enthält den Encryption-Key).
- **Dienst:** Docker-Container `n8n` mit `restart: unless-stopped` – startet nach
  Reboot automatisch (`onboot=1` + Docker-Autostart).
- **Logs des Stacks:** `pct exec <ID> -- bash -c 'cd /opt/n8n && docker compose logs -n 50'`.

### Wichtig: Encryption-Key sichern

`N8N_ENCRYPTION_KEY` in `/opt/n8n/.env` verschlüsselt alle gespeicherten
Credentials. **Ohne diesen Key sind Backups wertlos** – `.env` immer mitsichern.
Der Key wird einmalig erzeugt und bei jedem weiteren Lauf unverändert übernommen.

## Backup / Restore

```bash
CT=110   # im Gast ausführen (pct exec $CT -- bash -c '...')
docker run --rm -v n8n_n8n_data:/data -v /root:/backup alpine \
  tar czf /backup/n8n-data-$(date +%F).tar.gz -C /data .
cp /opt/n8n/.env /root/n8n-env-$(date +%F).bak
```

Restore: Volume `n8n_n8n_data` neu befüllen, `.env` nach `/opt/n8n/.env`
zurückkopieren, `docker compose up -d` in `/opt/n8n`.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=110
pct reboot "$CT"
sleep 60
pct exec "$CT" -- systemctl is-active docker
curl -fs "http://<LXC-IP>:5678/healthz" && echo WEB_UI_OK
```

Erwartung: `active` und `{"status":"ok"}`.

## Debugging

- Jeder Fehler liefert **Befehl + Zeile + Exit-Code + Log-Auszug + Docker-Status**,
  nie nur die letzte Zeile.
- Voll-Log Host: `/var/log/n8n-install-<zeit>.log` (Inner: `/var/log/n8n-install-inner.log`).
- `bash n8n.sh --debug` aktiviert `bash -x`.
- Im Gast: `pct exec 110 -- journalctl -u docker -n 100 --no-pager`.

## Migration von LocalDash

Ein Gast, in dem noch LocalDash (Port 8080) läuft, wird beim nächsten Lauf des
Installers automatisch bereinigt: systemd-Unit, `/opt/localdash`, `/var/lib/localdash`
und der User `localdash` werden entfernt – n8n-Daten (Volume) bleiben unangetastet.
Die LocalDash-App-Codes sind aus diesem Repo entfernt; alte Specs/Pläne stehen unter
`docs/superpowers/` als Historie (markiert als abgelöst).

## Voraussetzungen

- Proxmox VE 8.x, Root auf dem Host, Internetzugang.
- Debian-12-Template (`pveam`) für LXC bzw. Debian-12-Cloud-Image für VMs.
- LXC läuft unprivilegiert mit `nesting=1,keyctl=1` (Docker-Voraussetzung).

## Lokale Entwicklung / Tests

```bash
bash tests/validate_compose.sh     # statischer Compose-Check
bash -n install/*.sh tests/*.sh    # Syntax
shellcheck -S warning install/*.sh tests/*.sh
bash tests/mock_proxmox.sh         # Offline-Test mit gemockten pct/qm/pvesh/pveam
```

Der Mock-Harness deckt ab: Einzeiler-Lauf (LXC), Idempotenz (zweiter Lauf ohne
`pct create`), Reboot-Simulation, VM-Smoke, DNS-Pin-Format, keyctl=1, Docker-Setup,
LocalDash-Cleanup, Encryption-Key-Idempotenz und Update/Uninstall-Modi.
