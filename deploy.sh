#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.0)
# 支援硬體: Orange Pi One (armhf), Arduino UNO Q (arm64)
# 功能: 自動偵測 CPU 架構、記憶體優化、ICMP 權限修正、Nginx 反向代理
# ===========================================================================

set -euo pipefail

# --- [ 1. 自定義變數 ] ---
DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/raw/refs/heads/main/guardian_one_web.tar"
APP_USER="guardian"
APP_TAR="guardian_one_web.tar"
TARGET_HOME="/home/${APP_USER}"
APP_DIR="${TARGET_HOME}/guardian_one_web"

# --- [ 2. 環境偵測邏輯 ] ---
ARCH=$(uname -m)
OS_BIT=$(getconf LONG_BIT)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')

# --- [ 3. 工具函式 ] ---
log()  { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# --- [ 4. 前置檢查 ] ---
[[ $EUID -ne 0 ]] && error "請使用 sudo 權限執行此腳本。"

log "🚀 偵測到硬體架構: $ARCH ($OS_BIT-bit), 記憶體: ${TOTAL_RAM}MB"

# --- [ 5. 記憶體保護 (針對 Orange Pi One 等小記憶體設備) ] ---
if [ "$TOTAL_RAM" -lt 1000 ]; then
    log "檢測到低記憶體環境，配置 512MB 臨時 Swap..."
    if [ ! -f /swapfile ]; then
        fallocate -l 512M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=512
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    fi
fi

# --- [ 6. 系統帳號配置 ] ---
if ! id "$APP_USER" &>/dev/null; then
    log "建立專案使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    # 加入 dialout 以利 Arduino 序列埠存取
    usermod -aG sudo,dialout "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# --- [ 7. 套件安裝 ] ---
log "更新系統套件庫..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    htop curl wget net-tools python3-venv python3-pip python3-dev \
    build-essential nginx zram-tools lsb-release bash-completion logrotate

# --- [ 8. 專案檔案下載 ] ---
log "獲取專案源碼..."
wget -q -L -O "/tmp/$APP_TAR" "$DOWNLOAD_URL" || error "下載失敗，請檢查 GitHub 連結。"
mkdir -p "$APP_DIR"
tar -xf "/tmp/$APP_TAR" -C "$TARGET_HOME"
chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
rm "/tmp/$APP_TAR"

# --- [ 9. yq 二進位檔適配 ] ---
if ! command -v yq &>/dev/null; then
    YQ_VER="v4.43.1"
    if [[ "$ARCH" == "aarch64" ]]; then
        YQ_BIN="yq_linux_arm64"
    else
        YQ_BIN="yq_linux_arm"
    fi
    log "安裝 yq 適配版本: $YQ_BIN..."
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/${YQ_BIN}"
    chmod +x /usr/local/bin/yq
fi

# --- [ 10. Python 虛擬環境配置 ] ---
log "建置 Python 環境 (Module Mode)..."
sudo -u "$APP_USER" bash <<EOF
cd "$APP_DIR"
python3 -m venv venv --clear
./venv/bin/python3 -m pip install --upgrade pip
# 針對 Orange Pi 等資源受限設備強制不使用快取
./venv/bin/python3 -m pip install --no-cache-dir -r requirements.txt
EOF

# --- [ 11. ICMP (Ping) 權限修正 ] ---
log "套用資安優化：ICMP Unprivileged Socket..."
sysctl -w net.ipv4.ping_group_range="0 2147483647"
echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-guardian-ping.conf

# --- [ 12. 服務元件設定 (Systemd & Nginx) ] ---
log "生成服務設定檔..."
cat > /etc/systemd/system/guardian-web.service <<EOF
[Unit]
Description=Guardian One WebApp Service
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin"
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
    location /old_report {
        alias /var/www/html;
        index index.html;
    }
}
EOF

# --- [ 13. ZRAM 優化 ] ---
ZRAM_ALGO="lz4"
[[ "$ARCH" == "aarch64" ]] && ZRAM_ALGO="lzo-rle"
echo -e "ALGO=$ZRAM_ALGO\nPRIORITY=100\nSIZE=256" > /etc/default/zramswap

# --- [ 14. 服務啟動 ] ---
log "重載系統服務並啟動..."
systemctl daemon-reload
systemctl enable --now guardian-web.service
systemctl restart nginx
systemctl restart zramswap || true

log "====================================================="
log "✅ 萬用佈署完成！"
log "硬體模式: $ARCH"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
log "====================================================="
