# 订阅导入失败排查与修复（2300007 / 残留 VPN 隧道）

本文记录「导入订阅后一直显示 `0 个节点 · 未下载`，日志只有一句『订阅下载失败，请检查网络、URL 或证书配置』」这个问题的真实原因、证据与本仓库的修复。

记录环境：HUAWEI Pura X Max 典藏版（`HOP-AL10`，OpenHarmony 7.0.0.111 / API 26），本仓库以 `org.xbstudio.clashnext` 为 bundleName 侧载安装（见文末「本机构建与安装」）。

## 1. 症状

- 配置页填入订阅 URL 并点「保存」后，配置行显示 `远程订阅 · … · 未知` / `0 个节点 · 未下载`。
- 诊断页日志只有 `warn 订阅下载失败，请检查网络、URL 或证书配置`。
- 手机自身网络正常：浏览器能上网、`ping 223.5.5.5` 通、DNS 也能解析。
- 关键判据：**本地订阅服务器收不到任何请求**——请求在离开应用之前就被吞掉了。

## 2. 根因：应用自己残留的 VPN 隧道

`@ohos.net.http` 的请求走系统网络栈，而本应用的 VPN 隧道（`vpn-tun`）一旦残留，会把**本应用自己**出站的流量也送进隧道；隧道里没有可用的 mihomo 核心/节点时，连接会被立即重置，于是表现为「DNS 正常、TCP 立刻被拒」。

设备侧证据（应用已 `force-stop`，主进程与 VPN 扩展进程都不在，但隧道仍在）：

```
$ cat /proc/net/route
vpn-tun   000012C6  00000000  0001  ...  00FFFFFF
$ ifconfig vpn-tun
inet addr:10.0.0.254  Mask:255.255.255.0  UP POINTOPOINT RUNNING MTU:1500
TX packets:0  ...  dropped:18513
$ netstat -tn          # 源地址同时存在 wlan0 与 vpn-tun 两类连接
```

网络栈 hilog（进程号 pid 过滤）：

```
[http_exec.cpp:284] errCode:2300007, osErr:111, tcpConnectErrno:115,
                    dnsDur:0.09~0.16, connectDur:0.000, tlsDur:0.000
[http_exec.cpp:741] CURLcode result 7        # CURLE_COULDNT_CONNECT
```

`osErr 111` 是 `ECONNREFUSED`、`connectDur 0.000` 说明连 TCP 握手都没开始；`CURLcode 7` 是 curl 的「连接失败」。这与「DNS 失败」（`CURLE_COULDNT_RESOLVE_HOST = 6`）不同，是排查分叉点。

代码侧为什么会被自己吞掉：

- `ClashVpnExtensionAbility` 在 `connection.create()` 后调 `protectProcessNet()`，只把 **VPN 扩展进程**从隧道里豁免，UI 主进程没有豁免；
- 应用被 `force-stop` 或异常退出时，`VpnService.stop()` 没跑到，隧道就会残留到下次开机（该 ROM 上 shell 无法 `ifconfig vpn-tun down`，无 root）。

结论：**「下载订阅」与「已连接的隧道」互相打架**，而残留隧道让这个矛盾在应用未连接时也会发作。

## 3. 修复

### 3.1 `VpnService`：不再信任固定 bundleName，也不再只靠 5s 超时判成败

- `currentBundleName()` 用 `bundleManager.getBundleInfoForSelfSync(...)` 取真实包名，取不到才回退常量 `io.github.clashharmony.app`。
  原先常量写死，换包名侧载后 `startVpnExtensionAbility` 的 Want 指向不存在的 bundle，必然启动失败。
- `start()` 把「启动扩展」的超时从 5000ms 放宽到 20000ms，并且**以隧道是否真的存在为准**（`waitForTunnel()` 轮询），避免系统建隧道慢时误报「VPN 启动失败」。
- 新增 `tunnelPresent()`：优先问系统网络能力（`connection.getDefaultNetSync()` → `getNetCapabilitiesSync()` → `bearerTypes` 含 `NetBearType.BEARER_VPN`），取不到再回退读 `/proc/net/route` 找 `vpn-tun`。
- 新增 `releaseTunnelForDownload()` / `clearOrphanTunnel()`：`stop()` 后轮询到默认网络不再是 VPN 才返回。

### 3.2 `SubscriptionService`：下载失败时临时让路，成功后重试一次

```ts
let releasedTunnel: boolean = false;
let payload: FetchResult = await SubscriptionService.fetchText(profile.source);
if (!payload.ok && VpnService.tunnelPresent()) {
  releasedTunnel = await VpnService.releaseTunnelForDownload();
  if (releasedTunnel) {
    payload = await SubscriptionService.fetchText(profile.source);
  }
}
```

- 只有**失败且确实存在隧道**才断开，成功路径（有可用核心时隧道是通的）不受影响；
- 失败文案追加「已临时断开本机 VPN 隧道后仍失败」，成功文案提示「下载时已临时断开 VPN，请重新点『连接』」；
- 顺手把网络错误透出为 `SubscriptionService` 的 `BusinessError.code · message`（例如 `订阅下载失败（2300007 · Failed to connect to the server）`），并在请求头带上 `User-Agent: clash-meta/1.19.0 clash-harmony/0.1.0`、放宽 `connectTimeout 15000 / readTimeout 20000`。

### 3.3 `Index`：启动时清残留隧道，隧道被断开后界面回落

- `loadProfiles()` 之后调 `cleanOrphanTunnelIfNeeded()`：本地运行态认为未连接、但系统里仍有 VPN 隧道时，自动 `clearOrphanTunnel()` 并写日志
  （`检测到残留 VPN 隧道，已自动清理` / 清理不掉时 `…请重启手机后再试`）。
- `applyProfileState()` 里补「隧道不在了但界面还显示已连接」的回落：停流量轮询、复位 `connectedAt / vpnTunnelActive / vpnActionText`。
- 配置页顶部补上 `statusMessage` 展示（原先只有「代理」页底部有，用户点了保存看不到任何反馈）。

## 4. 验证

1. 清空应用数据后重新导入 `http://<局域网地址>/sub.yaml`：日志出现
   `info 已保存订阅：…` → `info 订阅已更新，保存 N 个节点，运行配置已准备`。
2. 点「连接」→ 系统弹「是否允许使用 VPN？」→ 允许 → 首页显示 `已连接 · 规则模式`，此时 `vpn-tun`（198.18.0.0/16）存在。
3. 在**已连接**状态下导入 `https://www.baidu.com/` 仍成功——说明有可用核心时无需断开，只有失败才让路。
4. `aa force-stop` 后 `vpn-tun` 自动消失；再次启动无残留告警。

## 5. 本机构建与安装（侧载）

本机没有 AGC 正规签名，只能用调试证书侧载，因此把 bundleName 临时改成证书 p7b 里绑定的包名：

- `AppScope/app.json5`：`bundleName: "org.xbstudio.clashnext"`（原值 `io.github.clashharmony.app` 备份在 `.app.json5.orig`）。
- 签名材料：`sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar sign-app -mode localSign -keyAlias xiaobai -appCertFile xiaobai-debug.cer -profileFile org_xbstudio_clashnext.p7b -signAlg SHA256withECDSA -keystoreFile xiaobai.p12 -compatibleVersion 12 -signCode 1`。
  `-compatibleVersion 12` 必须与 `p7b` 一致，写大了会 `9568329 verify signature failed`。
- 构建：`hvigorw --mode module -p product=default -p buildMode=debug assembleHap --no-daemon`，`DEVECO_SDK_HOME` 指向 `<DevEco>\sdk`。

## 6. 本地文件导入：读文件失败 + 只认 Clash YAML

### 6.1 `fileIo.readText(uri)` 在手机上必然失败

`LocalFileImportService.pickAndImport()` 原来直接 `await fileIo.readText(uri)`。系统文件选择器返回的是 `file://docs/...` 形式的能力型 URI，`readText()` 只接受真实路径，于是抛异常，被外层 `catch` 统一吞成一句「本地文件导入失败，请确认文件可访问且为文本 YAML」——真实原因（错误码）完全看不到。

修复：

- 改为「打开 → 按 fd 读 → 解码」：`fileIo.openSync(uri, READ_ONLY)` + `fileIo.statSync(fd).size` + `readSync(fd, buffer)` + `util.TextDecoder.create('utf-8').decodeToString(...)`，最后 `closeSync`；
- 失败时把 `BusinessError.code · message` 带进提示（例如 `13900002 · No such file or directory`）；
- 文件类型筛选加上 `JSON|.json`。

### 6.2 只认 Clash YAML，遇到 sing-box JSON 直接放弃

原转换器只认 Clash/Mihomo YAML 和 `ss://` 链接。用户的配置是 **sing-box 导出的 JSON**（本次实测：`hysteria2×13` + `vless×19`，含 ws 传输），于是会得到「订阅内容不是 Clash/Mihomo YAML……」。

新增 `services/SingBoxConverterService.ets`：把 sing-box 的 `outbounds` 转成 Clash/Mihomo 的 `proxies`：

| sing-box | Clash/Mihomo |
|---|---|
| `vless` + `tls.reality` + `tls.utls` | `type: vless`、`reality-opts.public-key/short-id`、`client-fingerprint`、`servername` |
| `vless`/`vmess` + `transport.type: ws/grpc` | `network: ws/grpc` + `ws-opts.path/headers.Host` 或 `grpc-opts.grpc-service-name` |
| `vmess` | `type: vmess`、`uuid`、`cipher`、`alterId: 0` |
| `trojan` | `type: trojan`、`password`、`sni` |
| `shadowsocks` | `type: ss`、`cipher`、`password` |
| `hysteria2`（含 `obfs.type: salamander`） | `type: hysteria2`、`password`、`sni`、`obfs`/`obfs-password` |
| `server_ports: ["20000:30000"]`（端口跳跃） | 取区间起点作为 `port`（Clash 侧单端口） |

`dns`/`inbounds`/`urltest`/`direct`/`block` 等非节点 outbound 会被跳过，并在提示里报告 `已转换/支持总数`（本次 `32/32`）。

### 6.3 验证

- 导入 `profile_share.json` → 提示「已将文件转换为 Clash YAML（32/32 个节点…）」，配置行显示 `32 个节点 · 已下载`；
- 启用后首页「连接」→ 允许 VPN → `已连接 · 规则模式`，控制器状态 `已连接 · 1.10.0 · 🇺🇸美国洛杉矶1号 589 ms`；
- `ifconfig vpn-tun` 的 RX/TX 计数持续增长（90→225 / 95→230），说明流量确实经隧道转发；
- 代理页显示 `节点列表 · 32/32`，节点类型正确（`hysteria2 · UDP`、`vless` 等）。

## 7. 已知的观感问题（不影响功能）

- 配置页顶部计数（`${items.length} 个配置`）与列表标题（`配置列表 · ${items.length}`）偶尔差 1：两者读同一份状态，属 ArkUI 局部未刷新，切一次 tab 即对齐。

## 8. 导入订阅后「0 个节点」，换台电脑/客户端却正常

**症状**：配置页已经有别的配置（尤其是本地文件导入的那条）并且它是「当前」时，再「导入订阅」一个远程链接，配置行会出现，但一直是 `0 个节点 · 未下载`；诊断日志只有

```
info 已保存订阅：node.freeclashnode.com，正在下载...
warn 「profile_share」是本机配置文件，不能在线更新（只有订阅链接才能下载）
```

同一个 URL 在 PC 上（Clash Verge / mihomo）能正常解析出 14 个节点，所以既不是 URL 的问题，也不是解析器的问题。

**根因**：`ProfileStore.addRemote()` 保留原来的 `currentUid`：

```ts
currentUid: state.currentUid.length > 0 ? state.currentUid : profile.uid
```

而 `addRemoteProfile()` 下载时用的是 `SubscriptionService.updateProfile(context, next.currentUid)`——**当前配置**，不是刚加入的那条。当前是本地配置时，`updateProfile()` 在 `profile.type !== 'remote'` 处直接返回失败，于是新订阅一次都没下载过，停在 0 个节点。之前一直没暴露，是因为早期测试时配置列表是空的，`addRemote` 会把新订阅设为当前。

**修复**（`Index.ets`、`services/ClipboardImportService.ets`）：

1. 下载对象改成刚创建的那条：`SubscriptionService.updateProfile(context, profile.uid)`；
2. 下载**成功后**再 `ProfileStore.activate(context, profile.uid)` 切为当前配置（点「保存」的意图就是要用这份订阅），失败则保留原当前配置、只报错，条目留着可以点「更新」重试；
3. 「剪贴板」里粘贴订阅 URL 的路径同样处理（原来也是只加条目不下下载）；
4. 顺带把那句误导性文案改成 `「<名字>」是本机配置文件，不能在线更新（只有订阅链接才能下载）`，让人一眼看出打在哪个配置上。

**验证**：修复后在「当前配置 = 本地 32 节点」的状态下导入 `https://node.freeclashnode.com/uploads/2026/11/3-20261120.yaml` → 日志 `info 订阅已更新，保存 14 个节点，运行配置已准备`，配置行显示 `14 个节点 · 已下载` 并标为「当前」，`files/runtime/current.yaml` 里 `proxy-groups` 31 个分组（该订阅节点只落在 US/冷门，故没有 HK/TW/JP/SG 组）、`rules` 34 条。
