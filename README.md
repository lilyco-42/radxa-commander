# radxa-commander — A7A 路由器手机管家

对标小米路由器 App：手机改 WiFi 密码/SSID、看在线设备、一键拉黑、切分流节点、重启、一键体检。

## 架构（企业级做法）

App **不直连 SSH**，只调板端控制 API。板子与手机之间是版本化 JSON 契约（见 `docs/api.md`），两边可独立发版。

```
手机 App (android/) ──HTTPS?/HTTP+Bearer token──▶ 板端 API (board/commander-api.py)
   状态 / WiFi / 设备 / 分流 / 工具                  └── nmcli / iptables / mihomo :9091
```

## 功能（v0.1.0）

| 页 | 能力 |
|---|---|
| 状态 | 在线时长/负载/内存/温度/WAN IP/热点/当前节点 |
| WiFi | 读 SSID/密码/信道，改完应用（手机需重连） |
| 设备 | 在线列表（主机名/IP/MAC/状态），一键拉黑/解禁 |
| 分流 | 当前节点 + 点选切换（即时生效） |
| 工具 | 一键体检（8 项）、重启路由器 |

## 板端部署（A7A 上执行一次）

```bash
# 把 board/ 传上板子后
sudo bash board/install.sh
# 输出 token，填进 App 的 token 栏
```

API 监听 `0.0.0.0:18080`，token 在 `/etc/radxa-commander/token`（0600）。

## App 构建（无 Android Studio）

沿用 radxa-monitor 验证过的链：aapt2 + javac + d8 + zipalign + apksigner，无第三方依赖。

```powershell
# Windows 本机构建（dev 签名，仅自用）
.\android\build-apk.ps1
```

CI（`.github/workflows/android.yml`）每次 push 出 APK artifact；打 tag `v*` 自动发 Release。
Release 签名用仓库 Secrets：`KEYSTORE_B64` / `KEY_ALIAS` / `KEYSTORE_PASS` / `KEY_PASS`。

## 使用

1. 手机连 `Radxa-AP`（或同一局域网）
2. 打开 App → IP 填 `10.42.0.1`（AP 下）或板子 LAN IP → 填 token → 连接
3. （可选）点“发现”自动找板子

## 路线图

- v0.2：AP 省电（夜间定时休眠 + App 一键开关 + 无人自动休眠开关，默认只开夜间）✅ 已落地
- v0.3：访客 WiFi、定时重启、限速、接入提醒
- v0.4：PPPoE 账号管理、端口转发、配置备份/恢复
