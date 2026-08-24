#!/bin/bash
# ============================================================================
# ICMP Tunnel — V2Ray/Xray TCP over ICMP
# Iran server (entry) ← ICMP → Abroad server (V2Ray) → Internet
# ============================================================================
set -o pipefail

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
P() { echo -e "$1"; }

DIR="/opt/ptunnel-ng"
BIN="${DIR}/src/ptunnel-ng"
REPO="https://github.com/utoni/ptunnel-ng.git"

# ── Build ───────────────────────────────────────────────────────────────────
build() {
    [ -x "$BIN" ] && return 0
    P "${B}[*] Building ptunnel-ng...${N}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential autoconf automake libtool pkg-config git libpcap-dev \
        iptables tcpdump iproute2 >/dev/null
    git clone --depth 1 "$REPO" "$DIR" 2>/dev/null
    ( cd "$DIR" && ./autogen.sh && ./configure && make -j"$(nproc)" ) || {
        P "${R}[✗] Build failed${N}"; exit 1; }
    [ -x "$BIN" ] || { P "${R}[✗] Binary not found${N}"; exit 1; }
    P "${G}[✓] Built${N}"
}

# ── Firewall ─────────────────────────────────────────────────────────────────
fw() {
    # ICMP open + dedup
    while iptables -D INPUT  -p icmp -j ACCEPT 2>/dev/null; do :; done
    while iptables -D OUTPUT -p icmp -j ACCEPT 2>/dev/null; do :; done
    iptables -I INPUT  1 -p icmp -j ACCEPT
    iptables -I OUTPUT 1 -p icmp -j ACCEPT
    # Disable ICMP rate limit
    sysctl -w net.ipv4.icmp_ratelimit=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.icmp_ratemask=0  >/dev/null 2>&1 || true
    grep -q 'icmp_ratelimit' /etc/sysctl.conf 2>/dev/null || \
        printf 'net.ipv4.icmp_ratelimit=0\nnet.ipv4.icmp_ratemask=0\n' >> /etc/sysctl.conf
    # Extra ports
    local ports="$1"
    if [ -n "$ports" ]; then
        local IFS=','
        for port in $ports; do
            port="${port//" "/}"
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            while iptables -D INPUT  -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
            while iptables -D OUTPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
            iptables -I INPUT  1 -p tcp --dport "$port" -j ACCEPT
            iptables -I OUTPUT 1 -p tcp --dport "$port" -j ACCEPT
            P "${G}[✓] Port ${port}${N}"
        done
    fi
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save >/dev/null 2>&1
    mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null
}

# ── Service ──────────────────────────────────────────────────────────────────
svc() {
    local name="$1" cmd="$2"
    systemctl stop "$name" 2>/dev/null; systemctl disable "$name" 2>/dev/null
    cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${name}
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${cmd}
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$name" >/dev/null 2>&1
    systemctl restart "$name"
    sleep 1
    systemctl is-active --quiet "$name" \
        && P "${G}[✓] ${name} running${N}" \
        || { P "${R}[✗] ${name} failed${N}"; journalctl -u "$name" -n 10 --no-pager 2>/dev/null; }
}

ipaddr() { hostname -I 2>/dev/null | awk '{print $1}'; }
pe() { echo ""; read -p "Press Enter..." </dev/tty; }

# ── 1) IRAN — ptunnel client (receives TCP from user, sends ICMP to Abroad) ──
iran() {
    clear
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${G}  IRAN Server — entry point (user connects here)${N}"
    P "${G}  Receives TCP from v2rayNG → tunnels via ICMP → Abroad${N}"
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    [ "$(id -u)" -ne 0 ] && { P "${R}[✗] Run as root${N}"; exit 1; }
    build

    local me; me=$(ipaddr)
    echo ""
    P "${C}This server IP: ${Y}${me}${N}"
    echo ""

    read -p "Abroad server IP: " ABROAD_IP </dev/tty
    read -p "V2Ray port on Abroad server (default 443): " VP </dev/tty
    VP=${VP:-443}
    read -p "Local listen port for v2rayNG (default 8000): " LP </dev/tty
    LP=${LP:-8000}
    read -p "Tunnel password (blank=none): " PASS </dev/tty
    read -p "Firewall ports to open, comma-separated (blank=none): " PORTS </dev/tty

    local cmd="${BIN} -p${ABROAD_IP} -l${LP} -r127.0.0.1 -R${VP} -v1"
    [ -n "$PASS" ] && cmd+=" -P${PASS}"
    fw "$PORTS"
    svc "ptunnel-ng-client" "$cmd"

    echo ""
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${G}  ✅ Iran server ready${N}"
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${C}This server   : ${Y}${me}${N}"
    P "${C}Abroad server : ${Y}${ABROAD_IP}${N}"
    P "${C}v2rayNG connects to: ${Y}${me}:${LP}${N}"
    P "${C}Forwards to   : ${Y}127.0.0.1:${VP}${N} ${C}(on Abroad)${N}"
    echo ""
    P "${Y}━━━ v2rayNG Settings ━━━${N}"
    P "${C}Address : ${Y}${me}${N}"
    P "${C}Port    : ${Y}${LP}${N}"
    P "${C}Network : ${Y}tcp${N} ${R}(NOT ws, NOT grpc)${N}"
    P "${C}Rest    : same as V2Ray config on Abroad server${N}"
    echo ""
    P "${Y}[!] Test: ping ${ABROAD_IP}${N}"
    pe
}

# ── 2) ABROAD — ptunnel server (receives ICMP, forwards to V2Ray) ────────────
abroad() {
    clear
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${G}  ABROAD Server — exit point (free internet)${N}"
    P "${G}  Receives ICMP from Iran → forwards to V2Ray${N}"
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    [ "$(id -u)" -ne 0 ] && { P "${R}[✗] Run as root${N}"; exit 1; }
    build

    local me; me=$(ipaddr)
    echo ""
    P "${C}This server IP: ${Y}${me}${N}"
    echo ""

    read -p "Iran server IP: " IRAN_IP </dev/tty
    read -p "V2Ray port on this server (default 443): " VP </dev/tty
    VP=${VP:-443}
    read -p "Tunnel password (blank=none): " PASS </dev/tty
    read -p "Firewall ports to open, comma-separated (blank=none): " PORTS </dev/tty

    local cmd="${BIN} -r127.0.0.1 -R${VP} -v1"
    [ -n "$PASS" ] && cmd+=" -P${PASS}"
    fw "$PORTS"
    svc "ptunnel-ng-server" "$cmd"

    echo ""
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${G}  ✅ Abroad server ready${N}"
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${C}This server  : ${Y}${me}${N}"
    P "${C}Iran server  : ${Y}${IRAN_IP}${N}"
    P "${C}Forwards to  : ${Y}127.0.0.1:${VP}${N} ${C}(local V2Ray)${N}"
    P "${C}V2Ray must be: ${Y}tcp${N} ${R}(NOT ws, NOT grpc)${N}"
    echo ""
    P "${Y}[!] Now run this script on Iran server → option 1${N}"
    pe
}

# ── 3) Status ────────────────────────────────────────────────────────────────
status() {
    clear; P "${G}━━━ Status ━━━${N}"; echo ""
    for s in ptunnel-ng-server ptunnel-ng-client; do
        systemctl cat "$s" &>/dev/null && {
            systemctl status "$s" --no-pager -l | head -n 12; echo ""; }
    done
    P "${C}Listening ports:${N}"
    ss -tlnp 2>/dev/null | grep -iE 'ptunnel|xray|v2ray' || echo "(none)"
    pe
}

# ── 4) Debug ──────────────────────────────────────────────────────────────────
debug() {
    clear
    P "${C}[*] Watching ICMP echo traffic (Ctrl+C to stop)...${N}"
    P "${C}[*] request + reply = tunnel working${N}"
    P "${C}[*] request, no reply = ICMP blocked one-way${N}"
    P "${C}[*] nothing = client not sending or fully blocked${N}"
    echo ""
    tcpdump -n -i any 'icmp[icmptype] == 8 or icmp[icmptype] == 0'
    pe
}

# ── 5) Uninstall ──────────────────────────────────────────────────────────────
uninstall() {
    for s in ptunnel-ng-server ptunnel-ng-client; do
        systemctl stop "$s" 2>/dev/null; systemctl disable "$s" 2>/dev/null
        rm -f "/etc/systemd/system/${s}.service"
    done
    systemctl daemon-reload
    pkill -f ptunnel-ng 2>/dev/null || true
    rm -rf "$DIR"
    P "${G}[✓] Uninstalled${N}"
    pe
}

# ── Menu ──────────────────────────────────────────────────────────────────────
while true; do
    clear
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    P "${G}  ICMP Tunnel — V2Ray TCP over ICMP${N}"
    P "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    P "${B}1${N} Iran server   (entry — user connects here, sends ICMP)"
    P "${B}2${N} Abroad server (exit — receives ICMP, runs V2Ray)"
    P "${B}3${N} Status"
    P "${B}4${N} Debug (tcpdump)"
    P "${B}5${N} Uninstall"
    P "${B}6${N} Exit"
    echo ""
    read -p "Select [1-6]: " C </dev/tty
    case $C in
        1) iran ;;
        2) abroad ;;
        3) status ;;
        4) debug ;;
        5) uninstall ;;
        6) exit 0 ;;
        *) sleep 1 ;;
    esac
done
