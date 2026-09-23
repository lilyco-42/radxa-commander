# radxa-commander board control API contract (v0.1.0)
# Base: http://<board>:18080   Auth: Authorization: Bearer <token>
# Token: /etc/radxa-commander/token (0600). Hello is public, everything else 401 without token.
#
# GET  /api/hello              {app, version}
# GET  /api/status             {board, uptime_s, load1, mem_mb{MemTotal,MemAvailable},
#                               temp_c|null, wan{iface,ip}, ap{ssid,channel},
#                               mihomo{active,group_now,group_all}, time}
# GET  /api/wifi               {ssid, password, channel}
# PUT  /api/wifi               {ssid?, password?(>=8), channel?(1..13)} -> wifi state
#                              NOTE: AP re-applies, clients drop and must reconnect.
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
# Errors: {"error": msg} with 400/401/404/500.
