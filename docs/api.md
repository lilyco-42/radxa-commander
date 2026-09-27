# radxa-commander board control API contract (v0.2.1)
# Base: http://<board>:18080   Auth: Authorization: Bearer <token>
# Token: /etc/radxa-commander/token (0600 root). install.sh 另存一份 0600 到安装者 home:
#        ~/commander-token.txt   ->  `cat ~/commander-token.txt` 即可取回，无需 sudo。
#
# GET  /api/hello              {app, version, token_required, token_ready}
#                              Public (no auth). token_ready=false 表示板子还没生成 token。
#                              NOTE: 客户端不要用 hello 判定「登录成功」——它免鉴权，
#                              token 错了也返回 200。登录必须再打一个需要鉴权的接口。
# GET  /api/status             {board, uptime_s, load1, mem_mb{MemTotal,MemAvailable},
#                               temp_c|null, wan{iface,ip}, ap{ssid,channel},
#                               mihomo{active,group_now,group_all}, time}
# GET  /api/wifi               {ssid, password, channel}
# PUT  /api/wifi               {ssid?, password?(>=8), channel?(1..13)} -> wifi state
#                              NOTE: AP re-applies, clients drop and must reconnect.
# GET  /api/ap                 {enabled, auto(null|quiet|idle|manual), ssid}
# PUT  /api/ap                 {enabled:true|false} -> ap state
#                              NOTE: manual action clears auto flag; timer never fights it.
# GET  /api/clients            [{mac, ip, hostname, state, blocked}]
# POST /api/clients/block      {mac} -> {mac, blocked:true}
# POST /api/clients/unblock    {mac} -> {mac, blocked:false}
# POST /api/reboot             {rebooting:true}
# GET  /api/split              {now, all}   (mihomo selector)
# PUT  /api/split              {name} -> {now, all}
# GET  /api/check              {ap_active, ip_forward, tx_delay{value,ok},
#                               nat_masquerade, redirect_tcp, dns_hijack_udp,
#                               mihomo_active, dnsmasq_running}
#
# Errors:
#   401 {"error":"token 不匹配", "hint":"取回 token：在板子上执行 cat ~/commander-token.txt ..."}
#   503 {"error":"板子还没生成 token", "hint":"在板子上执行 sudo bash ~/commander-board/install.sh"}
#   400/404/500 {"error": msg}
# 401 与 503 都带 hint，客户端应原样展示 —— 让用户知道 token 去哪拿，而不是对着 unauthorized 猜。
