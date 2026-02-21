#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
MM_DIR="$SCRIPT_DIR"

SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"
MM_PORT=8090

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    MM_HOST="${DOMAIN}"
    SUBDOMAIN_MODE=false
    SITE_URL="http://${MM_HOST}:${MM_PORT}"
else
    MM_HOST="chat.${DOMAIN}"
    SUBDOMAIN_MODE=true
fi

echo "============================================"
echo "  Mattermost Chat Setup"
echo "  Host : ${MM_HOST}"
echo "  IP   : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Subdomain DNS reminder ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    echo "DNS record required:"
    echo ""
    echo "  chat.${DOMAIN}  →  ${SERVER_IP}"
    echo ""
    read -rp "Have you added the DNS record? (Y/n): " DNS_DONE
    DNS_DONE="${DNS_DONE:-Y}"
    echo ""
fi

# ── SSL ──
SSL_ENABLED=false
if [ -f "${SHARED_CERT_DIR}/cert.pem" ]; then
    echo "Found shared SSL certificate from Jitsi setup — reusing it."
    SSL_ENABLED=true
elif [ "$SUBDOMAIN_MODE" = true ]; then
    read -rp "Generate a self-signed SSL certificate? (Y/n): " SSL_CHOICE
    SSL_CHOICE="${SSL_CHOICE:-Y}"
    if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
        SSL_ENABLED=true
        mkdir -p "$SHARED_CERT_DIR"
        echo "Generating self-signed certificate for *.${DOMAIN} ..."
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${SHARED_CERT_DIR}/key.pem" \
            -out "${SHARED_CERT_DIR}/cert.pem" \
            -subj "/C=IR/ST=Tehran/L=Tehran/O=SurvivalPack/CN=*.${DOMAIN}" \
            -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" 2>/dev/null
    fi
fi

if [ "$SUBDOMAIN_MODE" = true ]; then
    if [ "$SSL_ENABLED" = true ]; then
        SITE_URL="https://${MM_HOST}"
    else
        SITE_URL="http://${MM_HOST}"
    fi
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

# ── Nginx ──
echo "Configuring Nginx..."

if [ "$SUBDOMAIN_MODE" = true ]; then
    if [ "$SSL_ENABLED" = true ]; then
        cat > /etc/nginx/sites-available/mattermost <<NGINX
server {
    listen 80;
    server_name ${MM_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${MM_HOST};

    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8065;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        set \$conn_upgrade "";
        if (\$http_upgrade = "websocket") { set \$conn_upgrade "Upgrade"; }
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$conn_upgrade;
        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
    else
        cat > /etc/nginx/sites-available/mattermost <<NGINX
server {
    listen 80;
    server_name ${MM_HOST};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:8065;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        set \$conn_upgrade "";
        if (\$http_upgrade = "websocket") { set \$conn_upgrade "Upgrade"; }
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$conn_upgrade;
        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
    fi
else
    # IP mode — port-based
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
        if (\$http_upgrade = "websocket") { set \$conn_upgrade "Upgrade"; }
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$conn_upgrade;
        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
fi

ln -sf /etc/nginx/sites-available/mattermost /etc/nginx/sites-enabled/mattermost
nginx -t
systemctl reload nginx

# ── Firewall ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    ufw allow 80/tcp  comment "HTTP"  2>/dev/null || true
    ufw allow 443/tcp comment "HTTPS" 2>/dev/null || true
else
    ufw allow ${MM_PORT}/tcp comment "Mattermost" 2>/dev/null || true
fi
ufw allow 8445/udp comment "Mattermost Calls" 2>/dev/null || true
ufw allow 8445/tcp comment "Mattermost Calls" 2>/dev/null || true

# ── Start containers ──
echo "Starting Mattermost..."
cd "${MM_DIR}"
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "============================================"
echo "  Mattermost is running!"
echo ""
echo "  URL : ${SITE_URL}"
echo ""
echo "  Open the URL to create your admin account."
echo "============================================"
