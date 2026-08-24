#!/bin/bash
# install.sh - Stinger Unlocked Installer
# Remove all restrictions from original stinger binary

set -e

# ============================================
# Configuration
# ============================================
BINARY_NAME="stinger"
ORIGINAL_URL="https://github.com/lostsoul6/stinger-binary/raw/refs/heads/main/stinger"
# ============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================
# ALL FUNCTIONS DEFINED HERE
# ============================================
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }
print_header() { echo -e "${GREEN}▶${NC} $1"; }   # <-- DEFINED HERE
print_menu() { echo -e "${BLUE}▸${NC} $1"; }

clear
echo "=========================================="
echo "  🔓 Stinger Unlocked - Remove Restrictions"
echo "=========================================="
echo ""

# ============================================
# Step 1: Check OS
# ============================================
print_status "Checking operating system..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    print_success "OS: $NAME $VERSION_ID"
else
    print_warning "OS could not be identified, continuing..."
fi

# ============================================
# Step 2: Install wget if missing
# ============================================
if ! command -v wget &> /dev/null; then
    print_warning "wget not found, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq wget
fi

# ============================================
# Step 3: Download original binary
# ============================================
print_status "Downloading original stinger from:"
echo "  $ORIGINAL_URL"
echo ""

if wget -q --show-progress -O ${BINARY_NAME}.original "$ORIGINAL_URL"; then
    print_success "Download completed"
else
    print_error "Download failed! Please check your internet connection."
    exit 1
fi

# ============================================
# Step 4: Check file type and remove restrictions
# ============================================
print_status "Checking file type..."

if file ${BINARY_NAME}.original | grep -q "shell script"; then
    print_info "File is a shell script - editing directly..."
    
    cp ${BINARY_NAME}.original ${BINARY_NAME}
    
    print_status "Removing IP restrictions..."
    sed -i '/ifconfig.me/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/curl.*ifconfig/d' ${BINARY_NAME} 2>/dev/null || true
    
    print_status "Removing OS restrictions..."
    sed -i '/lsb_release/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/hostname/d' ${BINARY_NAME} 2>/dev/null || true
    
    print_status "Removing server whitelist..."
    sed -i '/allowed_servers/d' ${BINARY_NAME} 2>/dev/null || true
    
    print_status "Removing exit commands..."
    sed -i '/exit 1.*IP/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*server/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*ubuntu/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*hostname/d' ${BINARY_NAME} 2>/dev/null || true
    
    print_success "All restrictions removed from script"
    
else
    print_info "File is binary - building wrapper..."
    
    mv ${BINARY_NAME}.original ${BINARY_NAME}.bin
    chmod +x ${BINARY_NAME}.bin
    
    cat > ${BINARY_NAME} << 'EOF'
#!/bin/bash
# Stinger Wrapper - Unlocked Version

export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"
export FAKE_LSB_RELEASE="Ubuntu"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"

if [ -f "$BINARY_PATH" ]; then
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    echo "[✓] Running Stinger Unlocked..."
    exec "$BINARY_PATH" "$@"
else
    echo "[✗] Error: stinger.bin not found!"
    exit 1
fi
EOF

    chmod +x ${BINARY_NAME}
    print_success "Wrapper created and binary is ready"
fi

# ============================================
# Step 5: Create config.toml if needed
# ============================================
if [ ! -f "config.toml" ]; then
    print_status "Creating default config.toml..."
    cat > config.toml << 'EOF'
[general]
debug = false
log_level = "info"

[network]
timeout = 30
retry_count = 3

[server]
port = 8080
host = "0.0.0.0"
EOF
    print_success "config.toml created"
fi

# ============================================
# Step 6: Make executable
# ============================================
chmod +x ${BINARY_NAME}
print_success "${BINARY_NAME} is ready to run!"

echo ""
echo "=========================================="
print_success "✅ Installation completed!"
echo "=========================================="
echo ""

# ============================================
# Step 7: Interactive Menu
# ============================================
echo "═══════════════════════════════════════════"
echo "  📋 Main Menu"
echo "═══════════════════════════════════════════"
echo ""
echo "  1. ▶️  Run Stinger Unlocked"
echo "  2. 📝  Edit config.toml"
echo "  3. ℹ️  Show file info"
echo "  4. 🚪  Exit"
echo ""
echo "═══════════════════════════════════════════"
echo ""

read -p "Select an option [1-4]: " USER_CHOICE
echo ""

case $USER_CHOICE in
    1)
        echo -e "${GREEN}▶ Running Stinger Unlocked...${NC}"
        echo "=========================================="
        ./${BINARY_NAME}
        ;;
    2)
        if [ -f "config.toml" ]; then
            print_info "Editing config.toml..."
            nano config.toml
            echo ""
            read -p "Run Stinger with new config? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ./${BINARY_NAME}
            fi
        else
            print_error "config.toml not found!"
        fi
        ;;
    3)
        echo ""
        echo "📄 File Information:"
        echo "═══════════════════════════════════════════"
        if [ -f "${BINARY_NAME}" ]; then
            echo "  File: ${BINARY_NAME}"
            echo "  Size: $(du -h ${BINARY_NAME} | cut -f1)"
            echo "  Date: $(date -r ${BINARY_NAME} '+%Y-%m-%d %H:%M:%S')"
            file ${BINARY_NAME} | head -1
        fi
        if [ -f "config.toml" ]; then
            echo "  Config: config.toml ($(wc -l < config.toml) lines)"
        fi
        echo "═══════════════════════════════════════════"
        ;;
    4)
        print_info "Exiting..."
        exit 0
        ;;
    *)
        print_warning "Invalid option, running default..."
        ./${BINARY_NAME}
        ;;
esac

echo ""
print_success "Done!"
