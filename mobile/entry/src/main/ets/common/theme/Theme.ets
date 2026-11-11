// 设计令牌（Apple 式克制 · 避免 AI 味的配色与排版）
// 基调：暖纸白底 / 墨色字 / 单一低饱和强调色（靛蓝），语义色极简。
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

export const C: ThemeColors = {
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

export const F: ThemeFonts = {
  display: 28,
  title: 20,
  body: 15,
  caption: 13,
  pad: 16
};
