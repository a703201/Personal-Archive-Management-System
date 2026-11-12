/**
 * 移动端「关于」信息 · 唯一配置入口
 * ------------------------------------------------------------
 * 与 web/src/config/about.ts 保持同一口径：
 *   - 作者信息只保留「姓名 + 联系邮箱」，不再加署名 / 账号 / 身份；
 *   - 空字段统一渲染「待补充」（common.tbd）；未配置外链渲染「待配置」（about.tbd）；
 *   - 版本号与 web/package.json 对齐（当前 1.3.0），改版本时两处同步；
 *   - 外链 label / 描述在 I18n.ets 的 about.link* 键中按三语维护，
 *     这里只存 URL；href 留空即「待配置」，页面渲染为不可点击占位项。
 */

import { t } from '../common/theme/I18n';

export interface AboutLink {
  /** i18n 键（页面取 `{key}` 名称与 `{key}Desc` 描述）；不随语言变化。 */
  key: string;
  /** 目标地址；留空表示尚未配置，页面渲染为占位项并禁止点击。 */
  url: string;
}

export interface AboutInfo {
  productName: string;
  productNameEn: string;
  productNameFr: string;
  version: string;
  releaseDate: string;
  authorName: string;
  authorEmail: string;
  license: string;
  links: AboutLink[];
}

export const ABOUT: AboutInfo = {
  productName: 'AMS · 个人档案管理系统',
  productNameEn: 'AMS · Personal Archive Management System',
  productNameFr: 'AMS · Système de gestion d’archives personnelles',
  version: '1.3.0',
  releaseDate: '2026-11-05',
  authorName: '何宇翔',
  authorEmail: 'Lumio_a7032@qq.com',
  license: 'Apache-2.0',
  links: [
    { key: 'about.linkGitCode', url: 'https://gitcode.com/a703201/Personal-Archive-Management-System' },
    { key: 'about.linkGitHub', url: 'https://github.com/a703201/Personal-Archive-Management-System' },
    { key: 'about.linkSponsor', url: 'https://ifdian.net/a/a703201' },
    { key: 'about.linkDocs', url: '' },
    { key: 'about.linkFeedback', url: '' }
  ]
};

/** 空字段占位（与 Web 端 ABOUT_PLACEHOLDER.text 一致，三语）。 */
export function aboutOrPlaceholder(v: string): string {
  return v.length > 0 ? v : t('common.tbd');
}
