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

# --- 网络自愈（接任意路由器 + 重启后依旧有效）-------------------------------
# net-ensure.sh 是网络层规则的唯一事实源：自己探测 WAN/AP 接口与网段、
# 自己算规则、幂等。systemd timer 每 60s 兜一道，NM dispatcher 在接口变化时
# 立刻叫一次。两者互补 —— 以前只有 dispatcher，重启后 AP 不起来就彻底失效。
install -m 0755 net-ensure.sh /usr/local/bin/net-ensure.sh
install -m 0644 -o root -g root radxa-net-ensure.service /etc/systemd/system/radxa-net-ensure.service
install -m 0644 -o root -g root radxa-net-ensure.timer /etc/systemd/system/radxa-net-ensure.timer
install -m 0755 -o root -g root 95-commander-net /etc/NetworkManager/dispatcher.d/95-commander-net
# 老钩子把 end0/wlan0/10.42.0.0/24 写死在里面，已被 95-commander-net 取代
if [[ -e /etc/NetworkManager/dispatcher.d/95-ghboost-split ]]; then
  mv /etc/NetworkManager/dispatcher.d/95-ghboost-split \
     /etc/NetworkManager/dispatcher.d/95-ghboost-split.disabled-by-commander
  echo "已停用旧钩子 95-ghboost-split（写死网段，已被 net-ensure 取代）"
fi
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
if [[ ! -s /etc/radxa-commander/net.conf ]]; then
  cat > /etc/radxa-commander/net.conf <<'CONF'
# 网络自愈策略（net-ensure.sh 读这个文件，改了下一轮生效）
#
# BOOT_UP=1 —— 热点开机自启。这是「关机后重启依旧有效」的关键：
#   以前 radxa-ap 是 autoconnect=no，重启后热点不会自己起来，
#   于是 wlan0 没有 up 事件、规则永不重放，代理直接不通，必须人工再点一次 App。
#   设 0 可以回到「热点默认关，用时手动开」，但那样重启后就得手动开。
BOOT_UP=1

# 热点连接名 / 端口。一般不用改。
# AP_CON=radxa-ap
# DNS_PORT=1053
# REDIR_PORT=7892

# 上游网段与热点网段撞车时，热点自动改到下面第一个不冲突的网段。
# 撞车的后果是板子的 wlan0 和上游网关抢同一个 IP，网络直接崩。
# AP_SUBNET_CANDIDATES="192.168.42.0/24 172.30.42.0/24 10.99.42.0/24 192.168.73.0/24"
CONF
fi
if [[ ! -s /etc/radxa-commander/token ]]; then
  python3 -c "import secrets; print(secrets.token_hex(16))" > /etc/radxa-commander/token
  chmod 600 /etc/radxa-commander/token
fi
# 给执行 sudo 的那个人留一份 0600 的副本 —— 权限模型跟 ~/.ssh 私钥一样，
# 以后 `cat ~/commander-token.txt` 就能拿回来，不用再 sudo，也不会「装完就找不到了」。
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  _uhome="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [[ -n "$_uhome" && -d "$_uhome" ]]; then
    install -m 0600 -o "$SUDO_USER" -g "$SUDO_USER" \
      /etc/radxa-commander/token "$_uhome/commander-token.txt"
  fi
fi
install -m 0755 commander-token.sh /usr/local/bin/commander-token
command -v iw >/dev/null 2>&1 || apt-get install -y iw || true

# 热点永远不该抢默认路由：万一它装了一条 default，所有流量会绕回 wlan0 死循环。
nmcli connection modify radxa-ap ipv4.never-default yes 2>/dev/null || true

systemctl daemon-reload
systemctl enable commander-api.service
systemctl restart commander-api.service
systemctl enable --now ap-power.timer
systemctl enable --now radxa-net-ensure.timer
# 立刻跑一次，不用等 timer 的第一拍
/usr/local/bin/net-ensure.sh || true
sleep 1
systemctl is-active commander-api.service
systemctl is-active ap-power.timer || systemctl list-timers ap-power.timer --no-pager | head -4
systemctl is-active radxa-net-ensure.timer || systemctl list-timers radxa-net-ensure.timer --no-pager | head -4
TOKEN="$(cat /etc/radxa-commander/token)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

========== radxa-commander 装好了 ==========
管理页 : http://${IP:-<板子IP>}:18080/    (手机浏览器直接打开)
token  : ${TOKEN}

把这个 token 填进 App 的 token 栏（或网页版的 token 栏）。
忘了以后随时取回：
  cat ~/commander-token.txt        # 免 sudo
  sudo commander-token             # 或这条
===========================================
EOF
echo "--- 网络体检 ---"
/usr/local/bin/net-ensure.sh --check | python3 -m json.tool 2>/dev/null || \
  /usr/local/bin/net-ensure.sh --check
echo "--- api ---"
curl -s -m 5 http://127.0.0.1:18080/api/hello; echo
