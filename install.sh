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
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# ALL FUNCTIONS
# ============================================
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }
print_header() { echo -e "${GREEN}▶${NC} $1"; }

# ============================================
# FUNCTION: Check Tunnel Status
# ============================================
check_tunnel_status() {
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  🔍 Tunnel Status Check"
    echo "═══════════════════════════════════════════"
    echo ""
    
    LOCAL_IP=$(curl -s ifconfig.me 2>/dev/null || echo "Unknown")
    if [ "$LOCAL_IP" != "Unknown" ]; then
        echo -e "${GREEN}✓${NC} Local IP: $LOCAL_IP"
    else
        echo -e "${RED}✗${NC} Local IP: Could not detect"
    fi
    
    if pgrep -f "stinger" > /dev/null; then
        echo -e "${GREEN}✓${NC} Stinger process: Running"
        STINGER_PID=$(pgrep -f "stinger")
        echo "  PID: $STINGER_PID"
    else
        echo -e "${RED}✗${NC} Stinger process: Not running"
    fi
    
    echo ""
    echo "  📡 Open Ports:"
    if command -v ss &> /dev/null; then
        ss -tuln | grep -E ":(8080|8443|443)" 2>/dev/null | while read line; do
            echo "    $line"
        done
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep -E ":(8080|8443|443)" 2>/dev/null | while read line; do
            echo "    $line"
        done
    else
        echo "    netstat/ss not found"
    fi
    
    echo ""
    echo "  🔗 Active Connections:"
    if command -v ss &> /dev/null; then
        ss -tn | grep -E ":(8080|8443|443)" 2>/dev/null | wc -l | while read count; do
            echo "    Active connections: $count"
        done
    elif command -v netstat &> /dev/null; then
        netstat -tn | grep -E ":(8080|8443|443)" 2>/dev/null | wc -l | while read count; do
            echo "    Active connections: $count"
        done
    else
        echo "    netstat/ss not found"
    fi
    
    if [ -f "config.toml" ]; then
        echo ""
        echo -e "${GREEN}✓${NC} config.toml: Found"
        CONFIG_PORT=$(grep -E "^port = [0-9]+" config.toml 2>/dev/null | awk '{print $3}' || echo "8080")
        echo "  Port from config: $CONFIG_PORT"
        REMOTE_IP=$(grep -E "^remote_ip = " config.toml 2>/dev/null | awk -F'"' '{print $2}' || echo "Not set")
        echo "  Remote IP: $REMOTE_IP"
    else
        echo ""
        echo -e "${RED}✗${NC} config.toml: Not found"
    fi
    
    echo ""
    echo "  🌐 Tunnel Endpoints:"
    if command -v ss &> /dev/null; then
        ESTABLISHED=$(ss -tn | grep ESTAB | wc -l)
        echo "    Established connections: $ESTABLISHED"
    elif command -v netstat &> /dev/null; then
        ESTABLISHED=$(netstat -tn | grep ESTABLISHED | wc -l)
        echo "    Established connections: $ESTABLISHED"
    fi
    
    echo ""
    echo "  📶 Connectivity Test:"
    for host in "8.8.8.8" "1.1.1.1" "github.com"; do
        if ping -c 1 -W 2 $host &> /dev/null; then
            echo -e "    ${GREEN}✓${NC} $host: Reachable"
        else
            echo -e "    ${RED}✗${NC} $host: Unreachable"
        fi
    done
    
    echo ""
    echo "═══════════════════════════════════════════"
    
    echo ""
    if pgrep -f "stinger" > /dev/null; then
        if [ "$(ss -tn 2>/dev/null | grep -c ESTAB)" -gt 5 ] 2>/dev/null; then
            echo -e "${GREEN}✅ TUNNEL STATUS: ACTIVE & WORKING${NC}"
        else
            echo -e "${YELLOW}⚠️  TUNNEL STATUS: RUNNING BUT NO ACTIVE CONNECTIONS${NC}"
        fi
    else
        echo -e "${RED}❌ TUNNEL STATUS: NOT RUNNING${NC}"
        echo "   Run Stinger first (Option 1) to start the tunnel."
    fi
    echo ""
}

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
# Step 2: Install required tools
# ============================================
if ! command -v wget &> /dev/null; then
    print_warning "wget not found, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq wget
fi

# ============================================
# Step 3: Download original binary
# ============================================
if [ ! -f "${BINARY_NAME}.original" ] && [ ! -f "${BINARY_NAME}" ]; then
    print_status "Downloading original stinger from:"
    echo "  $ORIGINAL_URL"
    echo ""

    if wget -q --show-progress -O ${BINARY_NAME}.original "$ORIGINAL_URL"; then
        print_success "Download completed"
    else
        print_error "Download failed! Please check your internet connection."
        exit 1
    fi
else
    print_info "Binary already exists, skipping download..."
fi

# ============================================
# Step 4: Check file type and remove restrictions
# ============================================
if [ ! -f "${BINARY_NAME}" ]; then
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
else
    print_info "stinger already exists, skipping build..."
fi

# ============================================
# Step 5: Create FULL config.toml with remote_ip
# ============================================
print_status "Creating full config.toml..."

# Get server IP for remote_ip
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "0.0.0.0")

cat > config.toml << 'EOF'
# ============================================
# Stinger Configuration File
# ============================================

[general]
debug = false
log_level = "info"
log_file = "stinger.log"

[network]
timeout = 30
retry_count = 3
retry_delay = 1000

[server]
port = 8080
host = "0.0.0.0"
max_connections = 100

[tunnel]
# Remote IP - REQUIRED
remote_ip = "SERVER_IP_PLACEHOLDER"

# Remote port
remote_port = 8080

# Tunnel type: tcp, udp, both
type = "tcp"

# Encryption
encryption = true

# Buffer size
buffer_size = 8192

[security]
ssl_enabled = false
ssl_cert = ""
ssl_key = ""

[database]
type = "sqlite"
path = "stinger.db"
host = "localhost"
port = 3306
username = ""
password = ""
database = "stinger"

[features]
advanced_mode = false
experimental = false

# ============================================
# Custom Settings
# ============================================
EOF

# Replace SERVER_IP_PLACEHOLDER with actual IP
sed -i "s/SERVER_IP_PLACEHOLDER/$SERVER_IP/g" config.toml

print_success "config.toml created with remote_ip = $SERVER_IP"
print_info "If this is not the correct remote IP, edit config.toml (Option 3)"

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
while true; do
    echo "═══════════════════════════════════════════"
    echo "  📋 Main Menu"
    echo "═══════════════════════════════════════════"
    echo ""
    echo "  1. ▶️  Run Stinger Unlocked"
    echo "  2. 🔍 Check Tunnel Status"
    echo "  3. 📝  Edit config.toml"
    echo "  4. ℹ️  Show file info"
    echo "  5. 🚪  Exit"
    echo ""
    echo "═══════════════════════════════════════════"
    echo ""

    read -p "Select an option [1-5]: " USER_CHOICE
    echo ""

    case $USER_CHOICE in
        1)
            echo -e "${GREEN}▶ Running Stinger Unlocked...${NC}"
            echo "=========================================="
            ./${BINARY_NAME}
            echo ""
            read -p "Press Enter to return to menu..." 
            ;;
        2)
            check_tunnel_status
            read -p "Press Enter to return to menu..."
            ;;
        3)
            if [ -f "config.toml" ]; then
                print_info "Editing config.toml..."
                nano config.toml
                print_success "Config updated"
            else
                print_error "config.toml not found!"
            fi
            read -p "Press Enter to return to menu..."
            ;;
        4)
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
                REMOTE_IP=$(grep -E "^remote_ip = " config.toml 2>/dev/null | awk -F'"' '{print $2}' || echo "Not set")
                echo "  Remote IP: $REMOTE_IP"
            fi
            echo "═══════════════════════════════════════════"
            read -p "Press Enter to return to menu..."
            ;;
        5)
            print_info "Exiting..."
            exit 0
            ;;
        *)
            print_warning "Invalid option, please try again..."
            sleep 1
            ;;
    esac
    echo ""
done
