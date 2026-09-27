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

本项目历史上就踩过：本地 dev 包、v0.2.0 Release 包、后来的 CI 包**是三把不同的钥匙**，
而且那两把临时私钥随 runner 一起销毁、**永久找不回来了**。

所以现在 `build-apk.sh` 在**发版构建**（tag）时如果没有 `KEYSTORE_B64` 会**直接失败**，
不再产出「装不上去的 Release」。

> **一次性代价**：如果你手机上装的旧版是用已丢失的临时密钥签的，
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

## AP 省电策略

默认行为：AP 常开（定时器默认关闭——手动开关随时可用）。

如需夜间自动休眠，在板上改 `/etc/radxa-commander/ap-power.conf`
（`QUIET_ON=1` + 时间段），`systemctl enable --now ap-power.timer` 即生效；
无人自动关把 `IDLE_OFF=1`。注意 AP 关后手机无法自行唤醒，
需经家庭局域网用 App/网页重新打开，或等早晨定时结束自动恢复。

## 路线图

- v0.2：AP 省电（夜间定时休眠 + App 一键开关 + 无人自动休眠开关，默认只开夜间）✅ 已落地
- v0.3：访客 WiFi、定时重启、限速、接入提醒
- v0.4：PPPoE 账号管理、端口转发、配置备份/恢复
