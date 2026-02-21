#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

echo "============================================"
echo "  Iran Survival Pack - Server Init"
echo "============================================"
echo ""

# ── 0. Set anti-sanction DNS ──────────────────────────────────────────────────
# Shekan/403.online only bypass sanctioned foreign domains — they are NOT
# general-purpose resolvers. glibc uses at most 3 nameservers, so we use:
#   1. 10.202.10.202 (403.online)  — sanctions bypass + general resolver
#   2. 178.22.122.100 (Shekan)     — sanctions bypass fallback
#   3. 8.8.8.8 (Google)            — resolves everything else (mirror.arvancloud.com, etc.)
echo "[0/6] Setting anti-sanction DNS (403.online + Shekan + Google fallback)..."

# Replace symlink if systemd-resolved is managing it
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

cat > /etc/resolv.conf <<'EOF'
nameserver 10.202.10.202
nameserver 178.22.122.100
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF

# Also configure systemd-resolved so it survives reboots
if [ -f /etc/systemd/resolved.conf ]; then
    sed -i '/^DNS=/d; /^FallbackDNS=/d; /^DNSOverTLS=/d' /etc/systemd/resolved.conf
    cat >> /etc/systemd/resolved.conf <<'EOF'
DNS=10.202.10.202 178.22.122.100
FallbackDNS=8.8.8.8
DNSOverTLS=no
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
fi

echo "DNS set. Verifying connectivity..."
if curl -fsSL --connect-timeout 8 https://get.docker.com -o /dev/null 2>/dev/null; then
    echo "  -> get.docker.com: OK"
else
    echo "  -> WARNING: get.docker.com not reachable. Snap fallback will be used."
fi
if curl -fsSL --connect-timeout 8 https://mirror.arvancloud.com -o /dev/null 2>/dev/null; then
    echo "  -> mirror.arvancloud.com: OK"
else
    echo "  -> WARNING: mirror.arvancloud.com not reachable. Will keep existing apt sources."
fi

# ── 1. Switch APT sources to Arvan Cloud mirror ────────────────────────────────
echo "[1/6] Configuring Arvan Cloud package mirrors..."

CODENAME=$(lsb_release -sc 2>/dev/null || echo "jammy")
DISTRO=$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")

# Only switch if the mirror is actually reachable
if curl -fsSL --connect-timeout 8 "https://mirror.arvancloud.com" -o /dev/null 2>/dev/null; then
    if [ "$DISTRO" = "ubuntu" ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
        cat > /etc/apt/sources.list <<EOF
deb https://mirror.arvancloud.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirror.arvancloud.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirror.arvancloud.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb https://mirror.arvancloud.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
        echo "  -> Switched to mirror.arvancloud.com/ubuntu"
    elif [ "$DISTRO" = "debian" ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
        cat > /etc/apt/sources.list <<EOF
deb https://mirror.arvancloud.com/debian/ ${CODENAME} main contrib non-free
deb https://mirror.arvancloud.com/debian/ ${CODENAME}-updates main contrib non-free
deb https://mirror.arvancloud.com/debian-security/ ${CODENAME}-security main contrib non-free
EOF
        echo "  -> Switched to mirror.arvancloud.com/debian"
    fi
else
    echo "  -> mirror.arvancloud.com unreachable, keeping existing apt sources."
fi

# ── 2. Update system ───────────────────────────────────────────────────────────
echo "[2/6] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# ── 3. Install prerequisites ───────────────────────────────────────────────────
echo "[3/6] Installing prerequisites..."
apt-get install -y \
    curl wget gnupg gnupg2 lsb-release apt-transport-https \
    ca-certificates software-properties-common \
    jq ufw openssl snapd 2>/dev/null || \
apt-get install -y \
    curl wget gnupg lsb-release \
    ca-certificates software-properties-common \
    jq ufw openssl snapd

# ── 4. Install Docker ──────────────────────────────────────────────────────────
echo "[4/6] Installing Docker..."

if command -v docker &>/dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    DOCKER_INSTALLED=false

    # Method A: official get.docker.com (works now that DNS is set to Shekan)
    if curl -fsSL --connect-timeout 15 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        echo "Installing via get.docker.com..."
        sh /tmp/get-docker.sh && DOCKER_INSTALLED=true || true
        rm -f /tmp/get-docker.sh
    fi

    # Method B: snap (no apt repo needed — snap uses its own CDN)
    if [ "$DOCKER_INSTALLED" = false ]; then
        echo "get.docker.com failed. Installing via snap..."
        systemctl enable snapd --now 2>/dev/null || true
        sleep 3
        snap install docker && DOCKER_INSTALLED=true || true
        # snap docker needs a systemd override for group
        addgroup --system docker 2>/dev/null || true
    fi

    if ! command -v docker &>/dev/null; then
        echo "ERROR: All Docker install methods failed."
        echo "Please install Docker manually and re-run."
        exit 1
    fi
fi

# Ensure docker compose plugin is present (V2 syntax)
if ! docker compose version &>/dev/null; then
    apt-get install -y docker-compose-plugin 2>/dev/null || \
    snap install docker-compose 2>/dev/null || true
fi

# ── Configure Docker to use Arvan Cloud + focker.ir registry mirrors ──────────
echo "Configuring Docker registry mirrors..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.arvancloud.ir",
    "https://focker.ir"
  ],
  "dns": ["178.22.122.100", "10.202.10.202"]
}
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl restart docker || systemctl start docker || \
    systemctl restart snap.docker.dockerd 2>/dev/null || true
systemctl enable docker 2>/dev/null || true

# Add invoking user to docker group
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
fi

# ── 5. Install Nginx ───────────────────────────────────────────────────────────
echo "[5/6] Installing Nginx..."
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx

# ── 5.5 Firewall ──────────────────────────────────────────────────────────────
echo "Configuring firewall (ufw)..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 10000/udp
ufw allow 3478/udp
ufw allow 5349/tcp
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
echo "  Config saved → config.json"
echo "  IP     : ${SERVER_IP}"
echo "  Domain : ${DOMAIN}"
echo "============================================"
echo ""
echo "NOTE: Log out and back in for Docker group to take effect."
echo "Next: make jitsi"
