#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
FB_DIR="$SCRIPT_DIR"

SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"
FB_PORT=8091

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    FB_HOST="${DOMAIN}"
    SUBDOMAIN_MODE=false
    FB_URL="http://${FB_HOST}:${FB_PORT}"
else
    FB_HOST="files.${DOMAIN}"
    SUBDOMAIN_MODE=true
fi

echo "============================================"
echo "  File Browser Setup"
echo "  Host : ${FB_HOST}"
echo "  IP   : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Subdomain DNS reminder ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    echo "DNS record required:"
    echo ""
    echo "  files.${DOMAIN}  →  ${SERVER_IP}"
    echo ""
    read -rp "Have you added the DNS record? (Y/n): " DNS_DONE
    DNS_DONE="${DNS_DONE:-Y}"
    echo ""
fi

# ── SSL ──
SSL_ENABLED=false
if [ -f "${SHARED_CERT_DIR}/cert.pem" ]; then
    echo "Found shared SSL certificate — reusing it."
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
        FB_URL="https://${FB_HOST}"
    else
        FB_URL="http://${FB_HOST}"
    fi
fi

# ── Create directories ──
cd "${FB_DIR}"
mkdir -p ./data ./db ./config
chown -R 1000:1000 ./data ./db ./config 2>/dev/null || true

# ── Nginx ──
echo "Configuring Nginx..."

if [ "$SUBDOMAIN_MODE" = true ]; then
    if [ "$SSL_ENABLED" = true ]; then
        cat > /etc/nginx/sites-available/filebrowser <<NGINX
server {
    listen 80;
    server_name ${FB_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${FB_HOST};

    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${FB_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX
    else
        cat > /etc/nginx/sites-available/filebrowser <<NGINX
server {
    listen 80;
    server_name ${FB_HOST};

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${FB_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX
    fi
fi

if [ "$SUBDOMAIN_MODE" = true ]; then
    ln -sf /etc/nginx/sites-available/filebrowser /etc/nginx/sites-enabled/filebrowser
    nginx -t
    systemctl reload nginx
fi

# ── Firewall ──
ufw allow ${FB_PORT}/tcp comment "FileBrowser" 2>/dev/null || true
if [ "$SUBDOMAIN_MODE" = true ]; then
    ufw allow 80/tcp  comment "HTTP"  2>/dev/null || true
    ufw allow 443/tcp comment "HTTPS" 2>/dev/null || true
fi

# ── Start container ──
echo "Starting File Browser..."
docker compose down 2>/dev/null || true
docker compose up -d

sleep 5

echo ""
echo "============================================"
echo "  File Browser is running!"
echo ""
echo "  URL : ${FB_URL}"
echo ""
echo "  Default login: admin / (check logs below)"
echo "  Change the password after first login!"
echo ""
echo "  Manage users: Settings → User Management"
echo "============================================"
echo ""
docker compose logs filebrowser 2>&1 | grep -i "password\|admin" | tail -5 || true
