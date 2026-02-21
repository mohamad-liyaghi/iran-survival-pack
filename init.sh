#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

echo "============================================"
echo "  Iran Survival Pack - Server Init"
echo "============================================"
echo ""

# ── 0. Set anti-sanction DNS ──────────────────────────────────────────────────
# 403.online and Shekan bypass sanctioned domains (docker.com, github.com).
# 8.8.8.8 is a fallback for general resolution (Iranian mirrors, etc.).
# glibc resolves nameservers in order and uses up to 3.
echo "[0/6] Setting anti-sanction DNS (403.online + Shekan + Google fallback)..."

if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

cat > /etc/resolv.conf <<'EOF'
nameserver 10.202.10.202
nameserver 178.22.122.100
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF

# Persist through reboots via systemd-resolved
if [ -f /etc/systemd/resolved.conf ]; then
    sed -i '/^DNS=/d; /^FallbackDNS=/d; /^DNSOverTLS=/d' /etc/systemd/resolved.conf
    cat >> /etc/systemd/resolved.conf <<'EOF'
DNS=10.202.10.202 178.22.122.100
FallbackDNS=8.8.8.8
DNSOverTLS=no
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
fi

# ── 1. Switch APT sources to a working Iranian mirror ─────────────────────────
echo "[1/6] Configuring package mirrors..."

CODENAME=$(lsb_release -sc 2>/dev/null || echo "noble")
DISTRO=$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")

# Ordered list of Iranian/fast mirrors — first reachable one wins
UBUNTU_MIRRORS=(
    "http://mirror-linux.runflare.com/ubuntu"
    "https://edge02.10.ir.cdn.ir/repository/ubuntu"
    "https://mirror.iranserver.com/ubuntu"
    "http://ubuntu.hostiran.ir/ubuntu"
)

DEBIAN_MIRRORS=(
    "https://edge02.10.ir.cdn.ir/repository/debian"
    "https://mirror.iranserver.com/debian"
)

pick_mirror() {
    local mirrors=("$@")
    for m in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 6 "${m}" -o /dev/null 2>/dev/null; then
            echo "$m"
            return 0
        fi
    done
    return 1
}

MIRROR_SET=false

if [ "$DISTRO" = "ubuntu" ]; then
    if MIRROR=$(pick_mirror "${UBUNTU_MIRRORS[@]}"); then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true

        # Also disable any .sources files that reference old mirrors
        find /etc/apt/sources.list.d/ -name "*.list" -o -name "*.sources" 2>/dev/null | \
            xargs grep -l "arvancloud\|archive.ubuntu.com" 2>/dev/null | \
            while read -r f; do mv "$f" "${f}.bak"; done || true

        cat > /etc/apt/sources.list <<EOF
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
        echo "  -> Using mirror: ${MIRROR}"
        MIRROR_SET=true
    fi
elif [ "$DISTRO" = "debian" ]; then
    if MIRROR=$(pick_mirror "${DEBIAN_MIRRORS[@]}"); then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
        cat > /etc/apt/sources.list <<EOF
deb ${MIRROR} ${CODENAME} main contrib non-free
deb ${MIRROR} ${CODENAME}-updates main contrib non-free
deb ${MIRROR}-security ${CODENAME}-security main contrib non-free
EOF
        echo "  -> Using mirror: ${MIRROR}"
        MIRROR_SET=true
    fi
fi

if [ "$MIRROR_SET" = false ]; then
    echo "  -> No mirror reachable. Restoring original sources..."
    if [ -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list.bak /etc/apt/sources.list
    else
        # Wipe broken arvancloud lines, fall back to official
        sed -i 's|arvancloud\.com|archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null || true
    fi
fi

# ── 2. Update system ───────────────────────────────────────────────────────────
echo "[2/6] Updating system packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ── 3. Install prerequisites ───────────────────────────────────────────────────
echo "[3/6] Installing prerequisites..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget gnupg lsb-release ca-certificates \
    software-properties-common apt-transport-https \
    jq ufw openssl

# ── 4. Install Docker ──────────────────────────────────────────────────────────
echo "[4/6] Installing Docker..."

if command -v docker &>/dev/null; then
    echo "  -> Docker already installed: $(docker --version)"
else
    DOCKER_INSTALLED=false
    install -m 0755 -d /etc/apt/keyrings

    # Method A: official Docker apt repo (download.docker.com works with Shekan DNS)
    if curl -fsSL --connect-timeout 15 \
        "https://download.docker.com/linux/${DISTRO}/gpg" \
        -o /etc/apt/keyrings/docker.asc 2>/dev/null; then

        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list

        if apt-get update 2>/dev/null && \
           DEBIAN_FRONTEND=noninteractive apt-get install -y \
               docker-ce docker-ce-cli containerd.io \
               docker-buildx-plugin docker-compose-plugin; then
            DOCKER_INSTALLED=true
            echo "  -> Docker installed via official apt repo."
        else
            rm -f /etc/apt/sources.list.d/docker.list
        fi
    fi

    # Method B: get.docker.com convenience script
    if [ "$DOCKER_INSTALLED" = false ]; then
        echo "  -> apt repo failed. Trying get.docker.com..."
        if curl -fsSL --connect-timeout 20 https://get.docker.com -o /tmp/get-docker.sh; then
            sh /tmp/get-docker.sh && DOCKER_INSTALLED=true || true
            rm -f /tmp/get-docker.sh
        fi
    fi

    # Method C: snap
    if [ "$DOCKER_INSTALLED" = false ]; then
        echo "  -> Trying snap..."
        apt-get install -y snapd 2>/dev/null || true
        systemctl enable snapd --now 2>/dev/null || true
        sleep 3
        snap install docker && DOCKER_INSTALLED=true || true
    fi

    if ! command -v docker &>/dev/null; then
        echo "ERROR: All Docker install methods failed. Install manually and re-run."
        exit 1
    fi
fi

# Ensure docker compose plugin (V2)
if ! docker compose version &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin 2>/dev/null || true
fi

# Configure registry mirrors for docker pull (Arvan + focker.ir)
echo "  -> Configuring Docker registry mirrors..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.arvancloud.ir",
    "https://focker.ir"
  ],
  "dns": ["10.202.10.202", "178.22.122.100", "8.8.8.8"]
}
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl restart docker 2>/dev/null || \
    systemctl start docker 2>/dev/null || \
    systemctl restart snap.docker.dockerd 2>/dev/null || true
systemctl enable docker 2>/dev/null || true

if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
fi

# ── 5. Install Nginx ───────────────────────────────────────────────────────────
echo "[5/6] Installing Nginx..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
systemctl enable nginx
systemctl start nginx

# ── 5.5 Firewall ──────────────────────────────────────────────────────────────
echo "  -> Configuring firewall..."
ufw allow 22/tcp  comment "SSH"
ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 10000/udp comment "Jitsi media"
ufw allow 3478/udp comment "STUN"
ufw allow 5349/tcp comment "TURN/TLS"
echo "y" | ufw enable || true

# ── 6. Save server config ──────────────────────────────────────────────────────
echo ""
echo "[6/6] Server configuration"
echo ""
read -rp "Enter your server public IP address: " SERVER_IP
read -rp "Enter your domain (press Enter to use IP): " DOMAIN
DOMAIN="${DOMAIN:-$SERVER_IP}"

cat > "$CONFIG_FILE" <<EOF
{
  "server_ip": "${SERVER_IP}",
  "domain": "${DOMAIN}"
}
EOF

echo ""
echo "============================================"
echo "  Init complete!"
echo "  Config: config.json"
echo "  IP    : ${SERVER_IP}"
echo "  Domain: ${DOMAIN}"
echo "============================================"
echo ""
echo "NOTE: Log out and back in for Docker group to take effect."
echo "Next:  make jitsi"
