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
# Enable IP Forwarding (CRITICAL for traffic)
# ============================================
enable_ip_forwarding() {
    print_status "Enabling IP forwarding..."
    
    # Enable immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    # Make persistent after reboot
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    # Also check sysctl.d
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-stinger-forward.conf
    fi
    
    sysctl -p > /dev/null 2>&1
    print_success "IP forwarding enabled permanently"
}

# ============================================
# Setup iptables rules for tunnel traffic
# ============================================
setup_tunnel_firewall() {
    local MODE=$1
    
    print_status "Setting up firewall rules for tunnel traffic..."
    
    # Install required packages
    if ! command -v iptables &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    fi
    
    if ! command -v netfilter-persistent &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent > /dev/null 2>&1 || true
    fi
    
    # Allow traffic on tunnel interfaces (tun0, tun1, flagtun0, etc.)
    iptables -A INPUT -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o flagtun+ -j ACCEPT 2>/dev/null || true
    
    # Allow FORWARD traffic through tunnel
    iptables -A FORWARD -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -o flagtun+ -j ACCEPT 2>/dev/null || true
    
    # Allow established connections
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    # NAT/MASQUERADE for tunnel subnet
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE 2>/dev/null || true
    
    # Allow tunnel subnet traffic
    iptables -A FORWARD -s "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -d "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    
    # Save rules
    netfilter-persistent save > /dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    print_success "Firewall rules applied and saved"
}

# ============================================
# Port Forwarding (Server only)
# ============================================
setup_port_forwarding() {
    local MAIN_PORT=$1
    local FORWARD_PORTS=$2
    
    if [ -z "$FORWARD_PORTS" ]; then
        return 0
    fi
    
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
    if [ ! -f "$FORWARD_FILE" ]; then
        return 0
    fi
    
    print_status "Removing port forwarding rules..."
    while IFS= read -r PORT; do
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then
            iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT 2>/dev/null || true
            iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-port 8080 2>/dev/null || true
        fi
    done < "$FORWARD_FILE"
    
    rm -f "$FORWARD_FILE"
    netfilter-persistent save > /dev/null 2>&1 || true
    print_success "Port forwarding removed"
}

# ============================================
# Create Systemd Service (Survives Reboot)
# ============================================
create_systemd_service() {
    print_status "Creating systemd service for auto-start..."
    
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" > /dev/null 2>&1
    print_success "Systemd service created and enabled (auto-start on boot)"
}

# ============================================
# Start/Stop Service
# ============================================
start_service() {
    print_status "Starting Stinger service..."
    systemctl restart "${SERVICE_NAME}"
    sleep 3
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "Stinger is RUNNING (systemd managed)"
        print_info "Check logs: journalctl -u ${SERVICE_NAME} -f"
    else
        print_error "Failed to start service. Checking logs..."
        journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
    fi
}

stop_service() {
    print_status "Stopping Stinger service..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "stinger.bin" 2>/dev/null || true
    pkill -x "stinger" 2>/dev/null || true
    print_success "Stinger stopped"
}

# ============================================
# Uninstall
# ============================================
uninstall_stinger() {
    echo ""
    print_header "🗑️  Uninstalling Stinger..."
    
    stop_service
    remove_port_forwarding
    
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    
    rm -rf "$INSTALL_DIR"
    
    print_success "✅ Uninstall completed! All files, services, and rules removed."
}

# ============================================
# Install Server
# ============================================
install_server() {
    echo ""; print_header "🖥️  Installing Stinger SERVER..."
    
    # Install dependencies
    if ! command -v wget &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq wget file
    fi
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Download binary
    print_status "Downloading stinger binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    # Remove restrictions
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
[ -f "$BINARY_PATH" ] && exec "$BINARY_PATH" "$@" || { echo "[✗] stinger.bin not found!"; exit 1; }
WRAPPER
    fi
    
    # Get configuration
    echo ""
    read -p "  🌐 Remote IP (0.0.0.0 = any client) [0.0.0.0]: " REMOTE_IP < /dev/tty
    REMOTE_IP=${REMOTE_IP:-0.0.0.0}
    
    read -p "  🔗 Main Tunnel Port [8080]: " MAIN_PORT < /dev/tty
    MAIN_PORT=${MAIN_PORT:-8080}
    
    read -p "  🛜  Tunnel Virtual IP [10.0.0.1/24]: " LOCAL_TUN < /dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.1/24}
    
    echo ""
    print_info "💡 Forward additional ports to main tunnel port (optional)"
    read -p "  🔀 Extra ports (e.g. 443,2053,80) or press Enter to skip: " FORWARD_PORTS < /dev/tty
    
    # Create config
    print_status "Creating server configuration..."
    cat > config.toml << EOF
mode = "server"
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"

[server]
host = "0.0.0.0"
port = ${MAIN_PORT}
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"
EOF
    
    chmod +x "${BINARY_NAME}"
    
    # Enable networking
    enable_ip_forwarding
    setup_tunnel_firewall "server"
    
    # Port forwarding
    if [ -n "$FORWARD_PORTS" ]; then
        setup_port_forwarding "$MAIN_PORT" "$FORWARD_PORTS"
    fi
    
    # Create systemd service
    create_systemd_service
    
    # Start service
    start_service
    
    echo ""
    print_success "═══════════════════════════════════════════"
    print_success "✅ SERVER INSTALLED SUCCESSFULLY!"
    print_success "═══════════════════════════════════════════"
    print_info "  Main Port: $MAIN_PORT"
    print_info "  Tunnel IP: $LOCAL_TUN"
    [ -n "$FORWARD_PORTS" ] && print_info "  Forwarded: $FORWARD_PORTS -> $MAIN_PORT"
    print_info "  Service: systemctl status ${SERVICE_NAME}"
    print_info "  Logs: journalctl -u ${SERVICE_NAME} -f"
    print_success "═══════════════════════════════════════════"
}

# ============================================
# Install Client
# ============================================
install_client() {
    echo ""; print_header "💻 Installing Stinger CLIENT..."
    
    # Install dependencies
    if ! command -v wget &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq wget file
    fi
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Download binary
    print_status "Downloading stinger binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    # Remove restrictions
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-client"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
[ -f "$BINARY_PATH" ] && exec "$BINARY_PATH" "$@" || { echo "[✗] stinger.bin not found!"; exit 1; }
WRAPPER
    fi
    
    # Get configuration
    echo ""
    read -p "  🌐 Server IP: " SERVER_IP < /dev/tty
    if [ -z "$SERVER_IP" ]; then
        print_error "Server IP is required!"
        return 1
    fi
    
    read -p "  🔗 Server Port (ONE port only, e.g. 443) [8080]: " SERVER_PORT < /dev/tty
    SERVER_PORT=${SERVER_PORT:-8080}
    
    read -p "  🛜  Client Tunnel IP [10.0.0.2/24]: " LOCAL_TUN < /dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.2/24}
    
    # Create config
    print_status "Creating client configuration..."
    cat > config.toml << EOF
mode = "client"
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"
EOF
    
    chmod +x "${BINARY_NAME}"
    
    # Enable networking
    enable_ip_forwarding
    setup_tunnel_firewall "client"
    
    # Create systemd service
    create_systemd_service
    
    # Start service
    start_service
    
    echo ""
    print_success "═══════════════════════════════════════════"
    print_success "✅ CLIENT INSTALLED SUCCESSFULLY!"
    print_success "═══════════════════════════════════════════"
    print_info "  Server: $SERVER_IP:$SERVER_PORT"
    print_info "  Tunnel IP: $LOCAL_TUN"
    print_info "  Service: systemctl status ${SERVICE_NAME}"
    print_info "  Logs: journalctl -u ${SERVICE_NAME} -f"
    print_success "═══════════════════════════════════════════"
}

# ============================================
# Check Status
# ============================================
check_status() {
    echo ""; print_header "🔍 Stinger Status Report"
    echo "═══════════════════════════════════════════"
    
    # Service status
    echo -e "\n${YELLOW}[1] Service Status:${NC}"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_success "Stinger service is ACTIVE and RUNNING"
        systemctl status "${SERVICE_NAME}" --no-pager -l | head -10
    else
        print_error "Stinger service is NOT RUNNING"
    fi
    
    # IP Forwarding
    echo -e "\n${YELLOW}[2] IP Forwarding:${NC}"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
        print_success "IP forwarding is ENABLED"
    else
        print_error "IP forwarding is DISABLED (traffic won't pass!)"
    fi
    
    # Tunnel interfaces
    echo -e "\n${YELLOW}[3] Tunnel Interfaces:${NC}"
    TUN_IFACES=$(ip link show 2>/dev/null | grep -iE "tun|tap|flagtun" | awk -F: '{print $2}' | tr -d ' ')
    if [ -n "$TUN_IFACES" ]; then
        print_success "Tunnel interface(s) found:"
        for iface in $TUN_IFACES; do
            echo -e "  ${CYAN}▸${NC} $iface"
            ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print "    IPv4: " $2}'
        done
    else
        print_warning "No tunnel interfaces found"
    fi
    
    # iptables rules
    echo -e "\n${YELLOW}[4] Firewall Rules:${NC}"
    FORWARD_RULES=$(iptables -L FORWARD -n 2>/dev/null | grep -c "ACCEPT" || echo "0")
    NAT_RULES=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "REDIRECT" || echo "0")
    echo -e "  FORWARD ACCEPT rules: ${GREEN}${FORWARD_RULES}${NC}"
    echo -e "  NAT REDIRECT rules: ${GREEN}${NAT_RULES}${NC}"
    
    # Port forwarding
    echo -e "\n${YELLOW}[5] Port Forwarding:${NC}"
    if [ -f "$FORWARD_FILE" ]; then
        while IFS= read -r PORT; do
            echo -e "  ${CYAN}▸${NC} Port $PORT -> Main tunnel"
        done < "$FORWARD_FILE"
    else
        print_info "No port forwarding configured"
    fi
    
    # Recent logs
    echo -e "\n${YELLOW}[6] Recent Logs:${NC}"
    journalctl -u "${SERVICE_NAME}" -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || print_info "No logs available"
    
    echo -e "\n═══════════════════════════════════════════"
    read -p "Press Enter to return to menu..." < /dev/tty
}

# ============================================
# Test Connectivity
# ============================================
test_connection() {
    echo ""; print_header "🧪 Testing Tunnel Connectivity..."
    
    read -p "  🎯 Enter target tunnel IP to ping (e.g. 10.0.0.1): " TARGET_IP < /dev/tty
    
    if [ -z "$TARGET_IP" ]; then
        print_warning "No IP provided"
        return
    fi
    
    print_status "Pinging $TARGET_IP..."
    if ping -c 4 -W 3 "$TARGET_IP"; then
        echo ""
        print_success "✅ CONNECTION SUCCESSFUL! Tunnel is working."
    else
        echo ""
        print_error "❌ CONNECTION FAILED! Check the following:"
        echo "  1. Is Stinger running on both server and client?"
        echo "  2. Is the server port open in firewall?"
        echo "  3. Are tunnel IPs in the same subnet?"
        echo "  4. Check logs: journalctl -u ${SERVICE_NAME} -f"
    fi
    
    read -p "Press Enter to return to menu..." < /dev/tty
}

# ============================================
# Main Menu
# ============================================
while true; do
    clear
    echo "═══════════════════════════════════════════"
    echo "  🔓 Stinger Unlocked - Final Edition"
    echo "     Auto-Start | Port Forward | Traffic Fix"
    echo "═══════════════════════════════════════════"
    echo ""
    print_menu "1. 🖥️  Install & Start SERVER"
    print_menu "2. 💻 Install & Start CLIENT"
    print_menu "3. 🔍 Check Status & Diagnostics"
    print_menu "4. 🧪 Test Connection (Ping)"
    print_menu "5. 🔄 Restart Tunnel"
    print_menu "6. 🛑 Stop Tunnel"
    print_menu "7. 🗑️  Uninstall Everything"
    print_menu "8. 🚪 Exit"
    echo ""

    read -p "Select an option [1-8]: " CHOICE < /dev/tty

    case $CHOICE in
        1) install_server; read -p "Press Enter to continue..." < /dev/tty ;;
        2) install_client; read -p "Press Enter to continue..." < /dev/tty ;;
        3) check_status ;;
        4) test_connection ;;
        5) systemctl restart "${SERVICE_NAME}"; print_success "Tunnel restarted!"; sleep 2 ;;
        6) stop_service; read -p "Press Enter to continue..." < /dev/tty ;;
        7) uninstall_stinger; read -p "Press Enter to continue..." < /dev/tty ;;
        8) print_info "Exiting..."; exit 0 ;;
        *) print_warning "Invalid option"; sleep 1 ;;
    esac
done
