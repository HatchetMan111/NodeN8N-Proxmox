#!/usr/bin/env bash
#
# n8n.sh - Proxmox VE Einzeiler-Installer für n8n
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/n8n.sh)"
#
# Läuft AUF DEM PROXMOX-HOST (root). Erstellt einen LXC (Standard) oder eine VM
# (--type vm), installiert n8n (Docker Compose, SQLite) darin und verifiziert
# Docker + Web-UI (Port 5678).
#
set -euo pipefail
umask 077

APP="n8n"
APP_DISPLAY="n8n"
GUEST_NAME="NodN8N"
APP_PORT="5678"
REPO_URL="https://github.com/HatchetMan111/NodeN8N-Proxmox"
REPO_REF="main"

DEFAULT_CORES="2"
DEFAULT_RAM="2048"
DEFAULT_SWAP="512"
DEFAULT_DISK="8"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"
DEFAULT_OS="debian-12-standard"
VM_CORES="2"
VM_RAM="2048"
VM_DISK="8"
VM_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
SNIPPET_STORAGE="local"

RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}"
INNER_URL="${RAW_BASE}/${REPO_REF}/install/${APP}-inner.sh"

HOST_DNS="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null \
  | awk '$1 !~ /^(127\.|::1|0\.0\.0\.0)/ && !seen[$0]++' \
  | head -n 3 | tr '\n' ' ' | sed 's/ $//' || true)"

# HOST_PINS wird nach den msg_*-Helfern ermittelt (siehe unten).

CT_ID="${CT_ID:-${CTID:-}}"
CORES="${CORES:-$DEFAULT_CORES}"
RAM="${RAM:-$DEFAULT_RAM}"
DISK="${DISK:-$DEFAULT_DISK}"
TYPE="lxc"
HOSTNAME_ARG="$GUEST_NAME"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG=""
SSH_KEY_ARG=""
DEBUG="${DEBUG:-0}"
N8N_VERSION="${N8N_VERSION:-latest}"
TZ_VALUE="${TZ:-Europe/Berlin}"
FORWARD_ARGS=""
EXISTING=0
CREATED=0
INNER_TMP=""
CT_IP=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; msg_error "Abbruch in Zeile ${LINENO}: ${BASH_COMMAND}"; exit 1; }

LOG_DIR="/var/log"
[[ -w "$LOG_DIR" ]] || LOG_DIR="/tmp"
LOG_FILE="${LOG_DIR}/${APP}-install-$(date +%F-%H%M%S).log"
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: ${LOG_FILE}"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Download-Hosts auf dem Proxmox-Host auflösen und im Gast in /etc/hosts pinnen –
# der Gast ist dann für apt/Docker unabhängig von seinem (ggf. flakigen)
# DNS-Proxy. Manche Heim-Router/DNS-Filter liefern nur AAAA (kein IPv4); daher
# Retry und bekannte Fallback-Adressen, damit apt/Docker planbar laufen.
PIN_HOSTS="deb.debian.org security.debian.org download.docker.com docker.n8n.io registry-1.docker.io auth.docker.io production.cloudflare.docker.com github.com raw.githubusercontent.com"
declare -A PIN_FALLBACK=(
  [deb.debian.org]="151.101.2.132"
  [security.debian.org]="151.101.130.132"
  [download.docker.com]="18.238.17.76"
  [docker.n8n.io]="104.18.42.44"
  [registry-1.docker.io]="44.208.254.194"
  [auth.docker.io]="44.208.254.194"
  [production.cloudflare.docker.com]="104.18.42.44"
  [github.com]="140.82.121.3"
  [raw.githubusercontent.com]="185.199.108.133"
)
HOST_PINS=""
HOST_PINS_SOURCE="DNS"
for _h in $PIN_HOSTS; do
  _ip=""
  for _try in 1 2 3; do
    _ip="$(getent ahostsv4 "$_h" 2>/dev/null | awk 'NR==1{print $1}')" || true
    [[ -n "$_ip" ]] && break
    sleep 1
  done
  if [[ -z "$_ip" ]]; then
    _ip="${PIN_FALLBACK[$_h]:-}"
    [[ -n "$_ip" ]] && HOST_PINS_SOURCE="Fallback"
  fi
  [[ -n "$_ip" ]] && HOST_PINS+="${_h}=${_ip} "
done
HOST_PINS="${HOST_PINS% }"
msg_info "DNS-Pins (${HOST_PINS_SOURCE}): ${HOST_PINS:-keine}"

on_error() {
  local ec=$?
  trap - ERR
  set +e
  msg_error "════ INSTALLER FEHLGESCHLAGEN ════"
  msg_error "Befehl : ${BASH_COMMAND}"
  msg_error "Zeile  : ${LINENO}"
  msg_error "Exit   : ${ec}"
  msg_error "Log-Auszug (letzte 80 Zeilen von ${LOG_FILE}):"
  tail -n 80 "$LOG_FILE" >&2 2>/dev/null || true
  if [[ -n "${CT_ID:-}" ]]; then
    if [[ "${TYPE:-lxc}" == "lxc" ]] && command -v pct >/dev/null 2>&1; then
      msg_error "Container-Status:"
      pct status "$CT_ID" 2>&1 || true
      msg_error "Docker-Status im Gast:"
      pct exec "$CT_ID" -- sh -c 'systemctl is-active docker; docker ps -a 2>&1 | head -n 10; journalctl -u docker --no-pager -n 50' 2>&1 || true
    elif command -v qm >/dev/null 2>&1; then
      msg_error "VM-Status:"
      qm status "$CT_ID" 2>&1 || true
    fi
  fi
  msg_error "Vollständiges Log: ${LOG_FILE}"
  msg_error "Erneut mit --debug laufen lassen für bash -x (komplette Kette)."
  exit "$ec"
}
trap on_error ERR

cleanup() {
  if [[ -n "${INNER_TMP:-}" && -f "${INNER_TMP:-}" ]]; then
    rm -f "$INNER_TMP"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
${APP_DISPLAY} Proxmox Installer (Community-Scripts-Stil)

Installiert n8n (Workflow-Automation) als LXC oder VM – Docker Compose,
SQLite, Web-UI auf Port ${APP_PORT}.

Usage:
  bash -c "\$(wget -qLO - ${RAW_BASE}/${REPO_REF}/install/${APP}.sh)"
  bash ${APP}.sh [OPTIONEN]

Optionen:
  --ctid ID          ID (Default: nächste freie ID via pvesh /cluster/nextid)
  --hostname NAME    Hostname/VM-Name (Default: ${GUEST_NAME})
  --type lxc|vm      LXC (Default) oder VM (cloud-init)
  --cores N          vCPU (Default ${DEFAULT_CORES})
  --memory MB        RAM (Default ${DEFAULT_RAM} MB)
  --disk GB          Disk (Default ${DEFAULT_DISK} GB)
  --storage NAME     RootFS-Storage (Default: auto, local-lvm bevorzugt)
  --template-store N Template-/Snippet-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME      Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW      Root-Passwort (Default: zufällig, Datei unter /root/)
  --ssh-key PATH     SSH-Public-Key für root
  --update           n8n-Image/Stack im bestehenden Gast aktualisieren
  --uninstall        n8n-Stack im Gast entfernen (Docker bleibt)
  --debug            bash -x + vollständige Fehlerkette
  -h, --help         diese Hilfe

Umgebung: CT_ID, CORES, RAM, DISK, TZ, N8N_VERSION, DEBUG=1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --type) TYPE="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --update) FORWARD_ARGS="--update"; shift;;
    --uninstall) FORWARD_ARGS="--uninstall"; shift;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ "$TYPE" == "lxc" || "$TYPE" == "vm" ]] || die "--type muss lxc oder vm sein (war: $TYPE)."
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
for tool in pvesh pvesm pveam; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool nicht gefunden – kein Proxmox-Host?"
done
if [[ "$TYPE" == "lxc" ]]; then
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden."
else
  command -v qm >/dev/null 2>&1 || die "qm nicht gefunden (VM-Modus)."
fi

if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid | tr -d '[:space:]')"
  msg_info "Nächste freie ID: ${CT_ID}"
fi
[[ "$CT_ID" =~ ^[0-9]+$ ]] || die "Ungültige ID: ${CT_ID}"

if pct config "$CT_ID" >/dev/null 2>&1 || qm config "$CT_ID" >/dev/null 2>&1; then
  EXISTING=1
  msg_warn "ID ${CT_ID} existiert bereits – Update-Modus (kein Neuaufbau)."
else
  EXISTING=0
fi

# --update/--uninstall bei bereits existierender VM: Inner-Installer kann dort
# nicht per pct push/exec laufen; klar melden statt halb zu arbeiten.
if [[ "$TYPE" == "vm" && "$EXISTING" == "1" && -n "$FORWARD_ARGS" ]]; then
  die "--${FORWARD_ARGS#--} im VM-Modus: bitte im Gast ausführen (qm guest exec ${CT_ID} -- bash -c 'curl -fsSL ${INNER_URL} -o /tmp/${APP}-inner.sh && bash /tmp/${APP}-inner.sh ${FORWARD_ARGS}')."
fi

if [[ "$TYPE" == "vm" ]]; then
  CORES="$VM_CORES"; RAM="$VM_RAM"; DISK="$VM_DISK"
fi

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then
    STORAGE_ARG="local-lvm"
  else
    STORAGE_ARG="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')"
  fi
fi
[[ -n "$STORAGE_ARG" ]] || die "Kein RootFS-Storage gefunden (pvesm status -content rootdir)."
msg_info "Storage: ${STORAGE_ARG} | Template/Snippet-Store: ${TEMPLATE_STORE} | Bridge: ${BRIDGE}"

TEMPLATE=""
if [[ "$TYPE" == "lxc" && "$EXISTING" == "0" ]]; then
  msg_info "Prüfe LXC-Template ..."
  pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen – nutze vorhandene Templates."
  AVAILABLE="$(pveam available --section system 2>/dev/null || true)"
  TEMPLATE="$(printf '%s\n' "$AVAILABLE" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE="$(printf '%s\n' "$AVAILABLE" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  fi
  [[ -n "$TEMPLATE" ]] || {
    msg_error "Kein Debian-Standard-Template gefunden. Verfügbare Templates:"
    printf '%s\n' "$AVAILABLE" | head -n 20 >&2 || true
    die "Bitte 'pveam update' und Netz/DNS auf dem Host prüfen."
  }
  if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Lade Template ${TEMPLATE} ..."
    pveam download "$TEMPLATE_STORE" "$TEMPLATE"
  fi
  msg_ok "Template bereit: ${TEMPLATE_STORE}:vztmpl/${TEMPLATE}"
fi

if [[ "$EXISTING" == "0" ]]; then
  if [[ "$TYPE" == "lxc" ]]; then
    if [[ -z "$PASSWORD_ARG" ]]; then
      set +x
      PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
      [[ "$-" == *x* ]] && set -x
    fi
    msg_info "Erstelle LXC ${CT_ID} (${HOSTNAME_ARG}): ${CORES} vCPU / ${RAM} MB / ${DISK} GB ..."
    pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
      --hostname "$HOSTNAME_ARG" \
      --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
      --rootfs "${STORAGE_ARG}:${DISK}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --unprivileged 1 --features "nesting=1,keyctl=1" \
      --onboot 1 --start 0 --password "$PASSWORD_ARG"
    CREATED=1
    msg_ok "LXC erstellt (unprivilegiert, nesting=1, keyctl=1, onboot=1)."
    if [[ -n "$SSH_KEY_ARG" ]]; then
      [[ -f "$SSH_KEY_ARG" ]] || die "SSH-Key nicht gefunden: ${SSH_KEY_ARG}"
      pct exec "$CT_ID" -- mkdir -p /root/.ssh
      pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys
    fi
  else
    IMAGE_PATH="/var/lib/vz/images/${APP}-debian-12.qcow2"
    mkdir -p "$(dirname "$IMAGE_PATH")"
    if [[ ! -f "$IMAGE_PATH" ]]; then
      msg_info "Lade Debian-12-Cloud-Image ..."
      curl -fsSL --max-time 900 -o "${IMAGE_PATH}.tmp" "$VM_IMAGE_URL" \
        || die "Cloud-Image nicht ladbar: ${VM_IMAGE_URL}"
      mv "${IMAGE_PATH}.tmp" "$IMAGE_PATH"
    fi
    msg_info "Erstelle VM ${CT_ID} (${HOSTNAME_ARG}): ${CORES} vCPU / ${RAM} MB / ${DISK} GB ..."
    qm create "$CT_ID" --name "$HOSTNAME_ARG" --cores "$CORES" --memory "$RAM" \
      --net0 "virtio,bridge=${BRIDGE}" --onboot 1 --agent enabled=1 --ostype l26
    qm importdisk "$CT_ID" "$IMAGE_PATH" "$STORAGE_ARG" --format qcow2
    qm set "$CT_ID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE_ARG}:vm-${CT_ID}-disk-0"
    qm set "$CT_ID" --scsi0 "${STORAGE_ARG}:vm-${CT_ID}-disk-0,size=${DISK}G"
    qm set "$CT_ID" --ide2 "${STORAGE_ARG}:cloudinit"
    qm set "$CT_ID" --boot c --bootdisk scsi0
    qm set "$CT_ID" --serial0 socket --vga serial0
    qm set "$CT_ID" --ipconfig0 ip=dhcp
    if [[ -n "$SSH_KEY_ARG" ]]; then
      [[ -f "$SSH_KEY_ARG" ]] || die "SSH-Key nicht gefunden: ${SSH_KEY_ARG}"
      qm set "$CT_ID" --sshkeys "$SSH_KEY_ARG"
    fi
    SNIPPET_DIR="/var/lib/vz/snippets"
    mkdir -p "$SNIPPET_DIR"
    SNIPPET_FILE="${SNIPPET_DIR}/${APP}-${CT_ID}.yml"
    cat > "$SNIPPET_FILE" <<CLOUD
#cloud-config
hostname: ${HOSTNAME_ARG}
package_update: true
packages:
  - curl
  - ca-certificates
runcmd:
  - systemctl enable --now qemu-guest-agent || true
  - curl -fsSL --max-time 120 -o /tmp/${APP}-inner.sh ${INNER_URL}
  - REPO_URL=${REPO_URL} REPO_REF=${REPO_REF} APP_PORT=${APP_PORT} TZ=${TZ_VALUE} N8N_VERSION=${N8N_VERSION} DNS_SERVERS='${HOST_DNS}' DNS_PINS='${HOST_PINS}' bash /tmp/${APP}-inner.sh ${FORWARD_ARGS}
CLOUD
    qm set "$CT_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${APP}-${CT_ID}.yml"
    CREATED=1
    msg_ok "VM erstellt (cloud-init, onboot=1)."
  fi
fi

if [[ "$TYPE" == "lxc" ]]; then
  if ! pct status "$CT_ID" 2>/dev/null | grep -q '^status: running'; then
    msg_info "Starte LXC ${CT_ID} ..."
    pct start "$CT_ID"
    msg_ok "LXC gestartet."
  fi
else
  if ! qm status "$CT_ID" 2>/dev/null | grep -q '^status: running'; then
    msg_info "Starte VM ${CT_ID} ..."
    qm start "$CT_ID"
    msg_ok "VM gestartet."
  fi
fi

msg_info "Warte auf Netzwerk-Adresse ..."
for _ in $(seq 1 36); do
  sleep 5
  if [[ "$TYPE" == "lxc" ]]; then
    CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  else
    VM_NET="$(qm guest cmd "$CT_ID" network-get-interfaces 2>/dev/null || true)"
    CT_IP="$(printf '%s\n' "$VM_NET" | grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '^127\.' | head -n1 || true)"
  fi
  [[ -n "$CT_IP" ]] && break
done
if [[ -z "$CT_IP" ]]; then
  msg_error "Keine IP für ID ${CT_ID} erhalten – Diagnose:"
  if [[ "$TYPE" == "lxc" ]]; then
    pct status "$CT_ID" 2>&1 || true
    pct config "$CT_ID" 2>&1 | grep -E 'net0|hostname|onboot' || true
    pct exec "$CT_ID" -- ip -br addr 2>&1 || true
    pct exec "$CT_ID" -- cat /etc/network/interfaces 2>&1 || true
  else
    qm status "$CT_ID" 2>&1 || true
    qm guest cmd "$CT_ID" network-get-interfaces 2>&1 || true
  fi
  die "IP-Erkennung fehlgeschlagen – siehe Ausgabe oben und ${LOG_FILE}."
fi
msg_ok "Adresse: ${CT_IP}"

msg_info "Installiere ${APP_DISPLAY} im Gast ..."
if [[ "$TYPE" == "lxc" ]]; then
  if [[ -n "$HOST_PINS" ]]; then
    PINS_TMP="$(mktemp)"
    printf '# n8n-pins\n' > "$PINS_TMP"
    for _entry in $HOST_PINS; do
      printf '%s %s\n' "${_entry#*=}" "${_entry%%=*}" >> "$PINS_TMP"
    done
    pct push "$CT_ID" "$PINS_TMP" "/tmp/${APP}-pins.txt"
    pct exec "$CT_ID" -- bash -c \
      "sed -i '/# n8n-pins/d' /etc/hosts && cat /tmp/${APP}-pins.txt >> /etc/hosts && chmod 0644 /etc/hosts && rm -f /tmp/${APP}-pins.txt"
    msg_ok "Download-Hosts (via Host-DNS aufgelöst) in /etc/hosts des LXC gepinnt."
  else
    msg_warn "Keine Host-Pins ermittelbar – Gast nutzt DNS-Fallback aus fix_dns."
  fi
  INNER_TMP="$(mktemp)"
  LOCAL_INNER="${N8N_INNER:-}"
  if [[ -z "$LOCAL_INNER" && -n "${BASH_SOURCE[0]:-}" ]]; then
    CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/${APP}-inner.sh"
    [[ -f "$CANDIDATE" ]] && LOCAL_INNER="$CANDIDATE"
  fi
  if [[ -n "$LOCAL_INNER" ]]; then
    cp "$LOCAL_INNER" "$INNER_TMP"
    msg_info "Inner-Script lokal: ${LOCAL_INNER}"
  elif command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 120 -o "$INNER_TMP" "${INNER_URL}?cb=$(date +%s)"; then
    msg_info "Inner-Script via curl geladen (cache-geprüft)."
  elif command -v wget >/dev/null 2>&1 && wget -qLO "$INNER_TMP" "${INNER_URL}?cb=$(date +%s)"; then
    msg_info "Inner-Script via wget geladen (cache-geprüft)."
  else
    die "Inner-Script konnte nicht geladen werden: ${INNER_URL}"
  fi
  # Stale-CDN-Schutz: raw.githubusercontent.com kann nach einem Push einige
  # Minuten hinter dem Repo herhängen – ohne Versions-Marker ist das Innere
  # alt (z. B. ohne apt-Sandbox-Fix) und der Lauf würde kryptisch in apt enden.
  INNER_VER="$(grep -m1 -oP '(?<=INNER_VERSION=")[^"]+' "$INNER_TMP" 2>/dev/null || true)"
  if [[ -z "$INNER_VER" ]]; then
    die "Inner-Script ohne Versions-Marker geladen (vermutlich veralteter CDN-Cache von raw.githubusercontent.com) – in ~3 Minuten erneut versuchen."
  fi
  msg_info "Inner-Script Version: ${INNER_VER}"
  pct push "$CT_ID" "$INNER_TMP" "/tmp/${APP}-inner.sh"
  msg_ok "Inner-Script in den LXC übertragen."
  # shellcheck disable=SC2086  # FORWARD_ARGS ist bewusst unquoted (0/1 Argument)
  pct exec "$CT_ID" -- env REPO_URL="$REPO_URL" REPO_REF="$REPO_REF" \
    APP_PORT="$APP_PORT" TZ="$TZ_VALUE" N8N_VERSION="$N8N_VERSION" DEBUG="$DEBUG" \
    DNS_SERVERS="$HOST_DNS" DNS_PINS="$HOST_PINS" \
    bash "/tmp/${APP}-inner.sh" $FORWARD_ARGS
else
  for _ in $(seq 1 12); do
    if qm guest exec "$CT_ID" -- test -f "/tmp/${APP}-inner.sh" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  msg_info "Warte auf Abschluss der cloud-init-Installation (healthz) ..."
  for _ in $(seq 1 60); do
    if qm guest exec "$CT_ID" -- curl -fs -m 5 "http://localhost:${APP_PORT}/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
fi
msg_ok "Installation im Gast abgeschlossen."

msg_info "Verifiziere Installation (Docker + http://localhost:${APP_PORT}/healthz) ..."
if [[ "$TYPE" == "lxc" ]]; then
  DOCKER_STATE="$(pct exec "$CT_ID" -- systemctl is-active docker 2>/dev/null || true)"
  HEALTH="$(pct exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${APP_PORT}/healthz" 2>/dev/null || true)"
else
  DOCKER_STATE="$(qm guest exec "$CT_ID" -- systemctl is-active docker 2>/dev/null | grep -o 'active' | head -n1 || true)"
  VM_HEALTH_RAW="$(qm guest exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${APP_PORT}/healthz" 2>/dev/null || true)"
  HEALTH="${VM_HEALTH_RAW//\\\"/\"}"
fi
[[ "$DOCKER_STATE" == "active" ]] || {
  msg_error "Docker ist nicht active (war: '${DOCKER_STATE}')."
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$CT_ID" -- systemctl status docker --no-pager 2>&1 || true
    pct exec "$CT_ID" -- journalctl -u docker --no-pager -n 100 2>&1 || true
    pct exec "$CT_ID" -- docker info 2>&1 || true
  fi
  die "Docker-Verifikation fehlgeschlagen."
}
msg_ok "Docker läuft (systemctl is-active docker = active)."
HEALTH_OK=0
printf '%s' "$HEALTH" | grep -q '"status":"ok"' && HEALTH_OK=1
[[ "$HEALTH_OK" == "1" ]] || {
  msg_error "n8n antwortet nicht korrekt auf localhost:${APP_PORT}/healthz."
  msg_error "Antwort: ${HEALTH:-<leer>}"
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$CT_ID" -- bash -c 'cd /opt/n8n && docker compose logs --tail=50' 2>&1 || true
  fi
  die "HTTP-Verifikation fehlgeschlagen."
}
msg_ok "n8n antwortet (HTTP 200 auf localhost:${APP_PORT}/healthz)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : ${APP_DISPLAY} – Workflow-Automation (Docker Compose, SQLite)"
echo "  Repo         : ${REPO_URL}"
echo "  Typ          : ${TYPE^^} (ID ${CT_ID}, Name ${HOSTNAME_ARG}, onboot=1)"
echo "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Health       : http://${CT_IP}:${APP_PORT}/healthz"
echo "  Stack        : /opt/n8n (docker-compose.yml + .env mit Encryption-Key)"
if [[ "$CREATED" == "1" && "$TYPE" == "lxc" && -n "$PASSWORD_ARG" ]]; then
  PASS_STORE="/root"
  [[ -w "$PASS_STORE" ]] || PASS_STORE="${HOME:-$LOG_DIR}"
  PASS_FILE="${PASS_STORE}/${APP}-root-password"
  if (umask 077; printf '%s\n' "$PASSWORD_ARG" > "$PASS_FILE") 2>/dev/null; then
    echo "  Root-Passwort: ${PASS_FILE} (nur root lesbar)"
  else
    msg_warn "Root-Passwort konnte nicht gespeichert werden – bei Bedarf --password verwenden."
  fi
fi
echo "  Update       : CT_ID=${CT_ID} bash n8n.sh --update"
echo "  Uninstall    : CT_ID=${CT_ID} bash n8n.sh --uninstall"
echo "  Destroy      : $([[ "$TYPE" == "lxc" ]] && echo "pct stop ${CT_ID} && pct destroy ${CT_ID}" || echo "qm stop ${CT_ID} && qm destroy ${CT_ID}")"
if [[ "$TYPE" == "lxc" ]]; then
  echo "  Reboot-Test  : pct reboot ${CT_ID} && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/healthz"
else
  echo "  Reboot-Test  : qm reboot ${CT_ID} && sleep 90 && curl -fs http://${CT_IP}:${APP_PORT}/healthz"
fi
echo "  Log          : ${LOG_FILE}"
echo "══════════════════════════════════════════════════════════"
