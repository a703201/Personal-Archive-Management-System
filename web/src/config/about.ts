/**
 * 「关于」页内容 · 唯一配置入口
 * ------------------------------------------------------------
 * 这里集中存放项目简介、作者信息、版本与全部外链。
 * 页面只读取本文件，不在 .vue 里写死任何内容或地址；
 * 需要替换信息时，只改这里即可，无需改动页面代码。
 *
 * 【占位规则】尚未提供具体内容的字段一律留空字符串 ''：
 *   - 作者姓名 / 联系邮箱：页面上显示「待补充」，并提示配置位置；
 *   - 外链 href：页面上渲染为不可点击的占位项，标注「待配置」，避免死链。
 * 填入真实值后，页面会自动切换为正常展示 / 可点击跳转，无需改代码。
 *
 * 【版本号】直接读取 web/package.json 的 version，避免多处漂移。
 * 发布新版本时只需改 package.json（CHANGELOG 另行记录）。
 */
import pkg from '../../package.json'

/** 占位文案：留空字段在页面上的统一显示口径 */
export const ABOUT_PLACEHOLDER = {
  text: '待补充',
  link: '待配置',
} as const

export interface AboutLink {
  /** 链接名称（zh，品牌/身份标识，通常不译） */
  label: string
  /** 链接名称（en） */
  labelEn?: string
  /** 链接名称（fr） */
  labelFr?: string
  /** 一句话说明这个链接通向哪里（zh） */
  description: string
  /** 一句话说明这个链接通向哪里（en） */
  descriptionEn?: string
  /** 一句话说明这个链接通向哪里（fr） */
  descriptionFr?: string
  /** 目标地址；留空表示尚未配置，页面渲染为占位项 */
  href: string
}

export interface AboutConfig {
  /** 产品全称（品牌，不译） */
  productName: string
  /** 一句话标语（zh） */
  tagline: string
  /** 一句话标语（en） */
  taglineEn?: string
  /** 一句话标语（fr） */
  taglineFr?: string
  /** 项目简介（每段一条，页面按段落渲染，zh） */
  summary: string[]
  /** 项目简介（en） */
  summaryEn?: string[]
  /** 项目简介（fr） */
  summaryFr?: string[]
  /** 版本号：单一事实来源为 package.json */
  version: string
  /** 发布日期，可自由修改；留空则页面显示占位 */
  releaseDate: string
  /** 作者信息：只保留姓名与联系邮箱 */
  author: {
    /** 作者姓名，留空显示占位 */
    name: string
    /** 联系邮箱，留空显示占位 */
    email: string
  }
  /** 许可证 */
  license: string
  /** 技术栈摘要（品牌/专有名词，不译） */
  stack: string[]
  /** 外链列表；前三项为已提供的固定入口，其余留作可配置扩展 */
  links: AboutLink[]
}

export const aboutConfig: AboutConfig = {
  productName: 'AMS · 个人档案管理系统',
  tagline: '把重要的资料，安稳地收在一处。',
  taglineEn: 'Keep your important documents safe in one place.',
  taglineFr: 'Gardez vos documents importants en sécurité, au même endroit.',
  summary: [
    'AMS 是面向个人与家庭的私密数字档案管理平台，把证件、学历、职业、资质、资产、健康、家庭关系与影像附件统一归档，并提供全文检索、标签、版本追溯与精细的共享授权。',
    '敏感字段采用字段级国密 SM4 加密与盲索引，附件逐块加密，预览叠加动态水印；后端使用仓颉（Cangjie），前端使用 Vue 3 与 TypeScript，数据底座为 openGauss。',
  ],
  summaryEn: [
    'AMS is a private digital archive management platform for individuals and families. It unifies IDs, education, career, credentials, assets, health, family relations and media attachments into one archive, with full-text search, tags, version history and fine-grained sharing authorization.',
    'Sensitive fields use field-level SM4 (Chinese national cryptography standard) encryption with blind indexing; attachments are encrypted block by block and previews carry dynamic watermarks. The backend uses Cangjie, the frontend uses Vue 3 with TypeScript, and the data layer is openGauss.',
  ],
  summaryFr: [
    'AMS est une plateforme privée de gestion d’archives numériques pour les particuliers et les familles. Elle réunit pièces d’identité, études, carrière, certifications, patrimoine, santé, relations familiales et pièces jointes multimédias en une seule archive, avec recherche plein texte, étiquettes, historique des versions et autorisation de partage granulaire.',
    'Les champs sensibles utilisent un chiffrement SM4 (norme cryptographique nationale chinoise) au niveau du champ avec indexation à l’aveugle ; les pièces jointes sont chiffrées bloc par bloc et les aperçus portent un filigrane dynamique. Le backend utilise Cangjie, le frontend Vue 3 avec TypeScript, et la couche de données openGauss.',
  ],
  version: pkg.version,
  releaseDate: '2026-11-05',
  author: {
    name: '何宇翔',
    email: 'Lumio_a7032@qq.com',
  },
  license: 'Apache-2.0',
  stack: ['仓颉 Cangjie', 'Vue 3 + TypeScript', 'openGauss', '国密 SM3 / SM4'],
  links: [
    {
      label: 'GitCode',
      labelEn: 'GitCode',
      labelFr: 'GitCode',
      description: '查看源码、提交记录与版本发布',
      descriptionEn: 'View source, commit history and releases',
      descriptionFr: 'Voir le code source, l’historique et les versions',
      href: 'https://gitcode.com/a703201/Personal-Archive-Management-System',
    },
    {
      label: 'GitHub',
      labelEn: 'GitHub',
      labelFr: 'GitHub',
      description: '查看源码、问题反馈与版本发布',
      descriptionEn: 'View source, issue tracking and releases',
      descriptionFr: 'Voir le code source, les issues et les versions',
      href: 'https://github.com/a703201/Personal-Archive-Management-System',
    },
    {
      label: '爱发电',
      labelEn: 'Afdian',
      labelFr: 'Afdian',
      description: '支持项目持续维护',
      descriptionEn: 'Support ongoing maintenance',
      descriptionFr: 'Soutenir la maintenance continue',
      href: 'https://ifdian.net/a/a703201',
    },
    {
      label: '项目文档',
      labelEn: 'Docs',
      labelFr: 'Documentation',
      description: '使用说明与部署指南',
      descriptionEn: 'Usage guide and deployment docs',
      descriptionFr: 'Guide d’utilisation et de déploiement',
      // ↓ 尚未提供文档地址：填入后自动变为可点击链接
      href: '',
    },
    {
      label: '反馈与建议',
      labelEn: 'Feedback',
      labelFr: 'Commentaires',
      description: '问题反馈、功能建议与联系渠道',
      descriptionEn: 'Bug reports, feature suggestions and contact',
      descriptionFr: 'Rapports de bugs, suggestions et contact',
      // ↓ 尚未提供反馈地址：填入后自动变为可点击链接
      href: '',
    },
  ],
}
