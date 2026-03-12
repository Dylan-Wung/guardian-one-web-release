#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.8)
# 修正重點：
# 1. 補全 Nmap 系統套件與 python-nmap 依賴。
# 2. 自動賦予 Nmap 核心網路 Capability (Setcap)。
# 3. 修正 scan_worker.py 中的絕對路徑，解決 Systemd PATH 缺失問題。
# 4. 預建掃描任務目錄並確保權限完整。
# ===========================================================================

set -euo pipefail

DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/raw/refs/heads/main/guardian_one_web.tar"
APP_USER="guardian"
APP_DIR="/opt/guardian_one_web"
APP_TAR="guardian_one_web_v38.tar"

log()  { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

[[ $EUID -ne 0 ]] && error "請使用 sudo 執行。"

log "🚀 啟動萬用佈署流程 (v3.8)..."

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

# --- [ 4. 修正路徑與權限補強 ] ---
log "修正原始碼硬編碼路徑..."
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/guardian/guardian_one_web|$APP_DIR|g" {} +

# [核心修正] 解決 scan_worker 在 Systemd 下找不到 nmap 的問題
if [ -f "$APP_DIR/scan_worker.py" ]; then
    log "修正 scan_worker.py 中的 Nmap 絕對路徑..."
    sed -i 's/nmap_path = shutil.which("nmap")/nmap_path = "\/usr\/bin\/nmap"/' "$APP_DIR/scan_worker.py"
fi

log "初始化日誌、掃描目錄並修正所有權..."
touch "$APP_DIR/device_health.log"
mkdir -p "$APP_DIR/scan_jobs"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# --- [ 5. 系統套件安裝 ] ---
log "確認系統套件 (包含 Nmap)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y python3-venv python3-pip nginx sed curl nmap iproute2 > /dev/null

# [核心修正] 賦予 Nmap 特權 (必須在 apt install 之後)
log "配置 Nmap 網路掃描特權 (Setcap)..."
REAL_NMAP=$(readlink -f /usr/bin/nmap)
if [ -x "$REAL_NMAP" ]; then
    setcap cap_net_raw,cap_net_admin,cap_net_bind_service+eip "$REAL_NMAP"
    log "Nmap Capability 設定完成。"
else
    log "警告: 找不到 Nmap 執行檔，跳過賦權。"
fi

# --- [ 6. Python 虛擬環境配置 ] ---
log "建置 Python 虛擬環境並安裝依賴..."
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv" --clear
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip
# 強制安裝 python-nmap 以確保掃描模組運作
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install python-nmap

# --- [ 7. 系統優化與服務啟動 ] ---
log "設定核心參數 (Ping Range) 與 Systemd..."
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
Environment="PATH=$APP_DIR/venv/bin:/usr/bin:/bin"
Environment="HOME=$APP_DIR"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7.2 配置 Nginx 反向代理
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

ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
rm -f /var/www/html/index.nginx-debian.html || true

# 啟動服務
systemctl daemon-reload
systemctl enable --now guardian-web.service
nginx -t && systemctl restart nginx

log "====================================================="
log "✅ Guardian One v3.8 佈署完成！"
log "本機驗證狀態: $(curl -s -I http://127.0.0.1 | head -n 1)"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
log "====================================================="
