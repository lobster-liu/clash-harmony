import { ClashConfigParserService, ParsedProxyNode } from './ClashConfigParserService';

export interface RuleTemplateResult {
  ok: boolean;
  yaml: string;
  groupCount: number;
  ruleCount: number;
  message: string;
}

interface RegionRule {
  group: string;
  pattern: RegExp;
  names: string[];
}

interface AppGroup {
  group: string;
  geosite: string;
  directFirst: boolean;
  direct: boolean;
  reject: boolean;
}

interface ProxyFilterResult {
  text: string;
  dropped: number;
  droppedTypes: string[];
}

/** 随包内核没编译 gVisor / 相应出站，遇到这些类型的节点会让整份配置解析失败。 */
const UNSUPPORTED_PROXY_TYPES: string[] = ['wireguard', 'wg', 'tailscale'];

const G_ALL: string = '🧭 全部节点';
const G_AUTO: string = '♻️ 自动选择';
const G_MANUAL: string = '🚀 手动选择';
const G_DEFAULT: string = '🌐 Default';
const G_FINAL: string = '🐟 漏网之鱼';
const G_RARE: string = '🧊 冷门节点';
const G_ODD: string = '🔀 非标端口';
const G_FOLLOW: string = '🐟 遵循规则';
const SPEEDTEST_URL: string = 'https://www.gstatic.com/generate_204';

/**
 * 按「科学上网自定义规则 A（OpenClash）」编排 mihomo 的分组与规则：
 * 只保留订阅里的 proxies，分组与 rules 全部由本模板生成（对应原方案的
 * overwrite_original_rules=true），依赖 homeDir 下的 geosite.dat / geoip.dat。
 */
export class RuleTemplateService {
  private static readonly REGIONS: RegionRule[] = [
    { group: '🇭🇰 HK', pattern: new RegExp('(🇭🇰|香港|\\bHK\\b|hong\\s*kong)', 'i'), names: [] },
    { group: '🇹🇼 TW', pattern: new RegExp('(🇹🇼|台湾|台灣|\\bTW\\b|taiwan|taipei|hinet)', 'i'), names: [] },
    { group: '🇯🇵 JP', pattern: new RegExp('(🇯🇵|日本|\\bJP\\b|tokyo|osaka)', 'i'), names: [] },
    { group: '🇸🇬 SG', pattern: new RegExp('(🇸🇬|新加坡|\\bSG\\b|singapore)', 'i'), names: [] },
    { group: '🇺🇸 US', pattern: new RegExp('(🇺🇸|美国|美國|\\bUS\\b|united\\s*states|los\\s*angeles|san\\s*jose|seattle|new\\s*york)', 'i'), names: [] }
  ];

  private static readonly APPS: AppGroup[] = [
    { group: '📦 Notion', geosite: 'notion', directFirst: false, direct: true, reject: false },
    { group: '🍎 Apple', geosite: 'apple', directFirst: false, direct: true, reject: false },
    { group: '🤖 ChatGPT', geosite: 'openai', directFirst: false, direct: false, reject: false },
    { group: '🧠 AI', geosite: 'category-ai-!cn', directFirst: false, direct: false, reject: false },
    { group: '📨 Telegram', geosite: 'telegram', directFirst: false, direct: false, reject: false },
    { group: '📞 即时通讯', geosite: 'category-communication', directFirst: false, direct: false, reject: false },
    { group: '💬 社交媒体', geosite: 'category-social-media-!cn', directFirst: false, direct: false, reject: false },
    { group: '🎬 YouTube', geosite: 'youtube', directFirst: false, direct: false, reject: false },
    { group: '🎥 Netflix', geosite: 'netflix', directFirst: false, direct: false, reject: false },
    { group: '🎵 TikTok', geosite: 'tiktok', directFirst: false, direct: false, reject: false },
    { group: '📸 Instagram', geosite: 'instagram', directFirst: false, direct: false, reject: false },
    { group: '🐦 X', geosite: 'twitter', directFirst: false, direct: false, reject: false },
    { group: '🛠 GitHub', geosite: 'github', directFirst: false, direct: false, reject: false },
    { group: '🚝 测速工具', geosite: 'category-speedtest', directFirst: true, direct: false, reject: false },
    { group: '🎮 Steam', geosite: 'steam', directFirst: true, direct: false, reject: false },
    { group: '🟦 OKX', geosite: 'okx', directFirst: false, direct: true, reject: false },
    { group: '🟨 Binance', geosite: 'binance', directFirst: false, direct: true, reject: false },
    { group: '🟪 Bybit', geosite: 'bybit', directFirst: false, direct: true, reject: false },
    { group: '🟥 Adobe', geosite: 'adobe', directFirst: false, direct: true, reject: true },
    { group: '🔎 Google', geosite: 'google', directFirst: false, direct: false, reject: false },
    { group: '☁️ cloudflare', geosite: 'cloudflare', directFirst: false, direct: false, reject: false },
    { group: '🪟 Microsoft', geosite: 'microsoft', directFirst: true, direct: false, reject: false }
  ];

  static apply(profileYaml: string): RuleTemplateResult {
    const filtered: ProxyFilterResult = RuleTemplateService.filterUnsupportedProxies(profileYaml);
    const source: string = filtered.text;
    const proxies: string = RuleTemplateService.block(source, 'proxies');
    const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(source);
    if (proxies.length === 0 || nodes.length === 0) {
      return {
        ok: false,
        yaml: profileYaml,
        groupCount: 0,
        ruleCount: 0,
        message: '配置里没有可用的 proxies，保持原样'
      };
    }

    const regions: RegionRule[] = RuleTemplateService.classify(nodes);
    const groups: string[] = RuleTemplateService.buildGroups(nodes, regions);
    const rules: string[] = RuleTemplateService.buildRules();
    const body: string = source.replace(/\s+$/, '');

    const sections: string[] = [
      body,
      `proxy-groups:\n${groups.join('\n')}`,
      `rules:\n${rules.join('\n')}`
    ];

    const skipped: string = filtered.dropped > 0
      ? `，已跳过 ${filtered.dropped} 个不受支持的节点（${filtered.droppedTypes.join('/')}：随包内核未编译对应出站）`
      : '';

    return {
      ok: true,
      yaml: sections.join('\n\n'),
      groupCount: groups.length,
      ruleCount: rules.length,
      message: `已生成 ${groups.length} 个分组、${rules.length} 条规则${skipped}`
    };
  }

  private static classify(nodes: ParsedProxyNode[]): RegionRule[] {
    const regions: RegionRule[] = [];
    for (let index = 0; index < RuleTemplateService.REGIONS.length; index++) {
      const source: RegionRule = RuleTemplateService.REGIONS[index];
      regions.push({ group: source.group, pattern: source.pattern, names: [] });
    }

    for (let index = 0; index < nodes.length; index++) {
      const name: string = nodes[index].name;
      for (let r = 0; r < regions.length; r++) {
        if (regions[r].pattern.test(name)) {
          regions[r].names.push(name);
          break;
        }
      }
    }
    return regions;
  }

  private static rareNodes(nodes: ParsedProxyNode[], regions: RegionRule[]): string[] {
    const names: string[] = [];
    for (let index = 0; index < nodes.length; index++) {
      const name: string = nodes[index].name;
      let matched: boolean = false;
      for (let r = 0; r < regions.length; r++) {
        if (regions[r].pattern.test(name)) {
          matched = true;
          break;
        }
      }
      if (!matched) {
        names.push(name);
      }
    }
    return names;
  }

  /**
   * 去掉内核不支持的出站类型：一个 wireguard 节点就会让整份配置
   * `ParseWithPath` 失败（`gVisor is not included in this build`），
   * 而用户看到的是「导入成功但连不上」。
   */
  private static filterUnsupportedProxies(body: string): ProxyFilterResult {
    const lines: string[] = body.split('\n');
    const kept: string[] = [];
    const droppedTypes: string[] = [];
    let dropped: number = 0;
    let inProxies: boolean = false;
    let itemIndent: number = -1;
    let index: number = 0;

    while (index < lines.length) {
      const line: string = lines[index];
      const trimmed: string = line.trim();
      const topLevel: boolean = line.length > 0 && !line.startsWith(' ') && !line.startsWith('\t');

      if (!inProxies) {
        if (topLevel && trimmed === 'proxies:') {
          inProxies = true;
        }
        kept.push(line);
        index++;
        continue;
      }

      const indent: number = RuleTemplateService.dashIndent(line);
      if (indent >= 0) {
        // 以「同级第一个条目的缩进」为界：条目内部的嵌套列表（peers 等）缩进更深，不算新条目。
        if (itemIndent < 0) {
          itemIndent = indent;
        }
        if (indent === itemIndent) {
          let end: number = index + 1;
          while (end < lines.length) {
            const next: string = lines[end];
            const nextTrimmed: string = next.trim();
            const nextTop: boolean = next.length > 0 && !next.startsWith(' ') && !next.startsWith('\t');
            if (nextTop && !nextTrimmed.startsWith('- ')) {
              break;
            }
            if (RuleTemplateService.dashIndent(next) === itemIndent) {
              break;
            }
            end++;
          }
          const type: string = RuleTemplateService.itemType(lines, index, end);
          const normalized: string = type.toLowerCase();
          if (UNSUPPORTED_PROXY_TYPES.indexOf(normalized) >= 0) {
            dropped++;
            if (droppedTypes.indexOf(normalized) < 0) {
              droppedTypes.push(normalized);
            }
          } else {
            for (let cursor: number = index; cursor < end; cursor++) {
              kept.push(lines[cursor]);
            }
          }
          index = end;
          continue;
        }
      }

      if (topLevel) {
        inProxies = false;
        itemIndent = -1;
      }
      kept.push(line);
      index++;
    }

    return { text: kept.join('\n'), dropped: dropped, droppedTypes: droppedTypes };
  }

  private static dashIndent(line: string): number {
    let index: number = 0;
    while (index < line.length && line.charAt(index) === ' ') {
      index++;
    }
    if (index + 1 < line.length && line.charAt(index) === '-' && line.charAt(index + 1) === ' ') {
      return index;
    }
    return -1;
  }

  private static itemType(lines: string[], start: number, end: number): string {
    for (let index: number = start; index < end; index++) {
      const trimmed: string = lines[index].trim();
      const caret: string = trimmed.startsWith('- ') ? trimmed.substring(2).trim() : trimmed;
      if (!caret.startsWith('type:')) {
        continue;
      }
      let value: string = caret.substring(5).trim();
      const comma: number = value.indexOf(',');
      if (comma >= 0) {
        value = value.substring(0, comma);
      }
      value = value.replace(/^["']/, '').replace(/["']$/, '');
      return value;
    }
    return '';
  }

  private static buildGroups(nodes: ParsedProxyNode[], regions: RegionRule[]): string[] {
    const allNames: string[] = [];
    for (let index = 0; index < nodes.length; index++) {
      allNames.push(nodes[index].name);
    }
    const rare: string[] = RuleTemplateService.rareNodes(nodes, regions);
    const available: string[] = [];
    for (let r = 0; r < regions.length; r++) {
      if (regions[r].names.length > 0) {
        available.push(regions[r].group);
      }
    }
    if (rare.length > 0) {
      available.push(G_RARE);
    }

    const groupLines: string[] = [];

    // 🌐 兜底与手动选择
    const manualMembers: string[] = [G_AUTO];
    for (let index = 0; index < available.length; index++) {
      manualMembers.push(available[index]);
    }
    manualMembers.push(G_ALL);
    manualMembers.push('DIRECT');
    groupLines.push(RuleTemplateService.selectGroup(G_MANUAL, manualMembers));

    // 首选项放 ♻️ 自动选择（url-test 会自己挑最快且能连通的节点），地区组排在后面。
    // 若把某个地区组放在首位，机场里该地区节点全挂时，所有走「🌐 Default」的流量都会一起失败。
    const defaultMembers: string[] = [G_AUTO];
    for (let index = 0; index < available.length; index++) {
      defaultMembers.push(available[index]);
    }
    defaultMembers.push(G_ALL);
    defaultMembers.push('DIRECT');
    groupLines.push(RuleTemplateService.selectGroup(G_DEFAULT, defaultMembers));

    groupLines.push(RuleTemplateService.selectGroup(G_FINAL, [G_DEFAULT, 'DIRECT', G_AUTO, G_RARE, G_MANUAL]));

    const portMembers: string[] = [G_FOLLOW, 'DIRECT'];
    groupLines.push(RuleTemplateService.selectGroup(G_ODD, portMembers));
    groupLines.push(RuleTemplateService.selectGroup(G_FOLLOW, [G_FINAL]));

    // 应用分组
    for (let index = 0; index < RuleTemplateService.APPS.length; index++) {
      const app: AppGroup = RuleTemplateService.APPS[index];
      const members: string[] = [];
      if (app.directFirst) {
        members.push('DIRECT');
      }
      // 同样把自检组放前面：地区组只是可选项，默认出口不由某个可能全挂的地区决定
      members.push(G_AUTO);
      for (let a = 0; a < available.length; a++) {
        members.push(available[a]);
      }
      if (app.direct) {
        members.push('DIRECT');
      }
      if (app.reject) {
        members.push('REJECT');
      }
      members.push(G_DEFAULT);
      groupLines.push(RuleTemplateService.selectGroup(app.group, members));
    }

    // 全部节点 / 自动选择 / 地区测速 / 冷门
    groupLines.push(RuleTemplateService.selectGroup(G_ALL, allNames));
    groupLines.push(RuleTemplateService.urlTestGroup(G_AUTO, allNames));
    for (let r = 0; r < regions.length; r++) {
      if (regions[r].names.length === 0) {
        continue;
      }
      groupLines.push(RuleTemplateService.urlTestGroup(regions[r].group, regions[r].names));
    }
    if (rare.length > 0) {
      groupLines.push(RuleTemplateService.selectGroup(G_RARE, rare));
    }

    return groupLines;
  }

  private static buildRules(): string[] {
    const rules: string[] = [
      '  - GEOSITE,adobe,🟥 Adobe',
      '  - GEOSITE,private,DIRECT',
      '  - GEOIP,private,DIRECT,no-resolve',
      '  - GEOSITE,cn,DIRECT',
      '  - GEOIP,cn,DIRECT',
      '  - GEOSITE,google-cn,DIRECT',
      '  - GEOSITE,category-games,DIRECT',
      '  - GEOSITE,category-public-tracker,DIRECT'
    ];

    for (let index = 0; index < RuleTemplateService.APPS.length; index++) {
      const app: AppGroup = RuleTemplateService.APPS[index];
      if (app.geosite === 'adobe') {
        continue;
      }
      rules.push(`  - GEOSITE,${app.geosite},${app.group}`);
    }

    rules.push('  - GEOSITE,gfw,🚀 手动选择');

    // 非标端口：等价于笔记里的 rule-provider Custom_Port_Direct.yaml
    // （Aethersailor/Custom_OpenClash_Rules，payload 只有「除 80/443 之外的全部端口」
    // 三条 DST-PORT 区间）。内联成原生规则，省掉运行期下载规则集的失败面。
    rules.push(`  - DST-PORT,1-79,${G_ODD}`);
    rules.push(`  - DST-PORT,81-442,${G_ODD}`);
    rules.push(`  - DST-PORT,444-65535,${G_ODD}`);

    rules.push(`  - MATCH,${G_FINAL}`);
    return rules;
  }

  private static selectGroup(name: string, members: string[]): string {
    if (members.length === 0) {
      members.push('DIRECT');
    }
    const lines: string[] = [`  - name: ${name}`, '    type: select', '    proxies:'];
    for (let index = 0; index < members.length; index++) {
      lines.push(`      - ${RuleTemplateService.scalar(members[index])}`);
    }
    return lines.join('\n');
  }

  private static urlTestGroup(name: string, members: string[]): string {
    const lines: string[] = [
      `  - name: ${name}`,
      '    type: url-test',
      `    url: ${SPEEDTEST_URL}`,
      '    interval: 300',
      '    tolerance: 50',
      '    lazy: false',
      '    proxies:'
    ];
    for (let index = 0; index < members.length; index++) {
      lines.push(`      - ${RuleTemplateService.scalar(members[index])}`);
    }
    return lines.join('\n');
  }

  private static scalar(value: string): string {
    // 「@」和反引号是 YAML 的保留首字符（`- @xxx` 会直接让解析器报
    // “found character that cannot start any token”），`:`/`#`/引号同样危险。
    // 与其逐个列举，不如只放行「明显安全」的裸串，其余一律加引号。
    const safe: RegExp = new RegExp('^[A-Za-z0-9\\u00C0-\\uFFFF][A-Za-z0-9\\u00C0-\\uFFFF ._()+\\-]*$');
    if (value.length > 0 && safe.test(value)) {
      return value;
    }
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }

  private static block(text: string, key: string): string {
    const lines: string[] = text.split('\n');
    const kept: string[] = [];
    let inside: boolean = false;
    for (let index = 0; index < lines.length; index++) {
      const line: string = lines[index];
      const isTopLevel: boolean = line.length > 0 && !line.startsWith(' ') && !line.startsWith('\t') &&
        line.indexOf(':') > 0;
      if (isTopLevel) {
        if (inside) {
          break;
        }
        if (line.substring(0, line.indexOf(':')).trim() === key) {
          inside = true;
          kept.push(line);
        }
        continue;
      }
      if (inside) {
        kept.push(line);
      }
    }
    return kept.join('\n').replace(/\s+$/, '');
  }
}
