#!/usr/bin/env bash
# radxa-commander —— 网络自愈 / 通用化（「接任意路由器 + 重启后依旧有效」）
#
# 让板子的代理满足两件事：
#   A. 接任意路由器都成立 —— 不再写死 WAN 接口名 / AP 接口名 / 网段；
#      上游网段与 AP 网段撞车时自动避让。
#   B. 断电重启后依旧有效 —— 不再只依赖「wlan0 的 NetworkManager up 事件」，
#      由 systemd timer 定期自愈（开机后 + 每 60s）。
#
# 为什么必须改（三条都是实测出来的，不是猜的）：
#   1. 旧 dispatcher /etc/NetworkManager/dispatcher.d/95-ghboost-split 里
#      end0 / wlan0 / 10.42.0.0/24 全是写死的 → 换接口名、换网段就失效。
#   2. radxa-ap 是 autoconnect=no。重启后 AP 不会自己起来 → wlan0 没有 up 事件
#      → dispatcher 永不触发 → NAT / 劫持规则全部丢失 → 代理直接不通。
#      （所以「重启后失效」不是规则不持久，是「触发规则的那件事」不发生。）
#   3. mihomo 规则只有 GEOIP,CN + MATCH。私有地址（上游路由器 / NAS / 打印机）
#      既不是 CN 也不匹配任何规则 → 落进 MATCH 被送去代理。
#      实测 http://192.168.10.1/ ：直连 200 / 2.5ms，走代理 502 / 5.0s。
#
# 用法：
#   net-ensure.sh            应用（幂等，可反复跑）
#   net-ensure.sh --check    只输出 JSON 体检，不改任何东西
#   net-ensure.sh --quiet    静默应用（给 timer 用，只往 stderr/journal 写）
#
# 安装：/usr/local/bin/net-ensure.sh   root:root 0755

set -uo pipefail

# ---- 可调项（可被 /etc/radxa-commander/net.conf 覆盖） ----------------------
AP_CON="${AP_CON:-radxa-ap}"
DNS_PORT="${DNS_PORT:-1053}"
REDIR_PORT="${REDIR_PORT:-7892}"
MIHOMO_CTRL="${MIHOMO_CTRL:-http://127.0.0.1:9091}"
MIHOMO_CONF="${MIHOMO_CONF:-/etc/mihomo/config.yaml}"
TAG="commander"                      # 我们加的规则一律带这个 comment，方便识别与清理
STATE="/run/radxa-commander-net.state"
# AP 网段候选（按顺序取第一个不与上游冲突的）。只在检测到冲突时才会用。
AP_SUBNET_CANDIDATES="192.168.42.0/24 172.30.42.0/24 10.99.42.0/24 192.168.73.0/24"
# shellcheck source=/dev/null
[ -r /etc/radxa-commander/net.conf ] && . /etc/radxa-commander/net.conf

MODE="apply"
case "${1:-}" in
  --check)    MODE="check" ;;
  --quiet)    MODE="quiet" ;;
  --selftest) MODE="selftest" ;;
  "")         MODE="apply" ;;
  *) echo "用法: $0 [--check|--quiet|--selftest]" >&2; exit 2 ;;
esac

# 网段数学的自检。不依赖 root、不碰网络，所以放在 root 守卫前面。
# 为什么要有它：网段冲突判定错了会「该避让时不避让」——后果是板子和上游网关
# 抢同一个 IP、网络直接崩，而这种错在正常运行中完全看不出来（只有真撞上才暴露）。
selftest() {
  local fail=0
  t() {  # t <说明> <期望> <实际>
    if [ "$2" = "$3" ]; then
      echo "  ok    $1"
    else
      echo "  FAIL  $1   期望[$2] 实际[$3]"
      fail=$((fail + 1))
    fi
  }
  ov() { overlap "$1" "$2" && echo yes || echo no; }
  t "net_of 192.168.10.165/24"      "192.168.10.0/24" "$(net_of 192.168.10.165/24)"
  t "net_of 10.42.0.1/24"           "10.42.0.0/24"    "$(net_of 10.42.0.1/24)"
  t "net_of 172.30.42.7/16"         "172.30.0.0/16"   "$(net_of 172.30.42.7/16)"
  t "net_of 192.168.10.165/32"      "192.168.10.165/32" "$(net_of 192.168.10.165/32)"
  t "不冲突 10.42.0.0/24 vs 192.168.10.0/24"  no  "$(ov 10.42.0.0/24 192.168.10.0/24)"
  t "冲突   10.42.0.0/24 vs 10.42.0.0/24"     yes "$(ov 10.42.0.0/24 10.42.0.0/24)"
  t "冲突   10.42.0.0/24 vs 10.0.0.0/8"       yes "$(ov 10.42.0.0/24 10.0.0.0/8)"
  t "冲突   192.168.42.0/24 vs 192.168.0.0/16" yes "$(ov 192.168.42.0/24 192.168.0.0/16)"
  t "不冲突 172.30.42.0/24 vs 192.168.0.0/16"  no  "$(ov 172.30.42.0/24 192.168.0.0/16)"
  t "不冲突 10.42.0.0/24 vs 172.30.0.0/16"     no  "$(ov 10.42.0.0/24 172.30.0.0/16)"
  t "冲突   10.42.0.0/24 vs 0.0.0.0/0"        yes "$(ov 10.42.0.0/24 0.0.0.0/0)"
  t "避让 上游192.168.10.0/24" "192.168.42.0/24" "$(pick_free_subnet 192.168.10.0/24)"
  t "避让 上游192.168.0.0/16"  "172.30.42.0/24"  "$(pick_free_subnet 192.168.0.0/16)"
  t "避让 上游10.0.0.0/8"      "192.168.42.0/24" "$(pick_free_subnet 10.0.0.0/8)"
  t "避让 上游172.16.0.0/12"   "192.168.42.0/24" "$(pick_free_subnet 172.16.0.0/12)"
  if [ "$fail" -eq 0 ]; then
    echo "selftest: 全部通过"
    return 0
  fi
  echo "selftest: $fail 项失败"
  return 1
}

if [ "$MODE" = "selftest" ]; then
  : # 真正的调用在文件末尾 —— 那时 overlap / pick_free_subnet 才定义完
fi

# 必须 root。iptables / sysctl 都在 /usr/sbin，普通用户 PATH 里没有，
# 硬跑的结果是「每条规则都报缺失」—— 这种假阳性比不报还坏：用户会去修一个
# 根本不存在的问题。（2026-09-27 实测踩到：重启后忘了加 sudo，满屏红。）
# --selftest 是纯算术自检，不需要 root，所以放行。
if [ "$(id -u)" != "0" ] && [ "$MODE" != "selftest" ]; then
  if [ "$MODE" = "check" ]; then
    cat <<'JSON'
{"ok": false, "need_root": true,
 "problems": ["需要 root 才能体检：请用  sudo net-ensure.sh --check  （非 root 下 iptables/sysctl 不在 PATH，会误报所有规则缺失）"],
 "ap_active": null, "ip_forward": null, "nat_masquerade": null,
 "redirect_tcp": null, "dns_hijack_udp": null, "mihomo_active": null,
 "dnsmasq_running": null, "lan_direct": null, "conflict": null}
JSON
    exit 0
  fi
  echo "需要 root：sudo $0" >&2
  exit 1
fi

log() { [ "$MODE" = "quiet" ] || echo "$@"; }
warn() { echo "$@" >&2; }

# ---- 小工具 ---------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

ipt() { iptables -t "$1" "$2" "${@:3}" 2>/dev/null; }

# "192.168.10.165/24" -> "192.168.10.165" / "24"
cidr_addr() { echo "${1%%/*}"; }
cidr_len()  { echo "${1##*/}"; }

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

mask_of() {  # 24 -> 4294967040
  local l="$1"
  [ "$l" -eq 0 ] && { echo 0; return; }
  echo $(( (0xFFFFFFFF << (32 - l)) & 0xFFFFFFFF ))
}

cidr_start() { echo $(( $(ip2int "$(cidr_addr "$1")") & $(mask_of "$(cidr_len "$1")") )); }
cidr_end()   { local s m; s=$(cidr_start "$1"); m=$(mask_of "$(cidr_len "$1")"); echo $(( s | (~m & 0xFFFFFFFF) )); }

overlap() {  # 两个 CIDR 是否有交集
  local a1 a2 b1 b2
  a1=$(cidr_start "$1"); a2=$(cidr_end "$1")
  b1=$(cidr_start "$2"); b2=$(cidr_end "$2")
  [ "$a1" -le "$b2" ] && [ "$b1" -le "$a2" ]
}

net_of() {  # "192.168.10.165/24" -> "192.168.10.0/24"
  local s; s=$(cidr_start "$1")
  echo "$(( (s >> 24) & 255 )).$(( (s >> 16) & 255 )).$(( (s >> 8) & 255 )).$(( s & 255 ))/$(cidr_len "$1")"
}

# ---- 探测：不写死任何接口名 ------------------------------------------------
wan_iface() {
  local d
  d=$(ip -4 route show default 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -1)
  if [ -n "$d" ]; then echo "$d"; return; fi
  # 没有默认路由时退一步：找一个 up 的非无线、非 lo 接口（网线插着但还没拿到租约）
  ip -4 -o link show up 2>/dev/null | awk -F': ' '{print $2}' \
    | grep -vE '^(lo|wlan|wlx|wlp|docker|veth)' | head -1
}

wan_gw() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -1
}

iface_cidr() {  # 接口上的全局 IPv4/前缀（可能为空）
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'
}

ap_iface() {
  local name dev m
  # 1) 活动的连接里，ipv4.method=shared 的那个设备（最准）
  while IFS=: read -r name dev _; do
    [ -n "${name:-}" ] || continue
    m=$(nmcli -t -g ipv4.method connection show "$name" 2>/dev/null)
    if [ "$m" = "shared" ] && [ -n "${dev:-}" ]; then echo "$dev"; return; fi
  done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null)
  # 2) 退回 profile 里绑的接口
  dev=$(nmcli -t -g connection.interface-name connection show "$AP_CON" 2>/dev/null)
  [ -n "$dev" ] && { echo "$dev"; return; }
  dev=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
        | awk -F: -v n="$AP_CON" '$1==n{print $2; exit}')
  [ -n "$dev" ] && { echo "$dev"; return; }
  # 3) 最后兜底
  [ -d /sys/class/net/wlan0 ] && echo wlan0
}

ap_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$AP_CON"
}

ap_ssid() {
  nmcli -t -g 802-11-wireless.ssid connection show "$AP_CON" 2>/dev/null
}

ap_autoconnect() {
  nmcli -t -g connection.autoconnect connection show "$AP_CON" 2>/dev/null
}

mihomo_active() { [ "$(systemctl is-active mihomo 2>/dev/null)" = "active" ]; }

# ---- 规则集（唯一事实源） ---------------------------------------------------
# 每条： "<table>|<chain>|<insert-pos 或空>|<iptables 参数...>"
build_rules() {
  local wan="$1" ap="$2" apnet="$3"
  RULES=()
  # NAT：AP 网段出 WAN 做 MASQUERADE。
  # 为什么必须有：只有 TCP 被劫持进 mihomo；UDP(除 53) / ICMP 是真正被转发出去的，
  # 没有这条它们出不去。
  [ -n "$wan" ] && RULES+=("nat|POSTROUTING||-m comment --comment ${TAG}-nat -s $apnet -o $wan -j MASQUERADE")
  # DNS 劫持：必须排在通用 TCP 劫持【前面】，否则 53 端口会被先 REDIRECT 到 7892。
  RULES+=("nat|PREROUTING|1|-m comment --comment ${TAG}-dns -i $ap -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT")
  RULES+=("nat|PREROUTING|1|-m comment --comment ${TAG}-dns -i $ap -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT")
  # 通用 TCP 劫持：AP 客户端发往「非本机」的 TCP 全进 mihomo 的 redir-port。
  # --dst-type LOCAL 排掉「访问板子自己」的流量（管理页 10.42.0.1:18080 要能直连）。
  RULES+=("nat|PREROUTING||-m comment --comment ${TAG}-redir -i $ap -p tcp -m addrtype ! --dst-type LOCAL -j REDIRECT --to-ports $REDIR_PORT")
  # 转发放行（默认策略是 ACCEPT 时属于冗余保险；被改成 DROP 时它就是救命的那条）
  [ -n "$wan" ] && RULES+=("filter|FORWARD||-m comment --comment ${TAG}-fwd -i $ap -o $wan -j ACCEPT")
  [ -n "$wan" ] && RULES+=("filter|FORWARD||-m comment --comment ${TAG}-fwd -i $wan -o $ap -m state --state RELATED,ESTABLISHED -j ACCEPT")
}

del_our_rules() {
  local table chain line spec
  for table in nat filter; do
    for chain in PREROUTING POSTROUTING FORWARD INPUT OUTPUT; do
      # 用 iptables -S 的输出去删：它给出的是归一化后的形式，直接换 -A 为 -D 即可，
      # 不会因为「我写的 -p tcp --dport 53」和「它记的 -p tcp -m tcp --dport 53」不一致而删不掉。
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        spec="${line#-A }"
        # shellcheck disable=SC2086
        iptables -t "$table" -D $spec 2>/dev/null
      done < <(iptables -t "$table" -S "$chain" 2>/dev/null | grep -- "--comment ${TAG}-")
    done
  done
}

# 一次性迁移：老 dispatcher（95-ghboost-split）加的规则【没有 comment 标记】，
# 所以 del_our_rules 认不出它们。不删掉的话会和我们的新规则并存成重复项。
# 这些 spec 就是老脚本里写死的那 4 条，逐字照抄。
del_legacy_rules() {
  iptables -t nat -D POSTROUTING -s 10.42.0.0/24 -o end0 -j MASQUERADE 2>/dev/null
  iptables -t nat -D PREROUTING -i wlan0 -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
  iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null
  iptables -t nat -D PREROUTING -i wlan0 -p tcp -m addrtype ! --dst-type LOCAL \
    -j REDIRECT --to-ports 7892 2>/dev/null
  return 0
}

add_if_missing() {
  local table="$1" chain="$2" pos="$3"; shift 3
  iptables -t "$table" -C "$chain" "$@" 2>/dev/null && return 0
  if [ -n "$pos" ]; then
    iptables -t "$table" -I "$chain" "$pos" "$@" 2>/dev/null && return 0
  else
    iptables -t "$table" -A "$chain" "$@" 2>/dev/null && return 0
  fi
  return 1
}

# ---- mihomo：私有网段直连 --------------------------------------------------
# 为什么不能只靠 GEOIP,CN：私有地址（10/8 172.16/12 192.168/16）不在 CN 库里，
# 会落进 MATCH 被送去代理 → 上游路由器 / NAS / 打印机全打不开。
# 这几条是 RFC1918 通用值，与「接的是哪个路由器」无关，所以可以静态写死。
LAN_DIRECT_LINES='  # commander-lan-direct: 私有网段一律直连（与具体路由器无关）
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve'

mihomo_has_lan_direct() {
  grep -q 'commander-lan-direct' "$MIHOMO_CONF" 2>/dev/null
}

ensure_mihomo_lan_direct() {
  [ -f "$MIHOMO_CONF" ] || return 0
  mihomo_has_lan_direct && return 0
  cp -a "$MIHOMO_CONF" "$MIHOMO_CONF.bak-lan-direct-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  if ! LAN_LINES="$LAN_DIRECT_LINES" python3 - "$MIHOMO_CONF" <<'PY'
import os, re, sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
m = re.search(r'^rules:[ \t]*$', src, re.M)
if not m:
    sys.exit("config.yaml 里找不到顶层 rules: 行，拒绝改（免得改坏）")
block = "rules:\n" + os.environ["LAN_LINES"] + "\n"
open(p, "w", encoding="utf-8").write(src[:m.start()] + block + src[m.end():].lstrip("\n"))
PY
  then
    warn "!! 给 mihomo 配置插私有网段直连失败，跳过（不影响其它）"
    return 1
  fi
  reload_mihomo
}

reload_mihomo() {
  mihomo_active || return 0
  # mihomo 的 PUT /configs 必须带 ?force=true，否则被静默忽略
  if curl -s -m 10 -X PUT "$MIHOMO_CTRL/configs?force=true" \
       -H 'Content-Type: application/json' \
       -d "{\"path\":\"$MIHOMO_CONF\"}" >/dev/null 2>&1; then
    log "mihomo: 已重载配置"
  else
    warn "!! mihomo 重载失败，尝试重启服务"
    systemctl restart mihomo 2>/dev/null || true
  fi
}

mihomo_lan_direct_live() {
  mihomo_active || return 1
  curl -s -m 5 "$MIHOMO_CTRL/rules" 2>/dev/null | grep -q '"type":"IPCIDR"'
}

# ---- AP 网段与上游撞车时的自动避让 -----------------------------------------
pick_free_subnet() {
  local wan="$1" cand
  for cand in $AP_SUBNET_CANDIDATES; do
    overlap "$cand" "$wan" && continue
    echo "$cand"; return 0
  done
  echo ""; return 1
}

fix_ap_conflict() {
  local wan="$1" apnet="$2" new
  new=$(pick_free_subnet "$wan") || { warn "!! AP 网段 $apnet 与上游 $wan 冲突，且没有可用的候选网段"; return 1; }
  local ip="${new%.*}.1"
  warn "!! AP 网段 $apnet 与上游 $wan 冲突（会抢同一个网关 IP，网络直接崩）"
  warn "   自动把 AP 改到 $new（网关 $ip）"
  nmcli connection modify "$AP_CON" ipv4.addresses "${ip}/24" || return 1
  if ap_active; then
    warn "   重开热点以生效（客户端会掉线重连）"
    nmcli connection down "$AP_CON" >/dev/null 2>&1
    sleep 1
    nmcli connection up "$AP_CON" >/dev/null 2>&1
  fi
  return 0
}

# ---- 汇总 ------------------------------------------------------------------
gather() {
  WAN_IF=$(wan_iface)
  WAN_CIDR=""; [ -n "$WAN_IF" ] && WAN_CIDR=$(iface_cidr "$WAN_IF")
  WAN_GW=$(wan_gw)
  AP_IF=$(ap_iface)
  AP_CIDR=""; [ -n "$AP_IF" ] && AP_CIDR=$(iface_cidr "$AP_IF")
  AP_NET=""; [ -n "$AP_CIDR" ] && AP_NET=$(net_of "$AP_CIDR")
  # AP 还没起来时用默认值，这样规则也能先就位
  [ -n "$AP_NET" ] || AP_NET="10.42.0.0/24"
  AP_ON=$(ap_active && echo true || echo false)
  AP_AC=$(ap_autoconnect)
  [ "$AP_AC" = "yes" ] && AP_AC_B=true || AP_AC_B=false
  AP_SID=$(ap_ssid)
  # 热点当前不开时，是「省电策略关的」还是「用户手动关的」？
  # 必须能区分 —— 否则用户重启后发现热点没了，会以为自愈又坏了。
  AP_REASON=$(cat /run/radxa-ap-auto 2>/dev/null | tr -d '\r\n')
  CONFLICT=false
  if [ -n "$WAN_CIDR" ] && [ -n "$AP_NET" ] && overlap "$AP_NET" "$(net_of "$WAN_CIDR")"; then
    CONFLICT=true
  fi
  IPF=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  MM_ON=$(mihomo_active && echo true || echo false)
  DQ_ON=$([ "$(ps -o comm= -C dnsmasq 2>/dev/null | head -1)" = "dnsmasq" ] && echo true || echo false)
  # tx_delay 是 A7A 千兆网口的 RGMII 修正值，绑在具体网卡上，
  # 所以跟着实际 WAN 接口走（以前写死 end0）
  TXD=""
  local txnode="/sys/class/net/${WAN_IF:-end0}/device/tx_delay"
  [ -r "$txnode" ] && TXD=$(tail -1 "$txnode" 2>/dev/null | tr -dc '0-9')
}

apply() {
  gather
  log "WAN: ${WAN_IF:-<无>} ${WAN_CIDR:-<无地址>} gw=${WAN_GW:-<无>}"
  log "AP : ${AP_IF:-<无>} ${AP_CIDR:-<未启动>} net=$AP_NET ssid=${AP_SID:-?}"

  if [ "$CONFLICT" = true ]; then
    fix_ap_conflict "$(net_of "$WAN_CIDR")" "$AP_NET" && gather
  fi

  sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || warn "!! 打开 ip_forward 失败"

  # A7A 千兆网口 RGMII tx_delay 必须是 9（官方 DT 给的是 12，实测 1200 字节帧丢 42%，
  # 症状像坏网线）。原来只有 90-a7a-txdelay 这个 NM 钩子在写，属同一类「只靠事件」
  # 的脆弱点 —— 这里也兜一道，顺手自愈。
  local txnode="/sys/class/net/${WAN_IF:-end0}/device/tx_delay"
  if [ -w "$txnode" ]; then
    local cur; cur=$(tail -1 "$txnode" 2>/dev/null | tr -dc '0-9')
    if [ "$cur" != "9" ]; then
      echo 9 > "$txnode" 2>/dev/null && log "tx_delay: $cur -> 9"
    fi
  fi

  build_rules "$WAN_IF" "$AP_IF" "$AP_NET"
  local new_state="wan=$WAN_IF ap=$AP_IF apnet=$AP_NET dns=$DNS_PORT redir=$REDIR_PORT"
  local old_state=""; [ -r "$STATE" ] && old_state=$(cat "$STATE")
  if [ "$new_state" != "$old_state" ]; then
    log "参数变了 → 重建规则"
    [ -n "$old_state" ] && log "  旧: $old_state"
    log "  新: $new_state"
    del_our_rules
  fi
  # 老 dispatcher 留下的无标记规则，清掉以免和新规则重复（幂等，没有就静默跳过）
  del_legacy_rules

  local r added=0 failed=0
  for r in "${RULES[@]}"; do
    local table chain pos rest
    table="${r%%|*}"; rest="${r#*|}"
    chain="${rest%%|*}"; rest="${rest#*|}"
    pos="${rest%%|*}"; rest="${rest#*|}"
    # shellcheck disable=SC2086
    if add_if_missing "$table" "$chain" "$pos" $rest; then
      iptables -t "$table" -C "$chain" $rest 2>/dev/null && added=$((added+1))
    else
      warn "!! 规则失败: -t $table $chain $rest"
      failed=$((failed+1))
    fi
  done
  printf '%s\n' "$new_state" > "$STATE" 2>/dev/null
  log "规则: ${#RULES[@]} 条，就位 $added 条，失败 $failed 条"

  # AP 开机自启（只改 profile，不强制现在拉起来 —— 否则会跟省电策略打架）
  if [ "$AP_AC" != "yes" ] && [ "${BOOT_UP:-1}" = "1" ]; then
    if nmcli connection modify "$AP_CON" connection.autoconnect yes 2>/dev/null; then
      log "AP: 已设为开机自启（autoconnect=yes）"
    else
      warn "!! 设置 AP 开机自启失败"
    fi
  fi

  ensure_mihomo_lan_direct && log "mihomo: 私有网段直连已就位"

  [ "$failed" -eq 0 ] || exit 1
  exit 0
}

check() {
  gather
  local ok=true problems=()
  local nat=false redir=false dns=false fwd=false

  iptables -t nat -C POSTROUTING -m comment --comment "${TAG}-nat" \
    -s "$AP_NET" -o "${WAN_IF:-end0}" -j MASQUERADE 2>/dev/null && nat=true
  iptables -t nat -C PREROUTING -m comment --comment "${TAG}-redir" \
    -i "${AP_IF:-wlan0}" -p tcp -m addrtype ! --dst-type LOCAL \
    -j REDIRECT --to-ports "$REDIR_PORT" 2>/dev/null && redir=true
  iptables -t nat -C PREROUTING -m comment --comment "${TAG}-dns" \
    -i "${AP_IF:-wlan0}" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null && dns=true
  iptables -t filter -C FORWARD -m comment --comment "${TAG}-fwd" \
    -i "${AP_IF:-wlan0}" -o "${WAN_IF:-end0}" -j ACCEPT 2>/dev/null && fwd=true

  LAN_LIVE=false
  mihomo_lan_direct_live && LAN_LIVE=true

  [ -n "$WAN_IF" ]      || { ok=false; problems+=("没有默认路由：上游没插网线或没拿到 DHCP"); }
  if [ "$AP_ON" != true ]; then
    case "$AP_REASON" in
      quiet) problems+=("热点未开：夜间省电时段（ap-power.conf 的 QUIET_START/QUIET_END，到点自动恢复）") ;;
      idle)  problems+=("热点未开：无人使用自动休眠（有人在就恢复）") ;;
      manual) problems+=("热点未开：手动关闭的（App/网页版开回来即可）") ;;
      *)     problems+=("热点未开（省电策略或手动关闭）") ;;
    esac
  fi
  [ "$AP_AC_B" = true ] || { ok=false; problems+=("AP 不是开机自启：重启后代理会失效（把 BOOT_UP 设回 1 并重跑 net-ensure.sh）"); }
  [ "$CONFLICT" = false ] || { ok=false; problems+=("AP 网段 $AP_NET 与上游 $(net_of "$WAN_CIDR") 冲突"); }
  [ "$IPF" = "1" ]      || { ok=false; problems+=("IP 转发没打开"); }
  [ "$nat" = true ]     || { ok=false; problems+=("NAT 出口规则缺失"); }
  [ "$redir" = true ]   || { ok=false; problems+=("TCP 透明劫持规则缺失"); }
  [ "$dns" = true ]     || { ok=false; problems+=("DNS 劫持规则缺失"); }
  [ "$MM_ON" = true ]   || { ok=false; problems+=("mihomo 没在跑"); }
  [ "$LAN_LIVE" = true ] || { ok=false; problems+=("mihomo 缺私有网段直连规则：上游路由器/NAS 会打不开"); }

  local okjson="true"; [ "$ok" = true ] || okjson="false"
  python3 - "$okjson" "$TXD" "$LAN_LIVE" "$CONFLICT" "$nat" "$redir" "$dns" "$fwd" \
           "$WAN_IF" "$WAN_CIDR" "$WAN_GW" "$AP_IF" "$AP_CIDR" "$AP_NET" "$AP_ON" \
           "$AP_AC_B" "$AP_SID" "$AP_REASON" "$IPF" "$MM_ON" "$DQ_ON" "${problems[@]-}" <<'PY'
import json, sys
(a_ok, txd, lan, conflict, nat, redir, dns, fwd, wan_if, wan_cidr, wan_gw,
 ap_if, ap_cidr, ap_net, ap_on, ap_ac, ap_ssid, ap_reason, ipf, mm, dq, *rest) = sys.argv[1:]
b = lambda s: s == "true"
print(json.dumps({
    # ---- 老字段：App / 网页版已经在读，不能改 ----
    "ap_active": b(ap_on),
    "ip_forward": ipf == "1",
    "tx_delay": {"value": txd, "ok": txd == "9"},
    "nat_masquerade": b(nat),
    "redirect_tcp": b(redir),
    "dns_hijack_udp": b(dns),
    "mihomo_active": b(mm),
    "dnsmasq_running": b(dq),
    # ---- 新增：通用性 / 自愈 相关 ----
    "wan": {"iface": wan_if, "cidr": wan_cidr, "gw": wan_gw},
    "ap": {"iface": ap_if, "cidr": ap_cidr, "net": ap_net, "ssid": ap_ssid,
           "active": b(ap_on), "autoconnect": b(ap_ac), "power_reason": ap_reason},
    "forward_accept": b(fwd),
    "conflict": b(conflict),
    "lan_direct": b(lan),
    "ok": b(a_ok),
    "problems": [p for p in rest if p],
}, ensure_ascii=False))
PY
}

case "$MODE" in
  check)    check ;;
  selftest) selftest ;;
  *)        apply ;;
esac
