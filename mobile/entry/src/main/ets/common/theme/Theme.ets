// 设计令牌（Apple 式克制 · 避免 AI 味的配色与排版）
// 基调：暖纸白底 / 墨色字 / 单一低饱和强调色（靛蓝），语义色极简。
//
// 深色模式 / 大字模式：C、F 是全应用共享的**可变对象**（模块单例），
// applyTheme() 直接就地改写字段值。各页面持有 @StorageLink('ams_theme_rev')
// 观察到 rev 变化后会重跑 build()，此时再次读取 C.* / F.* 即为新值。
interface ThemeColors {
  bg: string;
  surface: string;
  surfaceAlt: string;
  ink: string;
  ink2: string;
  ink3: string;
  hairline: string;
  accent: string;
  accentDark: string;
  accentSoft: string;
  danger: string;
  warn: string;
  success: string;
  radius: number;
  radiusSm: number;
}

interface ThemeFonts {
  display: number;
  title: number;
  body: number;
  caption: number;
  pad: number;
}

/** 浅色（默认）调色板。 */
const LIGHT: ThemeColors = {
  bg: '#F6F7F9',
  surface: '#FFFFFF',
  surfaceAlt: '#F0F1F4',
  ink: '#1A1A1F',
  ink2: '#6B6F76',
  ink3: '#9A9EAA',
  hairline: '#E4E5EA',
  accent: '#3B5BD6',
  accentDark: '#2F49B0',
  accentSoft: 'rgba(59,91,214,0.10)',
  danger: '#C0392B',
  warn: '#B7791F',
  success: '#2F7D4F',
  radius: 18,
  radiusSm: 12
};

/** 深色（暖黑底，避免纯黑刺眼）。 */
const DARK: ThemeColors = {
  bg: '#15161A',
  surface: '#202228',
  surfaceAlt: '#2B2E35',
  ink: '#ECEEF2',
  ink2: '#A3A8B2',
  ink3: '#747A86',
  hairline: '#33373F',
  accent: '#7C97F5',
  accentDark: '#5B79E0',
  accentSoft: 'rgba(124,151,245,0.16)',
  danger: '#E06A5B',
  warn: '#D6A24E',
  success: '#5BB07E',
  radius: 18,
  radiusSm: 12
};

const BASE_FONTS: ThemeFonts = {
  display: 28,
  title: 20,
  body: 15,
  caption: 13,
  pad: 16
};

/** 全应用共享的可变令牌；applyTheme() 会就地改写字段。 */
export const C: ThemeColors = {
  bg: LIGHT.bg,
  surface: LIGHT.surface,
  surfaceAlt: LIGHT.surfaceAlt,
  ink: LIGHT.ink,
  ink2: LIGHT.ink2,
  ink3: LIGHT.ink3,
  hairline: LIGHT.hairline,
  accent: LIGHT.accent,
  accentDark: LIGHT.accentDark,
  accentSoft: LIGHT.accentSoft,
  danger: LIGHT.danger,
  warn: LIGHT.warn,
  success: LIGHT.success,
  radius: LIGHT.radius,
  radiusSm: LIGHT.radiusSm
};

export const F: ThemeFonts = {
  display: BASE_FONTS.display,
  title: BASE_FONTS.title,
  body: BASE_FONTS.body,
  caption: BASE_FONTS.caption,
  pad: BASE_FONTS.pad
};

/** 大字模式缩放系数。 */
const LARGE_SCALE: number = 1.3;

/** 按 AppStorage 里的 ams_dark / ams_large 就地刷新 C、F。 */
export function applyTheme(): void {
  let dark: boolean = false;
  let large: boolean = false;
  try {
    const d: boolean | undefined = AppStorage.get<boolean>('ams_dark');
    if (d !== undefined) {
      dark = d;
    }
    const l: boolean | undefined = AppStorage.get<boolean>('ams_large');
    if (l !== undefined) {
      large = l;
    }
  } catch (e) {}
  const src: ThemeColors = dark ? DARK : LIGHT;
  C.bg = src.bg;
  C.surface = src.surface;
  C.surfaceAlt = src.surfaceAlt;
  C.ink = src.ink;
  C.ink2 = src.ink2;
  C.ink3 = src.ink3;
  C.hairline = src.hairline;
  C.accent = src.accent;
  C.accentDark = src.accentDark;
  C.accentSoft = src.accentSoft;
  C.danger = src.danger;
  C.warn = src.warn;
  C.success = src.success;
  C.radius = src.radius;
  C.radiusSm = src.radiusSm;
  const s: number = large ? LARGE_SCALE : 1;
  F.display = Math.round(BASE_FONTS.display * s);
  F.title = Math.round(BASE_FONTS.title * s);
  F.body = Math.round(BASE_FONTS.body * s);
  F.caption = Math.round(BASE_FONTS.caption * s);
  F.pad = BASE_FONTS.pad;
}
