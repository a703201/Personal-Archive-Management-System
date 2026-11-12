import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * GET 离线缓存（preferences 持久化，与 AuthStore 同范式）。
 *
 * 旧版只写 AppStorage（内存态），杀进程后缓存全丢。现改为
 * preferences 同步 API 落盘 + AppStorage 作运行时镜像：
 *   - EntryAbility.onCreate 调 init() 拿到同一 Preferences 实例；
 *   - 写入同时更新内存镜像与磁盘（putSync + flushSync）；
 *   - 读取先查内存镜像，未命中再回磁盘并回填镜像。
 * 任何 preferences 调用都包 try/catch，磁盘不可用时静默降级为内存态。
 */
export class CacheStore {
  private static STORE_NAME: string = 'ams_cache_store';
  private static pref: preferences.Preferences | null = null;
  private static mirror: Record<string, string> = {};

  static init(context: common.Context): void {
    try {
      const opts: preferences.Options = { name: CacheStore.STORE_NAME };
      CacheStore.pref = preferences.getPreferencesSync(context, opts);
    } catch (e) {
      CacheStore.pref = null;
    }
  }

  static put(key: string, value: string): void {
    try {
      AppStorage.setOrCreate(key, value);
    } catch (e) {}
    CacheStore.mirror[key] = value;
    const p = CacheStore.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {}
  }

  static get(key: string): string | undefined {
    const m: string | undefined = CacheStore.mirror[key];
    if (m !== undefined && m.length > 0) {
      return m;
    }
    try {
      const v: string | undefined = AppStorage.get<string>(key);
      if (v !== undefined && v.length > 0) {
        CacheStore.mirror[key] = v;
        return v;
      }
    } catch (e) {}
    const p = CacheStore.pref;
    if (p === null) {
      return undefined;
    }
    try {
      const d: string = p.getSync(key, '') as string;
      if (d.length > 0) {
        CacheStore.mirror[key] = d;
        try {
          AppStorage.setOrCreate(key, d);
        } catch (e) {}
        return d;
      }
    } catch (e) {}
    return undefined;
  }
}
