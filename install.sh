rm -f stinger-installer.sh stinger stinger.bin config.toml 2>/dev/null
cat > stinger-installer.sh << 'EOF'
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

BINARY_NAME="stinger"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"

uninstall_stinger() {
    echo ""
    print_header "🗑️  Uninstalling Stinger..."
    pkill -f "stinger.bin" 2>/dev/null || true
    pkill -x "stinger" 2>/dev/null || true
    [ -f "stinger" ] && rm -f "stinger" && print_success "Removed: stinger"
    [ -f "stinger.bin" ] && rm -f "stinger.bin" && print_success "Removed: stinger.bin"
    [ -f "stinger.original" ] && rm -f "stinger.original" && print_success "Removed: stinger.original"
    [ -f "config.toml" ] && rm -f "config.toml" && print_success "Removed: config.toml"
    echo ""; print_success "✅ Uninstall completed! All files and processes removed."
}

install_server() {
    echo ""; print_header "🖥️  Installing Stinger Server..."
    if ! command -v wget &> /dev/null; then sudo apt-get update -qq && sudo apt-get install -y -qq wget file; fi
    
    print_status "Downloading stinger binary..."
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
export FAKE_IP="192.168.1.100"; export FAKE_HOSTNAME="ubuntu-server"; export ALLOWED_SERVER="true"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
[ -f "$BINARY_PATH" ] && exec "$BINARY_PATH" "$@" || echo "[✗] stinger.bin not found!"
WRAPPER
    fi
    
    echo ""
    read -p "  🌐 Enter Remote IP (Client IP or 0.0.0.0 for any) [0.0.0.0]: " REMOTE_IP
    REMOTE_IP=${REMOTE_IP:-0.0.0.0}
    
    cat > config.toml << EOF
mode = "server"
remote_ip = "${REMOTE_IP}"

[server]
host = "0.0.0.0"
port = 8080
EOF
    
    chmod +x "${BINARY_NAME}"
    print_success "✅ Server setup completed! (mode=server, remote_ip=${REMOTE_IP})"
    
    echo ""
    read -p "  ▶️ Run Stinger Server now? (y/N): " RUN_NOW
    if [[ $RUN_NOW =~ ^[Yy]$ ]]; then ./"${BINARY_NAME}"; else print_info "Run it later with: ./stinger"; fi
}

install_client() {
    echo ""; print_header "💻 Installing Stinger Client..."
    if ! command -v wget &> /dev/null; then sudo apt-get update -qq && sudo apt-get install -y -qq wget file; fi
    
    print_status "Downloading stinger binary..."
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
export FAKE_IP="192.168.1.100"; export FAKE_HOSTNAME="ubuntu-client"; export ALLOWED_SERVER="true"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
[ -f "$BINARY_PATH" ] && exec "$BINARY_PATH" "$@" || echo "[✗] stinger.bin not found!"
WRAPPER
    fi
    
    echo ""
    read -p "  🌐 Enter Server IP (remote_ip) [127.0.0.1]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-127.0.0.1}
    read -p "  🔗 Enter Server Port [8080]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-8080}
    
    cat > config.toml << EOF
mode = "client"
remote_ip = "${SERVER_IP}"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
EOF
    
    chmod +x "${BINARY_NAME}"
    print_success "✅ Client setup completed! (mode=client, remote_ip=${SERVER_IP})"
    
    echo ""
    read -p "  ▶️ Run Stinger Client now? (y/N): " RUN_NOW
    if [[ $RUN_NOW =~ ^[Yy]$ ]]; then ./"${BINARY_NAME}"; else print_info "Run it later with: ./stinger"; fi
}

check_status() {
    echo ""; print_header "🔍 Checking Stinger Status..."
    echo "═══════════════════════════════════════════"
    
    echo -e "\n${YELLOW}[1] Process Status:${NC}"
    if pgrep -f "stinger.bin" > /dev/null || pgrep -x "stinger" > /dev/null; then
        print_success "Stinger is RUNNING."
        ps -eo pid,etime,cmd | grep -iE "stinger.bin|./stinger" | grep -v grep | awk '{print "  PID: " $1 " | Uptime: " $2}'
    else
        print_error "Stinger is NOT RUNNING."
    fi

    echo -e "\n${YELLOW}[2] Tunnel Interfaces (TUN/TAP):${NC}"
    if command -v ip &> /dev/null; then
        TUN_INTERFACES=$(ip link show | grep -iE "tun|tap|stinger|flagtun|utun" | awk -F: '{print $2}' | tr -d ' ')
        if [ -n "$TUN_INTERFACES" ]; then
            print_success "Active tunnel interface(s) found:"
            for iface in $TUN_INTERFACES; do
                echo -e "  ${CYAN}▸${NC} $iface"
                ip addr show $iface 2>/dev/null | grep "inet " | awk '{print "    IPv4: " $2}'
            done
        else
            print_warning "No active TUN/TAP tunnel interfaces found."
        fi
    fi

    echo -e "\n${YELLOW}[3] Network / Ports:${NC}"
    if command -v ss &> /dev/null; then
        PORTS=$(ss -tuln | grep -E ":8080|:51820|stinger")
        if [ -n "$PORTS" ]; then
            print_success "Relevant listening ports:"
            echo "$PORTS" | awk '{print "  " $1 " " $5}'
        else
            print_info "No tunnel ports listening on default 8080."
        fi
    fi
    echo -e "\n═══════════════════════════════════════════"
    read -p "Press Enter to return to menu..."
}

while true; do
    clear
    echo "═══════════════════════════════════════════"
    echo "  🔓 Stinger Unlocked - Complete Installer"
    echo "═══════════════════════════════════════════"
    echo ""
    print_menu "1. 🖥️  Install Server"
    print_menu "2. 💻 Install Client"
    print_menu "3. 🔍 Check Status (Tunnel & Process)"
    print_menu "4. 🗑️  Uninstall (Stop & Remove)"
    print_menu "5. 🚪 Exit"
    echo ""
    read -p "Select an option [1-5]: " CHOICE
    case $CHOICE in
        1) install_server ;;
        2) install_client ;;
        3) check_status ;;
        4) uninstall_stinger; read -p "Press Enter to continue..." ;;
        5) print_info "Exiting..."; exit 0 ;;
        *) print_warning "Invalid option"; sleep 1 ;;
    esac
done
EOF
chmod +x stinger-installer.sh
./stinger-installer.sh
