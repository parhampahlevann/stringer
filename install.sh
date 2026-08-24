#!/bin/bash
# ============================================================================
# ICMP-over-VPN Tunnel Manager  (multi-port edition)
# Built on ptunnel-ng (https://github.com/utoni/ptunnel-ng) — open source,
# BSD licensed, compiled from source on your own machines. No third-party
# binaries, no patched/bypassed validation.
#
# What this does:
#   ptunnel-ng tunnels TCP connections inside ICMP echo request/reply
#   packets. We use it to carry your VPN's TCP control/data channel, so
#   from the outside the traffic just looks like ping packets.
#
# MULTI-PORT NOTE (read this before using PORTS):
#   ptunnel-ng's -r/-R flags fix ONE destination address:port per running
#   process — there is no built-in way to hand one instance a list of
#   ports. To forward several ports through the same ICMP path this
#   script runs one ptunnel-ng process per port (systemd template units,
#   ptunnel-ng-server@<port> / ptunnel-ng-client@<port>), all sharing the
#   same raw ICMP socket on the host. This generally works because each
#   session is tagged internally, but it is not as battle-tested as a
#   single instance — test with 2 ports before assuming 10 will behave,
#   and watch `debug_traffic` if a particular port misbehaves.
#
#   For the CLIENT, this script also adds a `nat OUTPUT` REDIRECT rule
#   per forwarded port so that anything on the client connecting to
#   <SERVER_PUBLIC_IP>:<port> is transparently sent into the matching
#   local tunnel listener instead — you don't have to repoint every app
#   at 127.0.0.1:<port> by hand.
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
PORTS_TAG_COMMENT="icmp-tunnel-manager"   # used to find/remove our iptables rules later

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
    persist_iptables
}

persist_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# Split "80, 443,8080" -> "80 443 8080", validating each entry is a bare port number.
parse_ports() {
    local raw="$1" out=() p
    IFS=',' read -ra parts <<< "$raw"
    for p in "${parts[@]}"; do
        p="$(echo -n "$p" | tr -d '[:space:]')"
        [ -z "$p" ] && continue
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            print_warning "Skipping invalid port entry: '$p'"
            continue
        fi
        out+=("$p")
    done
    echo "${out[@]}"
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

# Template unit: one process per extra forwarded port, instance name = the port number.
write_systemd_template() {
    local name="$1" exec_line_template="$2"   # exec_line_template uses %i for the port
    cat > "/etc/systemd/system/${name}@.service" <<EOF
[Unit]
Description=${name} (port %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${exec_line_template}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

start_port_instances() {
    local template="$1"; shift
    local ports=("$@")
    local p ok=0 fail=0
    for p in "${ports[@]}"; do
        systemctl enable --now "${template}@${p}.service" >/dev/null 2>&1
        sleep 0.3
        if systemctl is-active --quiet "${template}@${p}.service"; then
            print_success "  port ${p}: ${template}@${p} running"
            ok=$((ok+1))
        else
            print_error "  port ${p}: failed — journalctl -u ${template}@${p} -n 30"
            fail=$((fail+1))
        fi
    done
    print_info "Extra ports: ${ok} up, ${fail} failed."
}

stop_port_instances() {
    local template="$1"; shift
    local ports=("$@") p
    for p in "${ports[@]}"; do
        systemctl disable --now "${template}@${p}.service" >/dev/null 2>&1
    done
}

# Client-side only: redirect locally-originated connections aimed at
# SERVER_IP:port into the local tunnel listener for that port instead.
add_client_redirect_rules() {
    local server_ip="$1"; shift
    local ports=("$@") p
    for p in "${ports[@]}"; do
        iptables -t nat -C OUTPUT -p tcp -d "$server_ip" --dport "$p" \
            -m comment --comment "$PORTS_TAG_COMMENT" -j REDIRECT --to-port "$p" 2>/dev/null || \
        iptables -t nat -A OUTPUT -p tcp -d "$server_ip" --dport "$p" \
            -m comment --comment "$PORTS_TAG_COMMENT" -j REDIRECT --to-port "$p"
    done
    persist_iptables
}

remove_client_redirect_rules() {
    while read -r rule; do
        # rule is a full "-A OUTPUT ..." line from iptables-save; convert -A to -D
        eval "iptables -t nat -D ${rule#-A }" 2>/dev/null
    done < <(iptables-save -t nat 2>/dev/null | grep "$PORTS_TAG_COMMENT" | grep '^-A OUTPUT')
    persist_iptables
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
    read -p "  Extra TCP ports to also forward to ${DEST_IP}, comma-separated (leave blank for none): " EXTRA_PORTS_RAW </dev/tty
    read -p "  Password to protect the tunnel (leave blank for none): " TPASS </dev/tty
    read -p "  Custom magic value to help evade DPI pattern-matching (leave blank for default): " MAGIC </dev/tty

    local extra_ports; extra_ports=$(parse_ports "$EXTRA_PORTS_RAW")

    mkdir -p "$INSTALL_DIR"
    {
        echo "DEST_IP=${DEST_IP}"
        echo "DEST_PORT=${DEST_PORT}"
        echo "PORTS=${extra_ports}"
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
    systemctl is-active --quiet "$SERVER_SERVICE" && print_success "Main server tunnel running, forwarding to ${DEST_IP}:${DEST_PORT}" \
        || print_error "Main service failed to start — check: journalctl -u ${SERVER_SERVICE} -n 50"

    if [ -n "$extra_ports" ]; then
        print_status "Starting one ptunnel-ng instance per extra port..."
        write_systemd_template "$SERVER_SERVICE" "${BIN_PATH} -r${DEST_IP} -R%i -v1${extra}"
        # shellcheck disable=SC2086
        start_port_instances "$SERVER_SERVICE" $extra_ports
    fi
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
    read -p "  Extra TCP ports to also tunnel (must match the server's list), comma-separated: " EXTRA_PORTS_RAW </dev/tty
    read -p "  Password (must match the server, leave blank if none): " TPASS </dev/tty
    read -p "  Magic value (must match the server, leave blank for default): " MAGIC </dev/tty

    local extra_ports; extra_ports=$(parse_ports "$EXTRA_PORTS_RAW")

    mkdir -p "$INSTALL_DIR"
    {
        echo "SERVER_IP=${SERVER_IP}"
        echo "LISTEN_PORT=${LISTEN_PORT}"
        echo "DEST_IP=${DEST_IP}"
        echo "DEST_PORT=${DEST_PORT}"
        echo "PORTS=${extra_ports}"
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
        print_success "Main client tunnel running. Local listener: 127.0.0.1:${LISTEN_PORT}"
        print_info "Point your VPN client at 127.0.0.1:${LISTEN_PORT} (TCP) instead of the real server."
        print_warning "This only carries TCP. WireGuard (UDP) will not work over this tunnel."
    else
        print_error "Main service failed to start — check: journalctl -u ${CLIENT_SERVICE} -n 50"
    fi

    if [ -n "$extra_ports" ]; then
        print_status "Starting one ptunnel-ng instance per extra port (local listener = same port number)..."
        write_systemd_template "$CLIENT_SERVICE" "${BIN_PATH} -p${SERVER_IP} -l%i -r${DEST_IP} -R%i -v1${extra}"
        # shellcheck disable=SC2086
        start_port_instances "$CLIENT_SERVICE" $extra_ports

        print_status "Adding iptables rules to transparently redirect ${SERVER_IP}:<port> -> 127.0.0.1:<port>..."
        # shellcheck disable=SC2086
        add_client_redirect_rules "$SERVER_IP" $extra_ports
        print_info "Apps that connect to ${SERVER_IP} on those ports will be redirected into the tunnel automatically."
    fi
}

manage_ports() {
    echo ""; print_header "Add / remove extra forwarded ports"
    require_root
    if [ ! -f "$CONF_FILE" ]; then
        print_error "No config found — install the server or client first."
        read -p "Press Enter..." </dev/tty; return
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    local role="client"
    [ -z "${SERVER_IP:-}" ] && role="server"

    echo "  Current extra ports: ${PORTS:-none}"
    read -p "  New full list of extra ports, comma-separated (blank = remove all): " NEW_RAW </dev/tty
    local new_ports; new_ports=$(parse_ports "$NEW_RAW")
    local old_ports="${PORTS:-}"

    local extra=""
    [ -n "${TPASS:-}" ] && extra+=" -P${TPASS}"
    [ -n "${MAGIC:-}" ] && extra+=" -m${MAGIC}"

    if [ "$role" = "server" ]; then
        [ -n "$old_ports" ] && stop_port_instances "$SERVER_SERVICE" $old_ports
        if [ -n "$new_ports" ]; then
            write_systemd_template "$SERVER_SERVICE" "${BIN_PATH} -r${DEST_IP} -R%i -v1${extra}"
            start_port_instances "$SERVER_SERVICE" $new_ports
        fi
    else
        [ -n "$old_ports" ] && stop_port_instances "$CLIENT_SERVICE" $old_ports
        remove_client_redirect_rules
        if [ -n "$new_ports" ]; then
            write_systemd_template "$CLIENT_SERVICE" "${BIN_PATH} -p${SERVER_IP} -l%i -r${DEST_IP} -R%i -v1${extra}"
            start_port_instances "$CLIENT_SERVICE" $new_ports
            add_client_redirect_rules "$SERVER_IP" $new_ports
        fi
    fi

    # rewrite conf with the new PORTS value, preserving everything else
    grep -v '^PORTS=' "$CONF_FILE" > "${CONF_FILE}.tmp"
    echo "PORTS=${new_ports}" >> "${CONF_FILE}.tmp"
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    print_success "Port list updated."
    read -p "Press Enter..." </dev/tty
}

status_tunnel() {
    echo ""; print_header "Status"
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            echo ""
            systemctl status "$svc" --no-pager -l | head -n 12
        fi
    done
    echo ""
    print_info "Per-port instances:"
    systemctl list-units --all "ptunnel-ng-server@*.service" "ptunnel-ng-client@*.service" --no-legend 2>/dev/null
    read -p "Press Enter..." </dev/tty
}

debug_traffic() {
    echo ""; print_header "Debug — watching ICMP traffic (Ctrl+C to stop)"
    print_info "If the tunnel is working you should see steady echo-request/echo-reply pairs"
    print_info "between the two endpoints while a connection attempt is in progress."
    tcpdump -n -i any icmp
    read -p "Press Enter..." </dev/tty
}

restart_tunnel() {
    systemctl restart "$SERVER_SERVICE" 2>/dev/null
    systemctl restart "$CLIENT_SERVICE" 2>/dev/null
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        for p in ${PORTS:-}; do
            systemctl restart "${SERVER_SERVICE}@${p}.service" 2>/dev/null
            systemctl restart "${CLIENT_SERVICE}@${p}.service" 2>/dev/null
        done
    fi
    print_success "Restarted whichever service(s) are installed on this host."
    sleep 1
}

uninstall_tunnel() {
    require_root
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        for p in ${PORTS:-}; do
            systemctl disable --now "${SERVER_SERVICE}@${p}.service" 2>/dev/null || true
            systemctl disable --now "${CLIENT_SERVICE}@${p}.service" 2>/dev/null || true
        done
    fi
    remove_client_redirect_rules
    systemctl stop "$SERVER_SERVICE" 2>/dev/null || true
    systemctl stop "$CLIENT_SERVICE" 2>/dev/null || true
    systemctl disable "$SERVER_SERVICE" 2>/dev/null || true
    systemctl disable "$CLIENT_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVER_SERVICE}.service" "/etc/systemd/system/${CLIENT_SERVICE}.service"
    rm -f "/etc/systemd/system/${SERVER_SERVICE}@.service" "/etc/systemd/system/${CLIENT_SERVICE}@.service"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    print_success "Uninstalled. (ICMP firewall ACCEPT rules left in place — remove manually if you want.)"
}

while true; do
    clear
    echo "============================================"
    echo "  ICMP Tunnel Manager (ptunnel-ng, multi-port)"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER (inside the filtered network)"
    print_menu "2. Install CLIENT (outside / your VPN entry point)"
    print_menu "3. Add/remove extra forwarded ports"
    print_menu "4. Status"
    print_menu "5. Debug traffic (tcpdump)"
    print_menu "6. Restart"
    print_menu "7. Uninstall"
    print_menu "8. Exit"
    echo ""
    read -p "Select [1-8]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server; read -p "Press Enter..." </dev/tty ;;
        2) install_client; read -p "Press Enter..." </dev/tty ;;
        3) manage_ports ;;
        4) status_tunnel ;;
        5) debug_traffic ;;
        6) restart_tunnel ;;
        7) uninstall_tunnel; read -p "Press Enter..." </dev/tty ;;
        8) exit 0 ;;
        *) sleep 1 ;;
    esac
done
