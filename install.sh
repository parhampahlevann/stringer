#!/bin/bash
set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Functions
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_header() { echo -e "${GREEN}▶${NC} $1"; }
print_menu() { echo -e "${BLUE}▸${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

# ============================================
# Configuration
# ============================================
INSTALL_DIR="/opt/stinger"
BINARY_NAME="stinger"
SERVICE_NAME="stinger-tunnel"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"
FORWARD_FILE="${INSTALL_DIR}/forwarded_ports.txt"
TUNNEL_SUBNET="10.0.0.0/24"

# ============================================
# Enable IP Forwarding
# ============================================
enable_ip_forwarding() {
    print_status "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-stinger-forward.conf
    fi
    sysctl -p > /dev/null 2>&1
    print_success "IP forwarding enabled permanently"
}

# ============================================
# Setup Firewall for Tunnel Traffic
# ============================================
setup_tunnel_firewall() {
    print_status "Setting up firewall rules..."
    
    if ! command -v iptables &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    fi
    if ! command -v netfilter-persistent &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1 || true
    fi
    
    # Allow tunnel interface traffic
    iptables -A INPUT -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null || true
    
    # Allow FORWARD through tunnel
    iptables -A FORWARD -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -o flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -o tun+ -j ACCEPT 2>/dev/null || true
    
    # Established connections
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    # NAT for tunnel subnet
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -o eth0 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE 2>/dev/null || true
    
    # Allow subnet traffic
    iptables -A FORWARD -s "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -d "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    
    # Save
    netfilter-persistent save > /dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    print_success "Firewall rules applied"
}

# ============================================
# Setup Routing for Tunnel
# ============================================
setup_routing() {
    local PEER_TUN_IP=$1
    local TUN_IFACE="flagtun0"
    
    print_status "Setting up routing through tunnel..."
    
    # Wait for tunnel interface to come up
    sleep 3
    
    # Add route to peer through tunnel
    ip route add "${PEER_TUN_IP}/32" dev "$TUN_IFACE" 2>/dev/null || true
    
    # Add route for entire tunnel subnet
    ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    
    # Make persistent via rc.local or networkd-dispatcher
    cat > /etc/network/if-up.d/stinger-routes << EOF
#!/bin/bash
ip route add ${PEER_TUN_IP}/32 dev ${TUN_IFACE} 2>/dev/null || true
ip route add ${TUNNEL_SUBNET} dev ${TUN_IFACE} 2>/dev/null || true
EOF
    chmod +x /etc/network/if-up.d/stinger-routes 2>/dev/null || true
    
    print_success "Routing configured: traffic to $PEER_TUN_IP via $TUN_IFACE"
}

# ============================================
# Port Forwarding
# ============================================
setup_port_forwarding() {
    local MAIN_PORT=$1
    local FORWARD_PORTS=$2
    
    if [ -z "$FORWARD_PORTS" ]; then return 0; fi
    
    print_status "Setting up port forwarding..."
    > "$FORWARD_FILE"
    IFS=',' read -ra PORT_ARRAY <<< "$FORWARD_PORTS"
    
    for PORT in "${PORT_ARRAY[@]}"; do
        PORT=$(echo "$PORT" | tr -d ' ')
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then
            iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-port "$MAIN_PORT" 2>/dev/null || true
            iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-port "$MAIN_PORT"
            echo "$PORT" >> "$FORWARD_FILE"
            print_success "Port $PORT -> $MAIN_PORT"
        fi
    done
    netfilter-persistent save > /dev/null 2>&1 || true
}

remove_port_forwarding() {
    [ ! -f "$FORWARD_FILE" ] && return 0
    print_status "Removing port forwarding..."
    while IFS= read -r PORT; do
        [[ "$PORT" =~ ^[0-9]+$ ]] && iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT 2>/dev/null || true
    done < "$FORWARD_FILE"
    rm -f "$FORWARD_FILE"
    netfilter-persistent save > /dev/null 2>&1 || true
}

# ============================================
# Systemd Service
# ============================================
create_systemd_service() {
    print_status "Creating systemd service..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Stinger Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
Restart=always
RestartSec=5
LimitNOFILE=65535
ExecStartPost=/bin/sleep 2
ExecStartPost=/bin/bash -c 'ip route add 10.0.0.0/24 dev flagtun0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" > /dev/null 2>&1
    print_success "Systemd service created (auto-start on boot)"
}

start_service() {
    print_status "Starting Stinger service..."
    systemctl restart "${SERVICE_NAME}"
    sleep 4
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "Stinger is RUNNING"
    else
        print_error "Failed to start. Logs:"
        journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
    fi
}

stop_service() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "stinger.bin" 2>/dev/null || true
    print_success "Stinger stopped"
}

# ============================================
# Uninstall
# ============================================
uninstall_stinger() {
    echo ""; print_header "🗑️  Uninstalling..."
    stop_service
    remove_port_forwarding
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f /etc/network/if-up.d/stinger-routes
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    print_success "✅ Fully uninstalled!"
}

# ============================================
# INSTALL SERVER
# ============================================
install_server() {
    echo ""; print_header "🖥️  Installing Stinger SERVER..."
    
    command -v wget &> /dev/null || { apt-get update -qq && apt-get install -y -qq wget file; }
    
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    
    print_status "Downloading binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"; export FAKE_HOSTNAME="ubuntu-server"; export ALLOWED_SERVER="true"; export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/stinger.bin" "$@"
WRAPPER
    fi
    
    echo ""
    read -p "  🌐 Remote IP (0.0.0.0=any) [0.0.0.0]: " REMOTE_IP < /dev/tty
    REMOTE_IP=${REMOTE_IP:-0.0.0.0}
    read -p "  🔗 Main Port [8080]: " MAIN_PORT < /dev/tty
    MAIN_PORT=${MAIN_PORT:-8080}
    read -p "  🛜  Server Tunnel IP [10.0.0.1/24]: " LOCAL_TUN < /dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.1/24}
    read -p "  🎯 Client Tunnel IP (peer_tun) [10.0.0.2]: " PEER_TUN < /dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.2}
    echo ""
    print_info "💡 Extra ports to forward (e.g. 443,2053) or Enter to skip:"
    read -p "  🔀 Ports: " FORWARD_PORTS < /dev/tty
    
    # Config with peer_tun (CRITICAL FIX)
    cat > config.toml << EOF
mode = "server"
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"

[server]
host = "0.0.0.0"
port = ${MAIN_PORT}
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"
EOF
    
    chmod +x "${BINARY_NAME}"
    
    enable_ip_forwarding
    setup_tunnel_firewall
    [ -n "$FORWARD_PORTS" ] && setup_port_forwarding "$MAIN_PORT" "$FORWARD_PORTS"
    create_systemd_service
    start_service
    
    # Setup routing after service starts
    sleep 2
    setup_routing "$PEER_TUN"
    
    echo ""
    print_success "══════════════════════════════════════════════"
    print_success "✅ SERVER INSTALLED!"
    print_success "══════════════════════════════════════════════"
    print_info "  Port: $MAIN_PORT | Tunnel: $LOCAL_TUN"
    print_info "  Peer: $PEER_TUN"
    [ -n "$FORWARD_PORTS" ] && print_info "  Forwarded: $FORWARD_PORTS"
    print_info "  Test: ping $PEER_TUN"
    print_success "══════════════════════════════════════════════"
}

# ============================================
# INSTALL CLIENT
# ============================================
install_client() {
    echo ""; print_header "💻 Installing Stinger CLIENT..."
    
    command -v wget &> /dev/null || { apt-get update -qq && apt-get install -y -qq wget file; }
    
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    
    print_status "Downloading binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"; export FAKE_HOSTNAME="ubuntu-client"; export ALLOWED_SERVER="true"; export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/stinger.bin" "$@"
WRAPPER
    fi
    
    echo ""
    read -p "  🌐 Server IP: " SERVER_IP < /dev/tty
    [ -z "$SERVER_IP" ] && { print_error "Server IP required!"; return 1; }
    read -p "  🔗 Server Port (ONE port) [443]: " SERVER_PORT < /dev/tty
    SERVER_PORT=${SERVER_PORT:-443}
    read -p "  🛜  Client Tunnel IP [10.0.0.2/24]: " LOCAL_TUN < /dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.2/24}
    read -p "  🎯 Server Tunnel IP (peer_tun) [10.0.0.1]: " PEER_TUN < /dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.1}
    
    # Config with peer_tun (CRITICAL FIX)
    cat > config.toml << EOF
mode = "client"
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"
EOF
    
    chmod +x "${BINARY_NAME}"
    
    enable_ip_forwarding
    setup_tunnel_firewall
    create_systemd_service
    start_service
    
    # Setup routing
    sleep 2
    setup_routing "$PEER_TUN"
    
    echo ""
    print_success "══════════════════════════════════════════════"
    print_success "✅ CLIENT INSTALLED!"
    print_success "══════════════════════════════════════════════"
    print_info "  Server: $SERVER_IP:$SERVER_PORT"
    print_info "  Tunnel: $LOCAL_TUN | Peer: $PEER_TUN"
    print_info "  Test: ping $PEER_TUN"
    print_success "══════════════════════════════════════════════"
}

# ============================================
# CHECK STATUS
# ============================================
check_status() {
    echo ""; print_header "🔍 Status Report"
    echo "═══════════════════════════════════════════"
    
    echo -e "\n${YELLOW}[1] Service:${NC}"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_success "RUNNING (PID: $(systemctl show -p MainPID --value ${SERVICE_NAME}))"
    else
        print_error "NOT RUNNING"
    fi
    
    echo -e "\n${YELLOW}[2] IP Forwarding:${NC}"
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && print_success "ENABLED" || print_error "DISABLED"
    
    echo -e "\n${YELLOW}[3] Tunnel Interface:${NC}"
    TUN_IFACES=$(ip link show 2>/dev/null | grep -iE "flagtun|tun" | awk -F: '{print $2}' | tr -d ' ')
    if [ -n "$TUN_IFACES" ]; then
        for iface in $TUN_IFACES; do
            print_success "$iface is UP"
            ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print "    IPv4: " $2}'
        done
    else
        print_error "No tunnel interface found"
    fi
    
    echo -e "\n${YELLOW}[4] Routes:${NC}"
    ip route show | grep -E "flagtun|tun|10.0.0" | sed 's/^/  /' || print_info "No tunnel routes"
    
    echo -e "\n${YELLOW}[5] Traffic Stats:${NC}"
    journalctl -u "${SERVICE_NAME}" -n 3 --no-pager 2>/dev/null | grep "stats" | sed 's/^/  /' || print_info "No stats"
    
    echo -e "\n${YELLOW}[6] Port Forwarding:${NC}"
    if [ -f "$FORWARD_FILE" ]; then
        while IFS= read -r PORT; do echo -e "  ${CYAN}▸${NC} $PORT -> main"; done < "$FORWARD_FILE"
    else
        print_info "None"
    fi
    
    echo -e "\n${YELLOW}[7] Last Logs:${NC}"
    journalctl -u "${SERVICE_NAME}" -n 5 --no-pager 2>/dev/null | sed 's/^/  /'
    
    echo -e "\n═══════════════════════════════════════════"
    read -p "Press Enter..." < /dev/tty
}

# ============================================
# TEST CONNECTION
# ============================================
test_connection() {
    echo ""; print_header "🧪 Connection Test"
    read -p "  🎯 Ping target (server=10.0.0.1 / client=10.0.0.2): " TARGET < /dev/tty
    TARGET=${TARGET:-10.0.0.1}
    
    print_status "Pinging $TARGET through tunnel..."
    if ping -c 4 -W 3 "$TARGET" 2>/dev/null; then
        echo ""; print_success "✅ TUNNEL WORKING! Traffic is passing."
    else
        echo ""; print_error "❌ FAILED! Troubleshooting:"
        echo "  1. Check both sides are running: systemctl status stinger-tunnel"
        echo "  2. Check server port is open: ss -tuln | grep <port>"
        echo "  3. Check logs: journalctl -u stinger-tunnel -f"
        echo "  4. Make sure peer_tun IPs match on both sides"
        echo "  5. Try restarting: systemctl restart stinger-tunnel"
    fi
    read -p "Press Enter..." < /dev/tty
}

# ============================================
# MAIN MENU
# ============================================
while true; do
    clear
    echo "═══════════════════════════════════════════"
    echo "  🔓 Stinger Tunnel - Final Fixed Edition"
    echo "═══════════════════════════════════════════"
    echo ""
    print_menu "1. 🖥️  Install SERVER"
    print_menu "2. 💻 Install CLIENT"
    print_menu "3. 🔍 Status & Diagnostics"
    print_menu "4. 🧪 Test Connection (Ping)"
    print_menu "5. 🔄 Restart Tunnel"
    print_menu "6. 🛑 Stop Tunnel"
    print_menu "7. 🗑️  Uninstall"
    print_menu "8. 🚪 Exit"
    echo ""
    read -p "Select [1-8]: " CHOICE < /dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." < /dev/tty ;;
        2) install_client; read -p "Press Enter..." < /dev/tty ;;
        3) check_status ;;
        4) test_connection ;;
        5) systemctl restart "${SERVICE_NAME}"; print_success "Restarted!"; sleep 2 ;;
        6) stop_service; read -p "Press Enter..." < /dev/tty ;;
        7) uninstall_stinger; read -p "Press Enter..." < /dev/tty ;;
        8) exit 0 ;;
        *) sleep 1 ;;
    esac
done
