#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
FB_DIR="$SCRIPT_DIR"

FB_PORT=8091

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

echo "============================================"
echo "  File Browser Setup"
echo "  Access: http://${DOMAIN}:${FB_PORT}"
echo "============================================"
echo ""

cd "${FB_DIR}"

# ── Create directories ──
mkdir -p ./data ./db ./config
chown -R 1000:1000 ./data ./db ./config 2>/dev/null || true

# ── Firewall ──
ufw allow ${FB_PORT}/tcp comment "FileBrowser" 2>/dev/null || true

# ── Start container ──
echo "Starting File Browser..."
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "Waiting for first-time init..."
sleep 5

echo ""
echo "============================================"
echo "  File Browser is running!"
echo ""
echo "  URL : http://${DOMAIN}:${FB_PORT}"
echo ""
echo "  Default login (CHANGE the password!):"
echo "    user: admin"
echo "    pass: (shown in container logs)"
echo ""
echo "  To see the generated password:"
echo "    cd sftp && docker compose logs"
echo ""
echo "  Create users in Settings > User Management"
echo "============================================"
