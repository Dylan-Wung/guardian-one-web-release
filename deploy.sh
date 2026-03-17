#!/bin/bash
# ===========================================================================
# Guardian One Web - 萬用全自動佈署腳本 (v3.9.2)
# 修正重點：針對 2026 SHA-1 淘汰政策修復 APT 簽章與 ARM 編譯環境
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

log "🚀 啟動 Guardian One 佈署流程 (v3.9.2)..."

# --- [ 1. 系統環境預處理 ] ---
log "校正系統主機名解析與 APT 簽署金鑰..."
# 1.1 修正主機名解析錯誤 (解決 sudo 無法解析主機名問題)
if ! grep -q "$(hostname)" /etc/hosts; then
    echo "127.0.1.1 $(hostname)" >> /etc/hosts
fi

# 1.2 更新 Armbian GPG 金鑰 (針對 2026 資安規範修復)
if command -v gpg > /dev/null; then
    wget -q -O - https://apt.armbian.com/armbian.key | gpg --dearmor --yes -o /usr/share/keyrings/armbian.gpg || true
fi

# --- [ 2. 環境清理與舊版本移除 ] ---
log "執行舊環境深度清理..."
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

for path in "${OLD_PATHS[@]}"; do
    if [ -d "$path" ]; then
        log "偵測到舊有目錄: $path，執行移除..."
        [[ -n "$path" && "$path" != "/" ]] && rm -rf "$path"
    fi
done

mkdir -p "$APP_DIR"

# --- [ 3. 使用者與權限檢查 ] ---
if ! id "$APP_USER" &>/dev/null; then
    log "建立專案使用者 ${APP_USER}..."
    adduser --disabled-password --gecos "" "$APP_USER"
    usermod -aG sudo,dialout "$APP_USER"
    echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${APP_USER}"
fi

# --- [ 4. 下載與解壓 ] ---
log "從 GitHub 獲取專案專案壓縮檔..."
wget -q -L -O "/tmp/$APP_TAR" "$DOWNLOAD_URL" || error "下載失敗，請檢查網路連線。"
tar -xf "/tmp/$APP_TAR" -C "$APP_DIR" --strip-components=1 || error "解壓失敗。"
rm -f "/tmp/$APP_TAR"

# --- [ 5. 系統依賴與編譯環境安裝 ] ---
log "同步系統套件並配置編譯環境 (修復 ARM psutil 編譯錯誤)..."
export DEBIAN_FRONTEND=noninteractive

# 針對 2026 SHA-1 淘汰，允許舊簽章套件下載以完成編譯工具安裝
apt-get update -o Acquire::AllowInsecureRepositories=true \
        -o Acquire::AllowDowngradeToInsecureRepositories=true || true

apt-get install -y --allow-unauthenticated \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    nginx \
    sed \
    curl \
    nmap \
    iproute2 \
    libcap2-bin > /dev/null

# 資安防呆：檢查 Python 標頭檔是否安裝成功
if [ ! -d "/usr/include/python3.13" ] && [ ! -d "/usr/include/python3" ]; then
    log "警告: Python 開發標頭檔未找到，嘗試精確安裝..."
    apt-get install -y --allow-unauthenticated python3.13-dev || true
fi

# 配置 Nmap 特權
log "配置 Nmap 核心網絡掃描 Capability..."
REAL_NMAP=$(readlink -f /usr/bin/nmap)
if [ -x "$REAL_NMAP" ]; then
    setcap cap_net_raw,cap_net_admin,cap_net_bind_service+eip "$REAL_NMAP"
fi

# --- [ 6. 原始碼路徑修正 ] ---
log "執行路徑修正與初始化..."
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/guardian/guardian_one_web|$APP_DIR|g" {} +
find "$APP_DIR" -type f \( -name "*.py" -o -name ".env" -o -name "*.yaml" \) -exec sed -i "s|/home/dylan/guardian_one_web|$APP_DIR|g" {} +

if [ -f "$APP_DIR/scan_worker.py" ]; then
    sed -i 's/nmap_path = shutil.which("nmap")/nmap_path = "\/usr\/bin\/nmap"/' "$APP_DIR/scan_worker.py"
fi

touch "$APP_DIR/device_health.log"
mkdir -p "$APP_DIR/scan_jobs"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# --- [ 7. Python 虛擬環境與依賴安裝 ] ---
log "建立 VENV 並安裝依賴套件 (此步驟於 ARM 可能較慢，請耐心等待)..."
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv" --clear
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip

# 開始安裝依賴，此時已具備 Python.h，psutil 編譯將會成功
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install python-nmap

# --- [ 8. 服務啟動 ] ---
log "部署 Systemd 服務與 Nginx..."
cat > /etc/systemd/system/guardian-web.service <<EOF
[Unit]
Description=Guardian One WebApp
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/app.py
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
systemctl daemon-reload
systemctl enable --now guardian-web.service
nginx -t && systemctl restart nginx

log "✅ Guardian One v3.9.2 佈署完成！"
log "存取網址: http://$(hostname -I | awk '{print $1}')"
