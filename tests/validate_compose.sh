#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/docker/docker-compose.yml"
[[ -f "$FILE" ]] || { echo "FAIL: $FILE fehlt"; exit 1; }
for needle in 'container_name: n8n' '"5678:5678"' 'restart: unless-stopped' \
              'n8n_data:/home/node/.n8n' 'N8N_ENCRYPTION_KEY' 'healthcheck:'; do
  grep -qF "$needle" "$FILE" || { echo "FAIL: Compose fehlt: $needle"; exit 1; }
done
grep -qE '^\s{2}n8n_data:' "$FILE" || { echo "FAIL: Volume n8n_data nicht deklariert"; exit 1; }
[[ -f "$ROOT/docker/.env.example" ]] || { echo "FAIL: .env.example fehlt"; exit 1; }
grep -q '^N8N_ENCRYPTION_KEY=' "$ROOT/docker/.env.example" || { echo "FAIL: .env.example ohne Key"; exit 1; }
echo "COMPOSE_OK"
