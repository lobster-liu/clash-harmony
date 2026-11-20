import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ClashProfile, ProfileState } from '../models/Profile';
import { ClashConfigParserService, ParsedProxyNode } from './ClashConfigParserService';
import { ConvertedSubscription, GenericSubscriptionConverterService } from './GenericSubscriptionConverterService';
import { ProfileStore } from './ProfileStore';
import { VpnService } from './VpnService';

export interface SubscriptionUpdateResult {
  ok: boolean;
  message: string;
  state: ProfileState;
}

// 下载失败时把「下一步该干什么」直接写在提示里：手机在国内直连 GitHub raw 这类域名
// 往往拿到 2300007（connect 瞬间被拒）或 2300999（内部错误），光给错误码没人看得懂。
function hintForCode(code: number): string {
  if (code === 2300006) {
    return '（域名解析失败：先连接一个可用配置的 VPN 再导入，或换成可直连的订阅地址）';
  }
  if (code === 2300007) {
    return '（连接被拒绝：该域名在当前网络下无法直连，先连接 VPN 再导入，或用「本地文件」导入）';
  }
  if (code === 2300999) {
    return '（请求未完成：先连接 VPN 后再导入，或用「本地文件」导入）';
  }
  return '';
}

const USER_AGENT: string = 'clash-meta/1.19.0 clash-harmony/0.1.0';

// 手机在国内直连 raw.githubusercontent.com 会被拦（浏览器都打不开），而 GitHub 相关的
// 订阅又大多放在那里。实测 ghproxy.net 这类反代可以从手机直连（156 ms），所以原文失败时
// 自动换镜像再试：只要有一条通道能取到内容就不必让用户自己拼镜像地址。
const GITHUB_RAW_PREFIX: string = 'https://raw.githubusercontent.com/';
const MIRROR_PREFIXES: string[] = ['https://ghproxy.net/', 'https://ghfast.top/'];

interface MirrorFetchResult {
  payload: FetchResult;
  usedUrl: string;
}

function toJsDelivr(url: string): string {
  // https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>
  //   -> https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>
  if (!url.startsWith(GITHUB_RAW_PREFIX)) {
    return '';
  }
  const parts: string[] = url.slice(GITHUB_RAW_PREFIX.length).split('/');
  if (parts.length < 4) {
    return '';
  }
  const path: string = parts.slice(3).join('/');
  return `https://cdn.jsdelivr.net/gh/${parts[0]}/${parts[1]}@${parts[2]}/${path}`;
}

function mirrorCandidates(url: string): string[] {
  const list: string[] = [url];
  if (!url.startsWith(GITHUB_RAW_PREFIX)) {
    return list;
  }
  for (let index = 0; index < MIRROR_PREFIXES.length; index++) {
    list.push(`${MIRROR_PREFIXES[index]}${url}`);
  }
  const jsDelivr: string = toJsDelivr(url);
  if (jsDelivr.length > 0) {
    list.push(jsDelivr);
  }
  return list;
}

function mirrorLabel(url: string, original: string): string {
  if (url === original) {
    return '';
  }
  const index: number = url.indexOf('/', 'https://'.length);
  return index > 0 ? url.slice('https://'.length, index) : url;
}

export class SubscriptionService {
  static async updateProfile(context: common.Context, uid: string): Promise<SubscriptionUpdateResult> {
    const state: ProfileState = await ProfileStore.load(context);
    const profile: ClashProfile | undefined = SubscriptionService.findProfile(state, uid);
    if (!profile) {
      return {
        ok: false,
        message: '没有找到要更新的配置',
        state: state
      };
    }
    if (profile.type !== 'remote') {
      return {
        ok: false,
        message: `「${profile.name}」是本机配置文件，不能在线更新（只有订阅链接才能下载）`,
        state: state
      };
    }

    // 先按常规下载；只有当默认网络被自己的 VPN 隧道接管、请求又被隧道拒绝时，
    // 才临时断开隧道重试一次（隧道内没有可用节点时就是这种表现：2300007）。
    // 每次尝试都会把原文与镜像候选依次试一遍（GitHub raw 在手机上直连不通）。
    let releasedTunnel: boolean = false;
    let fetched: MirrorFetchResult = await SubscriptionService.fetchWithMirrors(profile.source);
    if (!fetched.payload.ok && VpnService.tunnelPresent()) {
      releasedTunnel = await VpnService.releaseTunnelForDownload();
      if (releasedTunnel) {
        fetched = await SubscriptionService.fetchWithMirrors(profile.source);
      }
    }
    const payload: FetchResult = fetched.payload;
    const viaMirror: string = mirrorLabel(fetched.usedUrl, profile.source);
    if (!payload.ok) {
      return {
        ok: false,
        message: releasedTunnel
          ? `${payload.message}（已临时断开本机 VPN 隧道后仍失败，请检查 URL 或节点可用性）`
          : payload.message,
        state: state
      };
    }

    const converted: ConvertedSubscription = GenericSubscriptionConverterService.normalizeToClashYaml(payload.text);
    if (!converted.ok) {
      return {
        ok: false,
        message: converted.message,
        state: state
      };
    }

    const filePath: string = await SubscriptionService.writeProfileYaml(context, profile.uid, converted.text);
    const nextProfile: ClashProfile = {
      uid: profile.uid,
      type: profile.type,
      name: profile.name,
      source: profile.source,
      filePath: filePath,
      updatedAt: Date.now(),
      nodeCount: converted.nodeCount > 0 ? converted.nodeCount : SubscriptionService.estimateNodeCount(converted.text),
      traffic: SubscriptionService.formatBytes(converted.text.length)
    };
    const nextState: ProfileState = await ProfileStore.replace(context, nextProfile);

    const baseMessage: string = converted.converted ? `订阅已转换，保存 ${nextProfile.nodeCount} 个节点` : `订阅已更新，保存 ${nextProfile.nodeCount} 个节点`;
    const mirrorNote: string = viaMirror.length > 0 ? `（原地址不通，已改用镜像 ${viaMirror} 下载）` : '';
    const tunnelNote: string = releasedTunnel ? '（下载时已临时断开 VPN，请重新点「连接」）' : '';
    return {
      ok: true,
      message: `${baseMessage}${mirrorNote}${tunnelNote}`,
      state: nextState
    };
  }

  private static findProfile(state: ProfileState, uid: string): ClashProfile | undefined {
    for (let index = 0; index < state.items.length; index++) {
      if (state.items[index].uid === uid) {
        return state.items[index];
      }
    }
    return undefined;
  }

  private static async fetchWithMirrors(url: string): Promise<MirrorFetchResult> {
    const candidates: string[] = mirrorCandidates(url);
    let last: FetchResult = {
      ok: false,
      message: '订阅下载失败',
      text: ''
    };
    for (let index = 0; index < candidates.length; index++) {
      last = await SubscriptionService.fetchText(candidates[index]);
      if (last.ok) {
        return {
          payload: last,
          usedUrl: candidates[index]
        };
      }
    }
    return {
      payload: last,
      usedUrl: url
    };
  }

  private static async fetchText(url: string): Promise<FetchResult> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 20000,
        connectTimeout: 15000,
        usingCache: false,
        // 只解析 IPv4：本工程的 VPN 扩展建的 TUN 只有 IPv4（isIPv6Accepted: false），
        // 手机在蜂窝网下却有原生 IPv6，目标域名带 AAAA 时请求会绕过隧道直出、被墙拦掉
        // （表现就是 2300999 / 2300007 一把抓，而 PC 上同一个 URL 正常）。
        addressFamily: http.AddressFamily.ONLY_V4,
        header: {
          'User-Agent': USER_AGENT,
          'Accept': '*/*'
        }
      });

      const code: number = response.responseCode as number;
      if (code < 200 || code >= 300) {
        return {
          ok: false,
          message: `订阅服务器返回 HTTP ${code}`,
          text: ''
        };
      }

      const text: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      if (text.length === 0) {
        return {
          ok: false,
          message: '订阅内容为空',
          text: ''
        };
      }

      return {
        ok: true,
        message: 'ok',
        text: text
      };
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      const code: number = typeof error.code === 'number' ? error.code : -1;
      const detail: string = `${error.code !== undefined ? error.code : '未知错误'} · ${error.message !== undefined ? error.message : ''}`;
      return {
        ok: false,
        message: `订阅下载失败（${detail}）${hintForCode(code)}`,
        text: ''
      };
    } finally {
      request.destroy();
    }
  }

  private static async writeProfileYaml(context: common.Context, uid: string, text: string): Promise<string> {
    const dir: string = `${context.filesDir}/profiles`;
    try {
      await fileIo.mkdir(dir, true);
    } catch (err) {
    }

    const path: string = `${dir}/${uid}.yaml`;
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
    return path;
  }

  private static estimateNodeCount(text: string): number {
    const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(text);
    if (nodes.length > 0) {
      return nodes.length;
    }
    return SubscriptionService.countOccurrences(text, '- name:');
  }

  private static countOccurrences(text: string, keyword: string): number {
    let count: number = 0;
    let start: number = 0;
    while (start < text.length) {
      const index: number = text.indexOf(keyword, start);
      if (index < 0) {
        break;
      }
      count++;
      start = index + keyword.length;
    }
    return count;
  }

  private static formatBytes(length: number): string {
    if (length < 1024) {
      return `${length} B`;
    }
    if (length < 1024 * 1024) {
      return `${Math.round(length / 1024)} KB`;
    }
    return `${Math.round(length / 1024 / 1024)} MB`;
  }
}

interface FetchResult {
  ok: boolean;
  message: string;
  text: string;
}
