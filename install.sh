#!/bin/bash
# install.sh - Automatic Stinger Unlocked Installer
# Repository: https://github.com/parhampahlevann/stringer

set -e

# ============================================
# Configuration - Edit this section as needed
# ============================================
GITHUB_USERNAME="parhampahlevann"
REPO_NAME="stringer"
BINARY_NAME="stinger"
ORIGINAL_URL="https://raw.githubusercontent.com/lostsoul6/stinger-binary/main/stinger"
# ============================================

# Colors for beautiful output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

echo "=========================================="
echo "  🚀 Stinger Unlocked - Auto Installer"
echo "  https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
echo "=========================================="
echo ""

# ============================================
# Step 1: Check Operating System
# ============================================
print_status "Checking operating system..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
    print_success "OS: $OS $VER"
else
    print_warning "OS could not be identified, but continuing..."
fi

# ============================================
# Step 2: Install Required Tools
# ============================================
print_status "Installing required tools..."

if ! command -v wget &> /dev/null; then
    print_warning "wget is not installed, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq wget
fi

if ! command -v curl &> /dev/null; then
    print_warning "curl is not installed, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl
fi

if ! command -v git &> /dev/null; then
    print_warning "git is not installed, installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq git
fi

print_success "All required tools installed"

# ============================================
# Step 3: Install GitHub CLI (Optional)
# ============================================
read -p "Do you want to install GitHub CLI? (for auto-upload) [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if ! command -v gh &> /dev/null; then
        print_status "Installing GitHub CLI..."
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        sudo apt-get update -qq
        sudo apt-get install -y -qq gh
        print_success "GitHub CLI installed"
    else
        print_success "GitHub CLI is already installed"
    fi
fi

# ============================================
# Step 4: Download Original Binary
# ============================================
print_status "Downloading original binary from: $ORIGINAL_URL"
if wget -q --show-progress -O ${BINARY_NAME}.original "$ORIGINAL_URL"; then
    print_success "Download completed successfully"
else
    print_error "Download failed! Please check your internet connection."
    exit 1
fi

# ============================================
# Step 5: Build Unlocked Version
# ============================================
print_status "Building unlocked version..."

if file ${BINARY_NAME}.original | grep -q "shell script"; then
    print_status "File is a shell script - editing directly..."
    cp ${BINARY_NAME}.original ${BINARY_NAME}
    
    sed -i '/ifconfig.me/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/curl.*ifconfig/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/lsb_release/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/hostname/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/allowed_servers/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*IP/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*server/d' ${BINARY_NAME} 2>/dev/null || true
    sed -i '/exit 1.*ubuntu/d' ${BINARY_NAME} 2>/dev/null || true
    
    print_success "Restrictions removed from script"
else
    print_status "File is binary - building wrapper..."
    
    cat > ${BINARY_NAME} << 'WRAPPER_EOF'
#!/bin/bash
# Stinger - Unlocked Version (Wrapper)

export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
export STINGER_IGNORE_CHECKS="1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"

if [ -f "$BINARY_PATH" ]; then
    chmod +x "$BINARY_PATH"
    echo "[✓] Running Stinger Unlocked..."
    exec "$BINARY_PATH" "$@"
else
    echo "[✗] Original binary not found!"
    echo "[!] Please make sure stinger.bin is in the current directory."
    exit 1
fi
WRAPPER_EOF

    mv ${BINARY_NAME}.original ${BINARY_NAME}.bin
    print_success "Wrapper created and original binary renamed to stinger.bin"
fi

chmod +x ${BINARY_NAME}
print_success "${BINARY_NAME} is now executable"

# ============================================
# Step 6: Upload to GitHub (Optional)
# ============================================
echo ""
read -p "Do you want to upload the unlocked version to GitHub? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI is not installed! Please install it first."
        exit 1
    fi
    
    print_status "Preparing to upload to GitHub..."
    
    if ! gh auth status &>/dev/null; then
        print_warning "You are not logged in to GitHub. Opening browser..."
        gh auth login
    fi
    
    REPO_URL="https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
    print_status "Using repository: $REPO_URL"
    
    if ! gh repo view ${GITHUB_USERNAME}/${REPO_NAME} &>/dev/null; then
        print_status "Creating new repository..."
        gh repo create ${REPO_NAME} --public --description "Stinger Unlocked - Auto Installer"
        git clone https://github.com/${GITHUB_USERNAME}/${REPO_NAME}.git temp-repo 2>/dev/null
    else
        print_status "Cloning existing repository..."
        git clone https://github.com/${GITHUB_USERNAME}/${REPO_NAME}.git temp-repo 2>/dev/null || mkdir -p temp-repo
    fi
    
    mkdir -p temp-repo 2>/dev/null
    cp ${BINARY_NAME} temp-repo/ 2>/dev/null || true
    cp ${BINARY_NAME}.bin temp-repo/ 2>/dev/null || true
    cp ${BINARY_NAME}.original temp-repo/ 2>/dev/null || true
    
    cd temp-repo 2>/dev/null || exit
    
    cat > README.md << 'README_EOF'
# Stinger Unlocked

Unlocked version of Stinger that works on ALL servers.

## Features

- Removed IP restrictions
- Removed OS restrictions
- Removed server whitelist
- One-click auto installation
- Runs on all Ubuntu servers

## Installation

```bash
wget -O stinger https://raw.githubusercontent.com/parhampahlevann/stringer/main/stinger
chmod +x stinger
./stinger
