#!/bin/bash
# ============================================================================
# Stinger Tunnel - Fixed Edition v14 (Full-tunnel + top-of-chain firewall)
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_status()   { echo -e "${BLUE}[*]${NC} $1"; }
print_success()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()    { echo -e "${RED}[✗]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[!]${NC} $1"; }
print_header()   { echo -e "${GREEN}▶${NC} $1"; }
print_menu()     { echo -e "${BLUE}▸${NC} $1"; }
print_info()     { echo -e "${CYAN}[i]${NC} $1"; }

INSTALL_DIR="/opt/stinger"
BINARY_NAME="stinger"
SERVICE_NAME="stinger-tunnel"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"
FWD_FILE="${INSTALL_DIR}/fwd_to_foreign.txt"
TUNNEL_SUBNET="10.0.0.0/24"
TUN_MTU=1280

detect_main_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}
MAIN_IFACE=$(detect_main_iface)

del_rule() {
    local table="$1" chain="$2" spec="$3"
    while iptables -t "$table" -C "$chain" $spec 2>/dev/null; do
        iptables -t "$table" -D "$chain" $spec 2>/dev/null || break
    done
}

install_iptables_persistent() {
    if command -v netfilter-persistent &>/dev/null; then return 0; fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>/dev/null; then return 0; fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netfilter-persistent 2>/dev/null; then return 0; fi
    mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    cat > /etc/systemd/system/iptables-restore.service << 'EOF'
[Unit]
Description=Restore iptables rules
After=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable iptables-restore 2>/dev/null || true
}

save_iptables() {
    mkdir -p /etc/iptables 2>/dev/null || true
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true
    else iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; fi
}

load_tun_module() {
    modprobe tun 2>/dev/null || true
    if [ ! -c /dev/net/tun ]; then mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null || true; chmod 600 /dev/net/tun 2>/dev/null || true; fi
}

enable_ip_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "^net.ipv4.conf.all.rp_filter=0" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.conf.all.rp_filter=0" >> /etc/sysctl.conf
    grep -q "^net.ipv4.conf.default.rp_filter=0" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.conf.default.rp_filter=0" >> /etc/sysctl.conf
    grep -q "^net.ipv4.icmp_echo_ignore_all=0" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.icmp_echo_ignore_all=0" >> /etc/sysctl.conf
    mkdir -p /etc/sysctl.d
    echo -e "net.ipv4.ip_forward=1\nnet.ipv4.conf.all.rp_filter=0\nnet.ipv4.conf.default.rp_filter=0\nnet.ipv4.icmp_echo_ignore_all=0" > /etc/sysctl.d/99-stinger.conf
    sysctl -p >/dev/null 2>&1 || true
}

cleanup_firewall() {
    local MAIN_PORT="${1:-}"
    del_rule filter INPUT "-i tun+ -j ACCEPT"; del_rule filter INPUT "-i flagtun+ -j ACCEPT"
    del_rule filter OUTPUT "-o tun+ -j ACCEPT"; del_rule filter OUTPUT "-o flagtun+ -j ACCEPT"
    del_rule filter FORWARD "-i tun+ -j ACCEPT"; del_rule filter FORWARD "-o tun+ -j ACCEPT"
    del_rule filter FORWARD "-i flagtun+ -j ACCEPT"; del_rule filter FORWARD "-o flagtun+ -j ACCEPT"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -o $MAIN_IFACE -j MASQUERADE"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -j MASQUERADE"
    del_rule filter FORWARD "-s $TUNNEL_SUBNET -j ACCEPT"; del_rule filter FORWARD "-d $TUNNEL_SUBNET -j ACCEPT"
    del_rule filter FORWARD "-m state --state ESTABLISHED,RELATED -j ACCEPT"
    del_rule mangle FORWARD "-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    # remove full-tunnel routes (def1 trick + explicit server route)
    ip route del 0.0.0.0/1 2>/dev/null || true
    ip route del 128.0.0.0/1 2>/dev/null || true
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        local SERVER_IP
        SERVER_IP=$(grep -E "remote_ip\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
        [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "0.0.0.0" ] && ip route del "$SERVER_IP" 2>/dev/null || true
    fi
}

setup_tunnel_firewall() {
    local MAIN_PORT=$1
    cleanup_firewall "$MAIN_PORT"
    # All rules INSERTED at position 1 so pre-existing DROP rules (UFW/Docker/cloud) can't shadow them
    iptables -I INPUT 1 -p icmp -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT 1 -p icmp -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p icmp -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT 1 -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT 1 -o flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -i tun+ -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -o tun+ -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -i flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -o flagtun+ -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -s "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -d "$TUNNEL_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -t nat -I POSTROUTING 1 -s "$TUNNEL_SUBNET" -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$TUNNEL_SUBNET" -j MASQUERADE
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    save_iptables
}

wait_for_tun_iface() {
    local MAX_WAIT=${1:-30}; local TUN_IFACE=""
    for i in $(seq 1 $MAX_WAIT); do
        TUN_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '/tun|flagtun/ {print $2; exit}')
        [ -n "$TUN_IFACE" ] && { echo "$TUN_IFACE"; return 0; }
        sleep 1
    done
    return 1
}

setup_routing() {
    local PEER_TUN=$1
    local LOCAL_TUN
    LOCAL_TUN=$(grep "local_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    TUN_IFACE=$(wait_for_tun_iface 30) || return 1
    sleep 2
    # rp_filter must be off per-interface (kernel uses max(all, dev))
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf."${TUN_IFACE}".rp_filter=0 >/dev/null 2>&1
    echo 0 > /proc/sys/net/ipv4/conf/"${TUN_IFACE}"/rp_filter 2>/dev/null || true
    ip route del "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    ip route del "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
    ip link set "$TUN_IFACE" mtu $TUN_MTU 2>/dev/null || true
    ip link set "$TUN_IFACE" up 2>/dev/null || true
    [ -n "$LOCAL_TUN" ] && ip addr replace "$LOCAL_TUN" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    cat > /etc/network/if-pre-up.d/stinger-routes << EOF
#!/bin/bash
TUN_IFACE=\$(ip -o link show 2>/dev/null | awk -F': ' '/tun|flagtun/ {print \$2; exit}')
[ -z "\$TUN_IFACE" ] && exit 0
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf."\$TUN_IFACE".rp_filter=0 >/dev/null 2>&1
echo 0 > /proc/sys/net/ipv4/conf/"\$TUN_IFACE"/rp_filter 2>/dev/null || true
ip link set "\$TUN_IFACE" mtu $TUN_MTU 2>/dev/null || true
ip link set "\$TUN_IFACE" up 2>/dev/null || true
ip addr replace "$LOCAL_TUN" dev "\$TUN_IFACE" 2>/dev/null || true
ip route del ${PEER_TUN}/32 dev "\$TUN_IFACE" 2>/dev/null || true
ip route del $TUNNEL_SUBNET dev "\$TUN_IFACE" 2>/dev/null || true
ip route add ${PEER_TUN}/32 dev "\$TUN_IFACE" 2>/dev/null || true
ip route add $TUNNEL_SUBNET dev "\$TUN_IFACE" 2>/dev/null || true
EOF
    chmod +x /etc/network/if-pre-up.d/stinger-routes 2>/dev/null || true
    chmod +x /etc/network/if-up.d/stinger-routes 2>/dev/null || true
}

setup_full_tunnel_client() {
    # 1) MASQUERADE at top of chain (fallback for LAN clients)
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -o $MAIN_IFACE -j MASQUERADE"
    del_rule nat POSTROUTING "-s $TUNNEL_SUBNET -j MASQUERADE"
    iptables -t nat -I POSTROUTING 1 -s "$TUNNEL_SUBNET" -j MASQUERADE 2>/dev/null || true

    # 2) Full-tunnel default route (def1 trick) — safe for SSH
    local SERVER_IP TUN_IFACE MAIN_GW
    SERVER_IP=$(grep -E "remote_ip\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    TUN_IFACE=$(wait_for_tun_iface 15) || return 1
    MAIN_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "0.0.0.0" ] && return 0
    [ -z "$MAIN_GW" ] && { print_warning "No physical default gateway found; skipping full-tunnel routes."; return 1; }

    # Tunnel's own packets must go via the physical path, never into the tunnel itself
    ip route del "$SERVER_IP" 2>/dev/null || true
    ip route add "$SERVER_IP" via "$MAIN_GW" dev "$MAIN_IFACE" 2>/dev/null || true

    # Two /1 routes beat the /0 default route (OpenVPN "def1" trick)
    ip route del 0.0.0.0/1 2>/dev/null || true
    ip route del 128.0.0.0/1 2>/dev/null || true
    ip route add 0.0.0.0/1 dev "$TUN_IFACE" 2>/dev/null || true
    ip route add 128.0.0.0/1 dev "$TUN_IFACE" 2>/dev/null || true

    # Persist across reboots (only applies when the tunnel iface actually exists)
    cat > /etc/network/if-up.d/stinger-fulltunnel << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/stinger"
[ -f "${INSTALL_DIR}/config.toml" ] || exit 0
TUN_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '/tun|flagtun/ {print $2; exit}')
[ -z "$TUN_IFACE" ] && exit 0
SERVER_IP=$(grep -E "remote_ip\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
MAIN_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
MAIN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "0.0.0.0" ] || [ -z "$MAIN_GW" ] && exit 0
ip route del "$SERVER_IP" 2>/dev/null || true
ip route add "$SERVER_IP" via "$MAIN_GW" dev "$MAIN_IFACE" 2>/dev/null || true
ip route del 0.0.0.0/1 2>/dev/null || true
ip route del 128.0.0.0/1 2>/dev/null || true
ip route add 0.0.0.0/1 dev "$TUN_IFACE" 2>/dev/null || true
ip route add 128.0.0.0/1 dev "$TUN_IFACE" 2>/dev/null || true
EOF
    chmod +x /etc/network/if-up.d/stinger-fulltunnel 2>/dev/null || true
    print_success "Full-tunnel enabled: all traffic via $TUN_IFACE (server $SERVER_IP stays on physical path)"
    save_iptables
}

apply_forward_rules() {
    [ ! -f "$FWD_FILE" ] && return 0
    local FOREIGN_TUN
    FOREIGN_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    local LOCAL_TUN
    LOCAL_TUN=$(grep "local_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/' | cut -d'/' -f1)
    [ -z "$FOREIGN_TUN" ] || [ -z "$LOCAL_TUN" ] && return 1

    while IFS= read -r PORT; do
        [[ "$PORT" =~ ^[0-9]+$ ]] || continue
        for PROTO in tcp udp; do
            del_rule nat PREROUTING "-p $PROTO --dport $PORT -j DNAT --to-destination ${FOREIGN_TUN}:${PORT}"
            iptables -t nat -I PREROUTING 1 -p $PROTO --dport "$PORT" -j DNAT --to-destination "${FOREIGN_TUN}:${PORT}"

            # OUTPUT rule for local testing (localhost)
            del_rule nat OUTPUT "-p $PROTO --dport $PORT -j DNAT --to-destination ${FOREIGN_TUN}:${PORT}"
            iptables -t nat -I OUTPUT 1 -p $PROTO --dport "$PORT" -j DNAT --to-destination "${FOREIGN_TUN}:${PORT}"

            del_rule nat POSTROUTING "-d ${FOREIGN_TUN} -p $PROTO --dport ${PORT} -j SNAT --to-source ${LOCAL_TUN}"
            iptables -t nat -I POSTROUTING 1 -d "${FOREIGN_TUN}" -p $PROTO --dport "${PORT}" -j SNAT --to-source "${LOCAL_TUN}"
            del_rule filter FORWARD "-p $PROTO -d ${FOREIGN_TUN} --dport ${PORT} -j ACCEPT"
            iptables -I FORWARD 1 -p $PROTO -d "${FOREIGN_TUN}" --dport "${PORT}" -j ACCEPT
        done
    done < "$FWD_FILE"
    save_iptables
}

forward_ports_to_foreign() {
    echo ""; print_header "Port Forwarding to Foreign Server"
    if [ ! -f "${INSTALL_DIR}/config.toml" ]; then print_error "Config not found. Install Stinger first."; return 1; fi
    read -p "  Enter ports to forward (e.g., 80,443): " PORTS </dev/tty
    [ -z "$PORTS" ] && return 1
    > "$FWD_FILE"
    IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        PORT=$(echo "$PORT" | tr -d ' ')
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "$PORT" >> "$FWD_FILE"; fi
    done
    apply_forward_rules
    print_success "Ports forwarded! Test connection."
    read -p "Press Enter..." </dev/tty
}

remove_forward_ports() {
    [ ! -f "$FWD_FILE" ] && return 0
    local FOREIGN_TUN
    FOREIGN_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    local LOCAL_TUN
    LOCAL_TUN=$(grep "local_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/' | cut -d'/' -f1)
    while IFS= read -r PORT; do
        [[ "$PORT" =~ ^[0-9]+$ ]] || continue
        for PROTO in tcp udp; do
            del_rule nat PREROUTING "-p $PROTO --dport $PORT -j DNAT --to-destination ${FOREIGN_TUN}:${PORT}"
            del_rule nat OUTPUT "-p $PROTO --dport $PORT -j DNAT --to-destination ${FOREIGN_TUN}:${PORT}"
            del_rule nat POSTROUTING "-d ${FOREIGN_TUN} -p $PROTO --dport ${PORT} -j SNAT --to-source ${LOCAL_TUN}"
            del_rule filter FORWARD "-p $PROTO -d ${FOREIGN_TUN} --dport ${PORT} -j ACCEPT"
        done
    done < "$FWD_FILE"
    rm -f "$FWD_FILE"; save_iptables
}

create_systemd_service() {
    cat > "${INSTALL_DIR}/tun-setup.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/stinger"; TUNNEL_SUBNET="10.0.0.0/24"; TUN_MTU=1280
LOCAL_TUN=$(grep "local_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
for i in {1..30}; do
    TUN_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '/tun|flagtun/ {print $2; exit}')
    [ -z "$TUN_IFACE" ] && { sleep 1; continue; }
    sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
    sysctl -w net.ipv4.conf."${TUN_IFACE}".rp_filter=0 2>/dev/null || true
    echo 0 > /proc/sys/net/ipv4/conf/"${TUN_IFACE}"/rp_filter 2>/dev/null || true
    ip link set "$TUN_IFACE" mtu $TUN_MTU 2>/dev/null || true
    ip link set "$TUN_IFACE" up 2>/dev/null || true
    [ -n "$LOCAL_TUN" ] && ip addr replace "$LOCAL_TUN" dev "$TUN_IFACE" 2>/dev/null || true
    if [ -n "$PEER_TUN" ]; then
        ip route del "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
        ip route add "${PEER_TUN}/32" dev "$TUN_IFACE" 2>/dev/null || true
    fi
    ip route del "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    ip route add "$TUNNEL_SUBNET" dev "$TUN_IFACE" 2>/dev/null || true
    exit 0
done
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
StartLimitBurst=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
}

download_and_patch_binary() {
    wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL" || { print_error "Download failed!"; return 1; }
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d; /exit 1.*check/d; /exit 1.*valid/d' "${BINARY_NAME}" 2>/dev/null || true
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"; chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"; export FAKE_HOSTNAME="ubuntu-server"
export ALLOWED_SERVER="true"; export STINGER_IGNORE_CHECKS="1"; export STINGER_SKIP_VALIDATION="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/stinger.bin" "$@"
WRAPPER
    fi
    chmod +x "${BINARY_NAME}"
}

install_server() {
    echo ""; print_header "Installing Stinger SERVER (Iran)"
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2 iptables; }
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"; download_and_patch_binary
    read -p "  Main Port [443]: " MAIN_PORT </dev/tty; MAIN_PORT=${MAIN_PORT:-443}
    read -p "  Server Tunnel IP [10.0.0.1/24]: " LOCAL_TUN </dev/tty; LOCAL_TUN=${LOCAL_TUN:-10.0.0.1/24}
    read -p "  Client Tunnel IP [10.0.0.2]: " PEER_TUN </dev/tty; PEER_TUN=${PEER_TUN:-10.0.0.2}
    cat > config.toml << EOF
mode = "server"; remote_ip = "0.0.0.0"; local_tun = "${LOCAL_TUN}"; peer_tun = "${PEER_TUN}"; transport = "icmp"
[server]; host = "0.0.0.0"; port = ${MAIN_PORT}
EOF
    load_tun_module; enable_ip_forwarding; install_iptables_persistent
    setup_tunnel_firewall "$MAIN_PORT"; create_systemd_service
    systemctl restart "${SERVICE_NAME}"; sleep 5; setup_routing "$PEER_TUN"
    print_success "SERVER INSTALLED!"
}

install_client() {
    echo ""; print_header "Installing Stinger CLIENT (Foreign)"
    command -v wget &>/dev/null || { apt-get update -qq && apt-get install -y -qq wget file iproute2 iptables; }
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"; download_and_patch_binary
    read -p "  Iran Server IP: " SERVER_IP </dev/tty
    read -p "  Server Port [443]: " SERVER_PORT </dev/tty; SERVER_PORT=${SERVER_PORT:-443}
    read -p "  Client Tunnel IP [10.0.0.2/24]: " LOCAL_TUN </dev/tty; LOCAL_TUN=${LOCAL_TUN:-10.0.0.2/24}
    read -p "  Server Tunnel IP [10.0.0.1]: " PEER_TUN </dev/tty; PEER_TUN=${PEER_TUN:-10.0.0.1}
    cat > config.toml << EOF
mode = "client"; remote_ip = "${SERVER_IP}"; local_tun = "${LOCAL_TUN}"; peer_tun = "${PEER_TUN}"; transport = "icmp"
[client]; server_host = "${SERVER_IP}"; server_port = ${SERVER_PORT}
EOF
    load_tun_module; enable_ip_forwarding; install_iptables_persistent
    setup_tunnel_firewall "$SERVER_PORT"; create_systemd_service
    systemctl restart "${SERVICE_NAME}"; sleep 5; setup_routing "$PEER_TUN"; setup_full_tunnel_client
    print_success "CLIENT INSTALLED!"
}

repair_tunnel() {
    load_tun_module
    local PORT="" PEER_TUN="" MODE=""
    if [ -f "${INSTALL_DIR}/config.toml" ]; then
        MODE=$(grep -E "^\s*mode\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
        PORT=$(grep -E "^\s*port\s*=" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *\([0-9]*\).*/\1/')
        PEER_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')
    fi
    setup_tunnel_firewall "$PORT"
    systemctl restart "${SERVICE_NAME}"; sleep 3
    [ -n "$PEER_TUN" ] && setup_routing "$PEER_TUN"
    apply_forward_rules
    [ "$MODE" = "client" ] && setup_full_tunnel_client
    print_success "Repair complete!"
}

# ADVANCED DEBUG FUNCTION
debug_traffic() {
    echo ""; print_header "Advanced Debug Tunnel Traffic"
    if ! command -v tcpdump &>/dev/null; then
        print_status "Installing tcpdump..."
        apt-get update -qq && apt-get install -y -qq tcpdump 2>/dev/null
    fi
    read -p "  Enter port to trace (e.g. 1080): " PORT </dev/tty

    local FOREIGN_TUN
    FOREIGN_TUN=$(grep "peer_tun" "${INSTALL_DIR}/config.toml" 2>/dev/null | head -n1 | sed 's/.*= *"\(.*\)".*/\1/')

    echo ""
    print_info "--- 1. Checking Route to Foreign Server ($FOREIGN_TUN) ---"
    ip route get "$FOREIGN_TUN" 2>/dev/null || print_error "No route to $FOREIGN_TUN! Tunnel is broken."

    echo ""
    print_info "--- 2. Checking NAT PREROUTING Rules for Port $PORT ---"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep -E "dpt:$PORT" || print_warning "No DNAT rule found! Did you run Option 4?"

    echo ""
    print_info "--- 3. Checking NAT OUTPUT Rules (for local test) ---"
    iptables -t nat -L OUTPUT -n 2>/dev/null | grep -E "dpt:$PORT" || print_warning "No OUTPUT rule found."

    echo ""
    print_info "--- 4. Checking FORWARD rules are at the TOP (above DROP) ---"
    iptables -L FORWARD -n --line-numbers 2>/dev/null | head -n 8

    echo ""
    print_info "=================================================="
    print_info "Starting packet capture on ALL interfaces for port $PORT..."
    print_info "Try connecting to this server's Public IP on port $PORT NOW."
    print_info "If you see 'IRAN_IP.PORT > 10.0.0.2.PORT', DNAT is working."
    print_info "Press Ctrl+C to stop."
    print_info "=================================================="
    tcpdump -n -i any "port $PORT"
    read -p "Press Enter..." </dev/tty
}

uninstall_stinger() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true; pkill -f "stinger" 2>/dev/null || true
    remove_forward_ports; cleanup_firewall
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f /etc/network/if-up.d/stinger-routes; rm -f /etc/network/if-pre-up.d/stinger-routes
    rm -f /etc/network/if-up.d/stinger-fulltunnel
    rm -rf "$INSTALL_DIR"; systemctl daemon-reload
    print_success "Uninstalled!"
}

# ─── Main Menu ───
while true; do
    clear
    echo "============================================"
    echo "  Stinger Tunnel - Fixed Edition v14"
    echo "============================================"
    echo ""
    print_menu "1.  Install SERVER (Iran)"
    print_menu "2.  Install CLIENT (Foreign)"
    print_menu "3.  Repair / Fix Routes & Firewall"
    print_menu "4.  Forward Ports to Foreign Server"
    print_menu "5.  Remove Port Forwarding"
    print_menu "6.  Debug Traffic (tcpdump)"
    print_menu "7.  Restart Tunnel"
    print_menu "8.  Uninstall"
    print_menu "9.  Exit"
    echo ""
    read -p "Select [1-9]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." </dev/tty ;;
        2) install_client; read -p "Press Enter..." </dev/tty ;;
        3) repair_tunnel; read -p "Press Enter..." </dev/tty ;;
        4) forward_ports_to_foreign ;;
        5) remove_forward_ports; read -p "Press Enter..." </dev/tty ;;
        6) debug_traffic ;;
        7) systemctl restart "${SERVICE_NAME}"; print_success "Restarted!"; sleep 2 ;;
        8) uninstall_stinger; read -p "Press Enter..." </dev/tty ;;
        9) exit 0 ;;
        *) sleep 1 ;;
    esac
done
