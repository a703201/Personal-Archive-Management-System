import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { applyTheme } from '../theme/Theme';

/**
 * 外观偏好：深色模式 / 三语 / 大字模式。
 * 与 AuthStore 同范式 —— preferences 同步 API 落盘 + AppStorage 运行时镜像。
 *
 * ams_theme_rev 是纯内存的信号量：每次外观变化自增，所有页面的
 * @StorageLink('ams_theme_rev') 据此重跑 build()，重新读取 Theme 里
 * 被 applyTheme() 就地改写的 C / F 令牌，实现全局即时换肤。
 */
export class Settings {
  static DARK: string = 'ams_dark';
  static LARGE: string = 'ams_large';
  static LANG: string = 'ams_lang';
  static REV: string = 'ams_theme_rev';
  static DEFAULT_LANG: string = 'zh-CN';

  private static STORE_NAME: string = 'ams_settings_store';
  private static pref: preferences.Preferences | null = null;

  static init(context: common.Context): void {
    try {
      const opts: preferences.Options = { name: Settings.STORE_NAME };
      Settings.pref = preferences.getPreferencesSync(context, opts);
    } catch (e) {
      Settings.pref = null;
    }
    let dark: boolean = false;
    let large: boolean = false;
    let lang: string = Settings.DEFAULT_LANG;
    const p = Settings.pref;
    if (p !== null) {
      try {
        dark = p.getSync(Settings.DARK, false) as boolean;
        large = p.getSync(Settings.LARGE, false) as boolean;
        lang = p.getSync(Settings.LANG, Settings.DEFAULT_LANG) as string;
      } catch (e) {
        dark = false;
        large = false;
        lang = Settings.DEFAULT_LANG;
      }
    }
    if (lang.length === 0) {
      lang = Settings.DEFAULT_LANG;
    }
    AppStorage.setOrCreate(Settings.DARK, dark);
    AppStorage.setOrCreate(Settings.LARGE, large);
    AppStorage.setOrCreate(Settings.LANG, lang);
    AppStorage.setOrCreate(Settings.REV, 0);
    applyTheme();
  }

  private static writeBool(key: string, value: boolean): void {
    const p = Settings.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {}
  }

  private static writeString(key: string, value: string): void {
    const p = Settings.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {}
  }

  /** 自增主题修订号，触发全应用重渲染。 */
  private static bump(): void {
    let n: number = 0;
    try {
      const v: number | undefined = AppStorage.get<number>(Settings.REV);
      if (v !== undefined) {
        n = v;
      }
    } catch (e) {}
    AppStorage.setOrCreate(Settings.REV, n + 1);
  }

  static dark(): boolean {
    try {
      const v: boolean | undefined = AppStorage.get<boolean>(Settings.DARK);
      if (v !== undefined) {
        return v;
      }
    } catch (e) {}
    return false;
  }

  static large(): boolean {
    try {
      const v: boolean | undefined = AppStorage.get<boolean>(Settings.LARGE);
      if (v !== undefined) {
        return v;
      }
    } catch (e) {}
    return false;
  }

  static lang(): string {
    try {
      const v: string | undefined = AppStorage.get<string>(Settings.LANG);
      if (v !== undefined && v.length > 0) {
        return v;
      }
    } catch (e) {}
    return Settings.DEFAULT_LANG;
  }

  static setDark(value: boolean): void {
    AppStorage.setOrCreate(Settings.DARK, value);
    Settings.writeBool(Settings.DARK, value);
    applyTheme();
    Settings.bump();
  }

  static setLarge(value: boolean): void {
    AppStorage.setOrCreate(Settings.LARGE, value);
    Settings.writeBool(Settings.LARGE, value);
    applyTheme();
    Settings.bump();
  }

  static setLang(value: string): void {
    const v: string = value.length > 0 ? value : Settings.DEFAULT_LANG;
    AppStorage.setOrCreate(Settings.LANG, v);
    Settings.writeString(Settings.LANG, v);
    Settings.bump();
  }
}
