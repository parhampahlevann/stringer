#!/bin/bash
set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_header() { echo -e "${GREEN}▶${NC} $1"; }
print_menu() { echo -e "${BLUE}▸${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

INSTALL_DIR="/opt/stinger"
BINARY_NAME="stinger"
SERVICE_NAME="stinger-tunnel"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"
FORWARD_FILE="${INSTALL_DIR}/forwarded_ports.txt"
TUNNEL_SUBNET="10.0.0.0/24"

detect_main_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}
MAIN_IFACE=$(detect_main_iface)

load_tun_module() {
    print_status "Loading TUN module..."
    modprobe tun 2>/dev/null || true
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi
    if [ -c /dev/net/tun ]; then
        print_success "TUN device ready"
    else
        print_error "TUN device not available!"
        return 1
    fi
}

enable_ip_forwarding() {
    print_status "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-stinger-forward.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
    print_success "IP forwarding enabled permanently"
}

setup_tunnel_firewall() {
    local MAIN_PORT=$1
    print_status "Setting up firewall rules..."
    
    if ! command -v iptables &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    fi
    if ! command -v netfilter-persistent &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
    fi
    
    iptables -D INPUT -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    iptables -A INPUT -i tun+ -j ACCEPT
    iptables -A OUTPUT -o tun+ -j ACCEPT
    iptables -A FORWARD -i tun+ -j ACCEPT
    iptables -A FORWARD -o tun+ -j ACCEPT
    
    if [ -n "$MAIN_PORT" ]; then
        iptables -A INPUT -p tcp --dport "$MAIN_PORT" -j ACCEPT 2>/dev/null || true
    fi
    
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE
    
    iptables -A FORWARD -s "$TUNNEL_SUBNET" -j ACCEPT
    iptables -A FORWARD -d "$TUNNEL_SUBNET" -j ACCEPT
    
    netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    print_success "Firewall rules applied (main iface: $MAIN_IFACE)"
}

wait_for_tun_iface() {
    local MAX_WAIT=${1:-30}
    local TUN_IFACE=""
    print_status "Waiting for TUN interface to appear (max ${MAX_WAIT}s)..."
    
    for i in $(seq 1 $MAX_WAIT); do
        TUN_IFACE=$(ip link show 2>/dev/null | grep -iE "tun|flagtun" | awk -F: '{print $2}' | tr -d ' ' | head -n1)
        if [ -n "$TUN_IFACE" ]; then
            print_success "TUN interface detected: $TUN_IFACE"
            echo "$TUN_IFACE"
            return 0
        fi
        sleep 1
    done
    print_error "TUN interface not found after ${MAX_WAIT}s"
    return 1
}

setup_routing() {
    local PEER_TUN_IP=$1
    
    print_status "Setting up routing through tunnel..."
    
    local TUN_IFACE
    TUN_IFACE=$(wait_for_tun_iface 30) || return 1
    
    sleep 2
    
    ip link set "$TUN_IFACE" mtu 1400 2>/dev/null || true
    ip link set "$TUN_IFACE" up 2>/dev/null || true
    
    ip route add "${PEER_TUN_IP}/32" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    
    cat > /etc/network/if-up.d/stinger-routes << EOF
#!/bin/bash
TUN_IFACE=\$(ip link show 2>/dev/null | grep -iE "tun|flagtun" | awk -F: '{print \$2}' | tr -d ' ' | head -n1)
if [ -n "\$TUN_IFACE" ]; then
    ip link set "\$TUN_IFACE" mtu 1400 2>/dev/null || true
    ip link set "\$TUN_IFACE" up 2>/dev/null || true
    ip route add ${PEER_TUN_IP}/32 dev "\$TUN_IFACE" 2>/dev/null || true
    ip route add ${TUNNEL_SUBNET} dev "\$TUN_IFACE" 2>/dev/null || true
fi
EOF
    chmod +x /etc/network/if-up.d/stinger-routes 2>/dev/null || true
    
    print_success "Routing configured: $PEER_TUN_IP via $TUN_IFACE (MTU 1400)"
}

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
    netfilter-persistent save >/dev/null 2>&1 || true
}

remove_port_forwarding() {
    [ ! -f "$FORWARD_FILE" ] && return 0
    print_status "Removing port forwarding..."
    while IFS= read -r PORT; do
        [[ "$PORT" =~ ^[0-9]+$ ]] && iptables -t nat -D PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-port "$MAIN_PORT" 2>/dev/null || true
    done < "$FORWARD_FILE"
    rm -f "$FORWARD_FILE"
    netfilter-persistent save >/dev/null 2>&1 || true
}

create_systemd_service() {
    print_status "Creating systemd service..."
    
    cat > "${INSTALL_DIR}/tun-setup.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/stinger"
TUNNEL_SUBNET="10.0.0.0/24"
PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')

for i in {1..30}; do
    TUN_IFACE=$(ip link show 2>/dev/null | grep -iE "tun|flagtun" | awk -F: '{print $2}' | tr -d ' ' | head -n1)
    if [ -n "$TUN_IFACE" ]; then
        ip link set "$TUN_IFACE" mtu 1400 2>/dev/null || true
        ip link set "$TUN_IFACE" up 2>/dev/null || true
        if [ -n "$PEER_TUN" ]; then
            ip route add "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
        fi
        ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
        echo "TUN setup complete: $TUN_IFACE"
        exit 0
    fi
    sleep 1
done
echo "TUN interface not found"
exit 1
EOF
    chmod +x "${INSTALL_DIR}/tun-setup.sh"
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Stinger Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/bin/bash -c 'modprobe tun; mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun'
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
ExecStartPost=${INSTALL_DIR}/tun-setup.sh
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=stinger

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    print_success "Systemd service created (auto-start on boot)"
}

start_service() {
    print_status "Starting Stinger service..."
    systemctl restart "${SERVICE_NAME}"
    sleep 5
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "Stinger is RUNNING"
        sleep 3
        bash "${INSTALL_DIR}/tun-setup.sh" >/dev/null 2>&1 || true
    else
        print_error "Failed to start. Logs:"
        journalctl -u "${SERVICE_NAME}" -n 20 --no-pager
        return 1
    fi
}

stop_service() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "stinger" 2>/dev/null || true
    ip route flush dev flagtun0 2>/dev/null || true
    ip link del flagtun0 2>/dev/null || true
    print_success "Stinger stopped"
}

uninstall_stinger() {
    echo ""; print_header "Uninstalling..."
    stop_service
    remove_port_forwarding
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f /etc/network/if-up.d/stinger-routes
    rm -f "${INSTALL_DIR}/tun-setup.sh"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    print_success "Fully uninstalled!"
}

install_server() {
    echo ""; print_header "Installing Stinger SERVER..."
    
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2; }
    
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    
    print_status "Downloading binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d; /exit 1.*check/d; /exit 1.*valid/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
export STINGER_SKIP_VALIDATION="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/stinger.bin" "$@"
WRAPPER
    fi
    
    echo ""
    read -p "  Remote IP (0.0.0.0=any) [0.0.0.0]: " REMOTE_IP </dev/tty
    REMOTE_IP=${REMOTE_IP:-0.0.0.0}
    read -p "  Main Port [8080]: " MAIN_PORT </dev/tty
    MAIN_PORT=${MAIN_PORT:-8080}
    read -p "  Server Tunnel IP [10.0.0.1/24]: " LOCAL_TUN </dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.1/24}
    read -p "  Client Tunnel IP (peer_tun) [10.0.0.2]: " PEER_TUN </dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.2}
    echo ""
    print_info "Extra ports to forward (e.g. 443,2053) or Enter to skip:"
    read -p "  Ports: " FORWARD_PORTS </dev/tty
    
    cat > config.toml << EOF
mode = "server"
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"

[server]
host = "0.0.0.0"
port = ${MAIN_PORT}
EOF
    
    chmod +x "${BINARY_NAME}"
    
    load_tun_module
    enable_ip_forwarding
    setup_tunnel_firewall "$MAIN_PORT"
    [ -n "$FORWARD_PORTS" ] && setup_port_forwarding "$MAIN_PORT" "$FORWARD_PORTS"
    create_systemd_service
    start_service || { print_error "Service failed to start"; return 1; }
    
    sleep 3
    setup_routing "$PEER_TUN"
    
    echo ""
    print_success "============================================"
    print_success "SERVER INSTALLED!"
    print_success "============================================"
    print_info "  Port: $MAIN_PORT | Tunnel: $LOCAL_TUN"
    print_info "  Peer: $PEER_TUN"
    print_info "  Main Interface: $MAIN_IFACE"
    [ -n "$FORWARD_PORTS" ] && print_info "  Forwarded: $FORWARD_PORTS"
    print_info "  Test: ping $PEER_TUN"
    print_success "============================================"
}

install_client() {
    echo ""; print_header "Installing Stinger CLIENT..."
    
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2; }
    
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    
    print_status "Downloading binary..."
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d; /exit 1.*check/d; /exit 1.*valid/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-client"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
export STINGER_SKIP_VALIDATION="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/stinger.bin" "$@"
WRAPPER
    fi
    
    echo ""
    read -p "  Server IP: " SERVER_IP </dev/tty
    [ -z "$SERVER_IP" ] && { print_error "Server IP required!"; return 1; }
    read -p "  Server Port (ONE port) [443]: " SERVER_PORT </dev/tty
    SERVER_PORT=${SERVER_PORT:-443}
    read -p "  Client Tunnel IP [10.0.0.2/24]: " LOCAL_TUN </dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.2/24}
    read -p "  Server Tunnel IP (peer_tun) [10.0.0.1]: " PEER_TUN </dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.1}
    
    cat > config.toml << EOF
mode = "client"
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
EOF
    
    chmod +x "${BINARY_NAME}"
    
    load_tun_module
    enable_ip_forwarding
    setup_tunnel_firewall "$SERVER_PORT"
    create_systemd_service
    start_service || { print_error "Service failed to start"; return 1; }
    
    sleep 3
    setup_routing "$PEER_TUN"
    
    echo ""
    print_success "============================================"
    print_success "CLIENT INSTALLED!"
    print_success "============================================"
    print_info "  Server: $SERVER_IP:$SERVER_PORT"
    print_info "  Tunnel: $LOCAL_TUN | Peer: $PEER_TUN"
    print_info "  Main Interface: $MAIN_IFACE"
    print_info "  Test: ping $PEER_TUN"
    print_success "============================================"
}

check_status() {
    echo ""; print_header "Status Report"
    echo "============================================"
    
    echo -e "\n${YELLOW}[1] Service:${NC}"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        PID=$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null)
        print_success "RUNNING (PID: $PID)"
    else
        print_error "NOT RUNNING"
    fi
    
    echo -e "\n${YELLOW}[2] IP Forwarding:${NC}"
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] && print_success "ENABLED" || print_error "DISABLED"
    
    echo -e "\n${YELLOW}[3] TUN Module:${NC}"
    [ -c /dev/net/tun ] && print_success "/dev/net/tun exists" || print_error "/dev/net/tun missing"
    
    echo -e "\n${YELLOW}[4] Tunnel Interface:${NC}"
    TUN_IFACES=$(ip link show 2>/dev/null | grep -iE "tun|flagtun" | awk -F: '{print $2}' | tr -d ' ')
    if [ -n "$TUN_IFACES" ]; then
        for iface in $TUN_IFACES; do
            print_success "$iface is UP"
            ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print "    IPv4: " $2}'
            ip link show "$iface" 2>/dev/null | grep -q "mtu 1400" && echo -e "    MTU: 1400" || echo -e "    MTU: not 1400 (may cause issues)"
        done
    else
        print_error "No tunnel interface found"
    fi
    
    echo -e "\n${YELLOW}[5] Routes:${NC}"
    ip route show | grep -E "tun|flagtun|10.0.0" | sed 's/^/  /' || print_info "No tunnel routes"
    
    echo -e "\n${YELLOW}[6] Firewall (NAT):${NC}"
    iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "MASQUERADE|10.0.0" | sed 's/^/  /' || print_info "No NAT rules for tunnel"
    
    echo -e "\n${YELLOW}[7] Port Forwarding:${NC}"
    if [ -f "$FORWARD_FILE" ]; then
        while IFS= read -r PORT; do echo -e "  -> $PORT -> main"; done < "$FORWARD_FILE"
    else
        print_info "None"
    fi
    
    echo -e "\n${YELLOW}[8] Config:${NC}"
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        grep -E "peer_tun|local_tun|mode|port|host" "${INSTALL_DIR}/config.toml" | sed 's/^/  /'
    else
        print_error "config.toml not found"
    fi
    
    echo -e "\n${YELLOW}[9] Last Logs:${NC}"
    journalctl -u "${SERVICE_NAME}" -n 8 --no-pager 2>/dev/null | sed 's/^/  /'
    
    echo -e "\n============================================"
    read -p "Press Enter..." </dev/tty
}

test_connection() {
    echo ""; print_header "Connection Test"
    read -p "  Ping target (server=10.0.0.1 / client=10.0.0.2): " TARGET </dev/tty
    TARGET=${TARGET:-10.0.0.1}
    
    print_status "Pinging $TARGET through tunnel..."
    if ping -c 4 -W 3 "$TARGET" 2>/dev/null; then
        echo ""; print_success "TUNNEL WORKING! Traffic is passing."
    else
        echo ""; print_error "FAILED! Troubleshooting:"
        echo "  1. Check both sides are running: systemctl status stinger-tunnel"
        echo "  2. Check server port is open: ss -tuln | grep <port>"
        echo "  3. Check logs: journalctl -u stinger-tunnel -f"
        echo "  4. Make sure peer_tun IPs match on both sides"
        echo "  5. Check TUN interface exists: ip link show | grep tun"
        echo "  6. Check routes: ip route | grep 10.0.0"
        echo "  7. Check firewall: iptables -L -n | grep tun"
        echo "  8. Try restarting: systemctl restart stinger-tunnel"
        echo "  9. Check MTU: ip link show | grep mtu"
    fi
    read -p "Press Enter..." </dev/tty
}

repair_tunnel() {
    echo ""; print_header "Repair Tunnel"
    print_status "Attempting automatic repair..."
    
    load_tun_module
    
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        PORT=$(grep -E "port" "${INSTALL_DIR}/config.toml" | head -n1 | sed 's/.*= *\([0-9]*\).*/\1/')
        setup_tunnel_firewall "$PORT"
    fi
    
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
        if [ -n "$PEER_TUN" ]; then
            setup_routing "$PEER_TUN"
        fi
    fi
    
    systemctl restart "${SERVICE_NAME}"
    sleep 5
    
    bash "${INSTALL_DIR}/tun-setup.sh" 2>/dev/null || true
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "Repair complete!"
    else
        print_error "Repair failed. Check logs."
    fi
    read -p "Press Enter..." </dev/tty
}

while true; do
    clear
    echo "============================================"
    echo "  Stinger Tunnel - Fixed Edition v2"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER"
    print_menu "2. Install CLIENT"
    print_menu "3. Status & Diagnostics"
    print_menu "4. Test Connection (Ping)"
    print_menu "5. Repair / Fix Routes"
    print_menu "6. Restart Tunnel"
    print_menu "7. Stop Tunnel"
    print_menu "8. Uninstall"
    print_menu "9. Exit"
    echo ""
    read -p "Select [1-9]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." </dev/tty ;;
        2) install_client; read -p "Press Enter..." </dev/tty ;;
        3) check_status ;;
        4) test_connection ;;
        5) repair_tunnel ;;
        6) systemctl restart "${SERVICE_NAME}"; print_success "Restarted!"; sleep 2 ;;
        7) stop_service; read -p "Press Enter..." </dev/tty ;;
        8) uninstall_stinger; read -p "Press Enter..." </dev/tty ;;
        9) exit 0 ;;
        *) sleep 1 ;;
    esac
done
