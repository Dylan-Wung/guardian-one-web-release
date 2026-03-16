#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.9)
# 修正重點：
# 1. 強化環境清理：自動檢查並移除多個潛在安裝目錄 (/home/dylan, /home/guardian, /opt)。
# 2. 確保服務清理：移除舊有 Systemd 服務定義，防止衝突。
# 3. 延續 v3.8 Nmap 特權配置與自動化路徑修正邏輯。
# ===========================================================================

set -euo pipefail

# --- [ 參數定義 ] ---
DOWNLOAD_URL="https://github.com/Dylan-Wung/guardian-one-web-release/raw/refs/heads/main/guardian_one_web.tar"
APP_USER="guardian"
APP_DIR="/opt/guardian_one_web"
APP_TAR="guardian_one_web_v39.tar"
SERVICE_NAME="guardian-web.service"

# 潛在的舊安裝路徑
OLD_PATHS=(
    "/home/dylan/guardian_one_web"
    "/home/guardian/guardian_one_web"
    "/opt/guardian_one_web"
)

log()  { echo -e "\e[32m[INFO] $1\e[0m"; }
error() { echo -e "\e[31m[ERROR] $1\e[0m"; exit 1; }

# --- [ 核心檢查 ] ---
[[ $EUID -ne 0 ]] && error "請使用 sudo 執行此腳本。"

log "🚀 啟動 Guardian One 佈署流程 (v3.9)..."

# --- [ 1. 環境清理與舊版本移除 ] ---
log "執行舊環境深度清理..."

# 1.1 停止並禁用服務
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "停止執行中的服務: $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME" || true
fi

if [ -f "/etc/systemd/system/$SERVICE_NAME" ]; then
    log "移除舊有 Systemd 服務定義..."
    systemctl disable "$SERVICE_NAME" || true
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload
fi

# 1.2 清除所有可能的安裝目錄
for path in "${OLD_PATHS[@]}"; do
    if [ -d "$path" ]; then
        log "偵測到舊有目錄: $path，執行移除..."
        # 防呆：確保 path 不為空且不是根目錄
        [[ -n "$path" && "$path" != "/" ]] && rm -rf "$path"
    fi
done

# 1.3 重新建立乾淨的目標目錄
log "準備全新安裝目錄: $APP_DIR"
mkdir -p "$APP_DIR"

# --- [ 2. 使用者檢查 ] ---
if ! id "$APP_USER" &>/dev/null; then
    log "建立專案使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    usermod -aG sudo,dialout "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# --- [ 3. 下載與解壓 ] ---
log "從 GitHub 獲取專案專案壓縮檔..."
wget -q -L -O "/tmp/$APP_TAR" "$DOWNLOAD_URL" || error "下載失敗，請檢查網路連線。"
tar -xf "/tmp/$APP_TAR" -C "$APP_DIR" --strip-components=1 || error "解壓失敗。"
rm -f "/tmp/$APP_TAR"

# --- [ 4. 路徑修正與權限配置 ] ---
log "執行原始碼路徑修正 (取代為 $APP_DIR)..."
# 針對所有可能包含舊路徑的設定檔進行全域取代
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/guardian/guardian_one_web|$APP_DIR|g" {} +
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/dylan/guardian_one_web|$APP_DIR|g" {} +

# 修正 scan_worker 內部 Nmap 路徑，確保 Systemd 環境下可執行
if [ -f "$APP_DIR/scan_worker.py" ]; then
    log "修正 scan_worker.py 中的 Nmap 絕對路徑..."
    sed -i 's/nmap_path = shutil.which("nmap")/nmap_path = "\/usr\/bin\/nmap"/' "$APP_DIR/scan_worker.py"
fi

log "初始化日誌、任務目錄並修正權限..."
touch "$APP_DIR/device_health.log"
mkdir -p "$APP_DIR/scan_jobs"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# --- [ 5. 系統依賴套件安裝 ] ---
log "同步系統套件並安裝 Nmap 掃描工具..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y python3-venv python3-pip nginx sed curl nmap iproute2 libcap2-bin > /dev/null

# 配置 Nmap Raw Socket 特權
log "配置 Nmap 核心網路掃描 Capability (Setcap)..."
REAL_NMAP=$(readlink -f /usr/bin/nmap)
if [ -x "$REAL_NMAP" ]; then
    setcap cap_net_raw,cap_net_admin,cap_net_bind_service+eip "$REAL_NMAP"
    log "Nmap Setcap 設定完成。"
else
    log "警告: 找不到 Nmap 二進制檔，請確認安裝狀態。"
fi

# --- [ 6. Python 虛擬環境與依賴 ] ---
log "建立隔離的 Python 虛擬環境 (VENV)..."
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv" --clear
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip
log "安裝 Python 依賴套件..."
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install python-nmap

# --- [ 7. 系統優化與服務啟動 ] ---
log "優化系統網路參數 (ICMP Range)..."
sysctl -w net.ipv4.ping_group_range="0 2147483647"
echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-guardian-ping.conf

log "部署 Systemd 服務單元..."
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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "配置 Nginx 反向代理 (Port 80 -> 5000)..."
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

# 重新載入並啟動
systemctl daemon-reload
systemctl enable --now guardian-web.service
nginx -t && systemctl restart nginx

log "====================================================="
log "✅ Guardian One v3.9 佈署完成！"
log "系統檢查: $(systemctl is-active guardian-web.service)"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
log "====================================================="
