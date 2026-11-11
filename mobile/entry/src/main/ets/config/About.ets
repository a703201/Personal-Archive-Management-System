/**
 * 移动端「关于」信息 · 唯一配置入口
 * ------------------------------------------------------------
 * 与 web/src/config/about.ts 保持同一口径：
 *   - 作者信息只保留「姓名 + 联系邮箱」，不再加署名 / 账号 / 身份；
 *   - 空字段统一渲染「待补充」；
 *   - 版本号与 web/package.json 对齐（当前 1.3.0），改版本时两处同步。
 */

export interface AboutInfo {
  productName: string;
  version: string;
  authorName: string;
  authorEmail: string;
  license: string;
}

export const ABOUT: AboutInfo = {
  productName: 'AMS · 个人档案管理系统',
  version: '1.3.0',
  authorName: '何宇翔',
  authorEmail: 'Lumio_a7032@qq.com',
  license: 'Apache-2.0'
};

/** 空字段占位（与 Web 端 ABOUT_PLACEHOLDER.text 一致）。 */
export function aboutOrPlaceholder(v: string): string {
  return v.length > 0 ? v : '待补充';
}
