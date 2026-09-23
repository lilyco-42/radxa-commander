#!/usr/bin/env bash
# radxa-commander board install. Run ONCE on the A7A as root (or via sudo).
# Idempotent: safe to re-run. Prints the API token at the end (enter it in the App).
set -euo pipefail
cd "$(dirname "$0")"

install -m 0755 commander-api.py /usr/local/bin/commander-api.py
mkdir -p /usr/local/share/radxa-commander
if [[ -f web/index.html ]]; then
  install -m 0644 web/index.html /usr/local/share/radxa-commander/index.html
elif [[ -f index.html ]]; then
  install -m 0644 index.html /usr/local/share/radxa-commander/index.html
fi
install -m 0644 -o root -g root commander-api.service /etc/systemd/system/commander-api.service
install -m 0755 ap-power-watch.py /usr/local/bin/ap-power-watch.py
install -m 0644 -o root -g root ap-power.service /etc/systemd/system/ap-power.service
install -m 0644 -o root -g root ap-power.timer /etc/systemd/system/ap-power.timer
mkdir -p /etc/radxa-commander
chmod 700 /etc/radxa-commander
if [[ ! -s /etc/radxa-commander/ap-power.conf ]]; then
  cat > /etc/radxa-commander/ap-power.conf <<'CONF'
# AP 省电策略：夜间定时休眠默认开，无人自动关默认关（见注释）
QUIET_ON=1
QUIET_START=01:00
QUIET_END=06:30
# IDLE_OFF=1 启用无人自动关（全部 station 静默超 IDLE_MINUTES 则关 AP，
# 早上 quiet 结束自动恢复；注意 AP 关后手机无法自行唤醒，需 App/定时开）
IDLE_OFF=0
IDLE_MINUTES=60
CONF
fi
if [[ ! -s /etc/radxa-commander/token ]]; then
  python3 -c "import secrets; print(secrets.token_hex(16))" > /etc/radxa-commander/token
  chmod 600 /etc/radxa-commander/token
fi
command -v iw >/dev/null 2>&1 || apt-get install -y iw || true
systemctl daemon-reload
systemctl enable commander-api.service
systemctl restart commander-api.service
systemctl enable --now ap-power.timer
sleep 1
systemctl is-active commander-api.service
systemctl is-active ap-power.timer || systemctl list-timers ap-power.timer --no-pager | head -4
echo "--- commander token (save into the App) ---"
cat /etc/radxa-commander/token
echo "--- api ---"
curl -s -m 5 http://127.0.0.1:18080/api/hello; echo
