#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
BIN="$TMP/bin"
STATE="$TMP/state"
mkdir -p "$BIN" "$STATE"
trap 'rm -rf "$TMP"' EXIT

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
  push) echo "[MOCK] pct push $*" ;;
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
  printf 'mock-cloud-image' > "$out"
  exit 0
fi
echo '{"status":"ok","version":"1.0.0"}'
STUB

chmod +x "$BIN"/*

echo "════ MOCK: Installation (LXC) ════"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" \
  bash "$ROOT/install/localdash.sh" --ctid 900 2>&1 | tee "$TMP/install.log"

echo ""
echo "════ MOCK: Reboot-Simulation ════"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct reboot 900'
echo "Service nach Reboot:"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct exec 900 -- systemctl is-active localdash'
echo "Web-UI nach Reboot:"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" bash -c 'pct exec 900 -- curl -fs http://localhost:8080/api/health'

echo ""
echo "════ MOCK: VM-Modus (Smoke) ════"
MOCK_STATE="$STATE" PATH="$BIN:$PATH" \
  bash "$ROOT/install/localdash.sh" --ctid 901 --type vm 2>&1 | tail -n 12 || true

grep -q "INSTALLATION ERFOLGREICH" "$TMP/install.log"
grep -q "pct start" "$TMP/install.log" || {
  echo "FAIL: LXC wurde nie gestartet (pct start fehlt im Installer)."
  exit 1
}
echo "MOCK_VERIFICATION_OK"
