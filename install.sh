#!/bin/bash
# install.sh - Automatic Stinger Unlocked Installer
# Repository: https://github.com/parhampahlevann/stringer

set -e

# ============================================
# Configuration
# ============================================
GITHUB_USERNAME="parhampahlevann"
REPO_NAME="stringer"
BINARY_NAME="stinger"
ORIGINAL_URL="https://raw.githubusercontent.com/lostsoul6/stinger-binary/main/stinger"
# ============================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "=========================================="
echo "  🚀 Stinger Unlocked - Auto Installer"
echo "  https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
echo "=========================================="
echo ""

# ============================================
# Step 1: Check OS
# ============================================
print_status "Checking operating system..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    print_success "OS: $NAME $VERSION_ID"
fi

# ============================================
# Step 2: Install Required Tools
# ============================================
print_status "Installing required tools..."
for tool in wget curl git; do
    if ! command -v $tool &> /dev/null; then
        print_warning "$tool is not installed, installing..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq $tool
    fi
done
print_success "All required tools installed"

# ============================================
# Step 3: Download Original Binary
# ============================================
print_status "Downloading original binary..."
if wget -q --show-progress -O ${BINARY_NAME}.original "$ORIGINAL_URL"; then
    print_success "Download completed"
else
    print_error "Download failed!"
    exit 1
fi

# ============================================
# Step 4: Build Unlocked Version
# ============================================
print_status "Building unlocked version..."

if file ${BINARY_NAME}.original | grep -q "shell script"; then
    print_status "Editing shell script..."
    cp ${BINARY_NAME}.original ${BINARY_NAME}
    sed -i '/ifconfig.me/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/curl.*ifconfig/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/lsb_release/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/hostname/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/allowed_servers/d' ${BINARY_NAME} 2>/dev/null || true
    print_success "Restrictions removed"
else
    print_status "Creating wrapper for binary..."
    
    # Rename original binary
    mv ${BINARY_NAME}.original ${BINARY_NAME}.bin
    
    # Make the binary executable
    chmod +x ${BINARY_NAME}.bin
    print_success "Binary permissions fixed"
    
    # Create wrapper script
    cat > ${BINARY_NAME} << 'EOF'
#!/bin/bash
# Stinger Wrapper - Unlocked Version

# Bypass restrictions
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"

# Run the actual binary
if [ -f "$BINARY_PATH" ]; then
    # Ensure binary is executable
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    echo "[✓] Running Stinger Unlocked..."
    exec "$BINARY_PATH" "$@"
else
    echo "[✗] Error: stinger.bin not found in $SCRIPT_DIR"
    exit 1
fi
EOF

    chmod +x ${BINARY_NAME}
    print_success "Wrapper created and permissions set"
fi

print_success "${BINARY_NAME} is ready"

# ============================================
# Step 5: Run
# ============================================
echo ""
print_success "Installation completed!"

if [[ -f "${BINARY_NAME}" ]]; then
    print_status "Unlocked version is ready at ${BINARY_NAME}"
    echo ""
    read -p "Do you want to run Stinger now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        print_status "Running Stinger Unlocked..."
        echo "=========================================="
        ./${BINARY_NAME}
    else
        echo ""
        print_status "You can run it later with:"
        echo "  ./${BINARY_NAME}"
    fi
else
    print_error "${BINARY_NAME} not found!"
fi

echo ""
echo "=========================================="
print_success "Process finished"
echo "=========================================="
