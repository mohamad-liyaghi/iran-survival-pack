#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
MM_DIR="$SCRIPT_DIR"

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

echo "============================================"
echo "  Mattermost Chat Setup"
echo "  Domain : ${DOMAIN}/chat"
echo "  IP     : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Determine protocol from existing SSL cert ──
SSL_CERT_DIR="/etc/nginx/ssl/jitsi"
if [ -f "${SSL_CERT_DIR}/cert.pem" ]; then
    SITE_URL="https://${DOMAIN}/chat"
else
    SITE_URL="http://${DOMAIN}/chat"
fi

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

# ── Nginx: write location snippet and rebuild main config ──
echo "Configuring Nginx..."

mkdir -p /etc/nginx/survival-pack.d

cat > /etc/nginx/survival-pack.d/mattermost.conf <<'NGINX'
    # ── Mattermost (/chat) ──
    location /chat {
        proxy_pass http://127.0.0.1:8065;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        tcp_nodelay on;
        client_max_body_size 50M;
        proxy_read_timeout 600s;
    }
NGINX

# If Jitsi location snippet doesn't exist yet, create it from the old config
if [ ! -f /etc/nginx/survival-pack.d/jitsi.conf ] && \
   [ -f /etc/nginx/sites-available/jitsi ]; then
    cat > /etc/nginx/survival-pack.d/jitsi.conf <<'NGINX'
    # ── Jitsi (/) ──
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        tcp_nodelay on;
    }
NGINX
fi

# Rebuild the unified server block
if [ -f "${SSL_CERT_DIR}/cert.pem" ]; then
    cat > /etc/nginx/sites-available/survival-pack <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SSL_CERT_DIR}/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    include /etc/nginx/survival-pack.d/*.conf;
}
NGINX
else
    cat > /etc/nginx/sites-available/survival-pack <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    include /etc/nginx/survival-pack.d/*.conf;
}
NGINX
fi

ln -sf /etc/nginx/sites-available/survival-pack /etc/nginx/sites-enabled/survival-pack
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/jitsi

nginx -t
systemctl reload nginx

# ── Firewall: allow Calls port ──
ufw allow 8443/udp comment "Mattermost Calls" 2>/dev/null || true
ufw allow 8443/tcp comment "Mattermost Calls" 2>/dev/null || true

# ── Start containers ──
echo "Starting Mattermost (pulling images from docker.arvancloud.ir)..."
cd "${MM_DIR}"
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "Waiting for Mattermost to initialize (this takes ~30s)..."
sleep 10

echo ""
echo "============================================"
echo "  Mattermost is running!"
echo ""
echo "  URL : ${SITE_URL}"
echo ""
echo "  Open the URL above to create your"
echo "  first admin account."
echo "============================================"
