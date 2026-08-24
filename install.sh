#!/bin/bash
# ============================================================================
# ICMP-over-VPN Tunnel Manager — Final Fixed Version
# Built on ptunnel-ng (https://github.com/utoni/ptunnel-ng)
# ============================================================================

set -o pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_header()  { echo -e "${GREEN}▶${NC} $1"; }
print_menu()    { echo -e "${BLUE}▸${NC} $1"; }
print_info()    { echo -e "${CYAN}[i]${NC} $1"; }

# ── Paths & Constants ────────────────────────────────────────────────────────
INSTALL_DIR="/opt/ptunnel-ng"
BIN_PATH="${INSTALL_DIR}/src/ptunnel-ng"
REPO_URL="https://github.com/utoni/ptunnel-ng.git"
SERVER_SERVICE="ptunnel-ng-server"
CLIENT_SERVICE="ptunnel-ng-client"
CONF_FILE="${INSTALL_DIR}/tunnel.env"

# ── Utility ──────────────────────────────────────────────────────────────────
require_root() {
    [ "$(id -u)" -ne 0 ] && { print_error "Run as root (sudo)."; exit 1; }
}

service_installed() {
    systemctl cat "$1" &>/dev/null
}

press_enter() {
    echo ""; read -p "Press Enter to continue..." </dev/tty
}

# ── Dependencies ──────────────────────────────────────────────────────────────
install_build_deps() {
    print_status "Installing build dependencies..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential autoconf automake libtool pkg-config git \
        iptables tcpdump iproute2 libpcap-dev libpcap0.8 >/dev/null
}

# ── Build ptunnel-ng ─────────────────────────────────────────────────────────
# FIX: explicitly run autogen → configure → make (autogen.sh only runs autoreconf)
build_ptunnel() {
    if [ -x "$BIN_PATH" ]; then
        print_success "ptunnel-ng already built at $BIN_PATH"
        return 0
    fi
    print_status "Cloning and building ptunnel-ng..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --ff-only
    else
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi
    ( cd "$INSTALL_DIR" && ./autogen.sh ) || { print_error "autogen.sh failed"; return 1; }
    ( cd "$INSTALL_DIR" && ./configure )  || { print_error "configure failed";  return 1; }
    ( cd "$INSTALL_DIR" && make -j"$(nproc)" ) || { print_error "make failed"; return 1; }
    [ -x "$BIN_PATH" ] || { print_error "Binary not found at $BIN_PATH"; return 1; }
    print_success "Built $BIN_PATH"
}

# ── Firewall ─────────────────────────────────────────────────────────────────
# FIX: insert at position 1 (before any DROP rules) + deduplicate + disable rate limit
dedup_iptables() {
    local chain="$1" rule="$2"
    # Delete ALL matching rules, then add ONE at the top
    while iptables -D "$chain" $rule 2>/dev/null; do :; done
    iptables -I "$chain" 1 $rule 2>/dev/null || true
}

allow_icmp_firewall() {
    print_status "Configuring firewall for ICMP..."
    dedup_iptables INPUT  "-p icmp -j ACCEPT"
    dedup_iptables OUTPUT "-p icmp -j ACCEPT"
    # Disable ICMP rate limiting (kernel silently drops ping bursts otherwise)
    sysctl -w net.ipv4.icmp_ratelimit=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.icmp_ratemask=0  >/dev/null 2>&1 || true
    grep -q 'icmp_ratelimit' /etc/sysctl.conf 2>/dev/null || \
        printf 'net.ipv4.icmp_ratelimit=0\nnet.ipv4.icmp_ratemask=0\n' >> /etc/sysctl.conf
    save_iptables
}

# FIX: open extra TCP ports (comma-separated) at end of install
open_extra_ports() {
    local ports_str="$1"
    [ -z "$ports_str" ] && { print_info "No extra ports specified."; return 0; }
    local IFS=','
    local port
    for port in $ports_str; do
        port="${port#"${port%%[![:space:]]*}"}"
        port="${port%"${port##*[![:space:]]}"}"
        [ -z "$port" ] && continue
        [[ "$port" =~ ^[0-9]+$ ]] || { print_warning "Skipping invalid port: $port"; continue; }
        dedup_iptables INPUT  "-p tcp --dport $port -j ACCEPT"
        dedup_iptables OUTPUT "-p tcp --dport $port -j ACCEPT"
        print_info "Opened TCP port $port (in/out)"
    done
    save_iptables
}

save_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# ── Config File ──────────────────────────────────────────────────────────────
# FIX: single-quote all values to prevent "command not found" when sourced
write_env_file() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    : > "$file"
    while [ $# -ge 2 ]; do
        local val="$2"
        val="${val//\'/\'\\\'\'}"
        printf "%s='%s'\n" "$1" "$val" >> "$file"
        shift 2
    done
    chmod 600 "$file"
}

# ── Systemd Service ──────────────────────────────────────────────────────────
write_systemd_service() {
    local name="$1" exec_line="$2"
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
    [ -f "/etc/systemd/system/${name}.service" ] || {
        print_error "Failed to write service file for $name"
        return 1
    }
}

# ── Helper: start service and report ─────────────────────────────────────────
start_and_report() {
    local svc="$1" desc="$2"
    systemctl restart "$svc"
    sleep 2
    if systemctl is-active --quiet "$svc"; then
        print_success "$desc is running"
        print_info "PID: $(systemctl show -p MainPID --value "$svc")"
        print_info "Logs: journalctl -u $svc -f"
    else
        print_error "$svc failed to start — last 20 log lines:"
        journalctl -u "$svc" -n 20 --no-pager
    fi
}

# ── Install: SERVER ──────────────────────────────────────────────────────────
install_server() {
    echo ""; print_header "Install SERVER (inside the filtered network)"
    require_root
    install_build_deps
    build_ptunnel || { print_error "Build failed."; return 1; }

    echo ""
    print_info "This machine RECEIVES ICMP tunnel packets from the client"
    print_info "and forwards the decoded TCP to your VPN server."
    echo ""

    read -p "  VPN server IP (where to forward to, 127.0.0.1 if VPN is on THIS machine): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}
    read -p "  VPN server port (default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}
    read -p "  Tunnel password (blank for none): " TPASS </dev/tty
    read -p "  Magic value to evade DPI (blank for default): " MAGIC </dev/tty

    # FIX: warn if DEST_IP looks like it's pointing at the client
    local my_ip
    my_ip=$(hostname -I | awk '{print $1}')
    if [ "$DEST_IP" != "127.0.0.1" ] && [ "$DEST_IP" != "localhost" ] && [ "$DEST_IP" != "$my_ip" ]; then
        print_warning "DEST_IP ($DEST_IP) is NOT 127.0.0.1 and NOT this server's IP ($my_ip)."
        print_warning "Make sure a VPN server is actually reachable at ${DEST_IP}:${DEST_PORT}."
        read -p "  Continue anyway? [y/N]: " confirm </dev/tty
        [ "$confirm" = "y" ] || { print_error "Aborted."; return 1; }
    fi

    write_env_file "$CONF_FILE" \
        ROLE     "server" \
        DEST_IP  "$DEST_IP" \
        DEST_PORT "$DEST_PORT" \
        TPASS    "$TPASS" \
        MAGIC    "$MAGIC"

    local exec_args="${BIN_PATH} -r${DEST_IP} -R${DEST_PORT} -v1"
    [ -n "$TPASS" ] && exec_args+=" -P${TPASS}"
    [ -n "$MAGIC" ] && exec_args+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$SERVER_SERVICE" "$exec_args" || return 1

    # Ask for extra ports
    echo ""
    read -p "  Extra TCP ports to allow in firewall (comma-separated, e.g. 1194,443 — blank for none): " EXTRA </dev/tty
    open_extra_ports "$EXTRA"

    echo ""
    print_header "Server Configuration Summary"
    print_info "Server IP    : $(hostname -I | awk '{print $1}')"
    print_info "Forward to   : ${DEST_IP}:${DEST_PORT}"
    print_info "Password     : $([ -n "$TPASS" ] && echo 'set' || echo 'none')"
    print_info "Magic        : $([ -n "$MAGIC" ] && echo "$MAGIC" || echo 'default')"
    echo ""

    start_and_report "$SERVER_SERVICE" "Server"
}

# ── Install: CLIENT ──────────────────────────────────────────────────────────
install_client() {
    echo ""; print_header "Install CLIENT (outside / VPN entry point)"
    require_root
    install_build_deps
    build_ptunnel || { print_error "Build failed."; return 1; }

    echo ""
    print_info "This machine SENDS ICMP tunnel packets to the server"
    print_info "and listens locally for your VPN client to connect."
    echo ""

    read -p "  Server public IP (the ptunnel SERVER you just set up): " SERVER_IP </dev/tty
    [ -z "$SERVER_IP" ] && { print_error "Server IP required."; return 1; }

    read -p "  Local listen port for your VPN client (default 8000): " LISTEN_PORT </dev/tty
    LISTEN_PORT=${LISTEN_PORT:-8000}

    read -p "  Destination IP on the server side (default 127.0.0.1): " DEST_IP </dev/tty
    DEST_IP=${DEST_IP:-127.0.0.1}

    read -p "  Destination port on the server side (default 1194): " DEST_PORT </dev/tty
    DEST_PORT=${DEST_PORT:-1194}

    read -p "  Tunnel password (MUST match server): " TPASS </dev/tty
    read -p "  Magic value (MUST match server): " MAGIC </dev/tty

    write_env_file "$CONF_FILE" \
        ROLE        "client" \
        SERVER_IP   "$SERVER_IP" \
        LISTEN_PORT "$LISTEN_PORT" \
        DEST_IP     "$DEST_IP" \
        DEST_PORT   "$DEST_PORT" \
        TPASS       "$TPASS" \
        MAGIC       "$MAGIC"

    local exec_args="${BIN_PATH} -p${SERVER_IP} -l${LISTEN_PORT} -r${DEST_IP} -R${DEST_PORT} -v1"
    [ -n "$TPASS" ] && exec_args+=" -P${TPASS}"
    [ -n "$MAGIC" ] && exec_args+=" -m${MAGIC}"

    allow_icmp_firewall
    write_systemd_service "$CLIENT_SERVICE" "$exec_args" || return 1

    # Ask for extra ports
    echo ""
    read -p "  Extra TCP ports to allow in firewall (comma-separated, e.g. 8000,1194 — blank for none): " EXTRA </dev/tty
    open_extra_ports "$EXTRA"

    echo ""
    print_header "Client Configuration Summary"
    print_info "Server IP    : $SERVER_IP"
    print_info "Listen on    : 127.0.0.1:${LISTEN_PORT}"
    print_info "Forward to   : ${DEST_IP}:${DEST_PORT} (via server)"
    print_info "Password     : $([ -n "$TPASS" ] && echo 'set' || echo 'none')"
    print_info "Magic        : $([ -n "$MAGIC" ] && echo "$MAGIC" || echo 'default')"
    echo ""
    print_warning "Point your VPN client at 127.0.0.1:${LISTEN_PORT} (TCP)"
    print_warning "WireGuard (UDP) will NOT work — use OpenVPN with proto tcp"
    echo ""

    start_and_report "$CLIENT_SERVICE" "Client"
}

# ── Status ───────────────────────────────────────────────────────────────────
status_tunnel() {
    echo ""; print_header "Status"
    local found=0
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if service_installed "$svc"; then
            found=1
            echo ""
            systemctl status "$svc" --no-pager -l | head -n 15
        fi
    done
    [ $found -eq 0 ] && print_warning "No tunnel service installed on this host."
    echo ""
    print_info "Listening TCP ports (ptunnel-ng):"
    ss -tlnp 2>/dev/null | grep -i ptunnel || print_info "(none)"
    press_enter
}

# ── Debug ────────────────────────────────────────────────────────────────────
debug_traffic() {
    echo ""; print_header "Debug — ICMP echo traffic (Ctrl+C to stop)"
    print_info "Only showing echo-request (type 8) and echo-reply (type 0)."
    print_info ""
    print_info "On the CLIENT, trigger a connection:"
    print_info "  nc -v 127.0.0.1 <LISTEN_PORT>"
    print_info ""
    print_info "If you see request+reply pairs → tunnel is working."
    print_info "If you see requests but NO replies → ICMP blocked one-way."
    print_info "If you see NOTHING → client not sending, or ICMP fully blocked."
    echo ""
    tcpdump -n -i any 'icmp[icmptype] == 8 or icmp[icmptype] == 0'
    press_enter
}

# ── Connection Test ──────────────────────────────────────────────────────────
test_connection() {
    echo ""; print_header "Connection Test"
    if [ ! -f "$CONF_FILE" ]; then
        print_error "No tunnel.env found — install first."
        press_enter; return
    fi
    local SERVER_IP="" LISTEN_PORT="" DEST_IP="" DEST_PORT=""
    while IFS= read -r line; do
        case "$line" in
            SERVER_IP=*)   SERVER_IP="${line#SERVER_IP=}";   SERVER_IP="${SERVER_IP//\'}" ;;
            LISTEN_PORT=*) LISTEN_PORT="${line#LISTEN_PORT=}"; LISTEN_PORT="${LISTEN_PORT//\'}" ;;
            DEST_IP=*)     DEST_IP="${line#DEST_IP=}";       DEST_IP="${DEST_IP//\'}" ;;
            DEST_PORT=*)   DEST_PORT="${line#DEST_PORT=}";   DEST_PORT="${DEST_PORT//\'}" ;;
        esac
    done < "$CONF_FILE"

    # Check services
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if service_installed "$svc"; then
            if systemctl is-active --quiet "$svc"; then
                print_success "$svc: active"
            else
                print_error "$svc: installed but NOT running"
            fi
        fi
    done

    # Check ICMP reachability (client side)
    if [ -n "$SERVER_IP" ]; then
        echo ""
        print_status "Pinging server $SERVER_IP ..."
        if ping -c 3 -W 2 "$SERVER_IP" >/dev/null 2>&1; then
            print_success "ICMP reachable to server"
        else
            print_error "ICMP NOT reachable — check firewall / VPS provider"
        fi
    fi

    # Check local listener (client side)
    if [ -n "$LISTEN_PORT" ]; then
        print_status "Checking local listener 127.0.0.1:${LISTEN_PORT} ..."
        if ss -tlnp 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
            print_success "Listener is UP"
        else
            print_error "Listener is DOWN"
        fi
    fi

    # Check destination (server side)
    if [ -n "$DEST_PORT" ]; then
        print_status "Checking destination port ${DEST_IP}:${DEST_PORT} ..."
        if [ "$DEST_IP" = "127.0.0.1" ]; then
            if ss -tlnp 2>/dev/null | grep -q ":${DEST_PORT} "; then
                print_success "Destination port ${DEST_PORT} is listening locally"
            else
                print_error "Nothing listening on port ${DEST_PORT} — is your VPN server running?"
            fi
        else
            if nc -zv -w 3 "$DEST_IP" "$DEST_PORT" 2>&1 | grep -q succeeded; then
                print_success "Destination ${DEST_IP}:${DEST_PORT} reachable"
            else
                print_error "Destination ${DEST_IP}:${DEST_PORT} NOT reachable"
            fi
        fi
    fi
    press_enter
}

# ── Restart ──────────────────────────────────────────────────────────────────
restart_tunnel() {
    echo ""; print_header "Restart"
    local restarted=0
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        if service_installed "$svc"; then
            systemctl restart "$svc" 2>/dev/null
            sleep 1
            if systemctl is-active --quiet "$svc"; then
                print_success "Restarted $svc"
            else
                print_error "$svc failed to restart"
            fi
            restarted=1
        fi
    done
    [ $restarted -eq 0 ] && print_warning "No tunnel service installed on this host."
    press_enter
}

# ── Uninstall ────────────────────────────────────────────────────────────────
uninstall_tunnel() {
    echo ""; print_header "Uninstall"
    require_root
    for svc in "$SERVER_SERVICE" "$CLIENT_SERVICE"; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload
    pkill -f ptunnel-ng 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    print_success "Uninstalled completely."
    print_info "ICMP firewall rules left in place — remove manually if desired:"
    print_info "  iptables -D INPUT  -p icmp -j ACCEPT"
    print_info "  iptables -D OUTPUT -p icmp -j ACCEPT"
    press_enter
}

# ── Main Menu ────────────────────────────────────────────────────────────────
while true; do
    clear
    echo "============================================"
    echo "  ICMP Tunnel Manager (ptunnel-ng)"
    echo "============================================"
    echo ""
    print_menu "1. Install SERVER  (inside filtered network)"
    print_menu "2. Install CLIENT  (outside / VPN entry)"
    print_menu "3. Status"
    print_menu "4. Debug traffic (tcpdump — echo only)"
    print_menu "5. Test connection"
    print_menu "6. Restart"
    print_menu "7. Uninstall"
    print_menu "8. Exit"
    echo ""
    read -p "Select [1-8]: " CHOICE </dev/tty
    case $CHOICE in
        1) install_server ;;
        2) install_client ;;
        3) status_tunnel ;;
        4) debug_traffic ;;
        5) test_connection ;;
        6) restart_tunnel ;;
        7) uninstall_tunnel ;;
        8) exit 0 ;;
        *) sleep 1 ;;
    esac
done
