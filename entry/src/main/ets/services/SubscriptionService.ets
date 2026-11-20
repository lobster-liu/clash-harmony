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

const USER_AGENT: string = 'clash-meta/1.19.0 clash-harmony/0.1.0';

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
    let releasedTunnel: boolean = false;
    let payload: FetchResult = await SubscriptionService.fetchText(profile.source);
    if (!payload.ok && VpnService.tunnelPresent()) {
      releasedTunnel = await VpnService.releaseTunnelForDownload();
      if (releasedTunnel) {
        payload = await SubscriptionService.fetchText(profile.source);
      }
    }
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
    return {
      ok: true,
      message: releasedTunnel ? `${baseMessage}（下载时已临时断开 VPN，请重新点「连接」）` : baseMessage,
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

  private static async fetchText(url: string): Promise<FetchResult> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 20000,
        connectTimeout: 15000,
        usingCache: false,
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
      const detail: string = `${error.code !== undefined ? error.code : '未知错误'} · ${error.message !== undefined ? error.message : ''}`;
      return {
        ok: false,
        message: `订阅下载失败（${detail}）`,
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
