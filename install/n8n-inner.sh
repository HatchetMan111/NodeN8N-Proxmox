#!/usr/bin/env bash
#
# n8n-inner.sh - wird INNERHALB des LXC / der VM ausgeführt.
# Entfernt evtl. vorhandenes LocalDash, installiert Docker CE + Compose und
# bringt den n8n-Stack (/opt/n8n, SQLite-Volume, Port 5678) hoch.
#
set -euo pipefail
umask 022

APP="n8n"
INNER_VERSION="2026-11-18.2-sandbox"
APP_PORT="5678"
APP_DIR="/opt/n8n"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/NodeN8N-Proxmox}"
REPO_REF="${REPO_REF:-main}"
N8N_VERSION="${N8N_VERSION:-latest}"
TZ_VALUE="${TZ:-Europe/Berlin}"
RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}"
COMPOSE_URL="${RAW_BASE}/${REPO_REF}/docker/docker-compose.yml"
LOG_FILE="/var/log/${APP}-install-inner.log"
MODE="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) MODE="uninstall" ;;
    --update) MODE="update" ;;
  esac
  shift
done

exec > >(tee -i "$LOG_FILE") 2>&1

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

on_error() {
  local ec=$?
  trap - ERR
  set +e
  msg_error "════ INNER-INSTALLER FEHLGESCHLAGEN ════"
  msg_error "Befehl : ${BASH_COMMAND}"
  msg_error "Exit   : ${ec}"
  [[ -x /usr/bin/docker ]] && docker ps -a 2>&1 | head -n 10
  msg_error "Log: ${LOG_FILE}"
  exit "$ec"
}
trap on_error ERR

[[ "$(id -u)" == "0" ]] || { msg_error "Inner-Installer muss als root laufen."; exit 1; }
msg_info "Starte n8n-Inner-Installer v${INNER_VERSION} (Modus: ${MODE}, Port ${APP_PORT}) – ${REPO_URL} @ ${REPO_REF}"

compose() { ( cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" "$@" ); }

guest_ip() {
  local ip
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

remove_localdash() {
  if [[ -f /etc/systemd/system/localdash.service ]]; then
    msg_info "Entferne vorhandenes LocalDash ..."
    systemctl disable --now localdash 2>/dev/null || true
    rm -f /etc/systemd/system/localdash.service \
          /etc/systemd/system/multi-user.target.wants/localdash.service
    systemctl daemon-reload || true
  fi
  rm -rf /opt/localdash /var/lib/localdash
  if id localdash >/dev/null 2>&1; then
    userdel localdash 2>/dev/null || true
    msg_ok "LocalDash-Reste entfernt (Service, Verzeichnisse, User)."
  else
    msg_ok "Kein LocalDash vorhanden – nichts zu entfernen."
  fi
}

DNS_TEST_HOST="deb.debian.org"
RESOLV_OPTS="options timeout:3 attempts:4 single-request-reopen"

write_resolv() {
  printf 'nameserver %s\n%s\n' "$1" "$RESOLV_OPTS" > /etc/resolv.conf
  chmod 0644 /etc/resolv.conf
}

fix_dns() {
  # shellcheck disable=SC2086  # Wortauftrennung der Nameserver-Liste ist beabsichtigt
  local candidates=() ns best_ipv4=""
  for ns in ${DNS_SERVERS:-}; do candidates+=("$ns"); done
  if [[ -f /etc/resolv.conf ]]; then
    while read -r _ ns; do
      [[ "$ns" =~ ^(127\.|::1|0\.0\.0\.0) ]] || candidates+=("$ns")
    done < /etc/resolv.conf
  fi
  ns="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  [[ -n "$ns" ]] && candidates+=("$ns")
  candidates+=(1.1.1.1 9.9.9.9 8.8.8.8)
  msg_info "Prüfe DNS-Auflösung (getestet wird: ${DNS_TEST_HOST}) ..."
  for ns in $(printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'); do
    write_resolv "$ns"
    if getent ahostsv4 "$DNS_TEST_HOST" >/dev/null 2>&1; then
      best_ipv4="$ns"
      if getent hosts "$DNS_TEST_HOST" >/dev/null 2>&1; then
        msg_ok "DNS funktioniert über ${ns} (A- und AAAA-Abfragen)."
        return 0
      fi
    fi
  done
  if [[ -n "$best_ipv4" ]]; then
    write_resolv "$best_ipv4"
    msg_warn "Nur IPv4-Auflösung funktioniert (Nameserver ${best_ipv4})."
    return 0
  fi
  msg_error "Kein funktionierender DNS-Server gefunden (Kandidaten: ${candidates[*]})."
  cat /etc/resolv.conf >&2 || true
  exit 1
}

apply_dns_pins() {
  # shellcheck disable=SC2086  # Wortauftrennung der Pin-Liste ist beabsichtigt
  [[ -n "${DNS_PINS:-}" ]] || return 0
  local entry host ip pinned=0
  for entry in $DNS_PINS; do
    host="${entry%%=*}"
    ip="${entry#*=}"
    [[ "$host" == "$ip" ]] && continue
    if ! grep -qE "^[[:space:]]*$(printf '%s' "$ip" | sed 's/\./\\./g')[[:space:]]+${host}([[:space:]]|$)" /etc/hosts; then
      printf '%s %s\n' "$ip" "$host" >> /etc/hosts
      pinned=$((pinned + 1))
    fi
  done
  [[ "$pinned" -gt 0 ]] && msg_ok "${pinned} Host-Einträge in /etc/hosts gepinnt."
  chmod 0644 /etc/hosts
}

apt_update_retry() {
  local attempt
  for attempt in 1 2 3; do
    if apt-get update; then return 0; fi
    msg_warn "apt-get update fehlgeschlagen (Versuch ${attempt}/3) – wiederhole in 5s."
    sleep 5
  done
  return 1
}

apt_install_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if apt-get install -y --fix-missing --no-install-recommends "$@"; then return 0; fi
    msg_warn "apt-get install fehlgeschlagen (Versuch ${attempt}/5) – wiederhole in 5s."
    if [[ "$attempt" == "2" ]]; then
      msg_warn "Bereinige inkonsistente apt-Listen und lade sie neu."
      rm -rf /var/lib/apt/lists/* || true
      apt-get update || true
    fi
    sleep 5
  done
  return 1
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    msg_ok "Docker + Compose bereits vorhanden."
    return 0
  fi
  msg_info "Richte Docker-Repository ein ..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --max-time 60 https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
    "$(dpkg --print-architecture)" "${VERSION_CODENAME:-bookworm}" \
    > /etc/apt/sources.list.d/docker.list
  apt_update_retry || { msg_error "apt-get update nach Docker-Repo fehlgeschlagen."; exit 1; }
  apt_install_retry docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || { msg_error "Docker-Installation fehlgeschlagen."; exit 1; }
  msg_ok "Docker CE + Compose installiert ($(docker --version))."
}

configure_docker_dns() {
  local ns dns_list="" daemon="/etc/docker/daemon.json"
  mkdir -p /etc/docker
  for ns in ${DNS_SERVERS:-}; do dns_list+="\"${ns}\","; done
  dns_list="[${dns_list%,}]"
  if [[ -f "$daemon" ]] && grep -q '"dns"' "$daemon"; then
    msg_info "Behalte bestehende ${daemon}."
  else
    cat > "$daemon" <<JSON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "dns": ${dns_list}
}
JSON
  fi
  systemctl enable --now docker
  local driver
  driver="$(docker info --format '{{.Driver}}' 2>/dev/null || true)"
  if [[ "$driver" == "vfs" ]]; then
    msg_warn "Storage-Treiber vfs aktiv – funktioniert, ist aber langsamer."
  fi
}

write_env() {
  mkdir -p "$APP_DIR"
  if [[ -f "$ENV_FILE" ]]; then
    msg_info "Behalte bestehende ${ENV_FILE} (Encryption-Key unverändert)."
    return 0
  fi
  local ip key
  ip="$(guest_ip)"
  key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  cat > "$ENV_FILE" <<ENV
N8N_IMAGE=docker.n8n.io/n8nio/n8n:${N8N_VERSION}
N8N_HOST=${ip}
WEBHOOK_URL=http://${ip}:${APP_PORT}/
GENERIC_TIMEZONE=${TZ_VALUE}
TZ=${TZ_VALUE}
N8N_ENCRYPTION_KEY=${key}
ENV
  chmod 0600 "$ENV_FILE"
  msg_ok "Neue .env erzeugt (Encryption-Key gesichert)."
}

write_compose() {
  if curl -fsSL --max-time 60 -o "${COMPOSE_FILE}.tmp" "${COMPOSE_URL}?cb=$(date +%s)"; then
    mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
    msg_ok "Compose-Datei aus Repo übernommen."
  else
    msg_warn "Compose-Datei nicht ladbar – nutze eingebettete Version."
    cat > "$COMPOSE_FILE" <<'YAML'
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
YAML
  fi
}

wait_health() {
  local _
  for _ in $(seq 1 40); do
    if curl -fs -m 5 "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1; then
      msg_ok "n8n antwortet (HTTP 200 auf /healthz)."
      return 0
    fi
    sleep 3
  done
  msg_error "n8n antwortet nicht auf http://127.0.0.1:${APP_PORT}/healthz."
  compose logs --tail=50 || true
  return 1
}

if [[ "$MODE" == "uninstall" ]]; then
  if [[ -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1; then
    compose down -v || true
    msg_ok "Container und Volume entfernt."
  else
    msg_warn "Kein n8n-Stack unter ${APP_DIR} gefunden – nichts zu stoppen."
  fi
  rm -rf "$APP_DIR"
  msg_ok "n8n entfernt (Docker selbst bleibt installiert)."
  exit 0
fi

if [[ "$MODE" == "update" ]]; then
  [[ -f "$COMPOSE_FILE" ]] || { msg_error "Kein n8n-Stack unter ${APP_DIR} – erst installieren."; exit 1; }
  fix_dns
  apply_dns_pins
  compose pull
  compose up -d
  wait_health
  msg_ok "n8n aktualisiert."
  exit 0
fi

remove_localdash
fix_dns
apply_dns_pins
chmod 0644 /etc/hosts /etc/resolv.conf
if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
  printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "10";\n' > /etc/apt/apt.conf.d/99n8n-ipv4
else
  msg_warn "Kein IPv4 für deb.debian.org – ForceIPv4 wird NICHT erzwungen."
fi
msg_info "Auflösung nach Pins: $(getent ahostsv4 deb.debian.org 2>/dev/null | awk 'NR==1{print $1}')"

# apt-Sandbox: apt's http-Methode läuft als eigener Benutzer _apt. Kann dieser
# die Resolver-Dateien nicht lesen oder bricht seine Sandbox-Umgebung im
# unprivilegierten LXC, meldet apt exakt 'Temporary failure resolving' – obwohl
# getent als root funktioniert (getent-ok/apt-tot-Spalte). Rechte korrigieren,
# Sandbox selbst testen, im Notfall dauerhaft als root arbeiten lassen.
chmod 0644 /etc/resolv.conf /etc/hosts /etc/nsswitch.conf 2>/dev/null || true
if id _apt >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
  if runuser -u _apt -- getent hosts deb.debian.org >/dev/null 2>&1; then
    msg_ok "apt-Sandbox (_apt) löst auf."
  else
    msg_warn "apt-Sandbox-Benutzer _apt kann nicht auflösen – korrigiere Dateirechte ..."
    chmod 0644 /etc/resolv.conf /etc/hosts /etc/nsswitch.conf 2>/dev/null || true
    if runuser -u _apt -- getent hosts deb.debian.org >/dev/null 2>&1; then
      msg_ok "Benutzer _apt löst jetzt auf (Rechte korrigiert)."
    else
      msg_warn "_apt löst weiterhin nicht auf – apt-Methoden laufen dauerhaft als root (APT::Sandbox::User=root)."
      printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99n8n-sandbox
    fi
  fi
fi

export DEBIAN_FRONTEND=noninteractive
msg_info "Installiere Basispakete ..."
apt_update_retry || { msg_error "apt-get update nach 3 Versuchen fehlgeschlagen."; exit 1; }
apt_install_retry ca-certificates curl gnupg openssl \
  || { msg_error "Basispakete fehlgeschlagen."; exit 1; }
msg_ok "Basispakete installiert."

install_docker
configure_docker_dns

write_env
write_compose
msg_info "Lade n8n-Image (kann einige Minuten dauern) ..."
pull_ok=0
for _attempt in 1 2 3 4 5; do
  if compose pull; then pull_ok=1; break; fi
  msg_warn "docker compose pull fehlgeschlagen (Versuch ${_attempt}/5) – wiederhole in 10s."
  sleep 10
done
[[ "$pull_ok" == "1" ]] || { msg_error "Image-Pull fehlgeschlagen."; exit 1; }

msg_info "Starte n8n (docker compose up -d) ..."
compose up -d
wait_health || exit 1

echo ""
echo "════ n8n INSTALLATION ERFOLGREICH ════"
echo "  URL        : http://$(guest_ip):${APP_PORT}"
echo "  Compose    : ${COMPOSE_FILE}"
echo "  Env        : ${ENV_FILE} (0600, Encryption-Key)"
echo "  Update     : bash n8n-inner.sh --update (im Gast)"
echo "  Uninstall  : bash n8n-inner.sh --uninstall (im Gast)"
echo "═════════════════════════════════════"
