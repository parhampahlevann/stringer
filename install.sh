#!/bin/bash
# install.sh - نصب خودکار Stinger بدون محدودیت

echo "=========================================="
echo "  🚀 Stinger Unlocked - نصب خودکار"
echo "=========================================="
echo ""

# 1. دانلود فایل اصلی
echo "[1/4] دانلود فایل اصلی..."
wget -q --show-progress -O stinger.original https://raw.githubusercontent.com/lostsoul6/stinger-binary/main/stinger

# 2. ساخت نسخه بدون محدودیت
echo "[2/4] ساخت نسخه بدون محدودیت..."

# بررسی نوع فایل
if file stinger.original | grep -q "shell script"; then
    cp stinger.original stinger
    sed -i '/ifconfig.me/d' stinger 2>/dev/null
    sed -i '/curl.*ifconfig/d' stinger 2>/dev/null
    sed -i '/lsb_release/d' stinger 2>/dev/null
    sed -i '/hostname/d' stinger 2>/dev/null
    echo "✅ نسخه بدون محدودیت ساخته شد"
else
    # ساخت wrapper برای فایل باینری
    cp stinger.original stinger.bin
    cat > stinger << 'EOF'
#!/bin/bash
export FAKE_IP="192.168.1.100"
export FAKE_OS="Ubuntu"
export ALLOWED_SERVER="true"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/stinger.bin" "$@"
EOF
    echo "✅ نسخه بدون محدودیت ساخته شد"
fi

# 3. قابل اجرا کردن
chmod +x stinger
echo "[3/4] فایل قابل اجرا شد"

# 4. اجرا
echo "[4/4] اجرای Stinger..."
echo "=========================================="
./stinger
