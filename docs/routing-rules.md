# 分流规则（OpenClash 规则 A 的手机版）

本工程不再直接使用订阅里自带的分流。每次生成运行配置时，`RuleTemplateService` 会：

1. 保留订阅里能用的 `proxies`（并且只保留解析得出的节点）；
2. **丢弃**订阅里的 `proxy-groups` 与 `rules`（`RuntimeConfigService.managedBlockKeys`）；
3. 按 `MyNote/Clippings/科学上网自定义规则A（Openclash）.md` 重建分组与规则；
4. 在 `<files>/runtime/` 就位 `geosite.dat` / `geoip.dat`，并打开 `geodata-mode`。

## 分组（36 个）

| 分组 | 类型 | 说明 |
| --- | --- | --- |
| `🧭 全部节点` | select | 兜底手动挑节点 |
| `♻️ 自动选择` | url-test | 全部节点，`generate_204`，间隔 300s，容差 50 |
| `🇭🇰 HK` `🇹🇼 TW` `🇯🇵 JP` `🇸🇬 SG` `🇺🇸 US` | url-test | 按节点名/emoji 归属，仅在有节点时创建 |
| `🧊 冷门节点` | url-test | 未归入上面五区的节点 |
| `🚀 手动选择` | select | gfw 流量与「手动」意图的落点：`♻️ 自动选择` + 五区 + 冷门 + `🧭 全部节点` + `DIRECT` |
| `🌐 Default` | select | 应用组默认落点 |
| `🐟 漏网之鱼` | select | `MATCH` 的落点 |
| `🔀 非标端口` / `🐟 遵循规则` | select | 预留（规则 A 里用于非标端口规则集） |
| 22 个应用组 | select | `📦 Notion` `🍎 Apple` `🤖 ChatGPT` `🧠 AI` `📨 Telegram` `📞 即时通讯` `💬 社交媒体` `🎬 YouTube` `🎥 Netflix` `🎵 TikTok` `📸 Instagram` `🐦 X` `🛠 GitHub` `🚝 测速工具` `🎮 Steam` `🟦 OKX` `🟨 Binance` `🟪 Bybit` `🟥 Adobe` `🔎 Google` `☁️ cloudflare` `🪟 Microsoft` |

Apple / Microsoft / OKX / Binance / Bybit / Adobe / Steam / 测速工具 里带 `DIRECT`，其中 Microsoft / Steam / 测速工具 把 `DIRECT` 放在首位；Adobe 组另有 `REJECT`。

## 规则顺序（31 条）

```
GeoSite,adobe                   -> 🟥 Adobe
GeoSite,private                 -> DIRECT
GeoIP,private                   -> DIRECT
GeoSite,cn                      -> DIRECT
GeoIP,cn                        -> DIRECT
GeoSite,google-cn               -> DIRECT
GeoSite,category-games          -> DIRECT
GeoSite,category-public-tracker -> DIRECT
… 22 个应用组（GeoSite,<name> -> 分组）…
GeoSite,gfw                     -> 🚀 手动选择
DstPort,1-79                    -> 🔀 非标端口
DstPort,81-442                  -> 🔀 非标端口
DstPort,444-65535               -> 🔀 非标端口
MATCH                           -> 🐟 漏网之鱼
```

合计 34 条。`🔀 非标端口` 组默认选 `🐟 遵循规则`（→ `🐟 漏网之鱼`），也可以手动切到 `DIRECT`。

## geo 数据

mihomo 的 `homeDir` 是 `<files>/runtime`（见 `mihomo-go-public.log` 的 `applyConfig … homeDir=…`），所以 geo 库必须落在该目录。

- 构建期：`entry/src/main/resources/rawfile/geo/{geosite.dat,geoip.dat}`（来自 `MetaCubeX/meta-rules-dat`）。
- 运行期：`GeoDataService.ensure()` 在 `prepareCurrentProfile()` 里把缺失的文件写到 `<files>/runtime/`（小于 1MB 视为缺失），因此**升级或清数据后会自动补回**，不需要手工推文件。
- 使用 `geodata-mode: true` + `.dat`（而不是 `geoip.metadb`）：实测手机侧下载 metadb 不稳定，且 `.dat` 与 `geodata-mode` 的组合在 mihomo 1.10.0 上可用。

## 已知边界

- `dns` / `hosts` / `proxy-groups` / `rules` 由本工程托管，订阅里的同名段落会被丢弃（这是刻意行为，否则规则 A 会被订阅覆盖）。
- 规则 A 里的「非标端口」原本依赖远程 rule-provider `Custom_Port_Direct.yaml`（`Aethersailor/Custom_OpenClash_Rules`，payload 只有「除 80/443 之外的全部端口」三条区间）。这里内联成三条等价的 `DST-PORT` 原生规则，避免运行期下载规则集成为新的失败点；如果以后要跟随上游规则集，可以改回 `rule-providers` + `RULE-SET`。
- sing-box JSON 转换出的配置只有 `MATCH,Proxy`，导入后由本模板接管，无需手工改。

## 验证（2026-11-20，Pura X Max / API 26）

- `GET /proxies` → 36 个分组，节点分布 `JP 8 / US 11 / TW 1 / 冷门 12 / 全部 32`；
- `GET /connections` → 华为云域名命中 `rule=GeoSite,cn  chain=DIRECT`（国内直连生效）；
- `GET /rules` → 34 条，顺序与上表一致，`GeoSite,gfw -> 🚀 手动选择`，三条 `DstPort,* -> 🔀 非标端口`；
- `GET /proxies/🚀 手动选择/delay` → `{"delay":66}`，`/proxies/🌐 Default/delay` → `{"delay":351}`（分组的出站链路可用）。
