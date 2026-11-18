#!/usr/bin/env bash
#
# localdash-inner.sh - wird INNERHALB des LXC / der VM ausgeführt.
# Installiert Python/Node-Abhängigkeiten, baut die React-UI und startet den Service.
#
set -euo pipefail

APP="localdash"
APP_PORT="8080"
APP_DIR="/opt/localdash"
DATA_DIR="/var/lib/localdash"
REPO_URL="${REPO_URL:-https://github.com/HatchetMan111/NodeN8N-Proxmox}"
REPO_REF="${REPO_REF:-main}"
LOCALDASH_SRC="${LOCALDASH_SRC:-}"

RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}"
UNIT_URL="${RAW_BASE}/${REPO_REF}/systemd/${APP}.service"
LOG_FILE="/var/log/${APP}-install-inner.log"

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

exec > >(tee -i "$LOG_FILE") 2>&1
[[ "${DEBUG:-0}" == "1" ]] && set -x

on_error() {
  local ec=$?
  trap - ERR
  set +e
  msg_error "Inner-Installer fehlgeschlagen: Befehl »${BASH_COMMAND}« in Zeile ${LINENO} (Exit ${ec})."
  msg_error "Vollständiges Log: ${LOG_FILE}"
  msg_error "Service-Status:"
  systemctl status "$APP" --no-pager 2>&1 || true
  msg_error "Journal (letzte 100 Zeilen):"
  journalctl -u "$APP" --no-pager -n 100 2>&1 || true
  exit "$ec"
}
trap on_error ERR

msg_info "Starte Inner-Installer v3 (DNS-Pins aktiv) – Repo: ${REPO_URL} @ ${REPO_REF}"
[[ "$(id -u)" == "0" ]] || { msg_error "Inner-Installer muss als root laufen."; exit 1; }

DNS_TEST_HOST="deb.debian.org"
RESOLV_OPTS="options timeout:3 attempts:4 single-request-reopen"

write_resolv() {
  printf 'nameserver %s\n%s\n' "$1" "$RESOLV_OPTS" > /etc/resolv.conf
  chmod 0644 /etc/resolv.conf
}

fix_dns() {
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
    msg_warn "Nur IPv4-Auflösung funktioniert (Nameserver ${best_ipv4}) – erzwinge IPv4 für apt."
    return 0
  fi
  msg_error "Kein funktionierender DNS-Server gefunden (Kandidaten: ${candidates[*]})."
  msg_error "Aktuelle /etc/resolv.conf:"
  cat /etc/resolv.conf >&2 || true
  msg_error "Bitte Nameserver/Firewall (UDP/TCP 53) im Gast-Netz prüfen."
  exit 1
}

apply_dns_pins() {
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
  if [[ "$pinned" -gt 0 ]]; then
    msg_ok "${pinned} Host-Einträge (auf dem Proxmox-Host aufgelöst) in /etc/hosts gepinnt."
  fi
  chmod 0644 /etc/hosts
}

fix_dns
apply_dns_pins
chmod 0644 /etc/hosts /etc/resolv.conf
printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "10";\n' > /etc/apt/apt.conf.d/99localdash-ipv4
msg_info "Auflösung nach Pins: $(getent ahostsv4 deb.debian.org 2>/dev/null | awk 'NR==1{print $1}')"

export DEBIAN_FRONTEND=noninteractive
msg_info "Installiere Systempakete ..."
apt_ok=0
for _attempt in 1 2 3; do
  if apt-get update; then apt_ok=1; break; fi
  msg_warn "apt-get update fehlgeschlagen (Versuch ${_attempt}/3) – wiederhole in 5s."
  sleep 5
done
[[ "$apt_ok" == "1" ]] || { msg_error "apt-get update nach 3 Versuchen fehlgeschlagen."; exit 1; }
install_ok=0
for _attempt in 1 2 3 4 5; do
  if apt-get install -y --fix-missing --no-install-recommends \
    ca-certificates curl git python3 python3-venv python3-pip nodejs npm; then
    install_ok=1
    break
  fi
  msg_warn "apt-get install fehlgeschlagen (Versuch ${_attempt}/5) – bereits geladene Pakete bleiben im Cache, wiederhole in 5s."
  if [[ "$_attempt" == "2" ]]; then
    msg_warn "Bereinige inkonsistente apt-Listen und lade sie neu."
    rm -rf /var/lib/apt/lists/* || true
    apt-get update || true
  fi
  sleep 5
done
[[ "$install_ok" == "1" ]] || { msg_error "apt-get install nach 5 Versuchen fehlgeschlagen."; exit 1; }
msg_ok "Systempakete installiert (Node $(node --version 2>/dev/null || echo '?'))."

id "$APP" >/dev/null 2>&1 || useradd --system --home /var/lib/localdash --shell /usr/sbin/nologin "$APP"
mkdir -p "$APP_DIR" "$DATA_DIR"

msg_info "Hole App-Quellen nach ${APP_DIR} ..."
if [[ -n "$LOCALDASH_SRC" && -d "$LOCALDASH_SRC" ]]; then
  rm -rf "${APP_DIR:?}/app" "${APP_DIR:?}/web" "${APP_DIR:?}/systemd" "${APP_DIR:?}/README.md" \
    "${APP_DIR:?}/requirements.txt" 2>/dev/null || true
  cp -a "$LOCALDASH_SRC/." "$APP_DIR/"
  msg_ok "Lokale Quelle übernommen: $LOCALDASH_SRC"
elif [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --all --quiet
  git -C "$APP_DIR" reset --hard "origin/${REPO_REF}" --quiet
  msg_ok "Repo aktualisiert (${REPO_REF})."
else
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$APP_DIR"
  msg_ok "Repo geklont (${REPO_REF})."
fi

[[ -f "$APP_DIR/app/localdash/main.py" ]] || { msg_error "App-Quelle fehlt: app/localdash/main.py"; exit 1; }
[[ -f "$APP_DIR/web/package.json" ]] || { msg_error "App-Quelle fehlt: web/package.json"; exit 1; }

msg_info "Installiere Python-Abhängigkeiten ..."
if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/app/requirements.txt"
"$APP_DIR/venv/bin/python" -c "import fastapi, uvicorn, psutil"
msg_ok "Python-Abhängigkeiten installiert."

msg_info "Baue React-Web-UI ..."
cd "$APP_DIR/web"
npm ci --no-audit --no-fund --loglevel=error
npm run build
[[ -f "$APP_DIR/web/dist/index.html" ]] || { msg_error "Frontend-Build fehlt: web/dist/index.html"; exit 1; }
msg_ok "Web-UI gebaut (web/dist/index.html vorhanden)."
cd /

msg_info "Installiere systemd-Unit ..."
if curl -fsSL --max-time 30 -o "/etc/systemd/system/${APP}.service" "$UNIT_URL"; then
  msg_ok "Unit aus Repo geladen: $UNIT_URL"
else
  msg_warn "Unit-URL nicht erreichbar – schreibe Inline-Unit."
  cat > "/etc/systemd/system/${APP}.service" <<UNIT
[Unit]
Description=LocalDash - lokales System- und Service-Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP}
Group=${APP}
WorkingDirectory=${APP_DIR}/app
EnvironmentFile=/etc/${APP}/config.env
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=${APP_DIR}/venv/bin/uvicorn localdash.main:app --host 0.0.0.0 --port ${APP_PORT} --proxy-headers
Restart=always
RestartSec=2
TimeoutStopSec=20
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
StateDirectory=${APP}
StateDirectoryMode=0750
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
UNIT
fi

mkdir -p "/etc/${APP}"
cat > "/etc/${APP}/config.env" <<ENV
LOCALDASH_STATIC_DIR=${APP_DIR}/web/dist
ENV

chown -R "${APP}:${APP}" "$APP_DIR" "$DATA_DIR"
chmod 0750 "/etc/${APP}"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
  msg_ok "Firewall: Port ${APP_PORT}/tcp freigegeben."
fi

systemctl daemon-reload
systemctl enable --now "$APP"
sleep 2
systemctl is-active "$APP" >/dev/null || { msg_error "Service ${APP} ist nicht aktiv."; exit 1; }
msg_ok "Service ${APP} läuft (systemctl is-active = active)."
echo "Inner-Installer erfolgreich (${APP}, Port ${APP_PORT}, ${APP_DIR})."
