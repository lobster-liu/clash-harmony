# 手机端订阅体检（Subscription probe）

> 目标：脱离 PC，在手机上把订阅里真正连得通的节点挑出来，生成一份新的本地配置。

## 1. 为什么要做

免费订阅动辄几百到上千个节点，其中大多数已经失效。原来只能：

1. 导入订阅 → 连接；
2. 在代理页一个个点「测速」；
3. 手动记下哪个能用。

节点一多就没法做。PC 侧原本有个 `subtools/subcheck.mjs` 借手机内核批量测，但要求手机常连 PC。本功能把这件事搬进 App 内。

## 2. 设计（最终形态）

入口：**诊断 → 订阅体检**（`ProbeCard`）。

流程：

1. 读当前配置文本，用 `SubscriptionProbeService.splitProxyEntries()` 切出节点条目（兼容缩进/顶格两种写法，跳过 `wireguard` 等内核不支持的出站）；
2. `MihomoControllerService.getProxies()` 取内核里真实加载的叶子节点（排除 `DIRECT/REJECT/GLOBAL/COMPATIBLE/PASS/PASS-RULE/REJECT-DROP` 与所有组）；
3. 两者取交集——**只测已经在内核里跑着的节点**；
4. 并发（默认 8）对每个节点做 `GET /proxies/<name>/delay?timeout=4000&url=<目标>`；默认目标 `https://www.gstatic.com/generate_204`，任一目标通过即算可用；
5. 用存活节点生成 `<files>/profiles/probe_<ts>.yaml`（只含 `proxies:`），登记成「<原配置名>-可用」并设为当前；
6. 提示「点『断开』再『连接』生效（当前隧道未受影响）」。

## 3. 为什么不用热重载（重要）

最初实现走的是 mihomo 热重载：生成探针配置 → `PUT /configs {"path": ...}` → 测速 → 恢复原配置 → 再热切换到筛选后的配置。`PUT /configs` 返回 204，`/proxies` 也确实立刻换成了新节点表，看起来完美。

真机上发现：

- 热切换后首页立刻变成「未连接 ×3」，`已连接 ·  · 当前节点可达 790 ms`（版本号为空）；
- `curl /group/🌐 Default/delay` 从 `{"delay":214}` 变成 `{"message":"get delay: all proxies timeout"}`；
- `ifconfig vpn-tun` 显示接口还在（`198.18.0.1/30`、UP、RX/TX 有计数），`/proc/net/route` 也还有 `vpn-tun 000012C6`；
- 只有重新走一遍 `VpnService.start()`（点「连接」）才恢复。

结论：**`PUT /configs` 会让内核按新配置重建 tun，把扩展通过 fd 交给它的那条隧道丢掉**，数据面实际已断，但网卡与路由表残留，从界面/系统层面看不出来。延迟测试本身不受影响（它走 socket hook，不经 tun），所以「测速阶段可以热载入」这个假设是成立的——但**切换生效配置不行**。

> 顺带一个排查技巧：`/configs` 里 `tun.enable=true`、`file-descriptor` 有值，不代表数据面可用；用 `/group/<组>/delay` 判断更可靠。

## 4. 实现落点

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/ets/services/SubscriptionProbeService.ets` | `splitProxyEntries()`、`runningLeafNames()`、`intersectWithRunning()`、`scan()`、`apply()` |
| `entry/src/main/ets/services/MihomoControllerService.ets` | `testDelay()`（既有）、`testGroupDelay()`、`reloadConfig()`（保留但体检不再使用） |
| `entry/src/main/ets/services/ProfileStore.ets` | `addLocal()`：登记本地配置并设为当前 |
| `entry/src/main/ets/pages/Index.ets` | `ProbeCard`、`runSubscriptionProbe()` |

## 5. 真机验证（HUAWEI Pura X Max 典藏版，`HOP-AL10`，API 26，`deviceType=phone`）

- 32 节点配置：`可用 12/32`，生成「profile_share-可用」；期间首页保持「已连接 · 规则模式」，下载/上传速度正常。
- 8 节点配置：`可用 8/8`，生成「profile_share-可用」，名字不再叠成「-可用-可用」。
- 体检结束后点「断开」→「连接」，内核叶子节点数变成筛选后的数量（实测 8），说明新配置生效。

## 6. 已知限制

- 只能测**当前正在运行**的节点。刚导入、还没连接的订阅，先点「连接」让这批节点进内核，再体检。
- 体检期间节点延迟会被如实计入，但已被 doh/域名劫持影响的节点无法识别。
- 生成的配置只含 `proxies:`，分组与规则由内置模板在连接时生成（见 `docs/routing-rules.md`）。
- `wireguard`/`wg`/`tailscale` 出站会被丢弃：随包内核没有编译 gVisor，存在这类节点会让整份配置加载失败。
