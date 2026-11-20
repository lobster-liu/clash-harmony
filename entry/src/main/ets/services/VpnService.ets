import { bundleManager, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import nativeCore from 'libentry.so';

const DEFAULT_BUNDLE_NAME: string = 'io.github.clashharmony.app';
const VPN_ABILITY_NAME: string = 'ClashVpnExtensionAbility';
const ROUTE_TABLE: string = '/proc/net/route';
const TUN_INTERFACE_MARK: string = 'vpn-tun';

function currentBundleName(): string {
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    if (info && info.name && info.name.length > 0) {
      return info.name;
    }
  } catch (err) {
    const error: BusinessError = err as BusinessError;
    console.warn(`VpnService: cannot resolve own bundle name (${error.message}); falling back`);
  }
  return DEFAULT_BUNDLE_NAME;
}

function createVpnWant(configPath?: string): Want {
  const want: Want = {
    bundleName: currentBundleName(),
    abilityName: VPN_ABILITY_NAME
  };
  if (configPath && configPath.length > 0) {
    want.parameters = {
      configPath: configPath
    };
  }
  return want;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve() }, ms);
  });
}

export class VpnService {
  static async start(configPath: string): Promise<boolean> {
    try {
      const result = await Promise.race([
        vpnExtension.startVpnExtensionAbility(createVpnWant(configPath)),
        VpnService.timeout(20000)
      ]);
      if (result === 'timeout') {
        // 系统有时先建隧道、后回执：以隧道是否真的建立为准。
        return await VpnService.waitForTunnel(6000);
      }
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn(`VpnService: startVpnExtensionAbility failed (${error.message})`);
      return await VpnService.waitForTunnel(3000);
    }
  }

  static async stop(): Promise<boolean> {
    try {
      const result = await Promise.race([
        vpnExtension.stopVpnExtensionAbility(createVpnWant()),
        VpnService.timeout(3000)
      ]);
      if (result === 'timeout') {
        return false;
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  // 隧道是否已经占用了本应用的出网路径：一旦当前默认网络是 VPN bearer，本进程的
  // http/socket 请求就会走进自己的隧道；隧道里没有可用核心时握手会被 RST，表现为 2300007。
  static tunnelPresent(): boolean {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      if (handle && handle.netId !== 0) {
        const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
        const types: connection.NetBearType[] = caps.bearerTypes;
        for (let index = 0; index < types.length; index++) {
          if (types[index] === connection.NetBearType.BEARER_VPN) {
            return true;
          }
        }
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.warn(`VpnService: cannot read default net capabilities (${error.message})`);
    }
    try {
      const table: string = fileIo.readTextSync(ROUTE_TABLE);
      return table.indexOf(TUN_INTERFACE_MARK) >= 0;
    } catch (err) {
      return false;
    }
  }

  static async waitForTunnel(timeoutMs: number): Promise<boolean> {
    let waited: number = 0;
    while (waited < timeoutMs) {
      if (VpnService.tunnelPresent()) {
        return true;
      }
      await delay(300);
      waited += 300;
    }
    return VpnService.tunnelPresent();
  }

  // 下载订阅前临时释放自己的隧道：隧道在时先断开，等默认网络不再是 VPN 再下载。
  static async releaseTunnelForDownload(waitMs: number = 4000): Promise<boolean> {
    if (!VpnService.tunnelPresent()) {
      return false;
    }
    console.info('VpnService: vpn bearer is the default net, stopping it before the subscription download');
    await VpnService.stop();
    let waited: number = 0;
    while (waited < waitMs) {
      await delay(300);
      waited += 300;
      if (!VpnService.tunnelPresent()) {
        break;
      }
    }
    console.info(`VpnService: tunnel released=${!VpnService.tunnelPresent()} after ${waited}ms`);
    return true;
  }

  // 启动时清理上一次进程遗留的隧道（force-stop / 崩溃之后隧道可能留在系统里）。
  static async clearOrphanTunnel(): Promise<boolean> {
    if (!VpnService.tunnelPresent()) {
      return false;
    }
    console.warn('VpnService: orphan VPN bearer detected at startup, trying to tear it down');
    await VpnService.stop();
    let waited: number = 0;
    while (waited < 3000) {
      await delay(300);
      waited += 300;
      if (!VpnService.tunnelPresent()) {
        break;
      }
    }
    return true;
  }

  private static timeout(ms: number): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      setTimeout(() => { resolve('timeout') }, ms);
    });
  }

  static async protectSocket(fd: number): Promise<boolean> {
    try {
      nativeCore.protectSocket(fd);
      return true;
    } catch (err) {
      return false;
    }
  }
}
