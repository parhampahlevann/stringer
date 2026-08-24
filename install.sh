#!/bin/bash
# ============================================================================
# ICMP-over-VPN Tunnel Manager
# Built on ptunnel-ng (https://github.com/utoni/ptunnel-ng) — open source,
# BSD licensed, compiled from source on your own machines. No third-party
# binaries, no patched/bypassed validation.
#
# What this does:
#   ptunnel-ng tunnels TCP connections inside ICMP echo request/reply
#   packets. We use it to carry your VPN's TCP control/data channel, so
#   from the outside the traffic just looks like ping packets.
#
# IMPORTANT LIMITATION:
#   ptunnel-ng only tunnels TCP. If your VPN is WireGuard (UDP) it will
#   NOT work through this directly — use OpenVPN configured for TCP,
#   stunnel, or an SSH-based tunnel as the thing being forwarded instead.
# ============================================================================

set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_header()  { echo -e "${GREEN}▶${NC} $1"; }
print_menu()    { echo -e "${BLUE}▸${NC} $1"; }
print_info()    { echo -e "${CYAN}[i]${NC} $1"; }

INSTALL_DIR="/opt/ptunnel-ng"
BIN_PATH="${INSTALL_DIR}/src/ptunnel-ng"
REPO_URL="https://github.com/utoni/ptunnel-ng.git"
SERVER_SERVICE="ptunnel-ng-server"
CLIENT_SERVICE="ptunnel-ng-client"
CONF_FILE="${INSTALL_DIR}/tunnel.env"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Run this as root (sudo)."
        exit 1
    fi
}

install_build_deps() {
    print_status "Installing build dependencies..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential autoconf automake libtool git iptables tcpdump iproute2 >/dev/null
}

build_ptunnel() {
    if [ -x "$BIN_PATH" ]; then
        print_success "ptunnel-ng already built at $BIN_PATH"
        return 0
    fi
    print_status "Cloning and building ptunnel-ng from source..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --ff-only
    else
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi
    ( cd "$INSTALL_DIR" && ./autogen.sh )
    if [ ! -x "$BIN_PATH" ]; then
        print_error "Build failed — ptunnel-ng binary not found at $BIN_PATH"
        return 1
    fi
    print_success "Built $BIN_PATH"
}

allow_icmp_firewall() {
    print_status "Allowing ICMP echo request/reply through the firewall..."
    iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -A INPUT -p icmp -j ACCEPT
    iptables -C OUTPUT -p icmp -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p icmp -j ACCEPT
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

write_systemd_service() {
    local name="$1" exec_line="$2"
    cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${exec_line}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${name}" >/dev/null 2>&1
}

install_server() {
    echo ""; print_header "Install ICMP Tunnel SERVER (the box inside the filtered network, next to your VPN)"
    require_root
    install_build_deps
    build_ptunnel || return 1

    read -p "  Destination IP the tunnel forwards to (your VPN, default 127.0.0.1): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}
    read -p "  Destination port (e.g. OpenVPN TCP port, default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}
    read -p "  Password to protect the tunnel (leave blank for none): " TPASS </dev/tty
    read -p "  Custom magic value to help evade DPI pattern-matching (leave blank for default): " MAGIC </dev/tty

    mkdir -p "$INSTALL_DIR"
    {
        echo "DEST_IP=${DEST_IP}"
        echo "DEST_PORT=${DEST_PORT}"
        echo "TPASS=${TPASS}"
        echo "MAGIC=${MAGIC}"
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"

    local extra=""
    [ -n "$TPASS" ] && extra+=" -P${TPASS}"
    [ -n "$MAGIC" ] && extra+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$SERVER_SERVICE" "${BIN_PATH} -r${DEST_IP} -R${DEST_PORT} -v1${extra}"
    systemctl restart "$SERVER_SERVICE"
    sleep 1
    systemctl is-active --quiet "$SERVER_SERVICE" && print_success "Server tunnel running, forwarding to ${DEST_IP}:${DEST_PORT}" \
        || print_error "Service failed to start — check: journalctl -u ${SERVER_SERVICE} -n 50"
}

install_client() {
    echo ""; print_header "Install ICMP Tunnel CLIENT (the box outside, e.g. your laptop/VPS abroad)"
    require_root
    install_build_deps
    build_ptunnel || return 1

    read -p "  Server public IP (the filtered-network box you just set up): " SERVER_IP </dev/tty
    read -p "  Local port to listen on for your VPN client to connect to (default 8000): " LISTEN_PORT </dev/tty
    LISTEN_PORT=${LISTEN_PORT:-8000}
    read -p "  Destination IP configured on the server (default 127.0.0.1): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}
    read -p "  Destination port configured on the server (default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}
    read -p "  Password (must match the server, leave blank if none): " TPASS </dev/tty
    read -p "  Magic value (must match the server, leave blank for default): " MAGIC </dev/tty

    mkdir -p "$INSTALL_DIR"
    {
        echo "SERVER_IP=${SERVER_IP}"
        echo "LISTEN_PORT=${LISTEN_PORT}"
        echo "DEST_IP=${DEST_IP}"
        echo "DEST_PORT=${DEST_PORT}"
        echo "TPASS=${TPASS}"
        echo "MAGIC=${MAGIC}"
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"

    local extra=""
    [ -n "$TPASS" ] && extra+=" -P${TPASS}"
    [ -n "$MAGIC" ] && extra+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$CLIENT_SERVICE" "${BIN_PATH} -p${SERVER_IP} -l${LISTEN_PORT} -r${DEST_IP} -R${DEST_PORT} -v1${extra}"
    systemctl restart "$CLIENT_SERVICE"
    sleep 1
    if systemctl is-active --quiet "$CLIENT_SERVICE"; then
        print_success "Client tunnel running. Local listener: 127.0.0.1:${LISTEN_PORT}"
        print_info "Point your VPN client at 127.0.0.1:${LISTEN_PORT} (TCP) instead of the real server."
        print_info "Example for OpenVPN client config: 'remote 127.0.0.1 ${LISTEN_PORT}' with 'proto tcp'."
        print_warning "This only carries TCP. WireGuard (UDP) will not work over this tunnel."
    else
        print_error "Service failed to start — check: journalctl -u ${CLIENT_SERVICE} -n 50"
    fi
}

status_tunnel() {
    echo ""; print_header "Status"
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            echo ""
            systemctl status "$svc" --no-pager -l | head -n 12
        fi
    done
    read -p "Press Enter..." </dev/tty
}

debug_traffic() {
    echo ""; print_header "Debug — watching ICMP traffic (Ctrl+C to stop)"
    print_info "If the tunnel is working you should see steady echo-request/echo-reply pairs"
    print_info "between the two endpoints while a VPN connection attempt is in progress."
    tcpdump -n -i any icmp
    read -p "Press Enter..." </dev/tty
}

restart_tunnel() {
    systemctl restart "$SERVER_SERVICE" 2>/dev/null
    systemctl restart "$CLIENT_SERVICE" 2>/dev/null
    print_success "Restarted whichever service is installed on this host."
    sleep 1
}

uninstall_tunnel() {
    require_root
    systemctl stop "$SERVER_SERVICE" 2>/dev/null || true
    systemctl stop "$CLIENT_SERVICE" 2>/dev/null || true
    systemctl disable "$SERVER_SERVICE" 2>/dev/null || true
    systemctl disable "$CLIENT_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVER_SERVICE}.service" "/etc/systemd/system/${CLIENT_SERVICE}.service"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    print_success "Uninstalled. (ICMP firewall rules left in place — remove manually if you want.)"
}

while true; do
    clear
    echo "============================================"
    echo "  ICMP Tunnel Manager (ptunnel-ng)"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER (inside the filtered network)"
    print_menu "2. Install CLIENT (outside / your VPN entry point)"
    print_menu "3. Status"
    print_menu "4. Debug traffic (tcpdump)"
    print_menu "5. Restart"
    print_menu "6. Uninstall"
    print_menu "7. Exit"
    echo ""
    read -p "Select [1-7]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." </dev/tty ;;
        2) install_client; read -p "Press Enter..." </dev/tty ;;
        3) status_tunnel ;;
        4) debug_traffic ;;
        5) restart_tunnel ;;
        6) uninstall_tunnel; read -p "Press Enter..." </dev/tty ;;
        7) exit 0 ;;
        *) sleep 1 ;;
    esac
done
