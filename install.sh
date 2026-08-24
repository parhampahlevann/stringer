#!/bin/bash
# ============================================================================
# Stinger Tunnel - Fixed Edition v5
# Server=IRAN | Client=FOREIGN
#
# FIXES vs v4:
#  1) transport=tcp  (ICMP transport is dropped by Iranian ISPs -> data dead)
#  2) tun-setup.sh never exits non-zero -> systemd unit survives boot races
#  3) MTU aligned to stinger inner MTU (1320) + MSS clamp rule added
#  4) iptables-persistent installed+enabled reliably -> rules survive reboot
#  5) Full-tunnel default route restored automatically after reboot
#  6) Port redirection also opens INPUT ACCEPT (was missing -> forward dead)
#  7) All iptables ops are delete-then-add -> no duplicate rules
# ============================================================================
set -e

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
FULL_TUNNEL_FLAG="${INSTALL_DIR}/.full_tunnel_enabled"
TUN_MTU=1320   # FIX: match stinger inner MTU (was 1280 -> mismatch drops packets)

detect_main_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}
MAIN_IFACE=$(detect_main_iface)

# Loop-delete until no match remains
del_rule() {
    local table="$1" chain="$2" spec="$3"
    while iptables -t "$table" -C "$chain" $spec 2>/dev/null; do
        iptables -t "$table" -D "$chain" $spec 2>/dev/null || break
    done
}

cleanup_firewall() {
    local MAIN_PORT="${1:-}"
    print_status "Cleaning up firewall rules..."

    if [ -f "$FORWARD_FILE" ] && [ -n "$MAIN_PORT" ]; then
        while IFS= read -r PORT; do
            [[ "$PORT" =~ ^[0-9]+$ ]] || continue
            del_rule nat PREROUTING "-p tcp --dport $PORT -j REDIRECT --to-port $MAIN_PORT"
            del_rule filter INPUT "-p tcp --dport $PORT -j ACCEPT"   # FIX: clean INPUT too
        done < "$FORWARD_FILE"
    fi

    [ -n "$MAIN_PORT" ] && del_rule filter INPUT "-p tcp --dport $MAIN_PORT -j ACCEPT"

    del_rule filter INPUT "-i tun+ -j ACCEPT"
    del_rule filter OUTPUT "-o tun+ -j ACCEPT"
    del_rule filter FORWARD "-i tun+ -j ACCEPT"
    del_rule filter FORWARD "-o tun+ -j ACCEPT"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -o $MAIN_IFACE -j MASQUERADE"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -j MASQUERADE"
    del_rule filter FORWARD "-s $TUNNEL_SUBNET -j ACCEPT"
    del_rule filter FORWARD "-d $TUNNEL_SUBNET -j ACCEPT"
    del_rule filter FORWARD "-m state --state ESTABLISHED,RELATED -j ACCEPT"
    # FIX: remove MSS clamp on cleanup too
    del_rule mangle FORWARD "-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"

    print_success "Firewall cleaned up"
}

save_iptables() {
    mkdir -p /etc/iptables 2>/dev/null || true
    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

# FIX: install & enable persistence for real (was silently skipped with || true)
ensure_iptables_persistent() {
    if ! command -v netfilter-persistent &>/dev/null; then
        print_status "Installing iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    fi
    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    systemctl start netfilter-persistent >/dev/null 2>&1 || true
}

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
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if ! grep -q "^net.ipv4.conf.all.rp_filter=0" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
    fi
    if [ -d /etc/sysctl.d ]; then
        echo -e "net.ipv4.ip_forward=1\nnet.ipv4.conf.all.rp_filter=0" > /etc/sysctl.d/99-stinger-forward.conf
    fi
    sysctl -p >/dev/null 2>&1 || true
    print_success "IP forwarding & rp_filter disabled permanently"
}

setup_tunnel_firewall() {
    local MAIN_PORT=$1
    print_status "Setting up firewall rules..."

    if ! command -v iptables &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq iptables
    fi
    ensure_iptables_persistent

    cleanup_firewall "$MAIN_PORT"

    iptables -A INPUT -i tun+ -j ACCEPT
    iptables -A OUTPUT -o tun+ -j ACCEPT
    iptables -A FORWARD -i tun+ -j ACCEPT
    iptables -A FORWARD -o tun+ -j ACCEPT

    [ -n "$MAIN_PORT" ] && iptables -A INPUT -p tcp --dport "$MAIN_PORT" -j ACCEPT 2>/dev/null || true

    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    # FIX: MSS clamp -> TCP through the tunnel now works
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # FIX: delete-then-add -> never duplicate MASQUERADE
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -o $MAIN_IFACE -j MASQUERADE"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -j MASQUERADE"
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE

    iptables -A FORWARD -s "$TUNNEL_SUBNET" -j ACCEPT
    iptables -A FORWARD -d "$TUNNEL_SUBNET" -j ACCEPT

    save_iptables
    print_success "Firewall rules applied (main iface: $MAIN_IFACE)"
}

fix_broad_nat() {
    print_status "Checking for overly broad NAT rules..."
    local found=0
    while true; do
        local line
        line=$(iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "MASQUERADE\s+all\s+--\s+0\.0\.0\.0/0\s+0\.0\.0\.0/0" | head -1 | awk '{print $1}')
        [ -z "$line" ] && break
        iptables -t nat -D POSTROUTING "$line" 2>/dev/null && { print_success "Removed broad rule at line $line"; found=1; } || break
    done
    [ "$found" = "0" ] && print_info "No broad NAT rules found"
    save_iptables
}

wait_for_tun_iface() {
    local MAX_WAIT=${1:-30}
    local TUN_IFACE=""
    print_status "Waiting for TUN interface (max ${MAX_WAIT}s)..."

    for i in $(seq 1 $MAX_WAIT); do
        # FIX: match the real name "flagtun0" explicitly
        TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)
        [ -z "$TUN_IFACE" ] && TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE '\btun[0-9]+' | head -1)
        [ -n "$TUN_IFACE" ] && { print_success "TUN interface detected: $TUN_IFACE"; echo "$TUN_IFACE"; return 0; }
        sleep 1
    done
    print_error "TUN interface not found after ${MAX_WAIT}s"
    return 1
}

setup_routing() {
    local PEER_TUN_IP=$1
    local TUN_IFACE=""

    print_status "Setting up routing through tunnel..."
    TUN_IFACE=$(wait_for_tun_iface 30) || return 1
    sleep 2

    ip route del "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    ip route del "${PEER_TUN_IP}/32" dev "$TUN_IFACE" 2>/dev/null || true

    ip link set "$TUN_IFACE" mtu "$TUN_MTU" 2>/dev/null || true
    ip link set "$TUN_IFACE" up 2>/dev/null || true

    ip route add "${PEER_TUN_IP}/32" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true

    cat > /etc/network/if-up.d/stinger-routes << EOF
#!/bin/bash
TUN_IFACE=\$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)
[ -z "\$TUN_IFACE" ] && exit 0
ip link set "\$TUN_IFACE" mtu ${TUN_MTU} 2>/dev/null || true
ip link set "\$TUN_IFACE" up 2>/dev/null || true
ip route del ${PEER_TUN_IP}/32 dev "\$TUN_IFACE" 2>/dev/null || true
ip route del ${TUNNEL_SUBNET} dev "\$TUN_IFACE" 2>/dev/null || true
ip route add ${PEER_TUN_IP}/32 dev "\$TUN_IFACE" 2>/dev/null || true
ip route add ${TUNNEL_SUBNET} dev "\$TUN_IFACE" 2>/dev/null || true
EOF
    chmod +x /etc/network/if-up.d/stinger-routes 2>/dev/null || true
    print_success "Routing configured: $PEER_TUN_IP via $TUN_IFACE (MTU $TUN_MTU)"
}

# Full tunnel for IRAN SERVER (route all traffic through tunnel to foreign client)
setup_full_tunnel_server() {
    local FOREIGN_PEER_IP=$1
    local TUN_IFACE=""

    print_status "Enabling SERVER FULL TUNNEL (Iran -> Foreign)..."
    TUN_IFACE=$(wait_for_tun_iface 10) || return 1

    local MAIN_GW MAIN_IFACE
    MAIN_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    MAIN_IFACE=$(detect_main_iface)

    if [ -z "$MAIN_GW" ] || [ -z "$MAIN_IFACE" ]; then
        print_error "Cannot detect default gateway"
        return 1
    fi

    cat > "${INSTALL_DIR}/.full_tunnel_backup" << EOF
MAIN_GW=$MAIN_GW
MAIN_IFACE=$MAIN_IFACE
FOREIGN_PEER=$FOREIGN_PEER_IP
EOF

    ip route del "$FOREIGN_PEER_IP" 2>/dev/null || true
    ip route add "$FOREIGN_PEER_IP" via "$MAIN_GW" dev "$MAIN_IFACE" 2>/dev/null || true

    ip route del default dev "$TUN_IFACE" metric 100 2>/dev/null || true
    ip route add default dev "$TUN_IFACE" metric 100 2>/dev/null || true

    touch "$FULL_TUNNEL_FLAG"
    print_success "Server full tunnel enabled."
    print_info "Foreign peer $FOREIGN_PEER_IP kept on $MAIN_IFACE."
}

# Full tunnel for FOREIGN CLIENT (NAT traffic coming from tunnel to internet)
setup_full_tunnel_client() {
    print_status "Enabling CLIENT FULL TUNNEL (Foreign -> Internet NAT)..."
    local TUN_IFACE
    TUN_IFACE=$(wait_for_tun_iface 10) || return 1

    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -o $MAIN_IFACE -j MASQUERADE"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -j MASQUERADE"
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$TUNNEL_SUBNET" -j MASQUERADE

    save_iptables
    touch "$FULL_TUNNEL_FLAG"
    print_success "Client NAT ready for tunnel traffic."
}

remove_full_tunnel() {
    print_status "Disabling full tunnel mode..."
    local TUN_IFACE
    TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)

    [ -n "$TUN_IFACE" ] && ip route del default dev "$TUN_IFACE" metric 100 2>/dev/null || true

    if [ -f "${INSTALL_DIR}/.full_tunnel_backup" ]; then
        local FOREIGN_PEER
        FOREIGN_PEER=$(grep "^FOREIGN_PEER=" "${INSTALL_DIR}/.full_tunnel_backup" 2>/dev/null | cut -d= -f2)
        [ -n "$FOREIGN_PEER" ] && ip route del "$FOREIGN_PEER" 2>/dev/null || true
    fi

    rm -f "$FULL_TUNNEL_FLAG" "${INSTALL_DIR}/.full_tunnel_backup"
    print_success "Full tunnel disabled"
}

setup_port_redirection() {
    local MAIN_PORT=$1
    local REDIRECT_PORTS=$2
    [ -z "$REDIRECT_PORTS" ] && return 0

    print_status "Setting up port redirection to Stinger main port..."
    > "$FORWARD_FILE"
    IFS=',' read -ra PORT_ARRAY <<< "$REDIRECT_PORTS"

    for PORT in "${PORT_ARRAY[@]}"; do
        PORT=$(echo "$PORT" | tr -d ' ')
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then
            del_rule nat PREROUTING "-p tcp --dport $PORT -j REDIRECT --to-port $MAIN_PORT"
            iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j REDIRECT --to-port "$MAIN_PORT"
            # FIX: must also ACCEPT the port in INPUT (was missing -> forward dead)
            del_rule filter INPUT "-p tcp --dport $PORT -j ACCEPT"
            iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
            echo "$PORT" >> "$FORWARD_FILE"
            print_success "Port $PORT -> $MAIN_PORT (Stinger)"
        fi
    done
    save_iptables
}

remove_port_redirection() {
    local MAIN_PORT="${1:-}"
    [ ! -f "$FORWARD_FILE" ] && return 0

    print_status "Removing port redirection..."
    while IFS= read -r PORT; do
        [[ "$PORT" =~ ^[0-9]+$ ]] || continue
        del_rule nat PREROUTING "-p tcp --dport $PORT -j REDIRECT --to-port $MAIN_PORT"
        del_rule filter INPUT "-p tcp --dport $PORT -j ACCEPT"   # FIX: clean INPUT too
    done < "$FORWARD_FILE"
    rm -f "$FORWARD_FILE"
    save_iptables
}

create_systemd_service() {
    print_status "Creating systemd service..."

    # FIX: tun-setup.sh now exits 0 always (never kills the unit), MTU 1320,
    #      and restores the full-tunnel default route after every boot.
    cat > "${INSTALL_DIR}/tun-setup.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/stinger"
TUNNEL_SUBNET="10.0.0.0/24"
CONF="${INSTALL_DIR}/config.toml"
FLAG="${INSTALL_DIR}/.full_tunnel_enabled"
BACKUP="${INSTALL_DIR}/.full_tunnel_backup"

PEER_TUN=$(grep "peer_tun" "$CONF" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
TUN_IFACE=""

for i in {1..30}; do
    TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)
    [ -z "$TUN_IFACE" ] && TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE '\btun[0-9]+' | head -1)
    [ -n "$TUN_IFACE" ] && break
    sleep 1
done

# Never exit non-zero: a failure here must NOT kill the stinger service
[ -z "$TUN_IFACE" ] && { echo "TUN interface not found (giving up, staying alive)"; exit 0; }

ip link set "$TUN_IFACE" mtu 1320 2>/dev/null || true
ip link set "$TUN_IFACE" up 2>/dev/null || true

if [ -n "$PEER_TUN" ]; then
    ip route del "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
fi
ip route del "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true

# Restore SERVER full-tunnel default route after reboot
if [ -f "$FLAG" ] && [ -f "$BACKUP" ]; then
    MAIN_GW=$(grep "^MAIN_GW=" "$BACKUP" 2>/dev/null | cut -d= -f2)
    MAIN_IFACE=$(grep "^MAIN_IFACE=" "$BACKUP" 2>/dev/null | cut -d= -f2)
    FOREIGN_PEER=$(grep "^FOREIGN_PEER=" "$BACKUP" 2>/dev/null | cut -d= -f2)
    if [ -n "$MAIN_GW" ] && [ -n "$MAIN_IFACE" ] && [ -n "$FOREIGN_PEER" ]; then
        ip route del "$FOREIGN_PEER" 2>/dev/null || true
        ip route add "$FOREIGN_PEER" via "$MAIN_GW" dev "$MAIN_IFACE" 2>/dev/null || true
        ip route del default dev "$TUN_IFACE" metric 100 2>/dev/null || true
        ip route add default dev "$TUN_IFACE" metric 100 2>/dev/null || true
        echo "Full-tunnel route restored"
    fi
fi

echo "TUN setup complete: $TUN_IFACE"
exit 0
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
    local MAIN_PORT=""
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        MAIN_PORT=$(grep -E "^\s*port\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *\([0-9]*\).*/\1/')
    fi

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "stinger" 2>/dev/null || true

    local TUN_IFACE
    TUN_IFACE=$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)
    if [ -n "$TUN_IFACE" ]; then
        ip route flush dev "$TUN_IFACE" 2>/dev/null || true
        ip link del "$TUN_IFACE" 2>/dev/null || true
    fi

    cleanup_firewall "$MAIN_PORT"
    [ -f "$FULL_TUNNEL_FLAG" ] && remove_full_tunnel

    print_success "Stinger stopped and cleaned up"
}

uninstall_stinger() {
    echo ""; print_header "Uninstalling..."

    local MAIN_PORT=""
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        MAIN_PORT=$(grep -E "^\s*port\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *\([0-9]*\).*/\1/')
    fi

    stop_service
    remove_port_redirection "$MAIN_PORT"
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f /etc/network/if-up.d/stinger-routes
    rm -f "${INSTALL_DIR}/tun-setup.sh"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    print_success "Fully uninstalled!"
}

download_and_patch_binary() {
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
    chmod +x "${BINARY_NAME}"
}

install_server() {
    echo ""; print_header "Installing Stinger SERVER (Iran)..."
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2; }
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

    download_and_patch_binary

    echo ""
    read -p "  Remote IP (0.0.0.0=any) [0.0.0.0]: " REMOTE_IP </dev/tty
    REMOTE_IP=${REMOTE_IP:-0.0.0.0}
    read -p "  Main Port [443]: " MAIN_PORT </dev/tty
    MAIN_PORT=${MAIN_PORT:-443}
    read -p "  Server Tunnel IP [10.0.0.1/24]: " LOCAL_TUN </dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.1/24}
    read -p "  Client Tunnel IP (peer_tun) [10.0.0.2]: " PEER_TUN </dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.2}
    # FIX: transport is now selectable; tcp default (icmp gets dropped for data in Iran)
    read -p "  Transport (tcp/udp/icmp) [tcp]: " TRANSPORT </dev/tty
    TRANSPORT=${TRANSPORT:-tcp}
    echo ""
    print_info "Extra ports to redirect to Stinger (e.g. 443,2053) or Enter:"
    read -p "  Ports: " REDIRECT_PORTS </dev/tty

    cat > config.toml << EOF
mode = "server"
remote_ip = "${REMOTE_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"
transport = "${TRANSPORT}"

[server]
host = "0.0.0.0"
port = ${MAIN_PORT}
EOF

    load_tun_module
    enable_ip_forwarding
    fix_broad_nat
    setup_tunnel_firewall "$MAIN_PORT"
    [ -n "$REDIRECT_PORTS" ] && setup_port_redirection "$MAIN_PORT" "$REDIRECT_PORTS"
    create_systemd_service
    start_service || { print_error "Service failed to start"; return 1; }

    sleep 3
    setup_routing "$PEER_TUN"

    echo ""
    read -p "  Route ALL server traffic through tunnel? [y/N]: " FULL_TUN </dev/tty
    [[ "$FULL_TUN" =~ ^[Yy]$ ]] && setup_full_tunnel_server "$PEER_TUN"

    echo ""
    print_success "============================================"
    print_success "SERVER (IRAN) INSTALLED!"
    print_success "============================================"
    print_info "  Port: $MAIN_PORT | Tunnel: $LOCAL_TUN | Transport: $TRANSPORT"
    print_info "  Peer: $PEER_TUN"
    print_info "  Main Interface: $MAIN_IFACE"
    [ -n "$REDIRECT_PORTS" ] && print_info "  Redirected to Stinger: $REDIRECT_PORTS"
    [[ "$FULL_TUN" =~ ^[Yy]$ ]] && print_info "  Mode: FULL TUNNEL (all traffic -> foreign)"
    print_info "  Test: curl -4 ip.gs  (must show FOREIGN IP)"
    print_success "============================================"
}

install_client() {
    echo ""; print_header "Installing Stinger CLIENT (Foreign)..."
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2; }
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

    download_and_patch_binary

    echo ""
    read -p "  Iran Server IP: " SERVER_IP </dev/tty
    [ -z "$SERVER_IP" ] && { print_error "Server IP required!"; return 1; }
    read -p "  Server Port [443]: " SERVER_PORT </dev/tty
    SERVER_PORT=${SERVER_PORT:-443}
    read -p "  Client Tunnel IP [10.0.0.2/24]: " LOCAL_TUN </dev/tty
    LOCAL_TUN=${LOCAL_TUN:-10.0.0.2/24}
    read -p "  Server Tunnel IP (peer_tun) [10.0.0.1]: " PEER_TUN </dev/tty
    PEER_TUN=${PEER_TUN:-10.0.0.1}
    read -p "  Transport (tcp/udp/icmp) [tcp]: " TRANSPORT </dev/tty
    TRANSPORT=${TRANSPORT:-tcp}

    cat > config.toml << EOF
mode = "client"
remote_ip = "${SERVER_IP}"
local_tun = "${LOCAL_TUN}"
peer_tun = "${PEER_TUN}"
transport = "${TRANSPORT}"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
EOF

    load_tun_module
    enable_ip_forwarding
    fix_broad_nat
    setup_tunnel_firewall "$SERVER_PORT"
    create_systemd_service
    start_service || { print_error "Service failed to start"; return 1; }

    sleep 3
    setup_routing "$PEER_TUN"
    setup_full_tunnel_client

    echo ""
    print_success "============================================"
    print_success "CLIENT (FOREIGN) INSTALLED!"
    print_success "============================================"
    print_info "  Server: $SERVER_IP:$SERVER_PORT | Transport: $TRANSPORT"
    print_info "  Tunnel: $LOCAL_TUN | Peer: $PEER_TUN"
    print_info "  Main Interface: $MAIN_IFACE"
    print_info "  NAT enabled for tunnel subnet"
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

    echo -e "\n${YELLOW}[2] Transport & Config:${NC}"
    grep -E "mode|transport|remote_ip|local_tun|peer_tun|port" "${INSTALL_DIR}/config.toml" 2>/dev/null | sed 's/^/  /'

    echo -e "\n${YELLOW}[3] IP Forwarding & rp_filter:${NC}"
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] && print_success "ip_forward ENABLED" || print_error "ip_forward DISABLED"
    [ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)" = "0" ] && print_success "rp_filter DISABLED (good)" || print_warning "rp_filter ENABLED (may drop packets)"

    echo -e "\n${YELLOW}[4] TUN Interface:${NC}"
    local TUN_IFACES
    TUN_IFACES=$(ip -o link show 2>/dev/null | grep -oE 'flagtun[0-9]+' | head -1)
    if [ -n "$TUN_IFACES" ]; then
        for iface in $TUN_IFACES; do
            print_success "$iface is UP"
            ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print "    IPv4: " $2}'
            local MTU
            MTU=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+')
            echo -e "    MTU: ${MTU:-unknown}"
        done
    else
        print_error "No tunnel interface found"
    fi

    echo -e "\n${YELLOW}[5] Routes:${NC}"
    ip route show | grep -E "flagtun|10.0.0" | sed 's/^/  /' || print_info "No tunnel routes"
    [ -f "$FULL_TUNNEL_FLAG" ] && print_success "  FULL TUNNEL MODE is ACTIVE" || print_warning "  Full tunnel NOT active"

    echo -e "\n${YELLOW}[6] Firewall (NAT + MSS):${NC}"
    iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "MASQUERADE|10.0.0" | sed 's/^/  /' || print_info "No NAT rules for tunnel"
    MSS=$(iptables -t mangle -L FORWARD -n 2>/dev/null | grep -c "TCPMSS" || true)
    [ "$MSS" -gt 0 ] && print_success "  MSS clamp: present" || print_warning "  MSS clamp: MISSING"

    echo -e "\n${YELLOW}[7] Port Redirection:${NC}"
    if [ -f "$FORWARD_FILE" ]; then
        while IFS= read -r PORT; do echo -e "  -> $PORT -> Stinger main"; done < "$FORWARD_FILE"
    else
        print_info "None"
    fi

    echo -e "\n${YELLOW}[8] Last Logs:${NC}"
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
        echo "  1. Check both sides running: systemctl status stinger-tunnel"
        echo "  2. Check transport in logs: journalctl -u stinger-tunnel | grep transport"
        echo "  3. Make sure both configs use the SAME transport (tcp recommended)"
        echo "  4. Check TUN interface: ip link show | grep flagtun"
        echo "  5. Check routes: ip route | grep 10.0.0"
        echo "  6. Check firewall: iptables -L -n | grep tun"
        echo "  7. Try restart: systemctl restart stinger-tunnel"
    fi
    read -p "Press Enter..." </dev/tty
}

repair_tunnel() {
    echo ""; print_header "Repair Tunnel"
    print_status "Attempting automatic repair..."

    load_tun_module
    fix_broad_nat

    local PORT="" PEER_TUN=""
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        PORT=$(grep -E "^\s*port\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *\([0-9]*\).*/\1/')
        PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    fi

    cleanup_firewall "$PORT"
    setup_tunnel_firewall "$PORT"

    [ -n "$PEER_TUN" ] && setup_routing "$PEER_TUN"

    # FIX: re-apply full tunnel after repair if it was enabled
    if [ -f "$FULL_TUNNEL_FLAG" ] && [ -n "$PEER_TUN" ]; then
        setup_full_tunnel_server "$PEER_TUN"
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

toggle_server_full_tunnel() {
    echo ""; print_header "Toggle Server Full Tunnel (Iran)"
    if [ -f "$FULL_TUNNEL_FLAG" ]; then
        remove_full_tunnel
    else
        local PEER_TUN
        PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
        [ -z "$PEER_TUN" ] && read -p "  Enter peer_tun IP (foreign side): " PEER_TUN </dev/tty
        [ -n "$PEER_TUN" ] && setup_full_tunnel_server "$PEER_TUN"
    fi
    read -p "Press Enter..." </dev/tty
}

while true; do
    clear
    echo "============================================"
    echo "  Stinger Tunnel - Fixed Edition v5"
    echo "  Server=IRAN  |  Client=FOREIGN"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER (Iran)"
    print_menu "2. Install CLIENT (Foreign)"
    print_menu "3. Status & Diagnostics"
    print_menu "4. Test Connection (Ping)"
    print_menu "5. Repair / Fix Routes & Firewall"
    print_menu "6. Restart Tunnel"
    print_menu "7. Stop Tunnel"
    print_menu "8. Uninstall"
    print_menu "9. Toggle Server Full Tunnel (Iran)"
    print_menu "10. Fix Broad NAT Rules"
    print_menu "11. Exit"
    echo ""
    read -p "Select [1-11]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." </dev/tty ;;
        2) install_client; read -p "Press Enter..." </dev/tty ;;
        3) check_status ;;
        4) test_connection ;;
        5) repair_tunnel ;;
        6) systemctl restart "${SERVICE_NAME}"; print_success "Restarted!"; sleep 2 ;;
        7) stop_service; read -p "Press Enter..." </dev/tty ;;
        8) uninstall_stinger; read -p "Press Enter..." </dev/tty ;;
        9) toggle_server_full_tunnel ;;
        10) fix_broad_nat; read -p "Press Enter..." </dev/tty ;;
        11) exit 0 ;;
        *) sleep 1 ;;
    esac
done
