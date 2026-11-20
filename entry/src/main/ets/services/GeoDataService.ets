import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

const GEO_DIR: string = 'runtime';
const GEO_FILES: string[] = ['geosite.dat', 'geoip.dat'];
const MIN_GEO_SIZE: number = 1024 * 1024;

export interface GeoDataResult {
  ok: boolean;
  copied: string[];
  message: string;
}

/**
 * mihomo 的 homeDir 是 <files>/runtime，GEOSITE/GEOIP 规则需要 homeDir 下存在
 * geosite.dat / geoip.dat。HAP 里已内置这两份数据（resources/rawfile/geo），
 * 首次连接前把它们落到 runtime 目录，避免依赖联网下载（首次连接往往还没有可用代理）。
 */
export class GeoDataService {
  static async ensure(context: common.Context): Promise<GeoDataResult> {
    const directory: string = `${context.filesDir}/${GEO_DIR}`;
    const copied: string[] = [];
    try {
      await GeoDataService.ensureDir(directory);
    } catch (err) {
      return {
        ok: false,
        copied: copied,
        message: '创建运行目录失败'
      };
    }

    for (let index = 0; index < GEO_FILES.length; index++) {
      const name: string = GEO_FILES[index];
      const target: string = `${directory}/${name}`;
      if (GeoDataService.present(target)) {
        continue;
      }
      try {
        const content: Uint8Array = context.resourceManager.getRawFileContentSync(`geo/${name}`);
        const buffer: ArrayBuffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
        const file = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, buffer);
        } finally {
          fileIo.closeSync(file);
        }
        copied.push(name);
      } catch (err) {
        return {
          ok: false,
          copied: copied,
          message: `写入 ${name} 失败，GEOSITE/GEOIP 规则将不可用`
        };
      }
    }

    return {
      ok: copied.length >= 0,
      copied: copied,
      message: copied.length > 0 ? `已就位 geo 数据：${copied.join('、')}` : 'geo 数据已就位'
    };
  }

  private static present(target: string): boolean {
    try {
      const stat = fileIo.statSync(target);
      return stat.size > MIN_GEO_SIZE;
    } catch (err) {
      return false;
    }
  }

  private static async ensureDir(directory: string): Promise<void> {
    try {
      const exists: boolean = await fileIo.access(directory);
      if (!exists) {
        await fileIo.mkdir(directory, true);
      }
    } catch (err) {
      await fileIo.mkdir(directory, true);
    }
  }
}
