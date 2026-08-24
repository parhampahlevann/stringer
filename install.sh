#!/bin/bash
# Stinger Unlocked - Complete Installer with Uninstall
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Functions
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_header() { echo -e "${GREEN}▶${NC} $1"; }
print_menu() { echo -e "${BLUE}▸${NC} $1"; }

BINARY_NAME="stinger"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"

# ============================================
# Uninstall Function
# ============================================
uninstall_stinger() {
    echo ""
    print_header "🗑️  Uninstalling Stinger..."
    echo ""
    
    # Remove binary files
    [ -f "stinger" ] && rm -f "stinger" && print_success "Removed: stinger"
    [ -f "stinger.bin" ] && rm -f "stinger.bin" && print_success "Removed: stinger.bin"
    [ -f "stinger.original" ] && rm -f "stinger.original" && print_success "Removed: stinger.original"
    [ -f "config.toml" ] && rm -f "config.toml" && print_success "Removed: config.toml"
    
    # Remove from common locations
    [ -f "$HOME/.config/stinger/config.toml" ] && rm -f "$HOME/.config/stinger/config.toml" && print_success "Removed: ~/.config/stinger/config.toml"
    [ -f "$HOME/.stinger/config.toml" ] && rm -f "$HOME/.stinger/config.toml" && print_success "Removed: ~/.stinger/config.toml"
    
    # Remove directories if empty
    rmdir "$HOME/.config/stinger" 2>/dev/null && print_success "Removed directory: ~/.config/stinger"
    rmdir "$HOME/.stinger" 2>/dev/null && print_success "Removed directory: ~/.stinger"
    
    echo ""
    print_success "✅ Uninstall completed! All files removed."
    echo ""
    read -p "Press Enter to exit..."
    exit 0
}

# ============================================
# Install Server Function
# ============================================
install_server() {
    echo ""
    print_header "🖥️  Installing Stinger Server..."
    echo ""
    
    # Check OS
    print_status "Checking operating system..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        print_success "OS: $NAME $VERSION_ID"
    fi
    
    # Install wget if missing
    if ! command -v wget &> /dev/null; then
        print_warning "wget not found, installing..."
        sudo apt-get update -qq && sudo apt-get install -y -qq wget
    fi
    
    # Download
    print_status "Downloading stinger binary..."
    if wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL"; then
        print_success "Download completed"
    else
        print_error "Download failed!"
        exit 1
    fi
    
    # Remove restrictions
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
        print_success "Restrictions removed from script"
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
if [ -f "$BINARY_PATH" ]; then
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    echo "[✓] Running Stinger Unlocked (SERVER MODE)..."
    exec "$BINARY_PATH" "$@"
else
    echo "[✗] Error: stinger.bin not found!"
    exit 1
fi
WRAPPER
        print_success "Wrapper created"
    fi
    
    # Create SERVER config - FIXED: mode at root level
    print_status "Creating SERVER configuration..."
    cat > config.toml << 'EOF'
mode = "server"

[server]
host = "0.0.0.0"
port = 8080
EOF
    
    chmod +x "${BINARY_NAME}"
    print_success "Configuration created: mode = server"
    
    echo ""
    print_success "✅ Server setup completed!"
    echo ""
    print_header "🖥️  Server will listen on: 0.0.0.0:8080"
    echo ""
    print_header "Starting Stinger Server..."
    echo ""
    ./"${BINARY_NAME}"
}

# ============================================
# Install Client Function
# ============================================
install_client() {
    echo ""
    print_header "💻 Installing Stinger Client..."
    echo ""
    
    # Check OS
    print_status "Checking operating system..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        print_success "OS: $NAME $VERSION_ID"
    fi
    
    # Install wget if missing
    if ! command -v wget &> /dev/null; then
        print_warning "wget not found, installing..."
        sudo apt-get update -qq && sudo apt-get install -y -qq wget
    fi
    
    # Download
    print_status "Downloading stinger binary..."
    if wget -q --show-progress -O "${BINARY_NAME}.original" "$ORIGINAL_URL"; then
        print_success "Download completed"
    else
        print_error "Download failed!"
        exit 1
    fi
    
    # Remove restrictions
    print_status "Removing restrictions..."
    if file "${BINARY_NAME}.original" | grep -q "shell script"; then
        cp "${BINARY_NAME}.original" "${BINARY_NAME}"
        sed -i '/ifconfig.me/d; /curl.*ifconfig/d; /lsb_release/d; /hostname/d; /allowed_servers/d; /exit 1.*IP/d; /exit 1.*server/d; /exit 1.*ubuntu/d; /exit 1.*hostname/d' "${BINARY_NAME}" 2>/dev/null || true
        print_success "Restrictions removed from script"
    else
        mv "${BINARY_NAME}.original" "${BINARY_NAME}.bin"
        chmod +x "${BINARY_NAME}.bin"
        cat > "${BINARY_NAME}" << 'WRAPPER'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-client"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"
if [ -f "$BINARY_PATH" ]; then
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    echo "[✓] Running Stinger Unlocked (CLIENT MODE)..."
    exec "$BINARY_PATH" "$@"
else
    echo "[✗] Error: stinger.bin not found!"
    exit 1
fi
WRAPPER
        print_success "Wrapper created"
    fi
    
    # Ask for server address
    echo ""
    read -p "  🔗 Enter Server IP [127.0.0.1]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-127.0.0.1}
    read -p "  🔗 Enter Server Port [8080]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-8080}
    
    # Create CLIENT config - FIXED: mode at root level
    print_status "Creating CLIENT configuration..."
    cat > config.toml << EOF
mode = "client"

[client]
server_host = "${SERVER_IP}"
server_port = ${SERVER_PORT}
EOF
    
    chmod +x "${BINARY_NAME}"
    print_success "Configuration created: mode = client"
    
    echo ""
    print_success "✅ Client setup completed!"
    echo ""
    print_header "🔗 Connecting to: ${SERVER_IP}:${SERVER_PORT}"
    echo ""
    print_header "Starting Stinger Client..."
    echo ""
    ./"${BINARY_NAME}"
}

# ============================================
# Main Menu
# ============================================
clear
echo "═══════════════════════════════════════════"
echo "  🔓 Stinger Unlocked - Complete Installer"
echo "═══════════════════════════════════════════"
echo ""
print_menu "1. 🖥️  Install Server"
print_menu "2. 💻 Install Client"
print_menu "3. 🗑️  Uninstall (Remove everything)"
print_menu "4. 🚪 Exit"
echo ""

read -p "Select an option [1-4]: " CHOICE

case $CHOICE in
    1) install_server ;;
    2) install_client ;;
    3) uninstall_stinger ;;
    4) print_info "Exiting..."; exit 0 ;;
    *) print_warning "Invalid option"; exit 1 ;;
esac
