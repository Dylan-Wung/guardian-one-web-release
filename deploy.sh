#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.7)
# 修正重點：確保 Nginx 反向代理設定正確生效，解決 Welcome 頁面問題
# ===========================================================================

set -euo pipefail

DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/raw/refs/heads/main/guardian_one_web.tar"
APP_USER="guardian"
APP_DIR="/opt/guardian_one_web"
APP_TAR="guardian_one_web_v37.tar"

log()  { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

[[ $EUID -ne 0 ]] && error "請使用 sudo 執行。"

log "🚀 啟動萬用佈署流程 (v3.7)..."

# --- [ 1. 環境清理與準備 ] ---
log "清理舊有環境..."
systemctl stop guardian-web.service || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

# --- [ 2. 使用者檢查 ] ---
if ! id "$APP_USER" &>/dev/null; then
    log "建立專案使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    usermod -aG sudo,dialout "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# --- [ 3. 下載與解壓 ] ---
log "從 GitHub 獲取專案檔..."
wget -q -L -O "/tmp/$APP_TAR" "$DOWNLOAD_URL" || error "下載失敗。"
tar -xf "/tmp/$APP_TAR" -C "$APP_DIR" --strip-components=1 || error "解壓失敗。"
rm -f "/tmp/$APP_TAR"

# --- [ 4. 重要：修正路徑與權限補強 ] ---
log "修正原始碼硬編碼路徑..."
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/guardian/guardian_one_web|$APP_DIR|g" {} +

log "初始化日誌並修正目錄所有權..."
touch "$APP_DIR/device_health.log"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# --- [ 5. 系統套件安裝 ] ---
log "確認系統套件..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y python3-venv python3-pip nginx sed curl > /dev/null

# --- [ 6. Python 虛擬環境配置 ] ---
log "建置 Python 虛擬環境..."
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv" --clear
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"

# --- [ 7. 系統優化與服務啟動 ] ---
log "設定核心參數與 Systemd..."
sysctl -w net.ipv4.ping_group_range="0 2147483647"
echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-guardian-ping.conf

# 7.1 寫入服務檔
cat > /etc/systemd/system/guardian-web.service <<EOF
[Unit]
Description=Guardian One WebApp
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin"
Environment="HOME=$APP_DIR"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7.2 關鍵：寫入並強制連結 Nginx 設定 (解決 Welcome 頁面問題)
log "配置 Nginx 反向代理..."
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 強制建立連結並移除可能干擾的預設頁面備份
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
rm -f /var/www/html/index.nginx-debian.html || true

# 啟動服務
systemctl daemon-reload
systemctl enable --now guardian-web.service
nginx -t && systemctl restart nginx

log "====================================================="
log "✅ 佈署完成！"
log "本機驗證狀態: $(curl -s -I http://127.0.0.1 | head -n 1)"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
log "====================================================="
