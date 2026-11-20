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

## 9. 导入成功却连不上：顶格列表项、WireGuard 节点、默认出口

换用别人的机场订阅（`raw.githubusercontent.com/ermaozi/...` 那类由 subconverter 生成的 YAML）时，又踩到三个叠加的问题，症状都是「导入成功、有节点数，但页面提示核心未响应或节点全不可达」。

### 9.1 顶格的 `- ` 列表项把分组条目留成了孤儿

这类订阅的列表**不缩进**，`proxies:` / `proxy-groups:` / `rules:` 三个键下面的条目都顶格写：

```yaml
proxies:
- name: ...
proxy-groups:
- name: ermao.net | 🚀 节点选择
  type: select
rules:
- MATCH,Proxy
```

`RuntimeConfigService.removeManagedTopLevelKeys()` 判断「块结束」用的是 `isTopLevelConfigLine()`（顶格且含冒号）。顶格的 `- name: ...` 恰好满足条件，于是删到 `proxy-groups:` 这一行就停了，**它下面的组条目全被留下**，紧接着 proxies 段落，最后被 mihomo 当成代理条目：

```
applyConfig ParseWithPath error: proxy 377: unsupport proxy type: select
```

同一个原因也让 `ClashConfigParserService.parseProxyNodes()` 读不到节点（`- type: vless` 顶格被当成新的顶层键、`inProxies` 被关掉），于是 `RuleTemplateService.apply()` 返回 `ok:false`，运行配置里**没有 proxy-groups / rules**，只有一堆裸节点。

**修复**：

1. `RuntimeConfigService.isTopLevelConfigLine()` 里把顶格的 `- ` / `-` 视为「上一个块的列表续行」，不算新顶层键；`managedBlockKeys` 加上 `rule-providers`（订阅自带但本模板不用，留着会触发内核去拉远程规则集）。
2. `ClashConfigParserService.parseProxyNodes()` 把「列表项」判断提到「顶层键」判断之前（`inProxies && trimmed.startsWith('- ')`），顶格与缩进两种写法都能读。

### 9.2 WireGuard 节点让整份配置解析失败

同一个订阅里混了 `type: wireguard` 节点，随包内核没有编译 gVisor：

```
applyConfig ParseWithPath error: proxy 262: create WireGuard device: gVisor is not included in this build, rebuild with -tags with_gvisor
```

一个节点就能让**整份配置**失败（不是跳过该节点），用户看到的是「连接」直接报「核心未响应：无法连接 127.0.0.1:9090」。

**修复**：`RuleTemplateService.filterUnsupportedProxies()` 在生成运行配置时按条目剔除 `wireguard` / `wg` / `tailscale` 节点，并在成功文案里说明（`已跳过 N 个不受支持的节点（wireguard：随包内核未编译对应出站）`）。条目切分按「同级第一个条目的缩进」判定，避免把 `peers:` 下面的嵌套列表误当成新条目。

### 9.3 默认出口钉在地区组上，那个地区全挂就全挂

模板最初按笔记把 `🌐 Default` 写成「五区 → 冷门 → 自动 → 全部 → DIRECT」，首位是地区组。机场若某个地区的节点全部超时，`🌐 Default`（以及末尾挂 `🌐 Default` 的应用组）就整体不可用，表现是「隧道已建立但节点不可达」，而 `♻️ 自动选择` 明明是通的。

**修复**：`🌐 Default` 与 22 个应用组都把 `♻️ 自动选择`（url-test，会自己挑最快且能连通的节点）放到首位，地区组作为可选项排在后面。

### 9.4 顺带：订阅域名被墙时，先连 VPN 再导入

`raw.githubusercontent.com` 在这台手机的网络下直连不通（用系统浏览器打开同样「网站暂无响应」，所以不是 App 的问题）。此时：

- 请求参数加 `addressFamily: http.AddressFamily.ONLY_V4`——本工程的 TUN 只有 IPv4（`isIPv6Accepted: false`），手机在蜂窝网下却有原生 IPv6，域名带 AAAA 时请求会绕过隧道直出、被拦掉；
- 下载失败时按错误码给出可执行提示（`2300006` 解析失败 / `2300007` 连接被拒 / `2300999` 请求未完成 → 先连 VPN，或用「本地文件」导入）。

### 9.5 验证

- 用户报的 URL `https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/clash.yml`：修复前 `0 个节点 / 未下载`；修复后日志 `订阅已更新，保存 378 个节点，运行配置已准备`，`files/runtime/current.yaml` 里 `proxies` 377 条（剔掉 1 个 WireGuard）、`proxy-groups` 35 个（29 个 select + 6 个 url-test）、`rules` 34 条，无 `type: select` 混进 proxies、无 `rule-providers`。
- 连接后 `MihomoStart success`，`/proxies` 中 `🌐 Default -> ♻️ 自动选择`；在此状态下再导入同一条 GitHub 订阅仍然成功（说明流量确实走了隧道）。

## 10. 连上之后首页误报「节点不可达」（探测校准）

**症状**：隧道已经建立、上网正常，首页却显示

```
已连接 · 1.10.0 · ♻️ 自动选择 不可达 · 请在代理页重新测速并切换节点
```

或者把组名当节点名报出来：`已连接 · 1.10.0 · 🌐 Default 可达 217 ms（☁️ cloudflare 内的可用节点）`。

**根因一：测的对象不是节点。** `findRuntimeProxyGroup()` 拿到的是「实际承载流量」的那个组（应用组，如 `☁️ cloudflare`），而它的 `now` 往往指向**另一个组**：

```
☁️ cloudflare -> 🌐 Default -> ♻️ 自动选择 -> 🇯🇵 日本 | JPN 4
```

`/proxies/<组名>/delay` 对组也会返回结果，但前提是这个组的 url-test 已经跑过一轮；刚连上时跑 `/proxies/♻️ 自动选择/delay` 常常直接失败，于是判定「不可达」——而真实节点是好的。

**根因二：只测一次就下结论。** 原实现 `measureProxyNodeDelay()` 失败即返回 -1，`verifySelectedProxyAfterConnection()` 立刻写「不可达」。

**修复**（`pages/Index.ets`、`services/MihomoControllerService.ets`）：

1. `resolveEffectiveNodeName(start)`：沿 `proxyGroups[].now` 最多下钻 8 层，直到拿到真正的节点名；
2. `measureProxyNodeDelayWithRetry(name, 3)`：失败间隔 1.5 秒重试，给 url-test 一点时间；
3. `pickReachableNodeInGroup(groupName)`：仍失败则调内核 `/group/<name>/delay` 把组内全部成员测一遍，取最小正值；若最佳条目本身还是组，再 `resolveEffectiveNodeName` 下钻并重测一次叶子；
4. 文案统一成 `已连接 · <版本> · 当前节点可达 <N> ms（<节点名>）`，失败才提示「隧道已建立但当前节点不可达」。

**控制器证据**（`hdc fport tcp:19101 tcp:9090`）：

```
GET /proxies/♻️ 自动选择/delay?timeout=5000&url=https://www.gstatic.com/generate_204  -> 200 {"delay":221}   (1.8s)
GET /group/♻️ 自动选择/delay?timeout=5000&url=https://www.gstatic.com/generate_204     -> 200 (47 条全部 >0)
```

即接口本身没问题，问题在「调用时机」和「测错对象」。

**验证**：重建装机后点「连接」，首页显示 `已连接 · 1.10.0 · 5 连接 · 🇯🇵 日本 | JPN 4 70 ms`——报的是真实叶子节点与实测延迟，不再出现「组名 + 不可达」。

