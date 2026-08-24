#!/bin/bash
# install.sh - نسخه کامل با پچ و آپلود خودکار

set -e

# ========== تنظیمات ==========
GITHUB_USERNAME="YOUR_USERNAME"  # 🔴 این را به یوزرنیم خود تغییر دهید
REPO_NAME="stinger-unlocked"
BINARY_NAME="stinger"
# ==============================

echo "🚀 شروع نصب Stinger بدون محدودیت..."

# 1. نصب ابزارهای مورد نیاز
echo "📦 نصب ابزارهای لازم..."
sudo apt-get update -qq
sudo apt-get install -y -qq wget git curl 2>/dev/null || echo "⚠️  برخی ابزارها از قبل نصب هستند"

# 2. نصب GitHub CLI (اگر نیاز به آپلود دارید)
if ! command -v gh &> /dev/null; then
    echo "📥 نصب GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo apt-get update -qq
    sudo apt-get install -y gh
fi

# 3. دانلود باینری اصلی
echo "⬇️  دانلود باینری اصلی..."
wget -q --show-progress -O ${BINARY_NAME}.original https://raw.githubusercontent.com/lostsoul6/stinger-binary/main/stinger

# 4. ساخت نسخه بدون محدودیت
echo "🔧 ساخت نسخه بدون محدودیت..."

# بررسی نوع فایل
if file ${BINARY_NAME}.original | grep -q "shell script"; then
    echo "📄 فایل از نوع اسکریپت شل است - ویرایش مستقیم..."
    cp ${BINARY_NAME}.original ${BINARY_NAME}
    
    # حذف محدودیت‌ها
    sed -i '/ifconfig.me/d' ${BINARY_NAME}
    sed -i '/curl.*ifconfig/d' ${BINARY_NAME}
    sed -i '/lsb_release/d' ${BINARY_NAME}
    sed -i '/hostname/d' ${BINARY_NAME}
    sed -i '/allowed_servers/d' ${BINARY_NAME}
    sed -i '/exit 1.*IP/d' ${BINARY_NAME}
    
else
    echo "⚙️  فایل باینری است - ساخت wrapper..."
    
    # ساخت wrapper برای باینری
    cat > ${BINARY_NAME} << 'EOF'
#!/bin/bash
# Stinger - نسخه بدون محدودیت (Wrapper)

# متغیرهای جعلی برای دور زدن محدودیت‌ها
export FAKE_IP="192.168.1.100"
export FAKE_HOSTNAME="ubuntu-server"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"

# پیدا کردن مسیر باینری اصلی
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/stinger.bin"

# اجرای باینری با متغیرهای جعلی
if [ -f "$BINARY_PATH" ]; then
    exec "$BINARY_PATH" "$@"
else
    echo "❌ فایل باینری اصلی پیدا نشد!"
    exit 1
fi
EOF

    # تغییر نام فایل اصلی
    mv ${BINARY_NAME}.original ${BINARY_NAME}.bin
fi

chmod +x ${BINARY_NAME}

# 5. آپلود به گیتهاب (اختیاری)
read -p "🔄 آیا می‌خواهید نسخه بدون محدودیت را به گیتهاب آپلود کنید؟ (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "📤 آپلود به گیتهاب..."
    
    # لاگین به GitHub
    gh auth login
    
    # ایجاد یا استفاده از ریپازیتوری موجود
    if ! gh repo view ${GITHUB_USERNAME}/${REPO_NAME} &>/dev/null; then
        gh repo create ${REPO_NAME} --public --description "Stinger بدون محدودیت" --clone
    else
        git clone https://github.com/${GITHUB_USERNAME}/${REPO_NAME}.git temp-repo 2>/dev/null || mkdir -p temp-repo
    fi
    
    # کپی فایل‌ها
    mkdir -p temp-repo 2>/dev/null
    cp ${BINARY_NAME} temp-repo/ 2>/dev/null || true
    cp ${BINARY_NAME}.bin temp-repo/ 2>/dev/null || true
    
    cd temp-repo 2>/dev/null || exit
    
    # ایجاد README
    cat > README.md << 'EOF'
# Stinger بدون محدودیت

نسخه بدون محدودیت که روی تمام سرورها کار میکند.

## نصب و اجرا
```bash
wget -O stinger https://raw.githubusercontent.com/YOUR_USERNAME/stinger-unlocked/main/stinger
chmod +x stinger
./stinger
