#!/usr/bin/env bash
#
# localdash.sh - Proxmox VE Einzeiler-Installer für LocalDash
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NodeN8N-Proxmox/main/install/localdash.sh)"
#
# Läuft AUF DEM PROXMOX-HOST (root). Erstellt einen LXC (Standard) oder eine VM
# (--type vm), installiert LocalDash darin und verifiziert Service + Web-UI.
#
set -euo pipefail
umask 077

APP="localdash"
APP_DISPLAY="LocalDash"
APP_PORT="8080"
REPO_URL="https://github.com/HatchetMan111/NodeN8N-Proxmox"
REPO_REF="main"

DEFAULT_CORES="1"
DEFAULT_RAM="1024"
DEFAULT_SWAP="512"
DEFAULT_DISK="4"
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

CT_ID="${CT_ID:-${CTID:-}}"
CORES="${CORES:-$DEFAULT_CORES}"
RAM="${RAM:-$DEFAULT_RAM}"
DISK="${DISK:-$DEFAULT_DISK}"
TYPE="lxc"
HOSTNAME_ARG="$APP"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG=""
SSH_KEY_ARG=""
DEBUG="${DEBUG:-0}"
LOCALDASH_SRC="${LOCALDASH_SRC:-}"
EXISTING=0
CREATED=0
INNER_TMP=""
CT_IP=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
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
      msg_error "Journal ${APP} (letzte 50 Zeilen):"
      pct exec "$CT_ID" -- journalctl -u "$APP" --no-pager -n 50 2>&1 || true
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

Usage:
  bash -c "\$(wget -qLO - ${RAW_BASE}/${REPO_REF}/install/${APP}.sh)"
  bash ${APP}.sh [OPTIONEN]

Optionen:
  --ctid ID          ID (Default: nächste freie ID via pvesh /cluster/nextid)
  --hostname NAME    Hostname/VM-Name (Default: ${APP})
  --type lxc|vm      LXC (Default) oder VM (cloud-init)
  --cores N          vCPU (Default LXC ${DEFAULT_CORES} / VM ${VM_CORES})
  --memory MB        RAM (Default LXC ${DEFAULT_RAM} / VM ${VM_RAM})
  --disk GB          Disk (Default LXC ${DEFAULT_DISK} / VM ${VM_DISK})
  --storage NAME     RootFS-Storage (Default: auto, local-lvm bevorzugt)
  --template-store N Template-/Snippet-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME      Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW      Root-Passwort (Default: zufällig, Datei unter /root/)
  --ssh-key PATH     SSH-Public-Key für root
  --debug            bash -x + vollständige Fehlerkette
  -h, --help         diese Hilfe

Umgebung: CT_ID, CORES, RAM, DISK, DEBUG=1
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
      --unprivileged 1 --features "nesting=1" \
      --onboot 1 --start 0 --password "$PASSWORD_ARG"
    CREATED=1
    msg_ok "LXC erstellt (unprivilegiert, nesting=1, onboot=1)."
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
  - REPO_URL=${REPO_URL} REPO_REF=${REPO_REF} APP_PORT=${APP_PORT} bash /tmp/${APP}-inner.sh
CLOUD
    qm set "$CT_ID" --cicustom "user=${SNIPPET_STORAGE}:snippets/${APP}-${CT_ID}.yml"
    qm start "$CT_ID"
    CREATED=1
    msg_ok "VM erstellt und gestartet (cloud-init, onboot=1)."
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
[[ -n "$CT_IP" ]] || die "Keine IP für ID ${CT_ID} erhalten – Netz/Bridge prüfen."
msg_ok "Adresse: ${CT_IP}"

msg_info "Installiere ${APP_DISPLAY} im Gast ..."
if [[ "$TYPE" == "lxc" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/${APP}-inner.sh" ]]; then
    INNER_TMP="$(mktemp)"
    cp "${SCRIPT_DIR}/${APP}-inner.sh" "$INNER_TMP"
    pct push "$CT_ID" "$INNER_TMP" "/tmp/${APP}-inner.sh"
    msg_ok "Inner-Script lokal übertragen."
  else
    pct exec "$CT_ID" -- curl -fsSL --max-time 120 -o "/tmp/${APP}-inner.sh" "$INNER_URL"
    msg_ok "Inner-Script aus Repo geladen."
  fi
  pct exec "$CT_ID" -- env REPO_URL="$REPO_URL" REPO_REF="$REPO_REF" \
    APP_PORT="$APP_PORT" LOCALDASH_SRC="$LOCALDASH_SRC" DEBUG="$DEBUG" \
    bash "/tmp/${APP}-inner.sh"
else
  for _ in $(seq 1 12); do
    if qm guest exec "$CT_ID" -- test -f "/tmp/${APP}-inner.sh" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  msg_info "Warte auf Abschluss der cloud-init-Installation ..."
  for _ in $(seq 1 36); do
    if qm guest exec "$CT_ID" -- systemctl is-active "$APP" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
fi
msg_ok "Installation im Gast abgeschlossen."

msg_info "Verifiziere Installation ..."
if [[ "$TYPE" == "lxc" ]]; then
  SERVICE_STATE="$(pct exec "$CT_ID" -- systemctl is-active "$APP" 2>/dev/null || true)"
  HEALTH="$(pct exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${APP_PORT}/api/health" 2>/dev/null || true)"
else
  SERVICE_STATE="$(qm guest exec "$CT_ID" -- systemctl is-active "$APP" 2>/dev/null | grep -o 'active' | head -n1 || true)"
  HEALTH="$(qm guest exec "$CT_ID" -- curl -fs -m 15 "http://localhost:${APP_PORT}/api/health" 2>/dev/null || true)"
fi
[[ "$SERVICE_STATE" == "active" ]] || {
  msg_error "Service ${APP} ist nicht active (war: '${SERVICE_STATE}')."
  if [[ "$TYPE" == "lxc" ]]; then
    pct exec "$CT_ID" -- systemctl status "$APP" --no-pager 2>&1 || true
    pct exec "$CT_ID" -- journalctl -u "$APP" --no-pager -n 100 2>&1 || true
  fi
  die "systemd-Verifikation fehlgeschlagen."
}
msg_ok "Service läuft (systemctl is-active ${APP} = active)."
HEALTH_OK=0
printf '%s' "$HEALTH" | grep -q 'status.*ok' && HEALTH_OK=1
[[ "$HEALTH_OK" == "1" ]] || {
  msg_error "Web-UI antwortet nicht korrekt auf localhost:${APP_PORT}/api/health."
  msg_error "Antwort: ${HEALTH:-<leer>}"
  die "HTTP-Verifikation fehlgeschlagen."
}
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/api/health)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : ${APP_DISPLAY} – lokales System-/Service-Dashboard"
echo "  Repo         : ${REPO_URL}"
echo "  Typ          : ${TYPE^^} (ID ${CT_ID}, Name ${HOSTNAME_ARG}, onboot=1)"
echo "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Health       : http://${CT_IP}:${APP_PORT}/api/health"
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
echo "  Service      : systemctl status ${APP}  (im Gast: ${TYPE^^} ${CT_ID})"
echo "  Update       : Skript erneut laufen lassen (idempotent)"
echo "  Deinstall    : $([[ "$TYPE" == "lxc" ]] && echo "pct stop ${CT_ID} && pct destroy ${CT_ID}" || echo "qm stop ${CT_ID} && qm destroy ${CT_ID}")"
if [[ "$TYPE" == "lxc" ]]; then
  echo "  Reboot-Test  : pct reboot ${CT_ID} && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/api/health"
else
  echo "  Reboot-Test  : qm reboot ${CT_ID} && sleep 90 && curl -fs http://${CT_IP}:${APP_PORT}/api/health"
fi
echo "  Log          : ${LOG_FILE}"
echo "══════════════════════════════════════════════════════════"
