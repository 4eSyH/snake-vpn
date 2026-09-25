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
#
#  Relay in a permitted network, VPN server elsewhere:
#    sudo bash install.sh --relay --target=vpn.example.com:3389
#
#  Re-running is safe: an existing server.yaml (and its admin token) is
#  never regenerated, and firewall rules are only added, never reset.
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

# ─── Non-interactive mode (CLI arguments) ───
# Every option accepts both "--opt value" and "--opt=value".
ARG_DOMAIN=""
ARG_EMAIL=""
ARG_AUTO=false
ARG_RELAY=false
ARG_TARGET=""
ARG_PORT=""
ARG_LISTEN_EXTRA=""
ARG_TURN_UDP=false
ARG_UPDATE=false
ARG_STATUS=false
ARG_UPSTREAM_PIN=""
ARG_UPSTREAM_CA=""
ARG_INSECURE_UPSTREAM=false

usage() {
    cat <<'USAGE'
Usage:
  Install / re-run a VPN server:
    sudo bash install.sh [--domain DOMAIN] [--email EMAIL] [--auto]

  Install / re-run a relay (dumb TCP proxy in front of a VPN server elsewhere):
    sudo bash install.sh --relay --target=HOST:PORT [--port N] [--domain DOMAIN]

  Upgrade an existing installation in place (config and firewall untouched):
    sudo bash install.sh --update

  Verify a running installation:
    sudo bash install.sh --status

Options:
  --domain DOMAIN     Domain name pointed to this server (A record).
                      VPN server: required, used for Let's Encrypt.
                      Relay: optional, switches the relay to TLS-terminating mode.
  --email  EMAIL      Email for Let's Encrypt (default: admin@DOMAIN)
  --relay              Install as a relay instead of a VPN server
  --target HOST:PORT   Relay only: address of the real VPN server (required)
  --port N             Port to listen on (default 3389)
  --listen-extra N     Publish a second VPN port (server.listen_extra)
  --turn-udp           Publish UDP 56000 for the whitelist/TURN bypass
                       (on a relay this needs --domain: the TURN receiver only
                       runs on a TLS-terminating relay)
  --update             Pull a new image and restart; changes nothing else
  --status             Print deployment status and exit
  --auto               Non-interactive mode, skip all confirmations

TLS relay only (--relay --domain) — how the relay verifies the VPN server:
  --upstream-pin HEX   SHA-256 of the VPN server's certificate. When none of
                       these three is given, the installer reads it itself.
  --upstream-ca FILE   PEM the VPN server's certificate must chain to
  --insecure-upstream  Do not verify the VPN server's certificate (old behaviour)

Examples:
  sudo bash install.sh --domain vpn.example.com --auto
  sudo bash install.sh --relay --target=vpn.example.com:3389
  sudo bash install.sh --relay --target=vpn.example.com:3389 --domain=relay.example.com --turn-udp
  sudo bash install.sh --update
USAGE
}

# Reads the value of an option that was given as "--opt value".
need_value() {
    [[ -n "${2:-}" ]] || { echo "Option $1 requires a value"; exit 1; }
    echo "$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain=*)       ARG_DOMAIN="${1#*=}";       shift ;;
        --domain)         ARG_DOMAIN=$(need_value "$1" "${2:-}"); shift 2 ;;
        --email=*)        ARG_EMAIL="${1#*=}";        shift ;;
        --email)          ARG_EMAIL=$(need_value "$1" "${2:-}");  shift 2 ;;
        --target=*)       ARG_TARGET="${1#*=}";       shift ;;
        --target)         ARG_TARGET=$(need_value "$1" "${2:-}"); shift 2 ;;
        --port=*)         ARG_PORT="${1#*=}";         shift ;;
        --port)           ARG_PORT=$(need_value "$1" "${2:-}");   shift 2 ;;
        --listen-extra=*) ARG_LISTEN_EXTRA="${1#*=}"; shift ;;
        --listen-extra)   ARG_LISTEN_EXTRA=$(need_value "$1" "${2:-}"); shift 2 ;;
        --upstream-pin=*) ARG_UPSTREAM_PIN="${1#*=}"; shift ;;
        --upstream-pin)   ARG_UPSTREAM_PIN=$(need_value "$1" "${2:-}"); shift 2 ;;
        --upstream-ca=*)  ARG_UPSTREAM_CA="${1#*=}";  shift ;;
        --upstream-ca)    ARG_UPSTREAM_CA=$(need_value "$1" "${2:-}");  shift 2 ;;
        --insecure-upstream) ARG_INSECURE_UPSTREAM=true; shift ;;
        --relay)          ARG_RELAY=true;    shift ;;
        --turn-udp)       ARG_TURN_UDP=true; shift ;;
        --update)         ARG_UPDATE=true;   shift ;;
        --status)         ARG_STATUS=true;   shift ;;
        --auto)           ARG_AUTO=true;     shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1"; echo "Run 'bash install.sh --help' for usage."; exit 1 ;;
    esac
done

# A relay never has anything to ask about, so it is always non-interactive.
$ARG_RELAY && ARG_AUTO=true

# The server serves /healthz on this loopback address inside the container. It is
# deliberately never published: a publicly reachable health endpoint fingerprints
# the host and defeats the protocol disguise. Change it with the server's
# -health-addr flag if 9977 is taken.
HEALTH_URL="http://127.0.0.1:9977/healthz"

LISTEN_PORT="${ARG_PORT:-3389}"
if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || (( LISTEN_PORT < 1 || LISTEN_PORT > 65535 )); then
    echo "Invalid --port: $LISTEN_PORT"; exit 1
fi
if [[ -n "$ARG_LISTEN_EXTRA" ]]; then
    ARG_LISTEN_EXTRA="${ARG_LISTEN_EXTRA#:}"
    if ! [[ "$ARG_LISTEN_EXTRA" =~ ^[0-9]+$ ]] || (( ARG_LISTEN_EXTRA < 1 || ARG_LISTEN_EXTRA > 65535 )); then
        echo "Invalid --listen-extra: $ARG_LISTEN_EXTRA"; exit 1
    fi
fi
if [[ -n "$ARG_TARGET" ]] && ! $ARG_RELAY; then
    echo "--target is only meaningful together with --relay"; exit 1
fi

# ─── Relay -> VPN server trust anchor ───
# A TLS-terminating relay decrypts client traffic and re-encrypts it towards the
# VPN server, so an unverified upstream is a man-in-the-middle seat. Everything
# here is checked before anything on the host is touched, so a typo costs
# nothing — rather than surfacing from the server's own -check after the box has
# already been provisioned.

# Prints a SHA-256 fingerprint the way the server wants it: 64 lowercase hex
# characters. Accepts bare hex, colon-separated hex and a "sha256:" prefix.
normalize_pin() {
    local p="${1,,}"
    p="${p#sha256:}"
    p="${p//:/}"
    [[ "$p" =~ ^[0-9a-f]{64}$ ]] || return 1
    echo "$p"
}

# True when the target's certificate chain and hostname verify against the
# system trust store, i.e. it is a real (Let's Encrypt) certificate.
upstream_chain_verifies() {
    local host="$1" port="$2"
    command -v openssl &>/dev/null || return 1
    timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" \
        -verify_hostname "$host" -verify_return_error -verify 5 </dev/null >/dev/null 2>&1
}

# SHA-256 of the target's leaf certificate, for relay.upstream_pin_sha256.
fetch_cert_pin() {
    local host="$1" port="$2" fp
    command -v openssl &>/dev/null || return 1
    fp=$(timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" </dev/null 2>/dev/null \
         | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    normalize_pin "${fp#*=}"
}

UPSTREAM_PIN=""
if [[ -n "$ARG_UPSTREAM_PIN" ]]; then
    UPSTREAM_PIN=$(normalize_pin "$ARG_UPSTREAM_PIN") || {
        echo "--upstream-pin must be a SHA-256 fingerprint: 64 hex characters, colons allowed. Got '${ARG_UPSTREAM_PIN}'."
        echo "Read it off the VPN server with:"
        echo "  openssl s_client -connect HOST:PORT </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256"
        exit 1
    }
fi
if [[ -n "$ARG_UPSTREAM_PIN" && -n "$ARG_UPSTREAM_CA" ]]; then
    echo "--upstream-pin and --upstream-ca both verify the same hop — pass only one."; exit 1
fi
if $ARG_INSECURE_UPSTREAM && [[ -n "${ARG_UPSTREAM_PIN}${ARG_UPSTREAM_CA}" ]]; then
    echo "--insecure-upstream turns off exactly the verification --upstream-pin/--upstream-ca configure — pass only one."; exit 1
fi
if [[ -n "$ARG_UPSTREAM_CA" && ! -r "$ARG_UPSTREAM_CA" ]]; then
    echo "--upstream-ca: cannot read '${ARG_UPSTREAM_CA}'"; exit 1
fi
if [[ -n "${ARG_UPSTREAM_PIN}${ARG_UPSTREAM_CA}" ]] || $ARG_INSECURE_UPSTREAM; then
    if ! $ARG_RELAY || [[ -z "$ARG_DOMAIN" ]]; then
        echo "--upstream-pin / --upstream-ca / --insecure-upstream apply to a TLS-terminating relay only."
        echo "Add --relay --domain=RELAY_HOSTNAME, or drop them: a transparent relay forwards bytes"
        echo "and never opens a TLS connection of its own."
        exit 1
    fi
fi
# The TURN receiver is started from the TLS relay path only, so publishing
# 56000/udp on a transparent relay would open a port nothing ever binds.
if $ARG_RELAY && $ARG_TURN_UDP && [[ -z "$ARG_DOMAIN" ]]; then
    echo "--turn-udp on a relay requires --domain: the TURN receiver only runs on a TLS-terminating relay."
    echo "Add --domain=RELAY_HOSTNAME, or drop --turn-udp and run the whitelist bypass on the VPN server itself."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════
#  PREFLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════

# Must be root
[[ $EUID -ne 0 ]] && fail "Run this script as root: sudo bash install.sh"

# ─── Helpers shared by the install, update and status paths ───

# Existing deployment, if any. Everything below treats it as read-only state:
# the admin token and any hand-added config keys must survive a re-run.
IS_UPGRADE=false
EXISTING_MODE=""
if [[ -f "${INSTALL_DIR}/server.yaml" ]]; then
    IS_UPGRADE=true
    if awk '/^relay:/{r=1;next} /^[^[:space:]#]/{r=0} r && /enabled:[[:space:]]*true/{f=1} END{exit !f}' \
           "${INSTALL_DIR}/server.yaml"; then
        EXISTING_MODE="relay"
    else
        EXISTING_MODE="server"
    fi
fi

# Reads a top-level-ish scalar out of the deployed server.yaml. Good enough for
# the flat keys this installer writes; anything more needs a real YAML parser.
read_yaml_value() {
    local key="$1" file="${2:-${INSTALL_DIR}/server.yaml}"
    [[ -f "$file" ]] || return 0
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$file" \
        | head -1 | sed 's/[[:space:]]*$//'
}

# TCP reachability probe that does not need nc installed.
probe_tcp() {
    local host="$1" port="$2"
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

show_status() {
    step "Snake VPN status"
    if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        fail "No installation found in ${INSTALL_DIR}."
    fi
    cd "$INSTALL_DIR"

    local mode="${EXISTING_MODE:-unknown}"
    info "Install dir:  ${INSTALL_DIR}"
    info "Mode:         ${mode}"

    local state
    state=$(docker inspect --format='{{.State.Status}}' "$(docker compose ps -q snake-vpn 2>/dev/null)" 2>/dev/null || echo "not running")
    if [[ "$state" == "running" ]]; then
        ok "Container:    running"
    else
        warn "Container:    ${state}"
    fi

    # The server validates its own config; this is the authoritative check.
    if docker compose exec -T snake-vpn snake-vpn -config /etc/snake-vpn/server.yaml -check 2>&1 | sed 's/^/    /'; then
        ok "Config:       valid"
    else
        warn "Config:       validation failed (see above)"
    fi

    local listen port
    listen=$(read_yaml_value listen)
    port="${listen#:}"
    port="${port:-3389}"
    if probe_tcp 127.0.0.1 "$port"; then
        ok "Port ${port}:   accepting connections"
    else
        warn "Port ${port}:   NOT accepting connections"
    fi

    local health
    if health=$(docker compose exec -T snake-vpn wget -q -T 3 -O - "$HEALTH_URL" 2>/dev/null); then
        ok "Health:       200 from ${HEALTH_URL}"
        echo "    ${health}"
    else
        warn "Health:       ${HEALTH_URL} did not return 200 (503 = certificate due for renewal, or the TUN router went silent)"
    fi

    if [[ "$mode" == "relay" ]]; then
        local target thost tport
        target=$(read_yaml_value target)
        thost="${target%:*}"; tport="${target##*:}"
        if [[ -n "$thost" && -n "$tport" ]] && probe_tcp "$thost" "$tport"; then
            ok "Upstream:     ${target} reachable"
        else
            warn "Upstream:     ${target} NOT reachable — clients will fail"
        fi
    fi

    echo ""
    info "Recent startup lines:"
    docker compose logs --tail 200 2>/dev/null \
        | grep -E "server listening|listener started|relay mode|relay: upstream|management API registered|turn_receiver: listening|config:" \
        | tail -12 | sed 's/^/    /' || true
    echo ""
}

if $ARG_STATUS; then
    command -v docker &>/dev/null || fail "Docker is not installed — nothing to check."
    show_status
    exit 0
fi

# ─── Upgrade in place: new image, same config, same firewall ───
if $ARG_UPDATE; then
    step "Updating Snake VPN"
    command -v docker &>/dev/null || fail "Docker is not installed. Run the installer without --update first."
    [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || fail "No installation found in ${INSTALL_DIR}. Run the installer without --update first."
    cd "$INSTALL_DIR"

    STAMP=$(date +%F-%H%M%S)
    cp -a server.yaml "server.yaml.bak.${STAMP}" 2>/dev/null && ok "Config backed up: server.yaml.bak.${STAMP}"
    # The service name is 'snake-vpn' in both the server and the relay compose file.
    if docker compose cp snake-vpn:/var/lib/snake-vpn/keystore.json "./keystore-${STAMP}.json" &>/dev/null; then
        ok "Keystore backed up: keystore-${STAMP}.json"
    else
        info "No keystore to back up (relay mode, or the server never issued a key)"
    fi

    info "Pulling the latest image..."
    docker compose pull 2>&1 | tail -1
    info "Restarting..."
    docker compose up -d 2>&1 | tail -1
    ok "Updated. Config and firewall rules were not touched."
    show_status
    exit 0
fi

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

# Must be run interactively (or in --auto mode)
if ! $ARG_AUTO && [[ ! -t 0 ]]; then
    # If stdin is not a terminal, re-exec with /dev/tty
    exec < /dev/tty || fail "This installer requires interactive input.\n  Download it first: wget $GITHUB_RAW/install.sh && sudo bash install.sh\n  Or use: sudo bash install.sh --domain vpn.example.com --auto"
fi

# Validate mode-specific required args
if $ARG_RELAY; then
    [[ -n "$ARG_TARGET" ]] || fail "--relay requires --target=HOST:PORT (the address of your real VPN server).\n  Example: sudo bash install.sh --relay --target=vpn.example.com:3389"
    TARGET_HOST="${ARG_TARGET%:*}"
    TARGET_PORT="${ARG_TARGET##*:}"
    if [[ "$ARG_TARGET" != *:* ]] || [[ -z "$TARGET_HOST" ]] || ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] \
       || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
        fail "--target must be HOST:PORT, got '${ARG_TARGET}'.\n  Example: --target=vpn.example.com:3389"
    fi
    if [[ "$IS_UPGRADE" == true && "$EXISTING_MODE" == "server" ]]; then
        fail "${INSTALL_DIR}/server.yaml is a VPN server config, not a relay.\n  Refusing to convert it. Move it aside first if that is really what you want."
    fi
elif $ARG_AUTO && [[ -z "$ARG_DOMAIN" ]] && ! $IS_UPGRADE; then
    fail "--auto mode requires --domain. Usage: sudo bash install.sh --domain vpn.example.com --auto"
elif [[ "$IS_UPGRADE" == true && "$EXISTING_MODE" == "relay" ]]; then
    fail "${INSTALL_DIR}/server.yaml is a relay config.\n  Re-run with --relay --target=HOST:PORT, or with --update to just pull a new image."
fi

# ═══════════════════════════════════════════════════════════════════
#  WELCOME
# ═══════════════════════════════════════════════════════════════════
if ! $ARG_AUTO; then
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
echo -e "${BOLD}  ║    4. Give you admin credentials for Manager       ║${NC}"
echo -e "${BOLD}  ║                                                    ║${NC}"
echo -e "${BOLD}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Before starting, make sure you have:${NC}"
echo -e "  ${DIM}  • A domain name pointed to this server's IP (A record)${NC}"
echo -e "  ${DIM}  • Ports 80 and 3389 available (not used by another service)${NC}"
echo ""
divider
read -rp "  Press Enter to continue or Ctrl+C to cancel..."
echo ""
fi  # end of !$ARG_AUTO welcome block

# ═══════════════════════════════════════════════════════════════════
#  STEP 1: GATHER INFORMATION
# ═══════════════════════════════════════════════════════════════════
step "Step 1/4: Configuration"

# Detect server IP
SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || \
            hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
info "Your server IP: ${BOLD}${SERVER_IP}${NC}"
echo ""

$IS_UPGRADE && ok "Existing installation detected in ${INSTALL_DIR} — nothing will be overwritten"

if $ARG_RELAY; then
    # Relay: no domain, no certificates, no keys. Just a listen port and a target.
    DOMAIN="$ARG_DOMAIN"
    ACME_EMAIL="${ARG_EMAIL:-admin@${DOMAIN}}"
    if [[ -n "$DOMAIN" ]]; then
        RELAY_MODE="tls"
        ok "Relay mode: TLS-terminating (domain ${DOMAIN})"
        warn "TLS mode makes this relay decrypt and re-encrypt client traffic."
        warn "Only use it if you control this host; otherwise drop --domain."
    else
        RELAY_MODE="transparent"
        ok "Relay mode: transparent TCP proxy (no TLS, no keys, no decryption)"
    fi
    ok "Listen port: ${LISTEN_PORT}"
    ok "Upstream VPN server: ${ARG_TARGET}"

    info "Probing ${ARG_TARGET} from this host..."
    if probe_tcp "$TARGET_HOST" "$TARGET_PORT"; then
        ok "Upstream reachable"
    else
        warn "Upstream ${ARG_TARGET} is NOT reachable from here."
        warn "Check the address, the VPN server's firewall, and that it is running."
        warn "Installation continues — the relay recovers on its own once it comes back."
    fi

    # Trust anchor for the relay -> VPN server hop. Only the TLS-terminating
    # relay opens that connection; a transparent relay forwards bytes untouched
    # and has nothing to verify.
    UPSTREAM_CA_IN_CONTAINER=""
    if [[ "$RELAY_MODE" == "tls" ]]; then
        if [[ -n "$ARG_UPSTREAM_CA" ]]; then
            UPSTREAM_CA_IN_CONTAINER="/etc/snake-vpn/upstream-ca.pem"
            ok "Upstream verified against ${ARG_UPSTREAM_CA}"
        elif [[ -n "$UPSTREAM_PIN" ]]; then
            ok "Upstream pinned to the fingerprint from --upstream-pin"
        elif $ARG_INSECURE_UPSTREAM; then
            warn "--insecure-upstream: the VPN server's certificate will NOT be verified."
        elif upstream_chain_verifies "$TARGET_HOST" "$TARGET_PORT"; then
            # A pinned Let's Encrypt leaf stops matching at the first renewal,
            # so verify the chain instead when there is a real one to verify.
            UPSTREAM_CA_IN_CONTAINER="/etc/ssl/certs/ca-certificates.crt"
            ok "Upstream has a publicly trusted certificate — verifying its chain"
        else
            info "Reading the certificate of ${ARG_TARGET} to pin it..."
            UPSTREAM_PIN=$(fetch_cert_pin "$TARGET_HOST" "$TARGET_PORT" || true)
            if [[ -n "$UPSTREAM_PIN" ]]; then
                ok "Upstream pinned: ${UPSTREAM_PIN}"
                info "Re-pin it if you ever replace the VPN server's certificate."
            else
                ARG_INSECURE_UPSTREAM=true
                warn "Could not read the certificate of ${ARG_TARGET}."
                warn "Falling back to relay.insecure_upstream: true — traffic between this"
                warn "relay and the VPN server will NOT be authenticated. Pin it once the"
                warn "VPN server is reachable:"
                warn "  openssl s_client -connect ${ARG_TARGET} </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256"
                warn "  then put that value in ${INSTALL_DIR}/server.yaml as"
                warn "    relay.upstream_pin_sha256: \"<fingerprint>\""
                warn "  remove relay.insecure_upstream and run: docker compose restart"
            fi
        fi
    fi
elif $ARG_AUTO || $IS_UPGRADE; then
    # Non-interactive, or a re-run: CLI arguments win, the deployed config fills
    # in the rest so a re-run without arguments keeps the current settings.
    DOMAIN="${ARG_DOMAIN:-$(read_yaml_value domain)}"
    [[ -n "$DOMAIN" ]] || fail "No domain given and none found in ${INSTALL_DIR}/server.yaml. Pass --domain."
    ACME_EMAIL="${ARG_EMAIL:-$(read_yaml_value acme_email)}"
    ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"
    ok "Domain: ${DOMAIN}"
    ok "Email: ${ACME_EMAIL}"
else
    # Interactive: ask user
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
fi

# Network interface (auto-detect, don't confuse the user)
if ! $ARG_RELAY; then
    NAT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    NAT_IFACE=${NAT_IFACE:-eth0}
    ok "Network interface: ${NAT_IFACE} (auto-detected)"
fi

# ─── Ports this deployment actually needs, as "port/proto|comment" ───
# One list feeds both the firewall rules and the published compose ports, so the
# two can no longer disagree.
NEEDED_PORTS=("${LISTEN_PORT}/tcp|Snake VPN")
if $ARG_RELAY; then
    # A transparent relay binds nothing on :80; only the TLS relay needs ACME.
    [[ "$RELAY_MODE" == "tls" ]] && NEEDED_PORTS+=("80/tcp|HTTP (ACME)")
else
    NEEDED_PORTS+=("80/tcp|HTTP (ACME)")
fi
[[ -n "$ARG_LISTEN_EXTRA" ]] && NEEDED_PORTS+=("${ARG_LISTEN_EXTRA}/tcp|Snake VPN (extra)")
# 56000 is not configurable: the client hardcodes it as the TURN peer port.
$ARG_TURN_UDP && NEEDED_PORTS+=("56000/udp|Whitelist TURN receiver")

# ═══════════════════════════════════════════════════════════════════
#  STEP 2: CAMOUFLAGE WEBSITE (disabled — not used with current protocol)
# ═══════════════════════════════════════════════════════════════════
# Camouflage website selection is disabled. All connections use protocol
# disguise (RDP/SSH/IMAP/Modbus/ShadowSnake), so serving a fake website
# on the VPN port is not needed. To re-enable, uncomment the block below.
#
# step "Step 2/5: Camouflage Website"
# echo ""
# echo -e "  When someone visits your server in a browser, they'll see"
# echo -e "  a regular website. Choose a disguise:"
# echo ""
# echo -e "  ${BOLD}1)${NC}  ${MAGENTA}CloudPulse${NC}       — Cloud monitoring SaaS (default)"
# echo -e "  ${BOLD}2)${NC}  ${MAGENTA}Tech Blog${NC}        — Personal engineering blog"
# echo -e "  ${BOLD}3)${NC}  ${MAGENTA}IT Consulting${NC}    — Corporate IT consulting firm"
# echo -e "  ${BOLD}4)${NC}  ${MAGENTA}Photography${NC}      — Photographer portfolio (dark theme)"
# echo -e "  ${BOLD}5)${NC}  ${MAGENTA}Restaurant${NC}       — Farm-to-table restaurant"
# echo -e "  ${BOLD}6)${NC}  ${MAGENTA}SaaS Startup${NC}     — API gateway product page"
# echo -e "  ${BOLD}7)${NC}  ${MAGENTA}Design Agency${NC}    — Digital design agency"
# echo ""
# read -rp "$(echo -e "  ${CYAN}Choose camouflage${NC} [1-7, default 1]: ")" CAMO_CHOICE
# CAMO_CHOICE=${CAMO_CHOICE:-1}
#
# case "$CAMO_CHOICE" in
#     1) CAMO_NAME="cloudpulse"   ; CAMO_SOURCE=""            ;;
#     2) CAMO_NAME="blog"         ; CAMO_SOURCE="blog"        ;;
#     3) CAMO_NAME="consulting"   ; CAMO_SOURCE="consulting"  ;;
#     4) CAMO_NAME="photography"  ; CAMO_SOURCE="photography" ;;
#     5) CAMO_NAME="restaurant"   ; CAMO_SOURCE="restaurant"  ;;
#     6) CAMO_NAME="startup"      ; CAMO_SOURCE="startup"     ;;
#     7) CAMO_NAME="agency"       ; CAMO_SOURCE="agency"      ;;
#     *) CAMO_NAME="cloudpulse"   ; CAMO_SOURCE=""            ;;
# esac
# ok "Camouflage: ${CAMO_NAME}"
ok "Camouflage website: skipped (not used with protocol disguise)"

# ═══════════════════════════════════════════════════════════════════
#  STEP 3: HARDEN SERVER
# ═══════════════════════════════════════════════════════════════════
step "Step 2/4: Server Hardening"

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
# Purely additive: rules are never reset, because we did not create the ones
# that are already there (custom SSH port, other services, earlier runs).
info "Configuring firewall..."

UFW_WAS_ACTIVE=false
ufw status 2>/dev/null | grep -qi '^Status: active' && UFW_WAS_ACTIVE=true

# Every source is unioned, never "first non-empty wins": each one can be right
# while another is stale. sshd -T reports the CONFIGURED port, the live listener
# reports the ACTUAL one (they differ under socket activation, or after an edit
# that was never reloaded), and $SSH_CONNECTION is the port this very session
# arrived on. Allowing all of them costs an extra rule; missing one locks the
# operator out of their own VPS.
SSH_PORT_CANDIDATES=""
# 1. sshd's own effective config, including multi-port setups.
SSH_PORT_CANDIDATES+=$'\n'$(sshd -T 2>/dev/null | awk '/^port /{print $2}' || true)
# 2. sshd_config as written, in case sshd -T is unavailable.
SSH_PORT_CANDIDATES+=$'\n'$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config 2>/dev/null || true)
# 3. The live listeners: sshd itself, and ssh.socket under systemd socket
#    activation, where the ListenStream= of the unit outranks sshd_config.
SSH_PORT_CANDIDATES+=$'\n'$(ss -tlnpH 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' || true)
SSH_PORT_CANDIDATES+=$'\n'$(systemctl show ssh.socket sshd.socket -p Listen 2>/dev/null \
    | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}' || true)
# 4. The port this session is actually connected on — the one that must not be
#    blocked, whatever the config files say.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    SSH_PORT_CANDIDATES+=$'\n'$(echo "$SSH_CONNECTION" | awk '{print $4}')
fi
SSH_PORTS=$(echo "$SSH_PORT_CANDIDATES" | grep -xE '[0-9]{1,5}' | sort -un || true)

for p in $SSH_PORTS; do
    ufw allow "${p}/tcp" comment 'SSH' > /dev/null 2>&1
done

for entry in "${NEEDED_PORTS[@]}"; do
    ufw allow "${entry%%|*}" comment "${entry#*|}" > /dev/null 2>&1
done

ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

if $UFW_WAS_ACTIVE; then
    ok "Firewall: rules added (existing rules kept): $(printf '%s ' "${NEEDED_PORTS[@]%%|*}")"
elif [[ -n "$SSH_PORTS" ]]; then
    ufw --force enable > /dev/null 2>&1
    ok "Firewall enabled: SSH ($(echo $SSH_PORTS | tr ' ' ',')), $(printf '%s ' "${NEEDED_PORTS[@]%%|*}") — all else blocked"
else
    # Enabling UFW without knowing the SSH port is how people lock themselves
    # out of their own VPS. The rules are staged; the operator flips the switch.
    warn "Could not determine the SSH port — refusing to enable the firewall."
    warn "Your rules are staged. Once you have confirmed your SSH port, run:"
    warn "  ufw allow <your-ssh-port>/tcp && ufw --force enable"
fi

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
# A relay only proxies TCP — it needs no forwarding and no TUN.
if $ARG_RELAY; then
    IP_FORWARD_LINE="# IP forwarding not needed in relay mode"
else
    IP_FORWARD_LINE="net.ipv4.ip_forward = 1"
fi
cat > /etc/sysctl.d/99-snake-vpn.conf <<SYSCTL
# IP forwarding (required for VPN)
${IP_FORWARD_LINE}

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
if $ARG_RELAY; then
    ok "Kernel: network hardened, buffers optimized"
else
    ok "Kernel: IP forwarding enabled, network hardened, buffers optimized"
fi

# ═══════════════════════════════════════════════════════════════════
#  STEP 4: INSTALL DOCKER & DEPLOY
# ═══════════════════════════════════════════════════════════════════
step "Step 3/4: Docker & Deployment"

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

# 4.3 Admin token — generated once, then reused forever.
# Regenerating it on a re-run is what silently breaks every Manager install.
if $ARG_RELAY; then
    ADMIN_TOKEN=""
elif [[ -f server.yaml ]]; then
    ADMIN_TOKEN=$(read_yaml_value admin_token "${INSTALL_DIR}/server.yaml")
    if [[ -n "$ADMIN_TOKEN" ]]; then
        ok "Admin token: reused from the existing server.yaml"
    else
        warn "Could not read admin_token from the existing server.yaml."
        warn "Leaving it alone — look it up with: grep admin_token ${INSTALL_DIR}/server.yaml"
    fi
else
    ADMIN_TOKEN=$(openssl rand -hex 32)
fi

# The CA the relay verifies the VPN server against has to be readable inside the
# container, so it lives next to server.yaml and is mounted read-only.
if [[ -n "$ARG_UPSTREAM_CA" ]]; then
    install -m 644 "$ARG_UPSTREAM_CA" "${INSTALL_DIR}/upstream-ca.pem"
    ok "Upstream CA copied to ${INSTALL_DIR}/upstream-ca.pem"
fi

# 4.4 Create server.yaml (never overwrite an existing one)
if [[ -f server.yaml ]]; then
    STAMP=$(date +%F-%H%M%S)
    cp -a server.yaml "server.yaml.bak.${STAMP}"
    ok "Existing server.yaml kept (backup: server.yaml.bak.${STAMP})"

    if $ARG_RELAY; then
        CUR_TARGET=$(read_yaml_value target)
        if [[ -n "$CUR_TARGET" && "$CUR_TARGET" != "$ARG_TARGET" ]]; then
            sed -i "s|^\([[:space:]]*\)target:.*|\1target: \"${ARG_TARGET}\"|" server.yaml
            ok "relay target updated: ${CUR_TARGET} -> ${ARG_TARGET}"
        fi
    else
        CUR_DOMAIN=$(read_yaml_value domain)
        CUR_EMAIL=$(read_yaml_value acme_email)
        CUR_IFACE=$(read_yaml_value nat_interface)
        if [[ -n "$ARG_DOMAIN" && "$ARG_DOMAIN" != "$CUR_DOMAIN" ]]; then
            sed -i "s|^\([[:space:]]*\)domain:.*|\1domain: \"${DOMAIN}\"|" server.yaml
            ok "domain updated: ${CUR_DOMAIN} -> ${DOMAIN}"
        fi
        if [[ -n "$ARG_EMAIL" && "$ARG_EMAIL" != "$CUR_EMAIL" ]]; then
            sed -i "s|^\([[:space:]]*\)acme_email:.*|\1acme_email: \"${ACME_EMAIL}\"|" server.yaml
            ok "acme_email updated: ${CUR_EMAIL} -> ${ACME_EMAIL}"
        fi
        if [[ -n "$CUR_IFACE" && "$CUR_IFACE" != "$NAT_IFACE" ]]; then
            warn "nat_interface in server.yaml is '${CUR_IFACE}', this host's default route is '${NAT_IFACE}' — left as is"
        fi
    fi

    # Keys this installer does not manage. Silently dropping them is exactly the
    # bug that made re-running the installer dangerous, so say what is there.
    PRESERVED=$(grep -oE '^[[:space:]]*(listen_extra|relay|whitelist|obfuscation|camouflage):' server.yaml \
                | tr -d ' :' | sort -u | tr '\n' ' ' || true)
    [[ -n "$PRESERVED" ]] && info "Preserved hand-added config: ${PRESERVED}"
else
    if $ARG_RELAY; then
        # Relay config: listen + target and nothing else. tls/auth/tunnel/network/
        # management are all inert in relay mode (the server returns before reading them).
        {
            echo "server:"
            echo "  listen: \":${LISTEN_PORT}\""
            [[ "$RELAY_MODE" == "tls" ]] && echo "  domain: \"${DOMAIN}\""
            [[ -n "$ARG_LISTEN_EXTRA" ]] && echo "  listen_extra: \":${ARG_LISTEN_EXTRA}\""
            echo ""
            echo "relay:"
            echo "  enabled: true"
            echo "  mode: \"${RELAY_MODE}\""
            echo "  target: \"${ARG_TARGET}\""
            # Exactly one of these, and only in tls mode — see the trust-anchor
            # block in step 1. Without one the server starts unverified and says so.
            if [[ -n "$UPSTREAM_CA_IN_CONTAINER" ]]; then
                echo "  upstream_ca_file: \"${UPSTREAM_CA_IN_CONTAINER}\""
            elif [[ -n "$UPSTREAM_PIN" ]]; then
                echo "  upstream_pin_sha256: \"${UPSTREAM_PIN}\""
            elif $ARG_INSECURE_UPSTREAM; then
                echo "  insecure_upstream: true"
            fi
            if $ARG_TURN_UDP; then
                echo "  turn_receiver:"
                echo "    enabled: true"
                echo "    listen_udp: \":56000\""
            fi
            if [[ "$RELAY_MODE" == "tls" ]]; then
                echo ""
                echo "tls:"
                echo "  mode: \"letsencrypt\""
                echo "  acme_email: \"${ACME_EMAIL}\""
                echo "  acme_cache_dir: \"/var/lib/snake-vpn/certs\""
            fi
            echo ""
            echo "logging:"
            echo "  level: \"info\""
        } > server.yaml
        chmod 600 server.yaml
        ok "server.yaml created — relay to ${ARG_TARGET} (chmod 600)"
    else
        LISTEN_EXTRA_LINE=""
        [[ -n "$ARG_LISTEN_EXTRA" ]] && LISTEN_EXTRA_LINE="  listen_extra: \":${ARG_LISTEN_EXTRA}\""
        cat > server.yaml <<YAML
server:
  listen: ":${LISTEN_PORT}"
  domain: "${DOMAIN}"
${LISTEN_EXTRA_LINE}
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
  obfuscation:             # disabled by default — adds jitter/batching to confuse DPI
    enabled: false
    # jitter_ms: 50
    # batch_size: 3
    # noise_percent: 10

network:
  subnet: "10.7.0.0/24"
  server_ip: "10.7.0.1"
  dns:
    - "1.1.1.1"
    - "8.8.8.8"
  nat_interface: "${NAT_IFACE}"

# camouflage website is disabled — protocol disguise is used instead
# camouflage:
#   static_dir: "/opt/snake-vpn/web"
#   index_file: "index.html"

logging:
  level: "info"
  file: ""

management:
  admin_token: "${ADMIN_TOKEN}"
  key_store_path: "/var/lib/snake-vpn/keystore.json"
YAML
        chmod 600 server.yaml
        ok "server.yaml created (chmod 600)"
    fi
fi

# 4.5 Create docker-compose.yml (never overwrite an existing one)
COMPOSE_PORTS=""
for entry in "${NEEDED_PORTS[@]}"; do
    port="${entry%%|*}"
    num="${port%%/*}"
    # Docker publishes TCP by default, so only /udp has to be spelled out.
    if [[ "$port" == */udp ]]; then
        COMPOSE_PORTS+="      - \"${num}:${num}/udp\"   # ${entry#*|}"$'\n'
    else
        COMPOSE_PORTS+="      - \"${num}:${num}\"   # ${entry#*|}"$'\n'
    fi
done

if [[ -f docker-compose.yml ]]; then
    ok "Existing docker-compose.yml kept"
    # A commented-out ports entry must still count as "not published".
    for entry in "${NEEDED_PORTS[@]}"; do
        port="${entry%%|*}"
        num="${port%%/*}"
        if [[ "$port" == */udp ]]; then publish="${num}:${num}/udp"; else publish="${num}:${num}"; fi
        if ! grep -qE "^[[:space:]]*-[[:space:]]*\"?[^\"]*:${num}(/|\"|$)" docker-compose.yml; then
            warn "Port ${port} is not published by your docker-compose.yml. Add under 'ports:':"
            warn "      - \"${publish}\""
        fi
    done
    if [[ -n "$ARG_UPSTREAM_CA" ]] && ! grep -q 'upstream-ca.pem' docker-compose.yml; then
        warn "The upstream CA is not mounted by your docker-compose.yml. Add under 'volumes:':"
        warn "      - ./upstream-ca.pem:/etc/snake-vpn/upstream-ca.pem:ro"
    fi
elif $ARG_RELAY; then
    RELAY_CA_MOUNT=""
    [[ -n "$ARG_UPSTREAM_CA" ]] && RELAY_CA_MOUNT=$'\n      - ./upstream-ca.pem:/etc/snake-vpn/upstream-ca.pem:ro'
    # No privileged, no NET_ADMIN, no /dev/net/tun, no ip_forward: a relay
    # proxies bytes and needs none of it.
    cat > docker-compose.yml <<COMPOSE
services:
  snake-vpn:
    image: ghcr.io/4esyh/snake-vpn:latest
    container_name: snake-vpn-relay
    restart: unless-stopped
    ports:
${COMPOSE_PORTS}    volumes:
      - ./server.yaml:/etc/snake-vpn/server.yaml:ro
      - vpn-data:/var/lib/snake-vpn${RELAY_CA_MOUNT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    # /healthz живёт на 127.0.0.1:9977 внутри контейнера и наружу не публикуется:
    # публичный health-эндпоинт демаскировал бы сервер. 503 — сертификат скоро
    # истекает или маршрутизация TUN замолчала.
    healthcheck:
      test: ["CMD", "sh", "-c", "wget -q -T 3 -O /dev/null ${HEALTH_URL} || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

volumes:
  vpn-data:
COMPOSE
    ok "docker-compose.yml created (relay: no privileged, no NET_ADMIN, no TUN)"
else
    cat > docker-compose.yml <<COMPOSE
services:
  snake-vpn:
    image: ghcr.io/4esyh/snake-vpn:latest
    container_name: snake-vpn
    restart: unless-stopped
    ports:
${COMPOSE_PORTS}    volumes:
      - ./server.yaml:/etc/snake-vpn/server.yaml:ro
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
    # /healthz живёт на 127.0.0.1:9977 внутри контейнера и наружу не публикуется:
    # публичный health-эндпоинт демаскировал бы сервер. 503 — сертификат скоро
    # истекает или маршрутизация TUN замолчала.
    healthcheck:
      test: ["CMD", "sh", "-c", "wget -q -T 3 -O /dev/null ${HEALTH_URL} || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

volumes:
  vpn-data:
COMPOSE
    ok "docker-compose.yml created"
fi

# 4.6 Camouflage website download (disabled — not used with protocol disguise)
# mkdir -p "${INSTALL_DIR}/web"
# ... camouflage download code commented out ...
# To re-enable, restore the download block from git history.
ok "Camouflage website: skipped"

# 4.7 Pull, validate the config, then start
info "Pulling Docker image (this may take a minute)..."
docker compose pull 2>&1 | tail -1

# The binary validates its own config — catch a bad relay target or a missing
# domain here, not from user reports afterwards.
if CHECK_OUT=$(docker compose run --rm --no-deps -T snake-vpn -config /etc/snake-vpn/server.yaml -check 2>&1); then
    ok "Config validated by the server binary"
    echo "$CHECK_OUT" | grep -i '^warning:' | while read -r line; do warn "${line}"; done
else
    echo "$CHECK_OUT" | sed 's/^/    /'
    fail "The generated config was rejected by the server. Nothing was started."
fi

info "Starting Snake VPN..."
docker compose up -d 2>&1 | tail -1

# 4.8 Wait for container
info "Waiting for server to start..."
CONTAINER_ID=$(docker compose ps -q snake-vpn 2>/dev/null)
HEALTHY=false
for i in $(seq 1 30); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_ID" 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "healthy" ]]; then
        HEALTHY=true
        break
    fi
    sleep 2
done

if $HEALTHY; then
    ok "Server is healthy and running"
else
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null || echo "unknown")
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
step "Step 4/4: Done!"

if $ARG_RELAY; then
    echo ""
    echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}  ║                                                    ║${NC}"
    echo -e "${GREEN}  ║         ✅  Snake VPN relay is ready!              ║${NC}"
    echo -e "${GREEN}  ║                                                    ║${NC}"
    echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Relay address:${NC}  ${SERVER_IP}:${LISTEN_PORT}"
    echo -e "  ${BOLD}Upstream:${NC}       ${ARG_TARGET}"
    echo -e "  ${BOLD}Relay mode:${NC}     ${RELAY_MODE}"
    echo -e "  ${BOLD}Install dir:${NC}    ${INSTALL_DIR}"
    echo ""
    divider
    echo ""

    # Prove it end to end rather than just claiming success.
    info "Verifying..."
    if probe_tcp 127.0.0.1 "$LISTEN_PORT"; then
        ok "Relay is accepting connections on port ${LISTEN_PORT}"
    else
        warn "Relay is NOT accepting connections on port ${LISTEN_PORT}"
        warn "Check: cd ${INSTALL_DIR} && docker compose logs -f"
    fi
    if probe_tcp "$TARGET_HOST" "$TARGET_PORT"; then
        ok "Upstream ${ARG_TARGET} is reachable from this host"
    else
        warn "Upstream ${ARG_TARGET} is NOT reachable — clients will connect and then fail"
    fi
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}What to do next:${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} Keys stay on the ${BOLD}VPN server${NC} — the relay knows nothing about them."
    echo ""
    echo -e "  ${CYAN}2.${NC} In each ${BOLD}svpn://${NC} link, replace the host with this relay,"
    echo -e "     keeping the token and the secret path unchanged:"
    echo -e "     ${GREEN}svpn://TOKEN@${SERVER_IP}:${LISTEN_PORT}/api/v2/events/stream#MyServer${NC}"
    echo ""
    echo -e "  ${CYAN}3.${NC} Give that link to users. Their traffic goes"
    echo -e "     client → this relay → ${ARG_TARGET}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "  ${DIM}cd ${INSTALL_DIR}${NC}"
    echo -e "  bash install.sh --status        ${DIM}# verify this deployment${NC}"
    echo -e "  bash install.sh --update        ${DIM}# pull a new image, keep the config${NC}"
    echo -e "  docker compose logs -f          ${DIM}# view logs${NC}"
    echo ""
    exit 0
fi

# Save credentials
CREDS_FILE="${INSTALL_DIR}/credentials.txt"
if [[ -n "$ADMIN_TOKEN" ]]; then
cat > "$CREDS_FILE" <<CREDS
Snake VPN — Credentials
========================
Installed:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Domain:     ${DOMAIN}
Server IP:  ${SERVER_IP}

Admin Token: ${ADMIN_TOKEN}

Manager connection:
  Server URL:  https://${DOMAIN}
  Admin Token: ${ADMIN_TOKEN}

API examples:
  curl -sk https://${DOMAIN}/admin-api/${ADMIN_TOKEN}/server | jq .
  curl -sk https://${DOMAIN}/admin-api/${ADMIN_TOKEN}/keys   | jq .
CREDS
chmod 600 "$CREDS_FILE"
fi

# Final output
echo ""
echo -e "${GREEN}  ╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║                                                    ║${NC}"
if $IS_UPGRADE; then
echo -e "${GREEN}  ║         ✅  Snake VPN updated in place!            ║${NC}"
else
echo -e "${GREEN}  ║         ✅  Snake VPN is ready!                    ║${NC}"
fi
echo -e "${GREEN}  ║                                                    ║${NC}"
echo -e "${GREEN}  ╚════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Server URL:${NC}    https://${DOMAIN}"
echo -e "  ${BOLD}Server IP:${NC}     ${SERVER_IP}"
echo -e "  ${BOLD}Install dir:${NC}   ${INSTALL_DIR}"
echo ""
if $IS_UPGRADE; then
    ok "Kept: server.yaml, its admin token, and your existing firewall rules"
    ok "Updated: Docker image, and any port rules this run needed"
fi
echo ""
divider
echo ""
if [[ -n "$ADMIN_TOKEN" ]]; then
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
else
warn "Admin token unknown — read it from ${INSTALL_DIR}/server.yaml"
fi
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
echo -e "  ${DIM}Blocked network? Put a relay in front of this server:${NC}"
echo -e "  ${DIM}  sudo bash install.sh --relay --target=${DOMAIN}:${LISTEN_PORT}${NC}"
echo ""
divider
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${DIM}cd ${INSTALL_DIR}${NC}"
echo -e "  bash install.sh --status        ${DIM}# verify this deployment${NC}"
echo -e "  bash install.sh --update        ${DIM}# pull a new image, keep the config${NC}"
echo -e "  docker compose logs -f          ${DIM}# view logs${NC}"
echo -e "  docker compose restart          ${DIM}# restart${NC}"
echo -e "  cat credentials.txt             ${DIM}# show saved credentials${NC}"
echo ""
