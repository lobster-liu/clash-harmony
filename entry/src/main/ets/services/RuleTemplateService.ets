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
    const proxies: string = RuleTemplateService.block(profileYaml, 'proxies');
    const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(profileYaml);
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
    const body: string = profileYaml.replace(/\s+$/, '');

    const sections: string[] = [
      body,
      `proxy-groups:\n${groups.join('\n')}`,
      `rules:\n${rules.join('\n')}`
    ];

    return {
      ok: true,
      yaml: sections.join('\n\n'),
      groupCount: groups.length,
      ruleCount: rules.length,
      message: `已生成 ${groups.length} 个分组、${rules.length} 条规则`
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

    const defaultMembers: string[] = [];
    for (let index = 0; index < available.length; index++) {
      defaultMembers.push(available[index]);
    }
    defaultMembers.push(G_AUTO);
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
    const needsQuote: boolean = value.indexOf(':') >= 0 || value.indexOf('#') >= 0 ||
      value.indexOf('"') >= 0 || value.indexOf("'") >= 0 ||
      (value.length > 0 && (value.startsWith(' ') || value.startsWith('{') ||
        value.startsWith('[') || value.startsWith('&') || value.startsWith('*') ||
        value.startsWith('!') || value.startsWith('|') || value.startsWith('>')));
    if (!needsQuote) {
      return value;
    }
    return `"${value.replace(/"/g, '\\"')}"`;
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
