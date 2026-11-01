#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT=/opt/arblens
DATA_ROOT=/var/lib/arblens
CONFIG_ROOT=/etc/arblens
RELEASE_REPO=Slliki/ArbLensMonitor-Installer
RELEASE_ASSET=arblens-source.tar.gz
PORT=3000

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 sudo 运行此安装器。" >&2
  exit 1
fi
echo ""
echo "ArbLens Monitor 一键安装 / 升级"
echo "--------------------------------"
echo "将安装网页、持久化历史数据库、3 秒后台采集和飞书报警服务。"
echo ""

mkdir -p "$APP_ROOT/releases" "$DATA_ROOT/home/.config" "$DATA_ROOT/wrangler-logs" "$CONFIG_ROOT"

SETTINGS="$CONFIG_ROOT/settings"
if [[ -f "$SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$SETTINGS"
fi
GATE_CROSSEX_KEY=${GATE_CROSSEX_KEY:-}
GATE_CROSSEX_SECRET=${GATE_CROSSEX_SECRET:-}
PUBLIC_DOMAIN=${PUBLIC_DOMAIN:-}

if [[ -r /dev/tty && -z "$GATE_CROSSEX_KEY" ]]; then
  read -r -p "Gate API Key（只读；可暂时留空）: " GATE_CROSSEX_KEY </dev/tty
fi
if [[ -r /dev/tty && -n "$GATE_CROSSEX_KEY" && -z "$GATE_CROSSEX_SECRET" ]]; then
  read -r -s -p "Gate API Secret（输入不显示）: " GATE_CROSSEX_SECRET </dev/tty
  echo ""
fi
if [[ -r /dev/tty && -z "$PUBLIC_DOMAIN" ]]; then
  read -r -p "已解析到本服务器的域名（没有可直接回车，先使用公网 IP）: " PUBLIC_DOMAIN </dev/tty
fi
if [[ -n "$PUBLIC_DOMAIN" && ! "$PUBLIC_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "域名格式无效。" >&2
  exit 1
fi

umask 077
{
  printf 'GATE_CROSSEX_KEY=%q\n' "$GATE_CROSSEX_KEY"
  printf 'GATE_CROSSEX_SECRET=%q\n' "$GATE_CROSSEX_SECRET"
  printf 'PUBLIC_DOMAIN=%q\n' "$PUBLIC_DOMAIN"
} > "$SETTINGS"
umask 022

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl nginx tar xz-utils python3 >/dev/null
if ! command -v node >/dev/null 2>&1 || [[ $(node -p 'Number(process.versions.node.split(".")[0])') -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi

if ! id arblens >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_ROOT" --shell /usr/sbin/nologin arblens
fi
install -d -o arblens -g arblens -m 750 "$DATA_ROOT/home" "$DATA_ROOT/home/.config" "$DATA_ROOT/wrangler-logs"

STAMP=$(date -u +%Y%m%d%H%M%S)
RELEASE="$APP_ROOT/releases/$STAMP"
PREVIOUS_RELEASE=$(readlink -f "$APP_ROOT/current" 2>/dev/null || true)
ARCHIVE=$(mktemp /tmp/arblens.XXXXXX.tar.gz)
cleanup() { rm -f "$ARCHIVE"; }
trap cleanup EXIT

HTTP_CODE=$(curl -sS -L --retry 3 --retry-all-errors -o "$ARCHIVE" -w '%{http_code}' \
  "https://github.com/$RELEASE_REPO/releases/latest/download/$RELEASE_ASSET")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "下载 ArbLens 公共安装包失败（HTTP $HTTP_CODE），请稍后重试。" >&2
  exit 1
fi
tar -tzf "$ARCHIVE" >/dev/null || { echo "安装包校验失败。" >&2; exit 1; }

mkdir -p "$RELEASE"
tar -xzf "$ARCHIVE" -C "$RELEASE"
cd "$RELEASE"
npm ci --no-audit --no-fund
npm run build

MONITOR_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')
export MONITOR_TOKEN GATE_CROSSEX_KEY GATE_CROSSEX_SECRET
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path("dist/server/wrangler.json")
d = json.loads(p.read_text())
d["vars"] = {
    "MONITOR_TOKEN": os.environ["MONITOR_TOKEN"],
    "MONITOR_MIN_VOLUME": "100000",
    "ENABLE_SERVER_BITGET": "1",
    "GATE_CROSSEX_KEY": os.environ.get("GATE_CROSSEX_KEY", ""),
    "GATE_CROSSEX_SECRET": os.environ.get("GATE_CROSSEX_SECRET", ""),
}
(p.parent / "wrangler.local.json").write_text(json.dumps(d, separators=(",", ":")))
PY
chmod 600 "$RELEASE/dist/server/wrangler.local.json"
chown -R arblens:arblens "$RELEASE" "$DATA_ROOT"
ln -sfn "$RELEASE" "$APP_ROOT/current"

cat > "$CONFIG_ROOT/runtime.env" <<EOF
MONITOR_TOKEN=$MONITOR_TOKEN
EOF
chown root:arblens "$CONFIG_ROOT/runtime.env"
chmod 640 "$CONFIG_ROOT/runtime.env"

cat > /usr/local/bin/arblens-monitor-loop <<'EOF'
#!/usr/bin/env bash
set -u
source /etc/arblens/runtime.env
while true; do
  curl -fsS --max-time 120 -X POST \
    -H "Authorization: Bearer ${MONITOR_TOKEN}" \
    http://127.0.0.1:3000/api/monitor/tick >/dev/null || true
  sleep 3
done
EOF
chmod 755 /usr/local/bin/arblens-monitor-loop

cat > /usr/local/bin/arblens-health-watchdog <<'EOF'
#!/usr/bin/env bash
set -u
failures=0
while true; do
  sleep 30
  if curl -fsS --max-time 8 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    failures=0
    continue
  fi
  failures=$((failures + 1))
  if (( failures < 2 )); then continue; fi
  logger -t arblens-watchdog "health check failed twice; restarting arblens-web"
  systemctl restart arblens-web
  failures=0
  sleep 15
done
EOF
chmod 755 /usr/local/bin/arblens-health-watchdog

cat > /etc/systemd/system/arblens-web.service <<'EOF'
[Unit]
Description=ArbLens web and API service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=arblens
Group=arblens
WorkingDirectory=/opt/arblens/current/dist/server
Environment=WRANGLER_SEND_METRICS=false
Environment=WRANGLER_LOG=warn
Environment=HOME=/var/lib/arblens/home
Environment=XDG_CONFIG_HOME=/var/lib/arblens/home/.config
Environment=WRANGLER_LOG_PATH=/var/lib/arblens/wrangler-logs
ExecStart=/opt/arblens/current/node_modules/.bin/wrangler dev --config wrangler.local.json --persist-to /var/lib/arblens --ip 127.0.0.1 --port 3000 --local --no-show-interactive-dev-session
Restart=always
RestartSec=3
TimeoutStopSec=20
KillMode=control-group
OOMPolicy=kill
MemoryAccounting=true
MemoryMax=1400M
MemorySwapMax=512M
RuntimeMaxSec=6h

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/arblens-watchdog.service <<'EOF'
[Unit]
Description=ArbLens HTTP health watchdog
After=arblens-web.service
Requires=arblens-web.service

[Service]
Type=simple
ExecStart=/usr/local/bin/arblens-health-watchdog
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/tmpfiles.d/arblens.conf <<'EOF'
d /var/lib/arblens/home 0750 arblens arblens 7d
d /var/lib/arblens/home/.config 0750 arblens arblens 7d
d /var/lib/arblens/wrangler-logs 0750 arblens arblens 7d
EOF
systemd-tmpfiles --create --clean /etc/tmpfiles.d/arblens.conf

cat > /etc/systemd/system/arblens-monitor.service <<'EOF'
[Unit]
Description=ArbLens 3-second market collector and alert monitor
After=arblens-web.service
Requires=arblens-web.service

[Service]
Type=simple
User=arblens
Group=arblens
ExecStart=/usr/local/bin/arblens-monitor-loop
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

SERVER_NAME=${PUBLIC_DOMAIN:-_}
cat > /etc/nginx/sites-available/arblens <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $SERVER_NAME;
    client_max_body_size 2m;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/arblens /etc/nginx/sites-enabled/arblens
nginx -t

systemctl daemon-reload
systemctl enable --now arblens-web arblens-monitor arblens-watchdog nginx
systemctl restart arblens-web arblens-monitor arblens-watchdog nginx

for _ in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
  if [[ -n "$PREVIOUS_RELEASE" && -d "$PREVIOUS_RELEASE" && "$PREVIOUS_RELEASE" == "$APP_ROOT/releases/"* ]]; then
    echo "新版本未通过健康检查，正在自动回滚到上一版本……" >&2
    ln -sfn "$PREVIOUS_RELEASE" "$APP_ROOT/current"
    systemctl restart arblens-web arblens-monitor
  fi
  echo "服务未能通过健康检查；已执行自动回滚。诊断命令：journalctl -u arblens-web -n 100 --no-pager" >&2
  exit 1
fi

# Keep only the two newest immutable releases. Persistent data is elsewhere.
mapfile -t OLD_RELEASES < <(find "$APP_ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | tail -n +3 | cut -d' ' -f2-)
for old in "${OLD_RELEASES[@]:-}"; do
  [[ "$old" == "$APP_ROOT/releases/"* && "$old" != "$RELEASE" ]] && rm -rf -- "$old"
done

PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
if [[ -n "$PUBLIC_DOMAIN" ]]; then
  URL="http://$PUBLIC_DOMAIN/live"
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email --redirect -d "$PUBLIC_DOMAIN" >/dev/null 2>&1; then
    URL="https://$PUBLIC_DOMAIN/live"
  else
    echo "提示：域名 HTTPS 证书暂未签发，请确认 DNS 已指向 $PUBLIC_IP 后再次运行安装命令。"
  fi
else
  URL="http://$PUBLIC_IP/live"
fi
echo ""
echo "ArbLens 已安装并开始 3 秒持续采集。"
echo "访问地址：$URL"
echo "状态检查：systemctl status arblens-web arblens-monitor arblens-watchdog"
echo "再次运行同一条安装命令即可无损升级，历史数据保存在 $DATA_ROOT。"
