#!/bin/bash
# ===========================================================================
# Guardian One Web - 一鍵全自動佈署腳本 (Final Version)
# 適用環境: Arduino UNO Q (Linux arm64)
# ===========================================================================

set -euo pipefail

# --- [自定義變數 - 請修改此處] ---
DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/blob/main/guardian_one_web.tar"
APP_USER="guardian"
APP_TAR="guardian_one_web.tar"
TARGET_HOME="/home/${APP_USER}"
APP_DIR="${TARGET_HOME}/guardian_one_web"

# --- [前置檢查] ---
[[ $EUID -ne 0 ]] && echo "請使用 sudo 權限執行" && exit 1

log()   { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

log "🚀 啟動自動化佈署流程..."

# 1. 建立使用者與權限設定
if ! id "$APP_USER" &>/dev/null; then
    log "建立使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    usermod -aG sudo "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# 2. 下載並解壓縮專案檔案
log "從雲端下載專案檔..."
if ! wget -q -L -O "$APP_TAR" "$DOWNLOAD_URL"; then
    error "下載失敗，請檢查 URL 是否正確。"
fi

log "解壓縮至 ${TARGET_HOME}..."
tar -xvf "$APP_TAR" -C "$TARGET_HOME"
chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
rm "$APP_TAR"

# 3. 安裝系統套件 (非互動模式)
log "安裝系統基礎環境..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    htop curl wget net-tools lsb-release bash-completion logrotate \
    zram-tools nmap traceroute gnupg2 ca-certificates python3-venv nginx

# 4. 安裝 yq (arm64)
if ! command -v yq &>/dev/null; then
    log "安裝 yq (arm64)..."
    YQ_VERSION="v4.43.1"
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64"
    chmod +x /usr/local/bin/yq
fi

# 5. Python 環境配置
log "配置 Python 虛擬環境..."
sudo -u "$APP_USER" bash <<EOF
cd "$APP_DIR"
python3 -m venv venv --clear
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
EOF

# 6. 建立 Systemd 服務
log "設定 guardian-web.service..."
cat > /etc/systemd/system/guardian-web.service <<EOF
[Unit]
Description=Guardian One WebApp Service
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7. Nginx 反向代理配置
log "設定 Nginx..."
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /old_report {
        alias /var/www/html;
        index index.html;
    }
}
EOF

# 8. 系統優化 (ZRAM)
log "設定 ZRAM (256MB)..."
echo -e "ALGO=lzo-rle\nPRIORITY=100\nSIZE=256" > /etc/default/zramswap

# 9. 啟動服務
systemctl daemon-reload
systemctl enable --now guardian-web.service
systemctl restart nginx
systemctl restart zramswap || systemctl restart zram-tools || true

log "✅ 佈署完成！"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
