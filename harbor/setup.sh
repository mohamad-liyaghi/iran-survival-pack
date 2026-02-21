#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"

SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"
HARBOR_PORT=8093
HARBOR_VERSION="v2.12.2"
HARBOR_INSTALL_DIR="/opt/harbor"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip' "$CONFIG_FILE")
DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    HB_HOST="${DOMAIN}"
    SUBDOMAIN_MODE=false
    HB_URL="http://${HB_HOST}:${HARBOR_PORT}"
else
    HB_HOST="hub.${DOMAIN}"
    SUBDOMAIN_MODE=true
fi

echo "============================================"
echo "  Harbor Docker Registry Setup"
echo "  Host : ${HB_HOST}"
echo "  IP   : ${SERVER_IP}"
echo "============================================"
echo ""

# ── Subdomain DNS reminder ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    echo "DNS record required:"
    echo ""
    echo "  hub.${DOMAIN}  →  ${SERVER_IP}"
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
        HB_URL="https://${HB_HOST}"
    else
        HB_URL="http://${HB_HOST}"
    fi
fi

# ── Download Harbor installer ──
if [ ! -f "${HARBOR_INSTALL_DIR}/harbor.yml" ] || [ ! -f "${HARBOR_INSTALL_DIR}/install.sh" ]; then
    echo "Downloading Harbor ${HARBOR_VERSION}..."
    HARBOR_TAR="/tmp/harbor-online-installer-${HARBOR_VERSION}.tgz"

    if [ ! -f "$HARBOR_TAR" ]; then
        curl -fSL --connect-timeout 30 --retry 3 \
            "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-online-installer-${HARBOR_VERSION}.tgz" \
            -o "$HARBOR_TAR"
    fi

    echo "Extracting Harbor..."
    mkdir -p /opt
    tar xzf "$HARBOR_TAR" -C /opt
    echo "  -> Installed to ${HARBOR_INSTALL_DIR}"
else
    echo "Harbor already installed at ${HARBOR_INSTALL_DIR}, updating config..."
fi

# ── Generate Harbor admin password ──
HARBOR_ADMIN_PASS=$(openssl rand -hex 12)
HARBOR_DB_PASS=$(openssl rand -hex 16)
HARBOR_SECRET=$(openssl rand -hex 16)

# ── Write harbor.yml ──
echo "Configuring Harbor..."

# Harbor's internal nginx listens on this port (HTTP only, our Nginx handles SSL)
HARBOR_HTTP_PORT=8093

cat > "${HARBOR_INSTALL_DIR}/harbor.yml" <<EOF
hostname: ${HB_HOST}

http:
  port: ${HARBOR_HTTP_PORT}

# SSL is handled by our external Nginx, not Harbor's internal one
# https:
#   port: 443
#   certificate: /your/certificate/path
#   private_key: /your/private/key/path

external_url: ${HB_URL}

harbor_admin_password: ${HARBOR_ADMIN_PASS}

database:
  password: ${HARBOR_DB_PASS}
  max_idle_conns: 50
  max_open_conns: 100
  conn_max_lifetime: 5m
  conn_max_idle_time: 0

data_volume: /opt/harbor-data

trivy:
  ignore_unfixed: false
  skip_update: false
  skip_java_db_update: false
  offline_scan: false
  security_check: vuln
  insecure: false

jobservice:
  max_job_workers: 10
  job_loggers:
    - STD_OUTPUT
    - FILE
  logger_sweeper_duration: 1

notification:
  webhook_job_max_retry: 3
  webhook_job_http_client_timeout: 3

log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor

_version: 2.12.0

proxy:
  http_proxy:
  https_proxy:
  no_proxy: 127.0.0.1,localhost,.local,.internal,log,db,redis,nginx,core,portal,postgresql,jobservice,registry,registryctl,trivy-adapter,exporter
  components:
    - core
    - jobservice
    - trivy
EOF

# ── Nginx ──
echo "Configuring Nginx..."

if [ "$SUBDOMAIN_MODE" = true ]; then
    if [ "$SSL_ENABLED" = true ]; then
        cat > /etc/nginx/sites-available/harbor <<NGINX
server {
    listen 80;
    server_name ${HB_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${HB_HOST};

    ssl_certificate     ${SHARED_CERT_DIR}/cert.pem;
    ssl_certificate_key ${SHARED_CERT_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${HARBOR_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    location /v2/ {
        proxy_pass http://127.0.0.1:${HARBOR_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        chunked_transfer_encoding on;
    }
}
NGINX
    else
        cat > /etc/nginx/sites-available/harbor <<NGINX
server {
    listen 80;
    server_name ${HB_HOST};

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${HARBOR_HTTP_PORT};
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
    # IP mode: Harbor listens on its own port, Nginx just proxies
    cat > /etc/nginx/sites-available/harbor <<NGINX
server {
    listen ${HARBOR_PORT};
    server_name ${DOMAIN} ${SERVER_IP};

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${HARBOR_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX
fi

ln -sf /etc/nginx/sites-available/harbor /etc/nginx/sites-enabled/harbor
nginx -t
systemctl reload nginx

# ── Firewall ──
if [ "$SUBDOMAIN_MODE" = true ]; then
    ufw allow 80/tcp  comment "HTTP"  2>/dev/null || true
    ufw allow 443/tcp comment "HTTPS" 2>/dev/null || true
else
    ufw allow ${HARBOR_PORT}/tcp comment "Harbor" 2>/dev/null || true
fi

# ── Configure Docker to trust the registry ──
if [ "$SSL_ENABLED" = true ] && [ -f "${SHARED_CERT_DIR}/ca.crt" ]; then
    mkdir -p "/etc/docker/certs.d/${HB_HOST}"
    cp "${SHARED_CERT_DIR}/ca.crt" "/etc/docker/certs.d/${HB_HOST}/ca.crt"
    echo "  -> Configured Docker to trust ${HB_HOST} certificate."
elif [ "$SSL_ENABLED" = false ]; then
    DAEMON_JSON="/etc/docker/daemon.json"
    if [ -f "$DAEMON_JSON" ]; then
        EXISTING=$(cat "$DAEMON_JSON")
    else
        EXISTING="{}"
    fi
    INSECURE_ENTRY="${HB_HOST}:${HARBOR_PORT}"
    if ! echo "$EXISTING" | grep -q "$INSECURE_ENTRY"; then
        echo "$EXISTING" | jq --arg reg "$INSECURE_ENTRY" \
            '.["insecure-registries"] = ((.["insecure-registries"] // []) + [$reg] | unique)' \
            > "$DAEMON_JSON"
        systemctl restart docker
        echo "  -> Added ${INSECURE_ENTRY} to Docker insecure registries."
    fi
fi

# ── Run Harbor installer ──
echo "Installing Harbor (this pulls images and starts services)..."
cd "${HARBOR_INSTALL_DIR}"

# Bind Harbor to localhost only so our Nginx is the entrypoint
sed -i "s|port: ${HARBOR_HTTP_PORT}|port: 127.0.0.1:${HARBOR_HTTP_PORT}|g" harbor.yml 2>/dev/null || true

bash install.sh --with-trivy 2>&1 | tail -20

echo ""
echo "============================================"
echo "  Harbor Docker Registry is running!"
echo ""
echo "  URL      : ${HB_URL}"
echo "  Username : admin"
echo "  Password : ${HARBOR_ADMIN_PASS}"
echo ""
echo "  ── Push an image ──"
echo "  docker login ${HB_HOST}"
echo "  docker tag myimage:latest ${HB_HOST}/library/myimage:latest"
echo "  docker push ${HB_HOST}/library/myimage:latest"
echo ""
echo "  SAVE THIS PASSWORD — change it from the Harbor UI."
echo "============================================"
