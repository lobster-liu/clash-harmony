import { ClashConfigParserService, ParsedProxyNode } from './ClashConfigParserService';
import { ConvertedSubscription } from './GenericSubscriptionConverterService';

class NodeDraft {
  name: string = '';
  type: string = '';
  server: string = '';
  port: number = 0;
  uuid: string = '';
  password: string = '';
  cipher: string = '';
  flow: string = '';
  sni: string = '';
  skipCertVerify: boolean = false;
  network: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcService: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  clientFingerprint: string = '';
  obfsType: string = '';
  obfsPassword: string = '';
  insecure: boolean = false;
}

export class SingBoxConverterService {
  static convert(text: string): ConvertedSubscription {
    let parsed: Object | undefined = undefined;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (err) {
      return SingBoxConverterService.failure('不是合法的 JSON');
    }

    const root: Record<string, Object> | undefined = SingBoxConverterService.asRecord(parsed);
    if (root === undefined) {
      return SingBoxConverterService.failure('JSON 顶层不是对象');
    }

    const outboundsValue: Object | undefined = root.outbounds;
    if (outboundsValue === undefined || !Array.isArray(outboundsValue)) {
      return SingBoxConverterService.failure('JSON 里没有 outbounds 数组');
    }

    const outbounds: Object[] = outboundsValue as Object[];
    const drafts: NodeDraft[] = [];
    let supported: number = 0;
    for (let index = 0; index < outbounds.length; index++) {
      const outbound: Record<string, Object> | undefined = SingBoxConverterService.asRecord(outbounds[index]);
      if (outbound !== undefined && SingBoxConverterService.isSupportedType(
        SingBoxConverterService.getString(outbound, 'type'))) {
        supported += 1;
      }
      const draft: NodeDraft | undefined = SingBoxConverterService.toDraft(outbounds[index], drafts.length + 1);
      if (draft !== undefined) {
        drafts.push(draft);
      }
    }

    if (drafts.length === 0) {
      return SingBoxConverterService.failure('sing-box 配置里没有可转换的节点（仅支持 vless / vmess / trojan / shadowsocks / hysteria2）');
    }

    const yaml: string = SingBoxConverterService.buildYaml(drafts);
    const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(yaml);
    const skipped: number = supported > drafts.length ? supported - drafts.length : 0;
    const skippedText: string = skipped > 0 ? `，跳过 ${skipped} 个（缺 server/port 或密码）` : '';
    return {
      ok: true,
      message: `已将 sing-box 配置转换为 Clash YAML（${drafts.length}/${supported} 个节点${skippedText}）`,
      text: yaml,
      nodeCount: nodes.length,
      converted: true
    };
  }

  private static isSupportedType(type: string): boolean {
    return type === 'vless' || type === 'vmess' || type === 'trojan' ||
      type === 'shadowsocks' || type === 'hysteria2' || type === 'hysteria';
  }

  private static toDraft(value: Object, fallbackIndex: number): NodeDraft | undefined {
    const record: Record<string, Object> | undefined = SingBoxConverterService.asRecord(value);
    if (record === undefined) {
      return undefined;
    }

    const type: string = SingBoxConverterService.getString(record, 'type');
    const server: string = SingBoxConverterService.getString(record, 'server');
    let port: number = SingBoxConverterService.getNumber(record, 'server_port');
    if (port <= 0) {
      port = SingBoxConverterService.firstPortOfRange(record.server_ports);
    }
    if (server.length === 0 || port <= 0) {
      return undefined;
    }

    const draft: NodeDraft = new NodeDraft();
    draft.server = server;
    draft.port = port;
    draft.name = SingBoxConverterService.pickName(record, port, fallbackIndex);
    draft.skipCertVerify = SingBoxConverterService.getBool(record, 'insecure');

    const tls: Record<string, Object> | undefined = SingBoxConverterService.asRecord(record.tls);
    if (tls !== undefined) {
      draft.sni = SingBoxConverterService.getString(tls, 'server_name');
      draft.insecure = SingBoxConverterService.getBool(tls, 'insecure');
      draft.skipCertVerify = draft.skipCertVerify || draft.insecure;
      const reality: Record<string, Object> | undefined = SingBoxConverterService.asRecord(tls.reality);
      if (reality !== undefined && SingBoxConverterService.getBool(reality, 'enabled')) {
        draft.realityPublicKey = SingBoxConverterService.getString(reality, 'public_key');
        draft.realityShortId = SingBoxConverterService.getString(reality, 'short_id');
      }
      const utls: Record<string, Object> | undefined = SingBoxConverterService.asRecord(tls.utls);
      if (utls !== undefined && SingBoxConverterService.getBool(utls, 'enabled')) {
        draft.clientFingerprint = SingBoxConverterService.getString(utls, 'fingerprint');
      }
    }

    const transport: Record<string, Object> | undefined = SingBoxConverterService.asRecord(record.transport);
    if (transport !== undefined) {
      const transportType: string = SingBoxConverterService.getString(transport, 'type');
      if (transportType === 'ws') {
        draft.network = 'ws';
        draft.wsPath = SingBoxConverterService.getString(transport, 'path');
        const headers: Record<string, Object> | undefined = SingBoxConverterService.asRecord(transport.headers);
        if (headers !== undefined) {
          draft.wsHost = SingBoxConverterService.getString(headers, 'Host');
          if (draft.wsHost.length === 0) {
            draft.wsHost = SingBoxConverterService.getString(headers, 'host');
          }
        }
      } else if (transportType === 'grpc') {
        draft.network = 'grpc';
        draft.grpcService = SingBoxConverterService.getString(transport, 'service_name');
      }
    }

    if (type === 'vless') {
      draft.type = 'vless';
      draft.uuid = SingBoxConverterService.getString(record, 'uuid');
      draft.flow = SingBoxConverterService.getString(record, 'flow');
    } else if (type === 'vmess') {
      draft.type = 'vmess';
      draft.uuid = SingBoxConverterService.getString(record, 'uuid');
      draft.cipher = SingBoxConverterService.getString(record, 'security');
      draft.flow = '';
    } else if (type === 'trojan') {
      draft.type = 'trojan';
      draft.password = SingBoxConverterService.getString(record, 'password');
    } else if (type === 'shadowsocks') {
      draft.type = 'ss';
      draft.password = SingBoxConverterService.getString(record, 'password');
      draft.cipher = SingBoxConverterService.getString(record, 'method');
    } else if (type === 'hysteria2' || type === 'hysteria') {
      draft.type = 'hysteria2';
      draft.password = SingBoxConverterService.getString(record, 'password');
      const obfs: Record<string, Object> | undefined = SingBoxConverterService.asRecord(record.obfs);
      if (obfs !== undefined) {
        draft.obfsType = SingBoxConverterService.getString(obfs, 'type');
        draft.obfsPassword = SingBoxConverterService.getString(obfs, 'password');
      }
    } else {
      return undefined;
    }

    if (draft.uuid.length === 0 && draft.password.length === 0) {
      return undefined;
    }
    return draft;
  }

  private static buildYaml(drafts: NodeDraft[]): string {
    const lines: string[] = [
      'mixed-port: 7890',
      'allow-lan: false',
      'mode: rule',
      'log-level: info',
      'external-controller: 127.0.0.1:9090',
      'secret: ""',
      'proxies:'
    ];

    for (let index = 0; index < drafts.length; index++) {
      const draft: NodeDraft = drafts[index];
      lines.push(`  - name: ${SingBoxConverterService.quote(draft.name)}`);
      lines.push(`    type: ${draft.type}`);
      lines.push(`    server: ${SingBoxConverterService.quote(draft.server)}`);
      lines.push(`    port: ${draft.port}`);
      lines.push('    udp: true');

      if (draft.type === 'vless' || draft.type === 'vmess') {
        lines.push(`    uuid: ${SingBoxConverterService.quote(draft.uuid)}`);
        if (draft.type === 'vmess') {
          lines.push(`    cipher: ${SingBoxConverterService.quote(draft.cipher.length > 0 ? draft.cipher : 'auto')}`);
          lines.push('    alterId: 0');
        }
        if (draft.flow.length > 0) {
          lines.push(`    flow: ${SingBoxConverterService.quote(draft.flow)}`);
        }
        if (draft.realityPublicKey.length > 0) {
          lines.push('    tls: true');
          lines.push('    reality-opts:');
          lines.push(`      public-key: ${SingBoxConverterService.quote(draft.realityPublicKey)}`);
          if (draft.realityShortId.length > 0) {
            lines.push(`      short-id: ${SingBoxConverterService.quote(draft.realityShortId)}`);
          }
        } else if (draft.sni.length > 0) {
          lines.push('    tls: true');
        }
        if (draft.clientFingerprint.length > 0) {
          lines.push(`    client-fingerprint: ${SingBoxConverterService.quote(draft.clientFingerprint)}`);
        }
        if (draft.sni.length > 0) {
          lines.push(`    servername: ${SingBoxConverterService.quote(draft.sni)}`);
        }
      } else if (draft.type === 'trojan') {
        lines.push(`    password: ${SingBoxConverterService.quote(draft.password)}`);
        if (draft.sni.length > 0) {
          lines.push(`    sni: ${SingBoxConverterService.quote(draft.sni)}`);
        }
      } else if (draft.type === 'ss') {
        lines.push(`    cipher: ${SingBoxConverterService.quote(draft.cipher.length > 0 ? draft.cipher : 'aes-128-gcm')}`);
        lines.push(`    password: ${SingBoxConverterService.quote(draft.password)}`);
      } else if (draft.type === 'hysteria2') {
        lines.push(`    password: ${SingBoxConverterService.quote(draft.password)}`);
        if (draft.sni.length > 0) {
          lines.push(`    sni: ${SingBoxConverterService.quote(draft.sni)}`);
        }
        if (draft.obfsType === 'salamander' && draft.obfsPassword.length > 0) {
          lines.push('    obfs: salamander');
          lines.push(`    obfs-password: ${SingBoxConverterService.quote(draft.obfsPassword)}`);
        }
      }

      if (draft.skipCertVerify) {
        lines.push('    skip-cert-verify: true');
      }
      if (draft.network === 'ws') {
        lines.push('    network: ws');
        lines.push('    ws-opts:');
        lines.push(`      path: ${SingBoxConverterService.quote(draft.wsPath.length > 0 ? draft.wsPath : '/')}`);
        if (draft.wsHost.length > 0) {
          lines.push('      headers:');
          lines.push(`        Host: ${SingBoxConverterService.quote(draft.wsHost)}`);
        }
      } else if (draft.network === 'grpc') {
        lines.push('    network: grpc');
        lines.push('    grpc-opts:');
        lines.push(`      grpc-service-name: ${SingBoxConverterService.quote(draft.grpcService)}`);
      }
    }

    lines.push('proxy-groups:');
    lines.push('  - name: Proxy');
    lines.push('    type: select');
    lines.push('    proxies:');
    for (let index = 0; index < drafts.length; index++) {
      lines.push(`      - ${SingBoxConverterService.quote(drafts[index].name)}`);
    }
    lines.push('rules:');
    lines.push('  - MATCH,Proxy');
    lines.push('');
    return lines.join('\n');
  }

  private static pickName(record: Record<string, Object>, port: number, fallbackIndex: number): string {
    const tag: string = SingBoxConverterService.getString(record, 'tag');
    if (tag.length > 0) {
      return tag;
    }
    const server: string = SingBoxConverterService.getString(record, 'server');
    const type: string = SingBoxConverterService.getString(record, 'type');
    if (server.length > 0 && port > 0) {
      return `${type}-${server}:${port}`;
    }
    return `node-${fallbackIndex}`;
  }

  private static firstPortOfRange(value: Object | undefined): number {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return 0;
    }
    const items: Object[] = value as Object[];
    if (items.length === 0) {
      return 0;
    }
    const first: Object = items[0];
    const text: string = typeof first === 'string' ? first as string : `${first as number}`;
    let digits: string = '';
    for (let index = 0; index < text.length; index++) {
      const char: string = text.charAt(index);
      if (char >= '0' && char <= '9') {
        digits += char;
      } else if (digits.length > 0) {
        break;
      }
    }
    if (digits.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(digits, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | undefined {
    if (value === undefined || value === null) {
      return undefined;
    }
    if (Array.isArray(value)) {
      return undefined;
    }
    if (typeof value !== 'object') {
      return undefined;
    }
    return value as Record<string, Object>;
  }

  private static getString(record: Record<string, Object>, key: string): string {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }

  private static getNumber(record: Record<string, Object>, key: string): number {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return 0;
    }
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      const parsed: number = Number.parseInt(value as string, 10);
      return Number.isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  }

  private static getBool(record: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return false;
    }
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    return false;
  }

  private static quote(value: string): string {
    return `'${value.replace(/'/g, "''")}'`;
  }

  private static failure(message: string): ConvertedSubscription {
    return {
      ok: false,
      message: message,
      text: '',
      nodeCount: 0,
      converted: false
    };
  }
}
