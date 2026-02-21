#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
FG_DIR="$SCRIPT_DIR"

SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"
FG_PORT=8092
SSH_PORT=2222

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    FG_HOST="${DOMAIN}"
    SUBDOMAIN_MODE=false
    SITE_URL="http://${FG_HOST}:${FG_PORT}"
else
    FG_HOST="git.${DOMAIN}"
    SUBDOMAIN_MODE=true
fi

echo "============================================"
echo "  Forgejo Git Setup"
echo "  Host : ${FG_HOST}"
echo "  IP   : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Subdomain DNS reminder ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    echo "DNS record required:"
    echo ""
    echo "  git.${DOMAIN}  →  ${SERVER_IP}"
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
        SITE_URL="https://${FG_HOST}"
    else
        SITE_URL="http://${FG_HOST}"
    fi
fi

# ── Build .env ──
echo "Configuring Forgejo environment..."
DB_PASSWORD=$(openssl rand -hex 16)

cp "${FG_DIR}/.env.template" "${FG_DIR}/.env"
sed -i "s|__SITE_URL__|${SITE_URL}|g"       "${FG_DIR}/.env"
sed -i "s|__DB_PASSWORD__|${DB_PASSWORD}|g"  "${FG_DIR}/.env"
sed -i "s|__SSH_PORT__|${SSH_PORT}|g"        "${FG_DIR}/.env"
sed -i "s|__HOST__|${FG_HOST}|g"             "${FG_DIR}/.env"
echo "SSH_PORT=${SSH_PORT}" >> "${FG_DIR}/.env"

# ── Create volume directories ──
echo "Creating data directories..."
cd "${FG_DIR}"
mkdir -p ./volumes/db ./volumes/data
chown -R 1000:1000 ./volumes/data 2>/dev/null || true

# ── Nginx ──
echo "Configuring Nginx..."

if [ "$SUBDOMAIN_MODE" = true ]; then
    if [ "$SSL_ENABLED" = true ]; then
        cat > /etc/nginx/sites-available/forgejo <<NGINX
server {
    listen 80;
    server_name ${FG_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${FG_HOST};

    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 512M;

    location / {
        proxy_pass http://127.0.0.1:3000;
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
        cat > /etc/nginx/sites-available/forgejo <<NGINX
server {
    listen 80;
    server_name ${FG_HOST};

    client_max_body_size 512M;

    location / {
        proxy_pass http://127.0.0.1:3000;
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
else
    cat > /etc/nginx/sites-available/forgejo <<NGINX
server {
    listen ${FG_PORT};
    server_name ${DOMAIN} ${SERVER_IP};

    client_max_body_size 512M;

    location / {
        proxy_pass http://127.0.0.1:3000;
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

ln -sf /etc/nginx/sites-available/forgejo /etc/nginx/sites-enabled/forgejo
nginx -t
systemctl reload nginx

# ── Firewall ──
ufw allow ${SSH_PORT}/tcp comment "Forgejo SSH" 2>/dev/null || true
if [ "$SUBDOMAIN_MODE" = true ]; then
    ufw allow 80/tcp  comment "HTTP"  2>/dev/null || true
    ufw allow 443/tcp comment "HTTPS" 2>/dev/null || true
else
    ufw allow ${FG_PORT}/tcp comment "Forgejo Web" 2>/dev/null || true
fi

# ── Start containers ──
echo "Starting Forgejo..."
cd "${FG_DIR}"
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "============================================"
echo "  Forgejo is running!"
echo ""
echo "  Web : ${SITE_URL}"
echo "  SSH : ssh://git@${FG_HOST}:${SSH_PORT}"
echo ""
echo "  Open the URL to create your admin account."
echo "  The first registered user becomes admin."
echo "============================================"
