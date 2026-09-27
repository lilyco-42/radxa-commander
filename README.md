# radxa-commander — A7A 路由器手机管家

对标小米路由器 App：手机改 WiFi 密码/SSID、看在线设备、一键拉黑、切分流节点、重启、一键体检。

## 架构（企业级做法）

App **不直连 SSH**，只调板端控制 API。板子与手机之间是版本化 JSON 契约（见 `docs/api.md`），两边可独立发版。

```
手机 App (android/) ──HTTPS?/HTTP+Bearer token──▶ 板端 API (board/commander-api.py)
   状态 / WiFi / 设备 / 分流 / 工具                  └── nmcli / iptables / mihomo :9091
                                                          ▲
                        net-ensure.sh ──(timer 每 60s + NM 事件)──┘
                        网络层规则的唯一事实源：自己探测接口/网段、自己算、幂等
```

## 功能

| 页 | 能力 |
|---|---|
| 状态 | 在线时长/负载/内存/温度/WAN IP/热点/当前节点 |
| WiFi | 读 SSID/密码/信道，改完应用（手机需重连） |
| 设备 | 在线列表（主机名/IP/MAC/状态），一键拉黑/解禁 |
| 分流 | 当前节点 + 点选切换（即时生效） |
| 工具 | 一键体检（含「热点开机自启 / 私网直连 / 网段冲突 / WAN·热点网段 / 待处理清单」）、重启路由器 |

> v0.3.0 起体检是**直接跑 `net-ensure.sh --check`** 拿结果，不再在 API 里另写一套
> `iptables -C`。以前两处各写一套，换了上游之后规则明明是对的、体检却报一排红。

## 板端部署（A7A 上执行一次）

```bash
# 把 board/ 传上板子后
sudo bash board/install.sh
# 结尾会把「管理页地址 + token」整块打出来，照着填就行
```

API 监听 `0.0.0.0:18080`，token 在 `/etc/radxa-commander/token`（0600 root）。

## token 忘了 / 进不去后台

这是最常见的卡点：token 只在装的时候打印过一次，之后锁在 `0600 root` 里，
普通用户 `ls` 都进不去 `/etc/radxa-commander/`（0700 root）。所以 **install.sh 会顺手给安装者留一份副本**，
权限模型和 `~/.ssh` 私钥一样（0600，属于你自己）：

```bash
cat ~/commander-token.txt              # 免 sudo，随时取回
sudo commander-token                   # 或者这条（顺带打印管理页地址）
```

老版本装过、home 里没有副本的，跑一次 `sudo bash ~/commander-board/install.sh` 就会补上
（token 不会被重置，install.sh 是幂等的）。

App 和网页版在 token 不对时都会**明确说「token 不对」并把上面两条命令摆出来**，
不会再只丢一个 `unauthorized` 让你猜。

> 设计取舍：连接校验分两步 —— 先打免鉴权的 `/api/hello` 判断「板子在不在」，
> 再打必须鉴权的 `/api/status` 判断「token 对不对」。
> 只用 `/api/hello` 判断会**谎报成功**（token 是错的也显示已连接），这是 v0.2.1 修掉的 bug。

## App 构建（无 Android Studio）

沿用 radxa-monitor 验证过的链：aapt2 + javac + d8 + zipalign + apksigner，无第三方依赖。

```powershell
# Windows 本机构建（dev 签名，仅自用）
.\android\build-apk.ps1
```

CI（`.github/workflows/android.yml`）每次 push 出 APK artifact；打 tag `v*` 自动发 Release。
版本号跟 tag 走（`v0.2.1` → `versionName=0.2.1` / `versionCode=201`）。

### ⚠️ 签名密钥必须固定（否则新版装不上旧版）

Release 签名用仓库 Secrets：`KEYSTORE_B64` / `KEY_ALIAS` / `KEYSTORE_PASS` / `KEY_PASS`（**已配置**）。

**为什么强调这个**：Secrets 没配时，`build-apk.sh` 会 `keytool` 现场生成一把临时 dev key。
结果是**每次 CI 出包的签名都不一样**，Android 直接拒绝安装：
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` —— 用户只能先卸载（连 IP/token 一起丢）。

实测三把不同的钥匙（`apksigner verify --print-certs` 逐个下载比对）：

| 包 | 签名 SHA-256 | 说明 |
|---|---|---|
| v0.1.0 Release | `04:99:44:AB:9A:4F:2B:9F:…` | CI 临时生成，私钥已随 runner 销毁 |
| v0.2.0 Release | `6E:85:33:F7:DA:10:5E:98:…` | 同上，**找不回来了** |
| **v0.2.1 起（固定）** | `60:D5:7C:8D:5C:68:57:3F:FA:F7:20:84:DB:DD:DB:2F:7D:08:E4:CA:19:96:98:C3:3D:6A:C2:0F:3A:63:C7:32` | 与本地 `android/build/dev.keystore` 同源 |

所以现在 `build-apk.sh` 在**发版构建**（tag）时如果没有 `KEYSTORE_B64` 会**直接失败**，
不再产出「装不上去的 Release」。构建日志里会打印签名指纹，一眼可核对。

> **坑（已修）**：Secrets 配好了也可能不生效 —— `build-apk.sh` 读的是**环境变量**，
> workflow 里必须显式写 `KEYSTORE_B64: ${{ secrets.KEYSTORE_B64 }}` 把它映射进 `env`。
> 只配 Secrets 不映射 = 等于没配，tag 构建会挂在 `REQUIRE_RELEASE_KEY` 上。
> 同理，`main` 分支构建也需要这段映射，否则它会退回「现场生成临时 key」，
> 于是每个 main 构建的签名又各不相同。

> **一次性代价**：如果你手机上装的旧版是用已丢失的临时密钥签的（v0.1.0 / v0.2.0），
> 这次（以及以后）的包第一次安装需要**先卸载旧版**。卸载一次之后，
> 以后所有版本都能正常覆盖安装。
> 如果旧版恰好是本地 `commander-dev.apk`（同一个 `dev.keystore`），则可以无缝升级。

## 使用

1. 手机连 `Radxa-AP`（或同一局域网）
2. App 首屏就是连接区：**板子 IP** 一行、**token** 一行（都带标签），
   填完点「连接」→ 状态栏显示「已连接 · token 正常」才算进去了
3. token 在板子上取：`cat ~/commander-token.txt`（免 sudo）
4. （可选）点「发现」自动找板子

> 早先 token 和 IP、两个按钮挤在同一行，token 只有一个 hint 当标签、颜色又没设，
> 深色底上几乎看不见 —— 用起来就像「这个 App 没有填 token 的地方」。v0.2.1 改成分行 + 显式标签。

## 免安装管理网页

板端 API 同端口直接 serve 管理页，无需装 App，手机浏览器打开即用：

- AP 下：http://10.42.0.1:18080/
- 家庭局域网：http://192.168.10.165:18080/

页面里填 token（浏览器记住），功能与 App 对齐：状态/体检、WiFi、设备拉黑、分流切换、AP 开关、重启。

## 接任意路由器 + 断电重启后自愈（v0.3.0）

板子作为「随身代理路由器」，上游换成**任意**路由器、或者直接拔电重启，
都不需要人工干预。由 `board/net-ensure.sh` 统一负责，它自己探测、自己算、幂等。

### 探测什么（全部不写死）

| 项 | 怎么来 |
|---|---|
| WAN 接口 | 默认路由的 `dev`（不是写死 `end0`） |
| WAN 网段 | 该接口的实际 IPv4/前缀 |
| AP 接口 | 活动连接里 `ipv4.method=shared` 的那个设备（不是写死 `wlan0`） |
| AP 网段 | 该接口的实际 IPv4/前缀 |

### 自愈靠两条互补的机制（不是二选一）

- **systemd timer**：开机 15s 后跑一次，之后每 60s 一次。不依赖任何事件 ——
  这才是「重启后依旧有效」的兜底。
- **NetworkManager dispatcher**（`95-commander-net`）：接口一变立刻叫一次，快。

> 以前只有 dispatcher 这一条，而 `radxa-ap` 是 `autoconnect=no`：
> 重启后热点不会自己起来 → `wlan0` 没有 up 事件 → 钩子永不触发 → 规则全丢。
> **所以「重启后失效」的根因不是规则不持久，是触发规则的那件事根本不发生。**
> 现在 `install.sh` 把热点设成开机自启（`net.conf` 里 `BOOT_UP=1` 控制）。

### 私有网段直连（否则上游局域网全打不开）

mihomo 默认只有 `GEOIP,CN,DIRECT` + `MATCH`。私有地址既不在 CN 库里、
也不匹配任何规则 → 落进 `MATCH` 被送去代理。实测：

| 访问上游路由器 `http://192.168.10.1/` | 结果 |
|---|---|
| 直连 | 200 / 2.5ms |
| 走代理（修复前） | **502 / 5.0s** |

也就是说，手机连上热点后，**上游路由器的管理页、NAS、打印机一律打不开**，
换任何一个路由器都一样。`net-ensure.sh` 会给 `/etc/mihomo/config.yaml` 插 8 条
RFC1918 / IPv6 私有网段直连规则（与接哪个路由器无关），并 reload 生效。

### 网段撞车自动避让

若上游路由器也占着热点网段（例如上游就是 `10.42.0.0/24`），板子的 `wlan0`
会和上游网关**抢同一个 IP，网络直接崩**。此时自动把热点换到
`AP_SUBNET_CANDIDATES` 里第一个不冲突的网段。

这套网段数学有 15 项自检，不需要 root、不碰网络，随时可验：

```bash
sudo net-ensure.sh --check      # 体检（JSON）
sudo net-ensure.sh --selftest   # 网段数学自检
sudo net-ensure.sh              # 手动应用一次（幂等）
```

> `--check` **必须 root**：`iptables`/`sysctl` 都在 `/usr/sbin`，普通用户 PATH 里没有，
> 硬跑会把每条规则都报成缺失。脚本会识别并直接告诉你「需要 sudo」，不给你假阳性。

### 可调项

`/etc/radxa-commander/net.conf`（install.sh 会生成，带注释）：

- `BOOT_UP=1` —— 热点开机自启。设 0 回到「热点默认关，用时手动开」，
  但那样重启后就得手动开一次。
- `AP_SUBNET_CANDIDATES` —— 撞车时备选的热点网段。

## AP 省电策略

默认行为：AP 常开（定时器默认关闭——手动开关随时可用）。
v0.3.0 起 AP 还会**开机自启**（`net.conf` 的 `BOOT_UP=1`），所以拔电重启后代理直接可用。

如需夜间自动休眠，在板上改 `/etc/radxa-commander/ap-power.conf`
（`QUIET_ON=1` + 时间段），`systemctl enable --now ap-power.timer` 即生效；
无人自动关把 `IDLE_OFF=1`。注意 AP 关后手机无法自行唤醒，
需经家庭局域网用 App/网页重新打开，或等早晨定时结束自动恢复。

> 重启后如果发现热点没开，先用 `sudo net-ensure.sh --check` 看一眼 ——
> 体检会区分「夜间省电时段关的」「无人休眠关的」「你手动关的」，
> 而不是笼统报一句「热点未开启」让你以为自愈又坏了。

## 路线图

- v0.2：AP 省电（夜间定时休眠 + App 一键开关 + 无人自动休眠开关，默认只开夜间）✅ 已落地
- v0.3：接任意路由器 + 重启自愈 ✅ 已落地；访客 WiFi、定时重启、限速、接入提醒
- v0.4：PPPoE 账号管理、端口转发、配置备份/恢复
