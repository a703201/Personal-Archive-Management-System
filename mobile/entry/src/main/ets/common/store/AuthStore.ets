import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 登录态与服务器地址的持久化存储。
 *
 * 之前只用 AppStorage（内存态），进程重启后登录态与地址全部丢失。
 * 现改为 preferences 同步 API 落盘 + AppStorage 作运行时镜像：
 *   - 启动时 init() 从磁盘恢复到 AppStorage；
 *   - 每次写同时更新内存与磁盘（putSync + flushSync）。
 * 同步版 API（getPreferencesSync / getSync / putSync / flushSync）让
 * 调用方保持纯同步，不需要改任何页面的调用方式。
 */
export class AuthStore {
  static TOKEN: string = 'ams_token';
  static REFRESH: string = 'ams_refresh';
  static LOGGED: string = 'ams_logged_in';
  static BASE_URL: string = 'ams_base_url';
  static DEFAULT_BASE_URL: string = 'http://127.0.0.1:8080';

  private static STORE_NAME: string = 'ams_auth_store';
  private static pref: preferences.Preferences | null = null;

  /** 在 EntryAbility.onCreate 调用：把磁盘值恢复成 AppStorage 运行时镜像。 */
  static init(context: common.Context): void {
    try {
      const opts: preferences.Options = { name: AuthStore.STORE_NAME };
      const p: preferences.Preferences = preferences.getPreferencesSync(context, opts);
      AuthStore.pref = p;
      const token: string = p.getSync(AuthStore.TOKEN, '') as string;
      const refresh: string = p.getSync(AuthStore.REFRESH, '') as string;
      const logged: boolean = p.getSync(AuthStore.LOGGED, false) as boolean;
      const base: string = p.getSync(AuthStore.BASE_URL, AuthStore.DEFAULT_BASE_URL) as string;
      AppStorage.setOrCreate(AuthStore.TOKEN, token);
      AppStorage.setOrCreate(AuthStore.REFRESH, refresh);
      AppStorage.setOrCreate(AuthStore.BASE_URL, base);
      // 只有「标记已登录」且确实有令牌才恢复登录态，避免脏数据直接进首页。
      AppStorage.setOrCreate(AuthStore.LOGGED, logged && token.length > 0);
    } catch (e) {
      // 首选项不可用时降级为内存态，绝不阻断启动。
      AppStorage.setOrCreate(AuthStore.LOGGED, false);
    }
  }

  private static writeString(key: string, value: string): void {
    const p = AuthStore.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {}
  }

  private static writeBool(key: string, value: boolean): void {
    const p = AuthStore.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {}
  }

  static token(): string {
    const v: string | undefined = AppStorage.get<string>(AuthStore.TOKEN);
    if (v !== undefined) {
      return v;
    }
    return '';
  }

  static refresh(): string {
    const v: string | undefined = AppStorage.get<string>(AuthStore.REFRESH);
    if (v !== undefined) {
      return v;
    }
    return '';
  }

  static save(token: string, refresh: string): void {
    AppStorage.setOrCreate(AuthStore.TOKEN, token);
    AppStorage.setOrCreate(AuthStore.REFRESH, refresh);
    AppStorage.setOrCreate(AuthStore.LOGGED, true);
    AuthStore.writeString(AuthStore.TOKEN, token);
    AuthStore.writeString(AuthStore.REFRESH, refresh);
    AuthStore.writeBool(AuthStore.LOGGED, true);
  }

  static clear(): void {
    AppStorage.setOrCreate(AuthStore.TOKEN, '');
    AppStorage.setOrCreate(AuthStore.REFRESH, '');
    AppStorage.setOrCreate(AuthStore.LOGGED, false);
    AuthStore.writeString(AuthStore.TOKEN, '');
    AuthStore.writeString(AuthStore.REFRESH, '');
    AuthStore.writeBool(AuthStore.LOGGED, false);
  }

  /** 读取已保存的服务端地址，未设置时回退默认（本地 8080）。 */
  static getBaseUrl(): string {
    const v: string | undefined = AppStorage.get<string>(AuthStore.BASE_URL);
    if (v !== undefined && v.length > 0) {
      return v;
    }
    return AuthStore.DEFAULT_BASE_URL;
  }

  /** 保存并规范化服务端地址（补全 http://、去除结尾斜杠），同时落盘。 */
  static setBaseUrl(raw: string): void {
    const url: string = AuthStore.normalizeUrl(raw);
    AppStorage.setOrCreate(AuthStore.BASE_URL, url);
    AuthStore.writeString(AuthStore.BASE_URL, url);
  }

  static normalizeUrl(raw: string): string {
    let u: string = raw.trim();
    if (u.length === 0) {
      return AuthStore.DEFAULT_BASE_URL;
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://' + u;
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
