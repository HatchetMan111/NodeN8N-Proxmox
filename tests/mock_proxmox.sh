#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
BIN="$TMP/bin"
STATE="$TMP/state"
mkdir -p "$BIN" "$STATE"
trap 'rm -rf "$TMP"' EXIT

# Statischer Compose-Check zuerst (Assets müssen zum Inner passen).
bash "$ROOT/tests/validate_compose.sh" || { echo "FAIL: Compose-Assets ungültig."; exit 1; }

# Repo-Aufräumen prüfen (LocalDash-Payload muss weg sein).
[[ ! -d "$ROOT/app" ]] || { echo "FAIL: app/ existiert noch."; exit 1; }
[[ ! -d "$ROOT/web" ]] || { echo "FAIL: web/ existiert noch."; exit 1; }
[[ ! -f "$ROOT/systemd/localdash.service" ]] || { echo "FAIL: localdash.service existiert noch."; exit 1; }
grep -q 'n8n' "$ROOT/README.md" || { echo "FAIL: README erwähnt n8n nicht."; exit 1; }

cat > "$BIN/pvesh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "get /cluster/nextid" ]]; then
  echo 900
fi
exit 0
STUB

cat > "$BIN/pvesm" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" && "${2:-}" == "--storage" ]]; then
  exit 0
fi
if [[ "${1:-}" == "status" ]]; then
  echo "Name Status Content Volumes"
  echo "local-lvm available rootdir 1"
fi
exit 0
STUB

cat > "$BIN/pveam" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  update) exit 0 ;;
  available) echo "debian-12-standard_12.7-1_amd64.tar.zst" ;;
  list) exit 1 ;;
  download) echo "[MOCK] pveam download $*" ;;
esac
exit 0
STUB

cat > "$BIN/pct" <<'STUB'
#!/usr/bin/env bash
STATE="${MOCK_STATE:?}"
case "${1:-}" in
  config)
    if [[ -f "$STATE/created" || -f "$STATE/vmcreated" ]]; then exit 0; else exit 1; fi
    ;;
  status)
    if [[ -f "$STATE/created" ]]; then exit 0; else exit 1; fi
    ;;
  create) echo "created" > "$STATE/created"; echo "[MOCK] pct create $*" ;;
  start) echo "[MOCK] pct start $*" ;;
  push) echo "[MOCK] pct push $*"; [[ -f "${3:-}" ]] && cat "${3:-}" ;;
  reboot) echo "[MOCK] pct reboot $*" ;;
  exec)
    shift
    guest="$1"
    shift
    [[ "${1:-}" == "--" ]] && shift
    case "${1:-}" in
      hostname) echo "10.20.30.40" ;;
      systemctl) echo "active" ;;
      curl) echo '{"status":"ok","version":"1.0.0"}' ;;
      journalctl) echo "[MOCK] journal" ;;
      *) echo "[MOCK] pct exec $guest -- $*" ;;
    esac
    ;;
  *) echo "[MOCK] pct $*" ;;
esac
exit 0
STUB

cat > "$BIN/qm" <<'STUB'
#!/usr/bin/env bash
STATE="${MOCK_STATE:?}"
case "${1:-}" in
  config)
    if [[ -f "$STATE/vmcreated" ]]; then exit 0; else exit 1; fi
    ;;
  status)
    if [[ -f "$STATE/vmcreated" ]]; then exit 0; else exit 1; fi
    ;;
  create) echo "created" > "$STATE/vmcreated"; echo "[MOCK] qm create $*" ;;
  guest)
    if [[ "${2:-}" == "cmd" ]]; then
      echo '{"result":[{"name":"eth0","ip-addresses":[{"ip-address":"10.20.30.41"}]}]}'
    elif [[ "${2:-}" == "exec" ]]; then
      if [[ "$*" == *systemctl* ]]; then echo '{"exitcode":"0","out-data":"active\n"}'; fi
      if [[ "$*" == *curl* ]]; then echo '{"exitcode":"0","out-data":"{\"status\":\"ok\"}"}'; fi
    fi
    ;;
  importdisk|set|start|reboot|stop|destroy) echo "[MOCK] qm $*" ;;
  *) echo "[MOCK] qm $*" ;;
esac
exit 0
STUB

cat > "$BIN/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo 0
  exit 0
fi
echo "uid=0(root) gid=0(root) groups=0(root)"
STUB

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$arg"; fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  if [[ "$*" == *n8n-inner.sh* && -f "${MOCK_REPO_INNER:-}" ]]; then
    cat "$MOCK_REPO_INNER" > "$out"
  else
    printf 'mock-cloud-image' > "$out"
  fi
  exit 0
fi
echo '{"status":"ok","version":"1.0.0"}'
STUB

cat > "$BIN/getent" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB

chmod +x "$BIN"/*

run_lxc_one_liner() {
  local log="$1"
  MOCK_STATE="$STATE" MOCK_REPO_INNER="$ROOT/install/n8n-inner.sh" \
    N8N_INNER="$ROOT/install/n8n-inner.sh" PATH="$BIN:$PATH" \
    bash -c "$(cat "$ROOT/install/n8n.sh")" n8n.sh --ctid 900 2>&1 | tee "$log"
}

echo "════ MOCK: Installation (LXC, Einzeiler-Modus) ════"
run_lxc_one_liner "$TMP/install.log"

echo ""
echo "════ MOCK: Idempotenz (zweiter Lauf, gleiche ID) ════"
run_lxc_one_liner "$TMP/install2.log"

echo ""
echo "════ MOCK: Reboot-Simulation ════"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct reboot 900'
echo "Docker nach Reboot:"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct exec 900 -- systemctl is-active docker'
echo "Web-UI nach Reboot:"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct exec 900 -- curl -fs http://localhost:5678/healthz'

echo ""
echo "════ MOCK: VM-Modus (Smoke) ════"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" \
  bash "$ROOT/install/n8n.sh" --ctid 901 --type vm 2>&1 | tail -n 12 || true

# ── Assertions: Lauf 1 (frischer LXC) ──────────────────────────────
LOG="$TMP/install.log"
grep -q "INSTALLATION ERFOLGREICH" "$LOG" || { echo "FAIL: Install nicht erfolgreich."; exit 1; }
grep -q "pct start" "$LOG" || {
  echo "FAIL: LXC wurde nie gestartet (pct start fehlt im Installer)."
  exit 1
}
grep -q "pct push.*n8n-inner.sh" "$LOG" || {
  echo "FAIL: Inner-Script wurde nicht in den LXC übertragen (Einzeiler-Modus)."
  exit 1
}
grep -q "DNS_SERVERS=" "$LOG" || {
  echo "FAIL: DNS_SERVERS wird nicht an den Gast übergeben (DNS-Selbstheilung)."
  exit 1
}
grep -q "DNS_PINS=" "$LOG" || {
  echo "FAIL: DNS_PINS (Host-aufgelöste IPs) werden nicht an den Gast übergeben."
  exit 1
}
grep -q "n8n-pins" "$LOG" || {
  echo "FAIL: Download-Hosts wurden nicht vom Outer-Installer in den Gast gepinnt."
  exit 1
}
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+deb\.debian\.org' "$LOG" || {
  echo "FAIL: Pins liegen nicht im Format 'IP hostname' vor (glibc ignoriert sie sonst)."
  exit 1
}
grep -q "chmod 0644 /etc/hosts" "$LOG" || {
  echo "FAIL: /etc/hosts wird nicht auf 0644 gesetzt (_apt kann es sonst nicht lesen)."
  exit 1
}
grep -q "DNS-Pins (Fallback)" "$LOG" || {
  echo "FAIL: Fallback-Pins bei IPv4-losem Host-DNS greifen nicht."
  exit 1
}
grep -q 'keyctl=1' "$LOG" || { echo "FAIL: keyctl=1 fehlt in pct create."; exit 1; }
grep -q 'download.docker.com=' "$LOG" || { echo "FAIL: Pin für download.docker.com fehlt."; exit 1; }
grep -q 'docker.n8n.io=' "$LOG" || { echo "FAIL: Pin für docker.n8n.io fehlt."; exit 1; }
grep -qE 'Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk' "$LOG" || {
  echo "FAIL: n8n-Defaults fehlen."
  exit 1
}
# Inner-Installer (wird per pct push übertragen und im Mock mitgecat't):
for needle in 'systemctl disable --now localdash' 'download.docker.com/linux/debian' \
              'N8N_ENCRYPTION_KEY' 'docker compose pull' 'docker compose up -d' \
              '/healthz'; do
  grep -qF "$needle" "$LOG" || { echo "FAIL: Inner fehlt: $needle"; exit 1; }
done
for forbidden in 'uvicorn' 'npm run build' 'fastapi' 'venv/bin/pip' '/api/health'; do
  grep -qF "$forbidden" "$LOG" && { echo "FAIL: LocalDash-Rest: $forbidden"; exit 1; } || true
done
grep -qF 'Behalte bestehende' "$LOG" || { echo "FAIL: .env-Idempotenz fehlt."; exit 1; }
grep -qF 'Kein n8n-Stack unter' "$LOG" || { echo "FAIL: Uninstall-Guard fehlt."; exit 1; }
# Outer-Verifikation + Modi:
grep -q 'http://localhost:5678/healthz' "$LOG" || { echo "FAIL: Health-Check nicht auf /healthz."; exit 1; }
grep -q 'systemctl is-active docker' "$LOG" || { echo "FAIL: Docker-Status wird nicht geprüft."; exit 1; }
grep -q -- '--uninstall' "$LOG" || { echo "FAIL: --uninstall fehlt in Summary/Modi."; exit 1; }
grep -q -- '--update' "$LOG" || { echo "FAIL: --update fehlt in Summary/Modi."; exit 1; }

# ── Assertions: Lauf 2 (Idempotenz) ────────────────────────────────
LOG2="$TMP/install2.log"
grep -q "INSTALLATION ERFOLGREICH" "$LOG2" || { echo "FAIL: Zweiter Lauf nicht erfolgreich."; exit 1; }
if grep -q "pct create" "$LOG2"; then
  echo "FAIL: Zweiter Lauf hat einen neuen CT angelegt (nicht idempotent)."
  exit 1
fi
if grep -q "pveam download" "$LOG2"; then
  echo "FAIL: Zweiter Lauf lädt das Template erneut."
  exit 1
fi

echo "MOCK_VERIFICATION_OK"
