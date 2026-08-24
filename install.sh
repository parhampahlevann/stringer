#!/bin/bash
# ============================================================================
# ICMP-over-VPN Tunnel Manager (FIXED)
# Built on ptunnel-ng (https://github.com/utoni/ptunnel-ng)
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
        build-essential autoconf automake libtool pkg-config git iptables tcpdump iproute2 >/dev/null
}

# FIX 1: explicitly run autogen → configure → make
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
    ( cd "$INSTALL_DIR" && ./autogen.sh ) || { print_error "autogen.sh failed"; return 1; }
    ( cd "$INSTALL_DIR" && ./configure ) || { print_error "configure failed"; return 1; }
    ( cd "$INSTALL_DIR" && make -j"$(nproc)" ) || { print_error "make failed"; return 1; }
    if [ ! -x "$BIN_PATH" ]; then
        print_error "Build done but binary not at $BIN_PATH"
        return 1
    fi
    print_success "Built $BIN_PATH"
}

# FIX 2: better ICMP handling — disable rate limit too
allow_icmp_firewall() {
    print_status "Configuring firewall for ICMP..."
    iptables -C INPUT  -p icmp -j ACCEPT 2>/dev/null || iptables -A INPUT  -p icmp -j ACCEPT
    iptables -C OUTPUT -p icmp -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p icmp -j ACCEPT
    # Disable ICMP rate limiting (kernel can silently drop ping floods otherwise)
    sysctl -w net.ipv4.icmp_ratelimit=0    >/dev/null 2>&1 || true
    sysctl -w net.ipv4.icmp_ratemask=0     >/dev/null 2>&1 || true
    # Persist sysctl
    grep -q 'icmp_ratelimit' /etc/sysctl.conf 2>/dev/null || \
        printf 'net.ipv4.icmp_ratelimit=0\nnet.ipv4.icmp_ratemask=0\n' >> /etc/sysctl.conf
    # Persist iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# FIX 3: write env file with SINGLE-QUOTED values (prevents "command not found")
write_env_file() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    : > "$file"
    while [ $# -ge 2 ]; do
        local key="$1"
        local val="$2"
        # escape any single quotes inside value
        val="${val//\'/\'\\\'\'}"
        printf "%s='%s'\n" "$key" "$val" >> "$file"
        shift 2
    done
    chmod 600 "$file"
}

write_systemd_service() {
    local name="$1" exec_line="$2"
    # Stop & remove any stale unit first
    systemctl stop    "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
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
    systemctl enable "$name" >/dev/null 2>&1
}

install_server() {
    echo ""; print_header "Install ICMP Tunnel SERVER (inside filtered network)"
    require_root
    install_build_deps
    build_ptunnel || return 1

    read -p "  Destination IP (default 127.0.0.1): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}
    read -p "  Destination port (default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}
    read -p "  Password (blank for none): " TPASS </dev/tty
    read -p "  Magic value (blank for default): " MAGIC </dev/tty

    write_env_file "$CONF_FILE" \
        DEST_IP "$DEST_IP" \
        DEST_PORT "$DEST_PORT" \
        TPASS "$TPASS" \
        MAGIC "$MAGIC"

    local exec_args="${BIN_PATH} -r${DEST_IP} -R${DEST_PORT} -v1"
    [ -n "$TPASS" ] && exec_args+=" -P${TPASS}"
    [ -n "$MAGIC" ] && exec_args+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$SERVER_SERVICE" "$exec_args"
    systemctl restart "$SERVER_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SERVER_SERVICE"; then
        print_success "Server running, forwarding to ${DEST_IP}:${DEST_PORT}"
        print_info "PID: $(systemctl show -p MainPID --value "$SERVER_SERVICE")"
    else
        print_error "Service failed — last logs:"
        journalctl -u "$SERVER_SERVICE" -n 20 --no-pager
    fi
}

install_client() {
    echo ""; print_header "Install ICMP Tunnel CLIENT (outside / VPN entry)"
    require_root
    install_build_deps
    build_ptunnel || return 1

    read -p "  Server public IP: " SERVER_IP </dev/tty
    if [ -z "$SERVER_IP" ]; then
        print_error "Server IP required."
        return 1
    fi
    read -p "  Local listen port (default 8000): " LISTEN_PORT </dev/tty
    LISTEN_PORT=${LISTEN_PORT:-8000}
    read -p "  Destination IP on server (default 127.0.0.1): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}
    read -p "  Destination port on server (default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}
    read -p "  Password (must match server): " TPASS </dev/tty
    read -p "  Magic value (must match server): " MAGIC </dev/tty

    write_env_file "$CONF_FILE" \
        SERVER_IP  "$SERVER_IP"  \
        LISTEN_PORT "$LISTEN_PORT" \
        DEST_IP    "$DEST_IP"    \
        DEST_PORT  "$DEST_PORT"  \
        TPASS      "$TPASS"      \
        MAGIC      "$MAGIC"

    local exec_args="${BIN_PATH} -p${SERVER_IP} -l${LISTEN_PORT} -r${DEST_IP} -R${DEST_PORT} -v1"
    [ -n "$TPASS" ] && exec_args+=" -P${TPASS}"
    [ -n "$MAGIC" ] && exec_args+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$CLIENT_SERVICE" "$exec_args"
    systemctl restart "$CLIENT_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$CLIENT_SERVICE"; then
        print_success "Client running on 127.0.0.1:${LISTEN_PORT}"
        print_info "Point your VPN client at 127.0.0.1:${LISTEN_PORT} (TCP)."
        print_warning "WireGuard (UDP) will NOT work over this tunnel."
    else
        print_error "Service failed — last logs:"
        journalctl -u "$CLIENT_SERVICE" -n 20 --no-pager
    fi
}

status_tunnel() {
    echo ""; print_header "Status"
    local found=0
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            found=1
            echo ""
            systemctl status "$svc" --no-pager -l | head -n 15
        fi
    done
    [ $found -eq 0 ] && print_warning "No tunnel service installed on this host."
    echo ""
    print_info "Listening TCP ports (look for ptunnel-ng / your LISTEN_PORT):"
    ss -tlnp 2>/dev/null | grep -E 'ptunnel' || true
    read -p "Press Enter..." </dev/tty
}

debug_traffic() {
    echo ""; print_header "Debug — ICMP traffic (Ctrl+C to stop)"
    print_info "Run on SERVER. You should see echo-request/echo-reply pairs."
    print_info "If you see requests but NO replies — ICMP is being dropped."
    tcpdump -n -i any icmp
    read -p "Press Enter..." </dev/tty
}

# FIX 4: real connection test — ping + check listener
test_connection() {
    echo ""; print_header "Connection test"
    if [ ! -f "$CONF_FILE" ]; then
        print_error "No tunnel.env found — install first."
        read -p "Press Enter..." </dev/tty
        return
    fi
    # Safe parse — only read KEY='value' lines
    local SERVER_IP="" LISTEN_PORT=""
    while IFS= read -r line; do
        case "$line" in
            SERVER_IP=*)   SERVER_IP="${line#SERVER_IP=}"; SERVER_IP="${SERVER_IP//\'}"; ;;
            LISTEN_PORT=*) LISTEN_PORT="${line#LISTEN_PORT=}"; LISTEN_PORT="${LISTEN_PORT//\'}"; ;;
        esac
    done < "$CONF_FILE"

    if [ -n "$SERVER_IP" ]; then
        print_status "Pinging server $SERVER_IP ..."
        if ping -c 3 -W 2 "$SERVER_IP" >/dev/null 2>&1; then
            print_success "ICMP reachable to server"
        else
            print_error "ICMP NOT reachable — check firewall / network path"
        fi
    fi
    if [ -n "$LISTEN_PORT" ]; then
        print_status "Checking local listener on 127.0.0.1:${LISTEN_PORT} ..."
        if ss -tlnp 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            print_success "Listener is up"
        else
            print_error "Listener is DOWN — check client service"
        fi
    fi
    read -p "Press Enter..." </dev/tty
}

# FIX 5: only restart actually-installed services
restart_tunnel() {
    local restarted=0
    if systemctl list-unit-files | grep -q "^${SERVER_SERVICE}.service"; then
        systemctl restart "$SERVER_SERVICE" 2>/dev/null && \
            { print_success "Restarted $SERVER_SERVICE"; restarted=1; }
    fi
    if systemctl list-unit-files | grep -q "^${CLIENT_SERVICE}.service"; then
        systemctl restart "$CLIENT_SERVICE" 2>/dev/null && \
            { print_success "Restarted $CLIENT_SERVICE"; restarted=1; }
    fi
    [ $restarted -eq 0 ] && print_warning "No tunnel service installed on this host."
    sleep 1
}

uninstall_tunnel() {
    require_root
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload
    pkill -f ptunnel-ng 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    print_success "Uninstalled. ICMP firewall rules left in place — remove manually if desired."
}

while true; do
    clear
    echo "============================================"
    echo "  ICMP Tunnel Manager (ptunnel-ng)"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER (inside filtered network)"
    print_menu "2. Install CLIENT (outside / VPN entry)"
    print_menu "3. Status"
    print_menu "4. Debug traffic (tcpdump)"
    print_menu "5. Test connection"
    print_menu "6. Restart"
    print_menu "7. Uninstall"
    print_menu "8. Exit"
    echo ""
    read -p "Select [1-8]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server;    read -p "Press Enter..." </dev/tty ;;
        2) install_client;    read -p "Press Enter..." </dev/tty ;;
        3) status_tunnel ;;
        4) debug_traffic ;;
        5) test_connection ;;
        6) restart_tunnel;    read -p "Press Enter..." </dev/tty ;;
        7) uninstall_tunnel;  read -p "Press Enter..." </dev/tty ;;
        8) exit 0 ;;
        *) sleep 1 ;;
    esac
done
