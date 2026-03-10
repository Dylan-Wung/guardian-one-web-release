#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.1 Standard)
# 適用環境: Orange Pi One (armhf), Arduino UNO Q (arm64)
# 安裝路徑: /opt/guardian_one_web
# ===========================================================================

set -euo pipefail

# --- [ 1. 自定義變數 ] ---
DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/raw/refs/heads/main/guardian_one_web.tar"
APP_USER="guardian"
APP_DIR="/opt/guardian_one_web"  # 遷移至標準應用程式目錄
APP_TAR="guardian_one_web.tar"

# --- [ 2. 環境偵測 ] ---
ARCH=$(uname -m)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')

log()  { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# --- [ 3. 前置檢查 ] ---
[[ $EUID -ne 0 ]] && error "請使用 sudo 權限執行此腳本。"

log "🚀 啟動萬用佈署流程 (架構: $ARCH)..."

# --- [ 4. 記憶體防護 (針對 Orange Pi One) ] ---
if [ "$TOTAL_RAM" -lt 1000 ]; then
    log "檢測到低記憶體環境，配置 512MB 臨時 Swap..."
    if [ ! -f /swapfile ]; then
        fallocate -l 512M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=512
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    fi
fi

# --- [ 5. 系統帳號與目錄準備 ] ---
if ! id "$APP_USER" &>/dev/null; then
    log "建立專案使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    usermod -aG sudo,dialout "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# 建立並鎖定 /opt 目錄
mkdir -p "$APP_DIR"
chown "$APP_USER":"$APP_USER" "$APP_DIR"

# --- [ 6. 系統套件安裝 ] ---
log "安裝系統基礎環境..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    htop curl wget net-tools python3-venv python3-pip python3-dev \
    build-essential nginx zram-tools logrotate

# --- [ 7. 專案下載與解壓縮 ] ---
log "從雲端獲取專案檔至 $APP_DIR..."
wget -q -L -O "/tmp/$APP_TAR" "$DOWNLOAD_URL" || error "下載失敗。"
tar -xf "/tmp/$APP_TAR" -C "$APP_DIR" --strip-components=1 # 若 tar 內含目錄則攤平
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
rm "/tmp/$APP_TAR"

# --- [ 8. yq 二進位檔適配 ] ---
if ! command -v yq &>/dev/null; then
    YQ_VER="v4.43.1"
    [[ "$ARCH" == "aarch64" ]] && YQ_BIN="yq_linux_arm64" || YQ_BIN="yq_linux_arm"
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VER}/${YQ_BIN}"
    chmod +x /usr/local/bin/yq
fi

# --- [ 9. Python 虛擬環境配置 (修正 Pip 錯誤) ] ---
log "建置 Python 虛擬環境於 $APP_DIR/venv..."
sudo -u "$APP_USER" bash <<EOF
cd "$APP_DIR"
python3 -m venv venv --clear
./venv/bin/python3 -m pip install --upgrade pip
./venv/bin/python3 -m pip install --no-cache-dir -r requirements.txt
EOF

# --- [ 10. ICMP (Ping) 權限修正 ] ---
log "設定核心參數以支援非特權 Ping..."
sysctl -w net.ipv4.ping_group_range="0 2147483647"
echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-guardian-ping.conf

# --- [ 11. Systemd 服務設定 ] ---
log "設定 Systemd 服務 (User=$APP_USER)..."
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

# --- [ 12. Nginx 配置 ] ---
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
}
EOF

# --- [ 13. 啟動與 ZRAM 優化 ] ---
ZRAM_ALGO="lz4"
[[ "$ARCH" == "aarch64" ]] && ZRAM_ALGO="lzo-rle"
echo -e "ALGO=$ZRAM_ALGO\nPRIORITY=100\nSIZE=256" > /etc/default/zramswap

systemctl daemon-reload
systemctl enable --now guardian-web.service
systemctl restart nginx
systemctl restart zramswap || true

log "====================================================="
log "✅ 佈署完成！"
log "安裝路徑: $APP_DIR"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
log "====================================================="
