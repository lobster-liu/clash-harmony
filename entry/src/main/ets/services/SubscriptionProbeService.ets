import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ClashProfile, createLocalProfile, ProfileState } from '../models/Profile';
import { ControllerTextResult, MihomoControllerService } from './MihomoControllerService';
import { ProfileStore } from './ProfileStore';

const UNSUPPORTED_PROXY_TYPES: string[] = ['wireguard', 'wg', 'tailscale'];
// 内核里这些名字不是真节点（内置出站 / 探测用的占位组）
const BUILTIN_PROXY_NAMES: string[] = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE', 'GLOBAL'];
const GROUP_PROXY_TYPES: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance'];
const AVAILABLE_SUFFIX: string = '-可用';

 export interface ProbeEntry {
  name: string;
  lines: string[];
}

export interface ProbeOptions {
  limit: number;
  concurrency: number;
  timeoutMs: number;
  targets: string[];
  requireAll: boolean;
}

export interface ProbeProgress {
  tested: number;
  total: number;
  alive: number;
  current: string;
}

export interface ProbeScanResult {
  ok: boolean;
  message: string;
  alive: string[];
  delays: Map<string, number>;
  tested: number;
}

export interface ProbeApplyResult {
  ok: boolean;
  message: string;
  state: ProfileState;
  path: string;
}

export class SubscriptionProbeService {
  /**
   * 把订阅文本里的 proxies 条目原样切出来（兼容缩进与顶格两种写法）。
   * 不支持的出站类型（wireguard 等）会被丢弃，否则整份探针配置会被内核拒绝加载。
   */
  static splitProxyEntries(text: string): ProbeEntry[] {
    const lines: string[] = text.split('\n');
    const entries: ProbeEntry[] = [];
    let inProxies: boolean = false;
    let itemIndent: number = -1;
    let current: string[] = [];

    const flush = () => {
      if (current.length > 0) {
        const entry: ProbeEntry | undefined = SubscriptionProbeService.toEntry(current);
        if (entry) {
          entries.push(entry);
        }
      }
      current = [];
    };

    for (let index = 0; index < lines.length; index++) {
      const line: string = lines[index];
      const trimmed: string = line.trim();

      if (!inProxies) {
        if (/^proxies:\s*$/.test(trimmed) && SubscriptionProbeService.indentOf(line) === 0) {
          inProxies = true;
        }
        continue;
      }

      if (trimmed.length === 0) {
        if (current.length > 0) {
          current.push(line);
        }
        continue;
      }

      if (trimmed.startsWith('#')) {
        if (current.length > 0) {
          current.push(line);
        }
        continue;
      }

      const indent: number = SubscriptionProbeService.indentOf(line);
      const isDash: boolean = /^-\s/.test(trimmed) || trimmed === '-';

      if (SubscriptionProbeService.isTopLevelKey(line)) {
        break;
      }

      if (isDash) {
        if (itemIndent < 0) {
          itemIndent = indent;
        }
        if (indent <= itemIndent) {
          flush();
          current.push(line);
          continue;
        }
      }

      if (current.length > 0) {
        current.push(line);
      }
    }
    flush();

    const unique: ProbeEntry[] = [];
    const seen: Set<string> = new Set<string>();
    for (let index = 0; index < entries.length; index++) {
      const entry: ProbeEntry = entries[index];
      if (seen.has(entry.name)) {
        continue;
      }
      seen.add(entry.name);
      unique.push(entry);
    }
    return unique;
  }

  /**
   * 当前运行内核里真正可测的叶子节点（跳过内置出站与各种代理组）。
   * 体检只测这些节点：它们已经在运行中的配置里，因此不需要重载内核。
   */
  static async runningLeafNames(): Promise<string[]> {
    const result: ControllerTextResult = await MihomoControllerService.getProxies();
    if (!result.ok) {
      return [];
    }
    try {
      const data = JSON.parse(result.raw) as Record<string, Object>;
      const proxies = data['proxies'] as Record<string, Object>;
      if (!proxies) {
        return [];
      }
      const names: string[] = [];
      const keys: string[] = Object.keys(proxies);
      for (let index = 0; index < keys.length; index++) {
        const key: string = keys[index];
        if (BUILTIN_PROXY_NAMES.indexOf(key) >= 0) {
          continue;
        }
        const proxy = proxies[key] as Record<string, Object>;
        const type: string = (proxy['type'] as string) || '';
        if (GROUP_PROXY_TYPES.indexOf(type) >= 0) {
          continue;
        }
        if (Array.isArray(proxy['all'])) {
          continue;
        }
        names.push(key);
      }
      return names;
    } catch (err) {
      return [];
    }
  }

  /**
   * 只保留「既在配置文本里、也在运行内核里」的节点名，保持配置文本中的顺序。
   */
  static intersectWithRunning(entries: ProbeEntry[], running: string[]): string[] {
    const runningSet: Set<string> = new Set<string>();
    for (let index = 0; index < running.length; index++) {
      runningSet.add(running[index]);
    }
    const names: string[] = [];
    for (let index = 0; index < entries.length; index++) {
      const name: string = entries[index].name;
      if (runningSet.has(name)) {
        names.push(name);
      }
    }
    return names;
  }

  /**
   * 并发实测：每个节点依次对 targets 发延迟测试，默认任一目标通过即算可用。
   */
  static async scan(names: string[], options: ProbeOptions, onProgress: (progress: ProbeProgress) => void): Promise<ProbeScanResult> {
    const total: number = names.length;
    const delays: Map<string, number> = new Map<string, number>();
    if (total === 0) {
      return { ok: false, message: '没有候选节点', alive: [], delays: delays, tested: 0 };
    }

    const concurrency: number = options.concurrency > 0 ? options.concurrency : 6;
    let cursor: number = 0;
    let tested: number = 0;

    const worker = async (): Promise<void> => {
      while (true) {
        const index: number = cursor;
        cursor += 1;
        if (index >= total) {
          return;
        }
        const name: string = names[index];
        const delay: number = await SubscriptionProbeService.testOne(name, options);
        tested += 1;
        if (delay > 0) {
          delays.set(name, delay);
        }
        onProgress({ tested: tested, total: total, alive: delays.size, current: name });
      }
    };

    const workers: Promise<void>[] = [];
    const poolSize: number = Math.min(concurrency, total);
    for (let index = 0; index < poolSize; index++) {
      workers.push(worker());
    }
    await Promise.all(workers);

    const alive: string[] = [];
    delays.forEach((value: number, key: string) => {
      alive.push(key);
    });
    // 按延迟从低到高，生成的“可用节点”列表顺带就是按速度排的
    alive.sort((left: string, right: string) => (delays.get(left) || 0) - (delays.get(right) || 0));

    return {
      ok: alive.length > 0,
      message: alive.length > 0 ? `体检完成：可用 ${alive.length}/${total}` : `体检完成：没有可用节点（共测 ${total} 个）`,
      alive: alive,
      delays: delays,
      tested: tested
    };
  }

  /**
   * 用存活节点生成新的本地配置，并登记成“<名字>-可用”设为当前。
   * 只落盘、不重载内核：重载会让内核重建 tun、把已建立的 VPN 数据面弄断。
   */
  static async apply(context: common.Context, profileName: string, text: string, aliveNames: string[], total: number): Promise<ProbeApplyResult> {
    const entries: ProbeEntry[] = SubscriptionProbeService.splitProxyEntries(text);
    const aliveSet: Set<string> = new Set<string>();
    for (let index = 0; index < aliveNames.length; index++) {
      aliveSet.add(aliveNames[index]);
    }

    const kept: ProbeEntry[] = [];
    for (let index = 0; index < entries.length; index++) {
      if (aliveSet.has(entries[index].name)) {
        kept.push(entries[index]);
      }
    }
    if (kept.length === 0) {
      return { ok: false, message: '没有可用节点，未生成配置', state: await ProfileStore.load(context), path: '' };
    }

    const body: string[] = [];
    body.push('proxies:');
    for (let index = 0; index < kept.length; index++) {
      const entry: ProbeEntry = kept[index];
      const dashIndent: number = SubscriptionProbeService.entryDashIndent(entry.lines);
      for (let lineIndex = 0; lineIndex < entry.lines.length; lineIndex++) {
        const line: string = entry.lines[lineIndex];
        if (line.trim().length === 0) {
          continue;
        }
        const indent: number = SubscriptionProbeService.indentOf(line);
        const shifted: number = indent >= dashIndent ? indent - dashIndent : 0;
        body.push(`${SubscriptionProbeService.spaces(2 + shifted)}${line.trim()}`);
      }
    }

    const dir: string = `${context.filesDir}/profiles`;
    await SubscriptionProbeService.ensureDir(dir);
    const path: string = `${dir}/probe_${Date.now()}.yaml`;
    await SubscriptionProbeService.writeText(path, `${body.join('\n')}\n`);

    let baseName: string = profileName.trim();
    while (baseName.endsWith(AVAILABLE_SUFFIX)) {
      baseName = baseName.slice(0, baseName.length - AVAILABLE_SUFFIX.length).trim();
    }
    const name: string = baseName.length > 0 ? `${baseName}${AVAILABLE_SUFFIX}` : `订阅体检${AVAILABLE_SUFFIX}`;
    const profile: ClashProfile = createLocalProfile(name, path, kept.length, `体检通过 ${kept.length}/${total}`);
    const state: ProfileState = await ProfileStore.addLocal(context, profile);

    return {
      ok: true,
      message: `已生成「${name}」：${kept.length} 个可用节点（原配置 ${total} 个），并设为当前配置；点「断开」再「连接」生效（当前隧道未受影响）`,
      state: state,
      path: path
    };
  }

  private static async testOne(name: string, options: ProbeOptions): Promise<number> {
    let best: number = -1;
    const targets: string[] = options.targets.length > 0 ? options.targets : ['https://www.gstatic.com/generate_204'];
    for (let index = 0; index < targets.length; index++) {
      const result: ControllerTextResult = await MihomoControllerService.testDelay(name, options.timeoutMs, targets[index]);
      if (!result.ok) {
        if (options.requireAll) {
          return -1;
        }
        continue;
      }
      const delay: number = SubscriptionProbeService.parseDelay(result.raw);
      if (delay > 0) {
        if (!options.requireAll) {
          return delay;
        }
        best = best < 0 || delay < best ? delay : best;
      } else if (options.requireAll) {
        return -1;
      }
    }
    return best;
  }

  private static parseDelay(raw: string): number {
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const value: Object | undefined = parsed['delay'];
      if (typeof value === 'number') {
        return value as number;
      }
    } catch (err) {
    }
    return -1;
  }

  private static toEntry(lines: string[]): ProbeEntry | undefined {
    let name: string = '';
    let type: string = '';
    for (let index = 0; index < lines.length; index++) {
      const trimmed: string = lines[index].trim();
      if (name.length === 0 && /^(- )?name:/.test(trimmed)) {
        name = SubscriptionProbeService.cleanValue(trimmed.replace(/^(- )?name:/, ''));
      }
      if (type.length === 0 && /^(- )?type:/.test(trimmed)) {
        type = SubscriptionProbeService.cleanValue(trimmed.replace(/^(- )?type:/, '')).toLowerCase();
      }
    }
    if (name.length === 0 || type.length === 0) {
      return undefined;
    }
    for (let index = 0; index < UNSUPPORTED_PROXY_TYPES.length; index++) {
      if (type === UNSUPPORTED_PROXY_TYPES[index]) {
        return undefined;
      }
    }
    return { name: name, lines: lines };
  }

  private static cleanValue(value: string): string {
    let text: string = value.trim();
    if (text.startsWith('"')) {
      text = text.substring(1);
      const closing: number = text.indexOf('"');
      if (closing >= 0) {
        text = text.substring(0, closing);
      }
      return text;
    }
    if (text.startsWith('\'')) {
      text = text.substring(1);
      const closing: number = text.indexOf('\'');
      if (closing >= 0) {
        text = text.substring(0, closing);
      }
      return text;
    }
    const comment: number = text.indexOf(' #');
    if (comment >= 0) {
      text = text.substring(0, comment);
    }
    return text.trim();
  }

  private static isTopLevelKey(line: string): boolean {
    if (SubscriptionProbeService.indentOf(line) !== 0) {
      return false;
    }
    const trimmed: string = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#') || trimmed.startsWith('-')) {
      return false;
    }
    return trimmed.indexOf(':') > 0;
  }

  private static entryDashIndent(lines: string[]): number {
    for (let index = 0; index < lines.length; index++) {
      const trimmed: string = lines[index].trim();
      if (/^-\s/.test(trimmed) || trimmed === '-') {
        return SubscriptionProbeService.indentOf(lines[index]);
      }
    }
    return 0;
  }

  private static indentOf(line: string): number {
    let count: number = 0;
    for (let index = 0; index < line.length; index++) {
      if (line.charAt(index) === ' ') {
        count += 1;
      } else {
        break;
      }
    }
    return count;
  }

  private static spaces(count: number): string {
    let text: string = '';
    for (let index = 0; index < count; index++) {
      text += ' ';
    }
    return text;
  }

  private static scalar(value: string): string {
    const safe: RegExp = new RegExp('^[A-Za-z0-9\\u00C0-\\uFFFF][A-Za-z0-9\\u00C0-\\uFFFF ._()+\\-]*$');
    if (value.length > 0 && safe.test(value)) {
      return value;
    }
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }

  private static async ensureDir(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
    } catch (err) {
    }
  }

  private static async writeText(path: string, text: string): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, text);
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
        }
      }
    }
  }
}
