#!/usr/bin/env bash
# Gets a real Let's Encrypt wildcard certificate using acme.sh + DNS-01.
# DNS-01 works from Iran — Let's Encrypt validates a TXT record in your DNS,
# it never connects to your server, so blocks/sanctions don't matter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/config.json"
SHARED_CERT_DIR="/etc/nginx/ssl/survival-pack"
ACME_HOME="/root/.acme.sh"

# ── Read config ──────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json not found. Run 'make init' first."
    exit 1
fi

DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")

is_ip() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

if is_ip "$DOMAIN"; then
    echo "ERROR: Your config has a plain IP (${DOMAIN})."
    echo "       Let's Encrypt only issues certs for domain names."
    echo "       Re-run 'make init' and provide a domain name instead."
    exit 1
fi

echo "============================================"
echo "  Free SSL Certificate (Let's Encrypt)"
echo "  Domain : ${DOMAIN}"
echo "  Covers : ${DOMAIN}  +  *.${DOMAIN}"
echo "============================================"
echo ""
echo "How this works:"
echo "  - Uses DNS-01 challenge — no server access needed from Let's Encrypt"
echo "  - Works from Iran servers (no blocking/sanctions issue)"
echo "  - You add one TXT record to your DNS panel, that's it"
echo ""

# ── Install acme.sh if missing ───────────────────────────────────────────────
if [ ! -f "${ACME_HOME}/acme.sh" ]; then
    echo "Installing acme.sh..."
    if ! curl -fsSL https://get.acme.sh | bash -s -- \
        --home "${ACME_HOME}" \
        --accountemail "admin@${DOMAIN}" 2>&1; then
        # Fallback: download directly if pipe fails
        curl -fsSL -o /tmp/acme.sh.zip \
            "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.zip"
        cd /tmp
        unzip -q acme.sh.zip
        cd acme.sh-master
        bash acme.sh --install --home "${ACME_HOME}" \
            --accountemail "admin@${DOMAIN}"
        cd "${SCRIPT_DIR}"
    fi
    echo "  -> acme.sh installed."
fi

ACME="${ACME_HOME}/acme.sh --home ${ACME_HOME}"

# ── DNS provider selection ───────────────────────────────────────────────────
echo "Choose your DNS provider:"
echo "  1) Cloudflare (automatic — recommended, needs API token)"
echo "  2) Manual (you add the TXT record yourself in your DNS panel)"
echo ""
read -rp "Enter 1 or 2: " DNS_CHOICE

case "$DNS_CHOICE" in
1)
    echo ""
    echo "Get your token at: https://dash.cloudflare.com/profile/api-tokens"
    echo "  Required permission: Zone → DNS → Edit  (for zone: ${DOMAIN})"
    echo ""
    read -rp "Cloudflare API Token: " CF_TOKEN
    if [ -z "$CF_TOKEN" ]; then
        echo "ERROR: token cannot be empty."
        exit 1
    fi
    export CF_Token="$CF_TOKEN"

    echo ""
    echo "Requesting certificate from Let's Encrypt..."
    $ACME --issue \
        --dns dns_cf \
        --server letsencrypt \
        -d "${DOMAIN}" \
        -d "*.${DOMAIN}" \
        --keylength 2048
    ;;
2)
    echo ""
    echo "Manual DNS challenge:"
    echo "  acme.sh will show you a TXT record value."
    echo "  Add it to your DNS panel, then press Enter here to continue."
    echo ""

    # First run: get TXT record value
    $ACME --issue \
        --dns \
        --server letsencrypt \
        -d "${DOMAIN}" \
        -d "*.${DOMAIN}" \
        --keylength 2048 \
        --yes-I-know-dns-manual-mode-enough-go-ahead-pleasegive-it-to-me \
        2>&1 | tee /tmp/acme_dns_out.txt || true

    echo ""
    echo "==========================================================="
    echo "  Add the TXT record(s) shown above to your DNS panel."
    echo "  Usually under: _acme-challenge.${DOMAIN}"
    echo ""
    echo "  Wait at least 2 minutes for DNS to propagate, then:"
    echo "==========================================================="
    read -rp "Press Enter when the DNS record is live: "

    # Second run: verify and issue
    $ACME --renew \
        --server letsencrypt \
        -d "${DOMAIN}" \
        -d "*.${DOMAIN}" \
        --yes-I-know-dns-manual-mode-enough-go-ahead-pleasegive-it-to-me
    ;;
*)
    echo "ERROR: invalid choice."
    exit 1
    ;;
esac

# ── Install the cert to Nginx location ──────────────────────────────────────
echo ""
echo "Installing certificate to Nginx..."
mkdir -p "$SHARED_CERT_DIR"

# acme.sh --install-cert copies the cert and calls our reload hook
$ACME --install-cert \
    -d "${DOMAIN}" \
    -d "*.${DOMAIN}" \
    --key-file   "${SHARED_CERT_DIR}/key.pem" \
    --cert-file  "${SHARED_CERT_DIR}/cert.pem" \
    --ca-file    "${SHARED_CERT_DIR}/chain.pem" \
    --fullchain-file "${SHARED_CERT_DIR}/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"

# Remove the old self-signed CA cert so browsers stop seeing it
rm -f "${SHARED_CERT_DIR}/ca.crt" "${SHARED_CERT_DIR}/ca.key" "${SHARED_CERT_DIR}/ca.srl"

chmod 600 "${SHARED_CERT_DIR}/key.pem"

# ── Update Nginx: remove HSTS suppression headers (not needed with real cert) ─
# Now that we have a real cert, HSTS is fine to keep (or just remove the override)
for CONF in /etc/nginx/sites-available/jitsi \
            /etc/nginx/sites-available/mattermost \
            /etc/nginx/sites-available/filebrowser; do
    if [ -f "$CONF" ]; then
        # Remove the lines that suppressed HSTS for self-signed workaround
        sed -i '/proxy_hide_header Strict-Transport-Security;/d' "$CONF" 2>/dev/null || true
        sed -i '/add_header Strict-Transport-Security "" always;/d' "$CONF" 2>/dev/null || true
        # Remove the /ca.crt endpoint (no longer needed)
        sed -i '/location = \/ca\.crt/,/^    }/d' "$CONF" 2>/dev/null || true
    fi
done

nginx -t && systemctl reload nginx

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Certificate installed successfully!"
echo ""
echo "  Valid for : ${DOMAIN}  and  *.${DOMAIN}"
echo "  Expires   : 90 days (auto-renews via cron)"
echo ""
echo "  All services now have a trusted green lock:"
echo "    https://meet.${DOMAIN}"
echo "    https://chat.${DOMAIN}"
echo "    https://files.${DOMAIN}"
echo ""
echo "  No certificate installation needed on devices."
echo "  Clear Chrome HSTS once:"
echo "    chrome://net-internals/#hsts → Delete: ${DOMAIN}"
echo "============================================"
