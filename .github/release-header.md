### 安装

1. 下载下面的 `commander.apk`
2. 手机上点开安装（需要允许「安装未知来源应用」）
3. 打开 App，填 **板子 IP** 和 **token**：
   - IP：手机直连板子的 AP 时是 `10.42.0.1`；同一个局域网时填板子的局域网地址
   - token：在板子上执行 `cat ~/commander-token.txt`（免 sudo）；取不到就 `sudo cat /etc/radxa-commander/token`
4. token 不对时 App 会把该执行的命令直接写在错误提示里，照抄即可

### ⚠️ 从 v0.2.0 或更早版本升级：必须先卸载一次

以前每次 CI 都用临时密钥现场签名，所以 v0.1.0 / v0.2.0 / v0.2.1 三个包的签名各不相同，
Android 会拒绝覆盖安装（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

**从 v0.2.1 起签名已固定**，以后可以正常覆盖升级，不会再有这一步。
卸载会清掉 App 里存的 token，重装后重新粘贴一次即可（板子上的 token 不变）。

本版签名指纹（从这次发布的 apk 现场提取，以后每个版本都应是这一串）：

```
SHA-256 @SIGNER_SHA256@
```

---
