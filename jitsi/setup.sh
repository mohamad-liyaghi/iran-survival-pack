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

read -rp "Generate SSL certificate? (Y/n): " SSL_CHOICE
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

    # Always regenerate — ensures fresh cert with correct SAN
    echo "Generating CA + signed certificate for ${CN} ..."

    # Step 1: Create a local Root CA
    openssl genrsa -out "${SHARED_CERT_DIR}/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes \
        -key "${SHARED_CERT_DIR}/ca.key" \
        -sha256 -days 3650 \
        -out "${SHARED_CERT_DIR}/ca.crt" \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=SurvivalPack/CN=SurvivalPack Root CA" 2>/dev/null

    # Step 2: Generate server key + CSR
    openssl genrsa -out "${SHARED_CERT_DIR}/key.pem" 2048 2>/dev/null
    openssl req -new \
        -key "${SHARED_CERT_DIR}/key.pem" \
        -out "${SHARED_CERT_DIR}/server.csr" \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=SurvivalPack/CN=${CN}" 2>/dev/null

    # Step 3: Sign the server cert with the CA (with SAN)
    cat > "${SHARED_CERT_DIR}/server.ext" <<EOF
subjectAltName = ${SAN}
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
EOF
    openssl x509 -req \
        -in "${SHARED_CERT_DIR}/server.csr" \
        -CA "${SHARED_CERT_DIR}/ca.crt" \
        -CAkey "${SHARED_CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${SHARED_CERT_DIR}/cert.pem" \
        -days 3650 -sha256 \
        -extfile "${SHARED_CERT_DIR}/server.ext" 2>/dev/null

    rm -f "${SHARED_CERT_DIR}/server.csr" "${SHARED_CERT_DIR}/server.ext"
    chmod 600 "${SHARED_CERT_DIR}/ca.key" "${SHARED_CERT_DIR}/key.pem"

    echo ""
    echo "  CA cert  : ${SHARED_CERT_DIR}/ca.crt"
    echo "  Server cert: ${SHARED_CERT_DIR}/cert.pem"
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

    # Remove leftover IP-mode snippets to avoid duplicate location conflicts
    rm -f /etc/nginx/survival-pack.d/jitsi.conf
    rm -f /etc/nginx/sites-enabled/survival-pack

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

    # Strip HSTS so Chrome doesn't hard-block self-signed certs
    proxy_hide_header Strict-Transport-Security;
    add_header Strict-Transport-Security "" always;

    # Download the CA cert — install once per device to trust all services
    location = /ca.crt {
        alias ${SHARED_CERT_DIR}/ca.crt;
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition 'attachment; filename="SurvivalPackCA.crt"';
    }

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

    # Remove leftover subdomain-mode files
    rm -f /etc/nginx/survival-pack.d/jitsi-locations.conf
    rm -f /etc/nginx/sites-enabled/jitsi

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
    proxy_hide_header Strict-Transport-Security;
    add_header Strict-Transport-Security "" always;
    location = /ca.crt {
        alias ${SHARED_CERT_DIR}/ca.crt;
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition 'attachment; filename="SurvivalPackCA.crt"';
    }
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
echo "  ── Trust the certificate (do this once) ──"
echo ""
echo "  1. Open this URL in your browser:"
echo "     ${PUBLIC_URL}/ca.crt"
echo ""
echo "  2. Download and install SurvivalPackCA.crt"
echo "     macOS  : double-click → Keychain → mark as Trusted"
echo "     Windows: double-click → Install Certificate → Trusted Root CA"
echo "     Android: Settings → Security → Install from storage"
echo "     iOS    : open the file → Settings → Profile → Install"
echo ""
echo "  3. Also clear old HSTS cache in Chrome:"
echo "     chrome://net-internals/#hsts"
echo "     → Delete domain: ${JITSI_HOST}"
echo ""
echo "  After installing the CA, no more browser warnings."
fi
echo "============================================"
