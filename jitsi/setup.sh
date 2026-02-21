#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
JITSI_DIR="$SCRIPT_DIR"

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

echo "============================================"
echo "  Jitsi Meet Setup"
echo "  Domain : ${DOMAIN}"
echo "  IP     : ${SERVER_IP}"
echo "============================================"
echo ""

# ── SSL decision ──
SSL_ENABLED=false
SSL_CERT_DIR="/etc/nginx/ssl/jitsi"

read -rp "Generate a self-signed SSL certificate? (Y/n): " SSL_CHOICE
SSL_CHOICE="${SSL_CHOICE:-Y}"

if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
    SSL_ENABLED=true
    echo "Generating self-signed certificate (valid 10 years)..."
    mkdir -p "$SSL_CERT_DIR"
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${SSL_CERT_DIR}/key.pem" \
        -out "${SSL_CERT_DIR}/cert.pem" \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=SelfSigned/CN=${DOMAIN}" 2>/dev/null
    echo "Certificate saved to ${SSL_CERT_DIR}"
fi

# ── Determine public URL ──
if [ "$SSL_ENABLED" = true ]; then
    PUBLIC_URL="https://${DOMAIN}"
else
    PUBLIC_URL="http://${DOMAIN}"
    echo ""
    echo "WARNING: Without HTTPS, browsers will block microphone/camera access."
    echo "         Video calls will NOT work over plain HTTP."
    echo ""
fi

# ── Build .env ──
echo "Configuring Jitsi environment..."
JITSI_CONFIG_DIR="${HOME}/.jitsi-meet-cfg"

cp "${JITSI_DIR}/.env.template" "${JITSI_DIR}/.env"

sed -i "s|__PUBLIC_URL__|${PUBLIC_URL}|g"    "${JITSI_DIR}/.env"
sed -i "s|__SERVER_IP__|${SERVER_IP}|g"      "${JITSI_DIR}/.env"
sed -i "s|__CONFIG__|${JITSI_CONFIG_DIR}|g"  "${JITSI_DIR}/.env"
sed -i "s|__DOMAIN__|${DOMAIN}|g"            "${JITSI_DIR}/.env"

# ── Generate passwords ──
echo "Generating secure passwords..."
bash "${JITSI_DIR}/gen-passwords.sh"

# ── Wipe old cached configs (settings are baked on first start) ──
echo "Clearing old Jitsi config cache..."
rm -rf "${JITSI_CONFIG_DIR}" 2>/dev/null || true

# ── Create config directories ──
echo "Creating Jitsi config directories..."
mkdir -p "${JITSI_CONFIG_DIR}"/{web/crontabs,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb}

# ── Set hostname ──
hostnamectl set-hostname "$DOMAIN" 2>/dev/null || true

# Ensure /etc/hosts has the domain
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "${SERVER_IP} ${DOMAIN}" >> /etc/hosts
fi

# ── Configure Nginx (include-based — other services can append) ──
echo "Configuring Nginx reverse proxy..."

mkdir -p /etc/nginx/survival-pack.d

cat > /etc/nginx/survival-pack.d/jitsi.conf <<'NGINX'
    # ── Jitsi WebSocket — XMPP signaling (P2P + multi-party) ──
    location /xmpp-websocket {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";

        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    # ── Jitsi WebSocket — Colibri/JVB media bridge ──
    location /colibri-ws {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";

        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    # ── Jitsi BOSH (HTTP long-polling fallback for XMPP) ──
    location /http-bind {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Connection "";

        proxy_buffering off;
        tcp_nodelay on;
        proxy_read_timeout 60s;
    }

    # ── Jitsi main app (/) ──
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Correctly upgrade WebSocket connections, close for regular HTTP
        set $conn_upgrade "";
        if ($http_upgrade = "websocket") {
            set $conn_upgrade "Upgrade";
        }
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $conn_upgrade;

        proxy_buffering off;
        tcp_nodelay on;
    }
NGINX

if [ "$SSL_ENABLED" = true ]; then
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

# ── Start Jitsi containers ──
echo "Starting Jitsi Meet (pulling images from docker.arvancloud.ir)..."
cd "${JITSI_DIR}"
docker compose down 2>/dev/null || true
docker compose up -d

echo ""
echo "============================================"
echo "  Jitsi Meet is running!"
echo ""
echo "  URL : ${PUBLIC_URL}"
echo ""
if [ "$SSL_ENABLED" = true ]; then
echo "  Self-signed cert — browsers will show a"
echo "  security warning. Click 'Advanced' and"
echo "  proceed to accept it."
fi
echo "============================================"
