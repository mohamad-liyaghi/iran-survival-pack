#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
MM_DIR="$SCRIPT_DIR"

MM_PORT=8080

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

echo "============================================"
echo "  Mattermost Chat Setup"
echo "  Access: http://${DOMAIN}:${MM_PORT}"
echo "  IP    : ${SERVER_IP}"
echo "============================================"
echo ""

SITE_URL="http://${DOMAIN}:${MM_PORT}"

# ── Build .env ──
echo "Configuring Mattermost environment..."
DB_PASSWORD=$(openssl rand -hex 16)

cp "${MM_DIR}/.env.template" "${MM_DIR}/.env"
sed -i "s|__SITE_URL__|${SITE_URL}|g"         "${MM_DIR}/.env"
sed -i "s|__MM_DB_PASSWORD__|${DB_PASSWORD}|g" "${MM_DIR}/.env"

# ── Create volume directories ──
echo "Creating data directories..."
cd "${MM_DIR}"
mkdir -p ./volumes/db
mkdir -p ./volumes/app/mattermost/{config,data,logs,plugins,client/plugins,bleve-indexes}
chown -R 2000:2000 ./volumes/app/mattermost

# ── Nginx: own site on port 8080, completely separate from Jitsi ──
echo "Configuring Nginx for Mattermost (port ${MM_PORT})..."

cat > /etc/nginx/sites-available/mattermost <<NGINX
server {
    listen ${MM_PORT};
    server_name ${DOMAIN} ${SERVER_IP};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8065;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        set \$conn_upgrade "";
        if (\$http_upgrade = "websocket") {
            set \$conn_upgrade "Upgrade";
        }
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$conn_upgrade;

        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/mattermost /etc/nginx/sites-enabled/mattermost

nginx -t
systemctl reload nginx

# ── Firewall ──
echo "Opening firewall ports..."
ufw allow ${MM_PORT}/tcp  comment "Mattermost HTTP"  2>/dev/null || true
ufw allow 8445/udp        comment "Mattermost Calls" 2>/dev/null || true
ufw allow 8445/tcp        comment "Mattermost Calls" 2>/dev/null || true

# ── Start containers ──
echo "Starting Mattermost (pulling images from docker.arvancloud.ir)..."
cd "${MM_DIR}"
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "============================================"
echo "  Mattermost is running!"
echo ""
echo "  URL : ${SITE_URL}"
echo ""
echo "  Open the URL above to create your"
echo "  first admin account."
echo "============================================"
