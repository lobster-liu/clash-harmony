# Clash Harmony

Clash Harmony 是一个 HarmonyOS / ArkTS Stage 工程，用于在鸿蒙设备上运行 Clash/mihomo 风格的代理与 VPN 工作流。当前版本已经接入真实 `arm64-v8a` mihomo native 库，支持订阅导入、节点测速、策略切换、VPN 启停、controller 诊断和首页实时状态刷新。

## 本 fork 的改动（相对上游）

这个 fork（`lobster-liu/clash-harmony`）不是简单同步上游，而是在 Pura X Max（`HOP-AL10`，HarmonyOS 7.0.0.111 / API 26，`deviceType=phone`）上真机跑通订阅、分流、诊断整条链路时，把踩到的坑逐条修掉。下面按「现象 → 原因 → 改动」说清楚改了什么，代码细节见 [docs/subscription-import-troubleshooting.md](docs/subscription-import-troubleshooting.md) 与 [docs/routing-rules.md](docs/routing-rules.md)。

### 1. 订阅下载永远失败（2300007 / `Failed to connect to the server`）

**现象**：同一个订阅 URL，手机浏览器和 `adb shell` 都能打开，App 里点「保存」必定失败，诊断日志只有一句通用文案。

**原因**：VPN 扩展先建 TUN、后起 mihomo；用户中途退出或核心起不来时，扩展进程被系统杀掉，但 `vpn-tun` 网卡会残留在系统里（连 `force-stop` 都不会清掉，只能重启）。残留隧道会把 **App 自己进程**的 HTTP 请求也吸进去，而隧道后面没有可用的核心，于是 DNS 成功（`dnsDur ≈ 0.1s`）、TCP 连接瞬间被拒（`connectDur 0.000`、`osErr 111`）——这就是 NETSTACK 里那串 2300007 的真实含义。原来的代码还有两个硬伤把这些线索全盖住了：`VpnService` 把包名写死成 `io.github.clashharmony.app`（换包名侧载时 want 根本对不上），以及起 VPN 只等 5 秒就把「隧道没建好」当失败。

**改动**：`VpnService` 改为从 `bundleManager` 读取自身包名；启动超时放宽到 20 秒，并以「TUN 是否真的存在」为成功判据；新增 `tunnelPresent()`（先查默认网络的 `BEARER_VPN` 能力，回退读 `/proc/net/route`）、`releaseTunnelForDownload()` 和 `clearOrphanTunnel()`。`SubscriptionService` 在下载失败且检测到隧道时，自动断开隧道重试一次，并在文案里提示用户重新连接。`Index` 在加载配置时清理上次泄漏的隧道，隧道被临时断开后界面也会跟着回落到「未连接」。

### 2. 本地文件 / sing-box JSON 导入不了

**现象**：用系统文件选择器挑一个 `profile_share.json`，一定报「本地文件导入失败，请确认文件可访问且为文本 YAML」，而且看不出是读文件失败还是解析失败。

**原因**：两层。选择器返回的是 `file://docs/...` 这种能力型 URI，`fileIo.readText(uri)` 只认真实路径、直接抛异常，异常又被统一 catch 成一句文案；即便读到了，转换器也只认 Clash YAML 和 `ss://` 链接，遇到 sing-box 的 `outbounds` 就当解析失败。

**改动**：`LocalFileImportService` 改成 `openSync` + `readSync` + `TextDecoder` 的 fd 读法，把 `BusinessError.code · message` 透出到界面，并在失败时打印内容嗅探结果（长度、首字符、命中的键名、节点类型直方图，不含密码），文件过滤器加上 `JSON`。新增 `SingBoxConverterService`，把 sing-box 的 `vless` / `vmess` / `trojan` / `shadowsocks` / `hysteria2` 出站（含 `ws`、`grpc`、`reality`、`obfs` 参数）翻成 Clash 节点。实测一个 37 KB、32 个节点的 sing-box 配置可以全量导入并成功连上。

### 3. 分流规则对齐「OpenClash 自定义规则 A」

**现象**：导入后用的是订阅自带的分组和规则，国内站点走代理、规则没法按自己的偏好调；手机侧也没有 `geosite.dat` / `geoip.dat`，`GEOSITE` 规则根本无从谈起。

**改动**：每次生成运行配置时，`RuleTemplateService` 保留订阅里的 `proxies`，丢弃订阅自带的 `proxy-groups` / `rules` / `dns` / `hosts`，改按自定义规则 A 重建分组与规则——36 个分组（全部节点、自动选择、按节点名关键词归类的五区 url-test、冷门节点、手动选择、Default、漏网之鱼、非标端口 + 22 个应用组），34 条规则（adobe → 私网 → 国内直连 → 应用组 → gfw → 非标端口 → `MATCH`）。「非标端口」原来依赖远程 rule-provider `Custom_Port_Direct.yaml`，这里内联成三条等价的 `DST-PORT` 区间规则（除 80/443 之外全部走 `🔀 非标端口` 组），省掉运行期下载规则集这个新的失败点。`GeoDataService` 把随包的 `geosite.dat` / `geoip.dat` 落盘到 mihomo 的 home 目录（`files/runtime`），所以清数据、升级之后不必手工推文件，并开启 `geodata-mode`。顺带把「带 geo 数据后起核要 3 秒、界面只等 1.6 秒就把刚起来的核杀掉」的超时也调对了。

### 4. 界面高亮不跟随点击

**现象**：诊断页点「日志 / 规则 / DNS」，下面内容换了但高亮不动；代理页切换分组、配置页切换导入入口同样是「点了没反应」，后来还出现过两个按钮同时高亮。

**原因**：ArkUI 里 `@Builder` 的**按值传参数不会随状态变化重绘**。高亮状态是通过 `this.ModeButton('日志', this.diagSegment === '日志')` 这种形式传进去的，状态变了但 builder 拿到的是旧布尔值；配置页更糟——「导入订阅」写死高亮，另外两个入口用另一套判断，于是会同时亮。

**改动**：把状态读取移进 builder 内部（`this.diagSegment`、`this.selectedProxyGroup`、`importTabActive()`），静态占位 chip 单独抽成 `StaticChip`；配置页三个入口改成真正的互斥分段（展开导入面板时只亮「导入订阅」，点本地文件/剪贴板会先收面板）。顺手修了代理页那句永远写着「等待核心同步」的副标题，改成真实的「N 个节点 · M 个分组」。

### 5. 构建与侧载

上游 `build-profile.json5` 里的签名材料指向作者 Mac 上的路径，并且带了 hvigor 不接受的明文口令，别的机器直接构建失败。这里清空 `signingConfigs`，让 `assembleHap` 产出未签名 HAP，再用 `hap-sign-tool` + 本地调试证书签名后 `install -r` 侧载；本机流水线在 `scripts/sideload.local.ps1`（含设备序列号与口令，已在 `.gitignore` 里排除）。换包名侧载的原因写在文档里：调试 profile 绑定包名，上游那个包名在本机被另一个 App 占用了。

> 说明：以上改动都在真机上验证过，测试设备为 HUAWEI Pura X Max 典藏版（`HOP-AL10`，API 26，`deviceType=phone`）。

## 当前状态

更新时间：2026-07-09

- 真机包名：`io.github.clashharmony.app`
- 主入口：`EntryAbility`
- VPN 扩展：`ClashVpnExtensionAbility`
- 已接入真实 `arm64-v8a/libmihomo_ohos.so`
- 已打包 `arm64-v8a/libmihomo_exec.so` 作为 mihomo 执行 fallback
- `x86_64` 仍使用内置 fake/stub adapter，主要用于模拟器界面与构建验证
- 真机验证过 VPN 可建立，controller 端口、TUN 网卡和代理访问链路可用
- 首页状态刷新已修复：连接状态、运行时长、下载/上传速度、连接数、当前链路会直接绑定 live 状态刷新
- 当前未上架鸿蒙应用市场，仅通过 HAP 包研究、调试和验证
- 开源许可：`GPL-3.0-only`，详见 [LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## 功能清单

### 首页

- VPN 连接/断开圆形主按钮
- 左上角连接状态：`未连接` / `已连接`
- 右上角运行时长：秒级刷新，60 秒内显示 `Xs`
- 下载速度、上传速度、连接数实时展示
- 运行模式切换：规则 / 全局 / 直连
- 当前链路展示：配置名、模式、策略组、运行配置状态
- 最近状态：配置状态、运行配置、核心状态、实时流量

### 代理页

- 展示订阅解析出的全部节点
- 支持搜索节点
- 支持同步 controller 策略组
- 支持节点选择并写入 mihomo controller
- 支持全量测速，状态直接展示在每个节点后面
- 测速中有 UI 反馈和进度文本

### 配置页

- 支持远程订阅导入
- 支持剪贴板导入
- 支持本地 YAML / 文本文件导入
- 支持订阅更新、启用、删除
- 支持 Shadowsocks 通用订阅转换
- 支持 runtime YAML 生成
- 支持 hosts 预解析、DNS 配置注入、IPv6 关闭等运行配置修正

### 诊断页

- controller `/version`、`/configs`、`/proxies`、`/connections`、`/rules` 检查
- native adapter 状态展示
- TUN fd、native fd、controllerReady、adapterVersion、lastError 展示
- VPN TUN 转发统计展示
- runtime 配置、DNS、规则、连接列表查看

## 技术实现

### ArkTS 层

- `Index.ets`：当前主 UI 与运行状态编排
- `ProfileStore.ets`：配置持久化
- `SubscriptionService.ets`：订阅更新
- `ClashConfigParserService.ets`：Clash YAML 解析
- `GenericSubscriptionConverterService.ets`：通用订阅格式转换
- `RuntimeConfigService.ets`：生成 mihomo 运行配置
- `MihomoControllerService.ets`：mihomo REST controller 封装
- `TrafficPollerService.ets`：实时流量轮询
- `VpnService.ets`：VPN Extension 启停入口
- `TcpDelayTestService.ets`：节点 TCP 延迟测试

### Native 层

- `napi_init.cpp`：NAPI 入口
- `mihomo_adapter.cpp`：动态加载 `libmihomo_ohos.so`
- `tun_forwarder.cpp`：TUN 转发循环
- `socket_protector.cpp`：socket 防环路保护
- `health_monitor.cpp`：native 健康监控

真实 mihomo adapter 需要导出以下 C ABI：

```text
MihomoStart
MihomoStop
MihomoVersion
MihomoLastError
```

当前真实库位置：

```text
entry/src/main/cpp/prebuilt/arm64-v8a/libmihomo_ohos.so
entry/src/main/cpp/prebuilt/arm64-v8a/libmihomo_exec.so
```

## 项目结构

```text
AppScope/
entry/
  src/main/
    cpp/
      fake_mihomo/
      prebuilt/
        arm64-v8a/
          libmihomo_ohos.so
          libmihomo_exec.so
      health_monitor.cpp
      mihomo_adapter.cpp
      napi_init.cpp
      socket_protector.cpp
      tun_forwarder.cpp
    ets/
      components/
      entryability/
      models/
      pages/
      services/
      vpnextensionability/
    module.json5
docs/
tests/
```

## 构建

推荐使用 DevEco Studio 自带的 hvigor wrapper：

```bash
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p module=entry@default -p product=default
```

构建产物：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

## Release 包

仓库内提供当前签名调试包：

```text
release/clash-harmony-v0.1.0-20260708-2318-signed.hap
```

校验值：

```text
SHA256: 2c00b356d7e2a8fefe1295449951cc22a780343ffadcd8aa19daf1e9e5f92b88
```

说明：

- 当前版本不能上架鸿蒙应用市场，仅供个人研究、调试和技术验证使用。
- 该 HAP 需要通过电脑和 `hdc` 安装到真机。
- 首次启动 VPN 时，系统会弹出 VPN 权限确认，需要在手机上手动允许。
- 请仅导入你有权使用的订阅或本地配置。

## 如何获得有效订阅文件

Clash Harmony 本身不提供代理节点或订阅服务。用户需要自行准备合法、可用、且有权使用的 Clash/mihomo 兼容订阅。

常见获取方式：

- 从你购买或自建的网络代理服务后台获取。通常服务后台会提供“Clash 订阅”、“Clash Meta 订阅”、“mihomo 订阅”或“复制订阅链接”入口。
- 从企业、学校或实验环境的内部网络管理员处获取。此类配置通常用于内部网络访问、研发测试或合规的远程接入。
- 自建服务后生成配置。你可以在自己的服务器上部署有权限使用的代理服务，再生成 Clash/mihomo YAML 配置文件。
- 使用已有的本地 Clash/mihomo 配置文件。如果你已经在电脑端 Clash 客户端里有可用配置，可以导出或找到对应 YAML 文件后导入本 App。

订阅通常有两种形式：

```text
https://example.com/subscription/your-token
```

或本地 YAML 文件：

```yaml
proxies:
  - name: example-node
    type: ss
    server: example.com
    port: 8388
    cipher: aes-128-gcm
    password: your-password
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - example-node
rules:
  - MATCH,Proxy
```

判断订阅是否适合导入：

- 后台明确标注支持 `Clash`、`Clash Meta` 或 `mihomo`。
- 链接打开后返回的是 YAML 配置，或返回可被转换为 Clash 节点列表的订阅文本。
- 配置里至少包含 `proxies` 或可解析的节点信息。
- 节点在其他 Clash/mihomo 客户端中可以正常测速和连接。

安全注意事项：

- 不要使用公开泄露、来历不明或未经授权的订阅链接。
- 订阅 URL 通常包含 token，等同于账号凭证，不要提交到 GitHub、截图公开或分享给他人。
- 不要把个人订阅写进仓库、日志或 issue。
- 如果订阅节点大面积 `timeout`，先确认手机当前网络、运营商线路、订阅是否过期、节点是否在其他客户端可用。
- 请遵守所在地区法律法规、网络服务条款和组织安全规范。

## 安装到真机

### 准备手机

1. 在手机上打开开发者模式。通常路径是“设置 -> 关于手机”，连续点击版本号或系统版本号直到提示已进入开发者模式。
2. 打开 USB 调试 / HDC 调试。不同 HarmonyOS 版本入口可能略有差异，通常在“设置 -> 系统和更新 -> 开发人员选项”里。
3. 使用 USB 连接手机和电脑，并在手机弹窗中允许调试授权。
4. 电脑需安装 DevEco Studio 或 OpenHarmony/HarmonyOS SDK，确保能使用 `hdc`。

查看设备是否已连接：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC list targets
```

如果输出类似下面内容，说明设备已连接：

```text
63Q0226113009373
```

### 使用脚本安装

仓库提供安装脚本：

```bash
chmod +x release/install-to-device.sh
./release/install-to-device.sh
```

如果连接了多台设备，需要指定设备序列号：

```bash
./release/install-to-device.sh <device-serial>
```

如果你的 `hdc` 不在默认路径，可以显式指定：

```bash
HDC=/path/to/hdc ./release/install-to-device.sh <device-serial>
```

默认安装的 HAP 是：

```text
release/clash-harmony-v0.1.0-20260708-2318-signed.hap
```

也可以指定其他 HAP：

```bash
HAP=/path/to/your.hap ./release/install-to-device.sh <device-serial>
```

### 手动安装

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
SERIAL=<device-serial>
HAP=release/clash-harmony-v0.1.0-20260708-2318-signed.hap

$HDC -t "$SERIAL" shell "aa force-stop io.github.clashharmony.app" || true
$HDC -t "$SERIAL" install -r "$HAP"
$HDC -t "$SERIAL" shell "aa start -a EntryAbility -b io.github.clashharmony.app"
```

安装完成后，手机上会打开 Clash Harmony。进入配置页导入订阅或本地配置后，可在代理页测速并选择节点，再回到首页连接 VPN。

## 验证

基础脚本：

```bash
node tests/app-flow.test.mjs
node --check tests/app-flow.test.mjs
node --check tests/verify-hap-contents.mjs
node --check tests/verify-device-mihomo.mjs
```

HAP 内容校验：

```bash
node tests/verify-hap-contents.mjs entry/build/default/outputs/default/entry-default-signed.hap
```

真实 mihomo ABI 校验：

```bash
node tests/verify-mihomo-prebuilt-abi.mjs --require-abi arm64-v8a
node tests/verify-mihomo-prebuilt-packaging.mjs --require-abi arm64-v8a
```

真机 mihomo 验收：

```bash
node tests/verify-device-mihomo.mjs --observe-ms 45000 --evidence-dir artifacts/mihomo-device
```

如果 `hdc` 不在 PATH，可使用环境变量：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc node tests/verify-device-mihomo.mjs --observe-ms 45000
```

## controller 验证

VPN 启动后，可通过 hdc 端口转发验证 mihomo controller 与 HTTP 代理：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
SERIAL=<device-serial>

$HDC -t "$SERIAL" fport tcp:29092 tcp:9090
$HDC -t "$SERIAL" fport tcp:27890 tcp:7890

curl http://127.0.0.1:29092/version
curl http://127.0.0.1:29092/connections
curl -x http://127.0.0.1:27890 https://www.gstatic.com/generate_204 -I
```

## 当前限制

- 真机 VPN 权限弹窗仍需要系统确认。
- 自动化 UI 验证容易受真机锁屏影响；关键链路以 controller、TUN、HAP 内容和日志验证为主。
- `x86_64` 未接入真实 mihomo 库，模拟器主要用于界面和构建验证。
- DevEco / HarmonyOS SDK 版本差异可能产生 ArkTS deprecation warning，目前不影响构建。

## 相关文档

- [开源许可证](LICENSE)
- [第三方声明](THIRD_PARTY_NOTICES.md)
- [产品规划](docs/harmonyos-product-design.md)
- [界面原型](docs/harmonyos-ui-prototype.md)
- [mihomo native 集成计划](docs/mihomo-native-integration-plan.md)

## 常用命令

```bash
# 构建
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p module=entry@default -p product=default

# HAP 内容校验
node tests/verify-hap-contents.mjs entry/build/default/outputs/default/entry-default-signed.hap

# 真机安装
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC list targets
$HDC -t <device-serial> install -r entry/build/default/outputs/default/entry-default-signed.hap
```

## 真机界面截图

以下截图来自真实 HarmonyOS 手机，展示当前版本的四个主页面。

| 首页 | 代理 |
| --- | --- |
| <img src="docs/screenshots/real-device-home.png" width="260" alt="首页真机截图"> | <img src="docs/screenshots/real-device-proxy.png" width="260" alt="代理页真机截图"> |

| 配置 | 诊断 |
| --- | --- |
| <img src="docs/screenshots/real-device-profiles.png" width="260" alt="配置页真机截图"> | <img src="docs/screenshots/real-device-diagnostics.png" width="260" alt="诊断页真机截图"> |
