#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Snake VPN — Turnkey Installer
#  Fully automated setup: Docker, firewall, server, camouflage page
#
#  Usage (one command on a fresh Ubuntu VPS):
#    curl -fsSL https://raw.githubusercontent.com/4eSyH/snake-vpn/main/install.sh | sudo bash
#
#  Or step-by-step:
#    wget https://raw.githubusercontent.com/4eSyH/snake-vpn/main/install.sh
#    chmod +x install.sh
#    sudo ./install.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "  ${CYAN}▸${NC} $*"; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "\n  ${RED}✗ $*${NC}\n"; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${NC}"; }
divider() { echo -e "${DIM}$(printf '%.0s─' {1..56})${NC}"; }

INSTALL_DIR="/opt/snake-vpn"
GITHUB_RELEASE="https://github.com/4eSyH/snake-vpn/releases/latest/download"
GITHUB_RAW="https://raw.githubusercontent.com/4eSyH/snake-vpn/main"

# ═══════════════════════════════════════════════════════════════════
#  PREFLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════

# Must be root
[[ $EUID -ne 0 ]] && fail "Run this script as root: sudo bash install.sh"

# Must be Ubuntu 22.04+
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        fail "This installer is designed for Ubuntu 22.04 and above.\n  Detected OS: $PRETTY_NAME\n  For other distributions, follow the manual setup guide."
    fi
    MAJOR_VER=$(echo "$VERSION_ID" | cut -d. -f1)
    if [[ "$MAJOR_VER" -lt 22 ]]; then
        fail "Ubuntu 22.04 or higher is required.\n  Detected version: $VERSION_ID"
    fi
    ok "OS: $PRETTY_NAME"
else
    fail "Cannot detect OS. This installer requires Ubuntu 22.04+."
fi

# Must be run interactively (not piped without terminal)
if [[ ! -t 0 ]]; then
    # If stdin is not a terminal, re-exec with /dev/tty
    exec < /dev/tty || fail "This installer requires interactive input.\n  Download it first: wget $GITHUB_RAW/install.sh && sudo bash install.sh"
fi

# ═══════════════════════════════════════════════════════════════════
#  WELCOME
# ═══════════════════════════════════════════════════════════════════
clear
echo ""
echo -e "${BOLD}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║                                                    ║${NC}"
echo -e "${BOLD}  ║      🐍  Snake VPN — Turnkey Installer            ║${NC}"
echo -e "${BOLD}  ║                                                    ║${NC}"
echo -e "${BOLD}  ║  This script will:                                 ║${NC}"
echo -e "${BOLD}  ║    1. Harden your server (firewall, SSH)           ║${NC}"
echo -e "${BOLD}  ║    2. Install Docker                               ║${NC}"
echo -e "${BOLD}  ║    3. Set up Snake VPN with Let's Encrypt          ║${NC}"
echo -e "${BOLD}  ║    4. Configure camouflage website                 ║${NC}"
echo -e "${BOLD}  ║    5. Give you admin credentials for Manager       ║${NC}"
echo -e "${BOLD}  ║                                                    ║${NC}"
echo -e "${BOLD}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Before starting, make sure you have:${NC}"
echo -e "  ${DIM}  • A domain name pointed to this server's IP (A record)${NC}"
echo -e "  ${DIM}  • Ports 80 and 443 available (not used by another service)${NC}"
echo ""
divider
read -rp "  Press Enter to continue or Ctrl+C to cancel..."
echo ""

# ═══════════════════════════════════════════════════════════════════
#  STEP 1: GATHER INFORMATION
# ═══════════════════════════════════════════════════════════════════
step "Step 1/5: Configuration"

# Detect server IP
SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
            hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
info "Your server IP: ${BOLD}${SERVER_IP}${NC}"
echo ""

# Domain
while true; do
    read -rp "$(echo -e "  ${CYAN}Your domain name${NC} (e.g. vpn.mydomain.com): ")" DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        warn "Domain is required. You need a domain for HTTPS certificates."
        continue
    fi
    # Quick DNS check
    RESOLVED_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
    if [[ -z "$RESOLVED_IP" ]]; then
        warn "DNS for ${DOMAIN} does not resolve yet."
        warn "Make sure you've added an A record: ${DOMAIN} -> ${SERVER_IP}"
        read -rp "$(echo -e "  ${YELLOW}Continue anyway?${NC} (y/n): ")" DNS_CONTINUE
        [[ "$DNS_CONTINUE" =~ ^[Yy] ]] && break
    elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
        warn "${DOMAIN} resolves to ${RESOLVED_IP}, but this server is ${SERVER_IP}"
        read -rp "$(echo -e "  ${YELLOW}Continue anyway?${NC} (y/n): ")" DNS_CONTINUE
        [[ "$DNS_CONTINUE" =~ ^[Yy] ]] && break
    else
        ok "${DOMAIN} -> ${RESOLVED_IP} (matches this server)"
        break
    fi
done

# Email
echo ""
read -rp "$(echo -e "  ${CYAN}Email for Let's Encrypt${NC} (e.g. admin@${DOMAIN}): ")" ACME_EMAIL
[[ -z "$ACME_EMAIL" ]] && ACME_EMAIL="admin@${DOMAIN}"
ok "Email: ${ACME_EMAIL}"

# Network interface (auto-detect, don't confuse the user)
NAT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
NAT_IFACE=${NAT_IFACE:-eth0}
ok "Network interface: ${NAT_IFACE} (auto-detected)"

# ═══════════════════════════════════════════════════════════════════
#  STEP 2: CHOOSE CAMOUFLAGE WEBSITE
# ═══════════════════════════════════════════════════════════════════
step "Step 2/5: Camouflage Website"
echo ""
echo -e "  When someone visits your server in a browser, they'll see"
echo -e "  a regular website. Choose a disguise:"
echo ""
echo -e "  ${BOLD}1)${NC}  ${MAGENTA}CloudPulse${NC}       — Cloud monitoring SaaS (default)"
echo -e "  ${BOLD}2)${NC}  ${MAGENTA}Tech Blog${NC}        — Personal engineering blog"
echo -e "  ${BOLD}3)${NC}  ${MAGENTA}IT Consulting${NC}    — Corporate IT consulting firm"
echo -e "  ${BOLD}4)${NC}  ${MAGENTA}Photography${NC}      — Photographer portfolio (dark theme)"
echo -e "  ${BOLD}5)${NC}  ${MAGENTA}Restaurant${NC}       — Farm-to-table restaurant"
echo -e "  ${BOLD}6)${NC}  ${MAGENTA}SaaS Startup${NC}     — API gateway product page"
echo -e "  ${BOLD}7)${NC}  ${MAGENTA}Design Agency${NC}    — Digital design agency"
echo ""
read -rp "$(echo -e "  ${CYAN}Choose camouflage${NC} [1-7, default 1]: ")" CAMO_CHOICE
CAMO_CHOICE=${CAMO_CHOICE:-1}

case "$CAMO_CHOICE" in
    1) CAMO_NAME="cloudpulse"   ; CAMO_SOURCE=""            ;;
    2) CAMO_NAME="blog"         ; CAMO_SOURCE="blog"        ;;
    3) CAMO_NAME="consulting"   ; CAMO_SOURCE="consulting"  ;;
    4) CAMO_NAME="photography"  ; CAMO_SOURCE="photography" ;;
    5) CAMO_NAME="restaurant"   ; CAMO_SOURCE="restaurant"  ;;
    6) CAMO_NAME="startup"      ; CAMO_SOURCE="startup"     ;;
    7) CAMO_NAME="agency"       ; CAMO_SOURCE="agency"      ;;
    *) CAMO_NAME="cloudpulse"   ; CAMO_SOURCE=""            ;;
esac
ok "Camouflage: ${CAMO_NAME}"

# ═══════════════════════════════════════════════════════════════════
#  STEP 3: HARDEN SERVER
# ═══════════════════════════════════════════════════════════════════
step "Step 3/5: Server Hardening"

# 3.1 System updates
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
ok "System updated"

# 3.2 Install essentials
info "Installing required packages..."
apt-get install -y -qq ufw curl wget openssl jq dnsutils ca-certificates > /dev/null 2>&1
ok "Packages installed"

# 3.3 Enable automatic security updates
if ! dpkg -l | grep -q unattended-upgrades; then
    apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
fi
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
ok "Automatic security updates enabled"

# 3.4 Firewall (UFW)
info "Configuring firewall..."
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
ufw allow 80/tcp comment 'HTTP (ACME)' > /dev/null 2>&1
ufw allow 443/tcp comment 'HTTPS (VPN)' > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
ok "Firewall: SSH (22), HTTP (80), HTTPS (443) — all else blocked"

# 3.5 Harden SSH
SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
    # Disable root password login (keep key-based)
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    # Disable password auth if key-based is set up
    if [[ -f ~/.ssh/authorized_keys ]] && [[ -s ~/.ssh/authorized_keys ]]; then
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
        ok "SSH: password auth disabled (you have SSH keys)"
    else
        warn "SSH: password auth kept (no SSH keys found — add keys for better security)"
    fi
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    ok "SSH hardened: root password login disabled, max 3 auth tries"
fi

# 3.6 Kernel tuning for VPN performance
cat > /etc/sysctl.d/99-snake-vpn.conf <<'SYSCTL'
# IP forwarding (required for VPN)
net.ipv4.ip_forward = 1

# Harden network stack
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Performance tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 5000
SYSCTL
sysctl --system > /dev/null 2>&1
ok "Kernel: IP forwarding enabled, network hardened, buffers optimized"

# ═══════════════════════════════════════════════════════════════════
#  STEP 4: INSTALL DOCKER & DEPLOY
# ═══════════════════════════════════════════════════════════════════
step "Step 4/5: Docker & Deployment"

# 4.1 Install Docker
if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
    systemctl enable --now docker > /dev/null 2>&1
    ok "Docker installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

if ! docker compose version &>/dev/null; then
    fail "docker compose plugin not available. Try: apt install docker-compose-plugin"
fi
ok "Docker Compose: $(docker compose version --short)"

# 4.2 Create working directory
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 4.3 Generate admin token
ADMIN_TOKEN=$(openssl rand -hex 32)

# 4.4 Create server.yaml
cat > server.yaml <<YAML
server:
  listen: ":443"
  domain: "${DOMAIN}"

tls:
  mode: "letsencrypt"
  acme_email: "${ACME_EMAIL}"
  acme_cache_dir: "/var/lib/snake-vpn/certs"

auth:
  tokens: []
  secret_path: "/api/v2/events/stream"

tunnel:
  mtu: 1400
  keepalive_interval: 30
  keepalive_timeout: 90
  padding:
    enabled: true
    min_size: 0
    max_size: 256

network:
  subnet: "10.7.0.0/24"
  server_ip: "10.7.0.1"
  dns:
    - "1.1.1.1"
    - "8.8.8.8"
  nat_interface: "${NAT_IFACE}"

camouflage:
  static_dir: "/opt/snake-vpn/web"
  index_file: "index.html"

logging:
  level: "info"
  file: ""

management:
  admin_token: "${ADMIN_TOKEN}"
  key_store_path: "/var/lib/snake-vpn/keystore.json"
YAML
chmod 600 server.yaml
ok "server.yaml created (chmod 600)"

# 4.5 Create docker-compose.yml
cat > docker-compose.yml <<'COMPOSE'
services:
  snake-vpn:
    image: ghcr.io/4esyh/snake-vpn:latest
    container_name: snake-vpn
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./server.yaml:/etc/snake-vpn/server.yaml:ro
      - ./web:/opt/snake-vpn/web:ro
      - vpn-data:/var/lib/snake-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:80/"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  vpn-data:
COMPOSE
ok "docker-compose.yml created"

# 4.6 Download camouflage website
mkdir -p "${INSTALL_DIR}/web"

if [[ -z "$CAMO_SOURCE" ]]; then
    # Default CloudPulse — download from repo
    info "Downloading camouflage: CloudPulse..."
    curl -fsSL "${GITHUB_RAW}/server/web/index.html" -o "${INSTALL_DIR}/web/index.html" 2>/dev/null || true
    curl -fsSL "${GITHUB_RAW}/server/web/style.css"  -o "${INSTALL_DIR}/web/style.css"  2>/dev/null || true
    # Fallback if download failed
    if [[ ! -s "${INSTALL_DIR}/web/index.html" ]]; then
        cat > "${INSTALL_DIR}/web/index.html" <<'FALLBACK_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CloudPulse — Cloud Monitoring</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, sans-serif; color: #1a1a2e; background: #fafafa; }
        header { background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); padding: 1rem 2rem; }
        .logo { font-size: 1.5rem; font-weight: 700; color: #4361ee; }
        .hero { text-align: center; padding: 6rem 2rem; max-width: 800px; margin: 0 auto; }
        .hero h1 { font-size: 3rem; margin-bottom: 1rem; }
        .hero p { font-size: 1.2rem; color: #666; margin-bottom: 2rem; }
        .btn { display: inline-block; padding: 0.75rem 2rem; border-radius: 8px; text-decoration: none; font-weight: 600; }
        .btn-primary { background: #4361ee; color: #fff; }
        footer { text-align: center; padding: 2rem; color: #999; }
    </style>
</head>
<body>
    <header><div class="logo">CloudPulse</div></header>
    <main>
        <section class="hero">
            <h1>Monitor Your Infrastructure in Real-Time</h1>
            <p>Comprehensive monitoring, alerting, and analytics for your cloud infrastructure.</p>
            <a href="#" class="btn btn-primary">Start Free Trial</a>
        </section>
    </main>
    <footer><p>&copy; 2024 CloudPulse Inc. All rights reserved.</p></footer>
</body>
</html>
FALLBACK_HTML
    fi
else
    info "Downloading camouflage: ${CAMO_NAME}..."
    curl -fsSL "${GITHUB_RAW}/server/web-examples/${CAMO_SOURCE}/index.html" \
        -o "${INSTALL_DIR}/web/index.html" 2>/dev/null
    if [[ ! -s "${INSTALL_DIR}/web/index.html" ]]; then
        warn "Failed to download ${CAMO_NAME} template, using default"
        curl -fsSL "${GITHUB_RAW}/server/web/index.html" -o "${INSTALL_DIR}/web/index.html" 2>/dev/null || true
        curl -fsSL "${GITHUB_RAW}/server/web/style.css"  -o "${INSTALL_DIR}/web/style.css"  2>/dev/null || true
    fi
fi
ok "Camouflage website installed"

# 4.7 Pull and start
info "Pulling Docker image (this may take a minute)..."
docker compose pull 2>&1 | tail -1
info "Starting Snake VPN..."
docker compose up -d 2>&1 | tail -1

# 4.8 Wait for container
info "Waiting for server to start..."
HEALTHY=false
for i in $(seq 1 30); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' snake-vpn 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "healthy" ]]; then
        HEALTHY=true
        break
    fi
    sleep 2
done

if $HEALTHY; then
    ok "Server is healthy and running"
else
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' snake-vpn 2>/dev/null || echo "unknown")
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
        ok "Server is running (healthcheck still warming up)"
    else
        warn "Container status: ${CONTAINER_STATUS}"
        warn "Check logs: cd ${INSTALL_DIR} && docker compose logs -f"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
#  STEP 5: SAVE CREDENTIALS & SHOW RESULTS
# ═══════════════════════════════════════════════════════════════════
step "Step 5/5: Done!"

# Save credentials
CREDS_FILE="${INSTALL_DIR}/credentials.txt"
cat > "$CREDS_FILE" <<CREDS
Snake VPN — Credentials
========================
Installed:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Domain:     ${DOMAIN}
Server IP:  ${SERVER_IP}
Camouflage: ${CAMO_NAME}

Admin Token: ${ADMIN_TOKEN}

Manager connection:
  Server URL:  https://${DOMAIN}
  Admin Token: ${ADMIN_TOKEN}

API examples:
  curl -sk https://${DOMAIN}/admin-api/${ADMIN_TOKEN}/server | jq .
  curl -sk https://${DOMAIN}/admin-api/${ADMIN_TOKEN}/keys   | jq .
CREDS
chmod 600 "$CREDS_FILE"

# Final output
echo ""
echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║                                                    ║${NC}"
echo -e "${GREEN}  ║         ✅  Snake VPN is ready!                    ║${NC}"
echo -e "${GREEN}  ║                                                    ║${NC}"
echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Server URL:${NC}    https://${DOMAIN}"
echo -e "  ${BOLD}Server IP:${NC}     ${SERVER_IP}"
echo -e "  ${BOLD}Camouflage:${NC}    ${CAMO_NAME}"
echo -e "  ${BOLD}Install dir:${NC}   ${INSTALL_DIR}"
echo ""
divider
echo ""
echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${YELLOW}║  ⚠  SAVE THIS! You will need it for Manager:   ║${NC}"
echo -e "  ${BOLD}${YELLOW}╠══════════════════════════════════════════════════╣${NC}"
echo -e "  ${BOLD}${YELLOW}║${NC}                                                  ${BOLD}${YELLOW}║${NC}"
echo -e "  ${BOLD}${YELLOW}║${NC}  Admin Token:                                    ${BOLD}${YELLOW}║${NC}"
echo -e "  ${BOLD}${YELLOW}║${NC}  ${BOLD}${ADMIN_TOKEN}${NC}"
echo -e "  ${BOLD}${YELLOW}║${NC}                                                  ${BOLD}${YELLOW}║${NC}"
echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Also saved to: ${CREDS_FILE}${NC}"
echo ""
divider
echo ""
echo -e "  ${BOLD}What to do next:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Install ${BOLD}Snake VPN Manager${NC} on your phone or PC"
echo -e "     (download from GitHub Releases)"
echo ""
echo -e "  ${CYAN}2.${NC} Open Manager and add your server:"
echo -e "     URL:   ${GREEN}https://${DOMAIN}${NC}"
echo -e "     Token: ${GREEN}${ADMIN_TOKEN}${NC}"
echo ""
echo -e "  ${CYAN}3.${NC} Create VPN keys for users (tap ${BOLD}+${NC} in Manager)"
echo ""
echo -e "  ${CYAN}4.${NC} Share the ${BOLD}svpn://${NC} link with users"
echo -e "     They paste it into ${BOLD}Snake VPN Client${NC} and connect"
echo ""
divider
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${DIM}cd ${INSTALL_DIR}${NC}"
echo -e "  docker compose logs -f          ${DIM}# view logs${NC}"
echo -e "  docker compose restart          ${DIM}# restart${NC}"
echo -e "  docker compose pull && docker compose up -d  ${DIM}# update${NC}"
echo -e "  cat credentials.txt             ${DIM}# show saved credentials${NC}"
echo ""
