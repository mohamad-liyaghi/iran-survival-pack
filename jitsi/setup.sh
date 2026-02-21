#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
JITSI_DIR="$SCRIPT_DIR"

SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"

# ── Read config ──
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

# Detect if DOMAIN is a raw IP or a real domain name
is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    JITSI_HOST="${DOMAIN}"
    SUBDOMAIN_MODE=false
else
    JITSI_HOST="meet.${DOMAIN}"
    SUBDOMAIN_MODE=true
fi

echo "============================================"
echo "  Jitsi Meet Setup"
echo "  Host   : ${JITSI_HOST}"
echo "  IP     : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Subdomain DNS reminder ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    echo "DNS record required:"
    echo ""
    echo "  meet.${DOMAIN}  →  ${SERVER_IP}"
    echo ""
    read -rp "Have you added the DNS record? (Y/n): " DNS_DONE
    DNS_DONE="${DNS_DONE:-Y}"
    echo ""
fi

# ── SSL decision ──
SSL_ENABLED=false

read -rp "Generate a self-signed SSL certificate? (Y/n): " SSL_CHOICE
SSL_CHOICE="${SSL_CHOICE:-Y}"

if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
    SSL_ENABLED=true
    mkdir -p "$SHARED_CERT_DIR"

    if [ "$SUBDOMAIN_MODE" = true ]; then
        CN="*.${DOMAIN}"
        SAN="DNS:${DOMAIN},DNS:*.${DOMAIN}"
    else
        CN="${DOMAIN}"
        SAN="IP:${DOMAIN}"
    fi

    if [ ! -f "${SHARED_CERT_DIR}/cert.pem" ]; then
        echo "Generating self-signed certificate for ${CN} ..."
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "${SHARED_CERT_DIR}/key.pem" \
            -out "${SHARED_CERT_DIR}/cert.pem" \
            -subj "/C=IR/ST=Tehran/L=Tehran/O=SurvivalPack/CN=${CN}" \
            -addext "subjectAltName=${SAN}" 2>/dev/null
        echo "Certificate saved to ${SHARED_CERT_DIR}"
    else
        echo "Reusing existing cert at ${SHARED_CERT_DIR}"
    fi
fi

# ── Determine public URL ──
if [ "$SSL_ENABLED" = true ]; then
    PUBLIC_URL="https://${JITSI_HOST}"
else
    PUBLIC_URL="http://${JITSI_HOST}"
    echo ""
    echo "WARNING: Without HTTPS, browsers block microphone/camera access."
    echo ""
fi

# ── Build .env ──
echo "Configuring Jitsi environment..."
JITSI_CONFIG_DIR="${HOME}/.jitsi-meet-cfg"

cp "${JITSI_DIR}/.env.template" "${JITSI_DIR}/.env"
sed -i "s|__PUBLIC_URL__|${PUBLIC_URL}|g"    "${JITSI_DIR}/.env"
sed -i "s|__SERVER_IP__|${SERVER_IP}|g"      "${JITSI_DIR}/.env"
sed -i "s|__CONFIG__|${JITSI_CONFIG_DIR}|g"  "${JITSI_DIR}/.env"
sed -i "s|__DOMAIN__|${JITSI_HOST}|g"        "${JITSI_DIR}/.env"

# ── Generate passwords ──
echo "Generating secure passwords..."
bash "${JITSI_DIR}/gen-passwords.sh"

# ── Wipe old cached configs ──
echo "Clearing old Jitsi config cache..."
rm -rf "${JITSI_CONFIG_DIR}" 2>/dev/null || true

# ── Create config directories ──
echo "Creating Jitsi config directories..."
mkdir -p "${JITSI_CONFIG_DIR}"/{web/crontabs,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb}

# ── Set hostname + /etc/hosts ──
hostnamectl set-hostname "$JITSI_HOST" 2>/dev/null || true
if ! grep -q "$JITSI_HOST" /etc/hosts; then
    echo "${SERVER_IP} ${JITSI_HOST}" >> /etc/hosts
fi

# ── Configure Nginx ──
echo "Configuring Nginx..."

_proxy_headers() {
cat <<'EOF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        tcp_nodelay on;
EOF
}

if [ "$SUBDOMAIN_MODE" = true ]; then
    # ── Subdomain mode: own server block for meet.DOMAIN ──
    mkdir -p /etc/nginx/survival-pack.d

    if [ "$SSL_ENABLED" = true ]; then
        cat > /etc/nginx/sites-available/jitsi <<NGINX
server {
    listen 80;
    server_name ${JITSI_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${JITSI_HOST};

    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    include /etc/nginx/survival-pack.d/jitsi-locations.conf;
}
NGINX
    else
        cat > /etc/nginx/sites-available/jitsi <<NGINX
server {
    listen 80;
    server_name ${JITSI_HOST};

    include /etc/nginx/survival-pack.d/jitsi-locations.conf;
}
NGINX
    fi

    # Write locations to a reusable snippet
    cat > /etc/nginx/survival-pack.d/jitsi-locations.conf <<'NGINX'
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

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        set $conn_upgrade "";
        if ($http_upgrade = "websocket") { set $conn_upgrade "Upgrade"; }
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $conn_upgrade;
        proxy_buffering off;
        tcp_nodelay on;
    }
NGINX

    ln -sf /etc/nginx/sites-available/jitsi /etc/nginx/sites-enabled/jitsi

else
    # ── IP mode: shared survival-pack server block ──
    mkdir -p /etc/nginx/survival-pack.d

    cat > /etc/nginx/survival-pack.d/jitsi.conf <<'NGINX'
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

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        set $conn_upgrade "";
        if ($http_upgrade = "websocket") { set $conn_upgrade "Upgrade"; }
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
    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
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
fi

rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ── Start Jitsi containers ──
echo "Starting Jitsi Meet..."
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
echo "  Self-signed cert: click 'Advanced' in the"
echo "  browser warning and proceed."
fi
echo "============================================"
