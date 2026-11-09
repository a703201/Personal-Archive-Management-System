/**
 * 轻量多语言框架（FR-CFG-009 · 框架预留）
 *
 * 设计取舍：不引入 vue-i18n 依赖，用一组 reactive 的 locale 状态 +
 * 文案目录即可满足「默认 zh-CN、可切换 en / fr、刷新后保持」的框架需求。
 * 后续接入更多语言：在 catalogs 下追加目录并在 supported 登记即可。
 *
 * 【t() 不插值】词条只做静态查表：动态文案一律用 {name} 命名占位符。
 * 调用点传入 vars 时 t() 才替换占位符；未提供 vars（或词条含 ${...} 死译文）时
 * 回退到调用点已插值好的中文 fallback，界面绝不显示 {n} 字面量。
 * 也可在调用点对 t() 的结果自行 .replace('{name}', value)（见 fmtUptime）。
 * 切勿把 JS 模板字符串 ${...} 或 JS 表达式写进词条：它们不会被求值。
 *
 * 用法：
 *   import { t, locale, supported } from '../i18n'
 *   t('login.title')                                      // 取当前语言的文案
 *   t('common.query', '查询')                            // 目录缺键时回退到传入的默认文案
 *   t('msg.deleted', '已删除 {count} 项', { count: 3 }) // {name} + vars 替换
 *   locale.value = 'en'                                  // 切换语言（自动持久化）
 */
import { ref, watch } from 'vue'

// 三语文案目录（codemod 生成；死译文已清理，动态文案统一用 {name} 占位符）
import catalogZh from './catalog.zh-CN'
import catalogEn from './catalog.en'
import catalogFr from './catalog.fr'

export type Locale = 'zh-CN' | 'en' | 'fr'

export const defaultLocale: Locale = 'zh-CN'
export const supported: Locale[] = ['zh-CN', 'en', 'fr']
const STORAGE_KEY = 'ams.locale'

function detectInitial(): Locale {
  const saved = localStorage.getItem(STORAGE_KEY) as Locale | null
  if (saved && (supported as string[]).includes(saved)) return saved
  const nav = (navigator.language || 'zh-CN').toLowerCase()
  if (nav.startsWith('zh')) return 'zh-CN'
  if (nav.startsWith('fr')) return 'fr'
  return 'en'
}

export const locale = ref<Locale>(detectInitial())

// 文案目录：键以「页面/模块.字段」组织，便于规模化扩展。
export const catalogs: Record<Locale, Record<string, string>> = {
  'zh-CN': {
    'app.name': '档案管理',
    'nav.archive': '档案',
    'nav.overview': '概览',
    'nav.import': '导入',
    'nav.tags': '标签',
    'nav.audit': '审计',
    'nav.profile': '个人主页',
    'nav.system': '系统',
    'login.title': '个人档案管理系统',
    'login.subtitle': '请登录以继续',
    'login.submit': '登录',
    'common.query': '查询',
    'common.cancel': '取消',
    'common.save': '保存',
    'archive.title': '档案管理',
    'profile.title': '个人主页',
    'dp.placeholder': '选择日期',
    'dp.dialog': '选择日期',
    'dp.titleYear': '选择年份',
    'dp.prevMonth': '上一月',
    'dp.nextMonth': '下一月',
    'dp.prevYear': '上一年',
    'dp.nextYear': '下一年',
    'dp.today': '今天',
    'dp.clear': '清除',
    'route.overview': '概览',
    'route.notifications': '通知',
    'route.archive': '档案',
    'route.templates': '条目模板',
    'route.family': '家庭协作',
    'route.tags': '标签管理',
    'route.import': '批量导入',
    'route.profile': '个人主页',
    'route.users': '用户管理',
    'route.roles': '角色与权限',
    'route.audit': '审计日志',
    'route.system': '系统运维',
    'route.about': '关于',
    'route.login': '登录',
    'route.register': '注册',
    'route.forgot': '找回口令',
    'route.share': '共享档案',
    'route.invite': '家庭邀请',
    'route.setup': '首次部署',
    'route.notFound': '页面不存在',
    'route.notFoundTitle': '页面不存在',
    'route.notFoundDesc': '你访问的地址不存在，或者内容已被移动。',
    'route.notFoundBack': '返回概览',
    'route.loadFailedTitle': '页面加载失败',
    'route.loadFailedDesc': '资源没有成功载入，通常是网络中断或版本更新导致的，刷新后重试即可。',
    'route.loadFailedRetry': '刷新重试',
    'viewsFamilyView.grantCreatedItem': '已授权（单条条目）',
    'viewsFamilyView.grantCreatedCategory': '已授权（某分类）',
    'viewsFamilyView.grantCreatedSubject': '已授权（整个主体）',
    'about.linkAria': '{label} · {description}（{newWindow}）',
    'viewsArchiveView.batchUnchanged': '；{count} 条未变更（可能无权限或已删除）',
  },
  en: {
    'app.name': 'Archive Manager',
    'nav.archive': 'Archive',
    'nav.overview': 'Overview',
    'nav.import': 'Import',
    'nav.tags': 'Tags',
    'nav.audit': 'Audit',
    'nav.profile': 'Profile',
    'nav.system': 'System',
    'login.title': 'Personal Archive Management',
    'login.subtitle': 'Sign in to continue',
    'login.submit': 'Sign in',
    'common.query': 'Search',
    'common.cancel': 'Cancel',
    'common.save': 'Save',
    'archive.title': 'Archive',
    'profile.title': 'Profile',
    'dp.placeholder': 'Select date',
    'dp.dialog': 'Select date',
    'dp.titleYear': 'Select year',
    'dp.prevMonth': 'Previous month',
    'dp.nextMonth': 'Next month',
    'dp.prevYear': 'Previous year',
    'dp.nextYear': 'Next year',
    'dp.today': 'Today',
    'dp.clear': 'Clear',
    'route.overview': 'Overview',
    'route.notifications': 'Notifications',
    'route.archive': 'Archive',
    'route.templates': 'Item templates',
    'route.family': 'Family collaboration',
    'route.tags': 'Tags',
    'route.import': 'Batch import',
    'route.profile': 'Profile',
    'route.users': 'Users',
    'route.roles': 'Roles & permissions',
    'route.audit': 'Audit log',
    'route.system': 'System',
    'route.about': 'About',
    'route.login': 'Sign in',
    'route.register': 'Sign up',
    'route.forgot': 'Reset passphrase',
    'route.share': 'Shared archive',
    'route.invite': 'Family invitation',
    'route.setup': 'First-time setup',
    'route.notFound': 'Page not found',
    'route.notFoundTitle': 'Page not found',
    'route.notFoundDesc': 'The address you requested does not exist or has been moved.',
    'route.notFoundBack': 'Back to overview',
    'route.loadFailedTitle': 'Page failed to load',
    'route.loadFailedDesc': 'The page resources did not load. This is usually a network interruption or a version update; refresh and try again.',
    'route.loadFailedRetry': 'Refresh',
    'viewsFamilyView.grantCreatedItem': 'Granted (single item)',
    'viewsFamilyView.grantCreatedCategory': 'Granted (category)',
    'viewsFamilyView.grantCreatedSubject': 'Granted (whole subject)',
    'about.linkAria': '{label} · {description} ({newWindow})',
    'viewsArchiveView.batchUnchanged': '; {count} unchanged (possibly no permission or already deleted)',
  },
  fr: {
    'app.name': 'Gestion des archives',
    'nav.archive': 'Archives',
    'nav.overview': 'Vue d’ensemble',
    'nav.import': 'Import',
    'nav.tags': 'Étiquettes',
    'nav.audit': 'Audit',
    'nav.profile': 'Profil',
    'nav.system': 'Système',
    'login.title': 'Gestion des archives personnelles',
    'login.subtitle': 'Connectez-vous pour continuer',
    'login.submit': 'Se connecter',
    'common.query': 'Rechercher',
    'common.cancel': 'Annuler',
    'common.save': 'Enregistrer',
    'archive.title': 'Archives',
    'profile.title': 'Profil',
    'dp.placeholder': 'Choisir une date',
    'dp.dialog': 'Choisir une date',
    'dp.titleYear': 'Choisir une année',
    'dp.prevMonth': 'Mois précédent',
    'dp.nextMonth': 'Mois suivant',
    'dp.prevYear': 'Année précédente',
    'dp.nextYear': 'Année suivante',
    'dp.today': "Aujourd’hui",
    'dp.clear': 'Effacer',
    'route.overview': 'Vue d’ensemble',
    'route.notifications': 'Notifications',
    'route.archive': 'Archives',
    'route.templates': 'Modèles d’éléments',
    'route.family': 'Collaboration familiale',
    'route.tags': 'Étiquettes',
    'route.import': 'Import par lot',
    'route.profile': 'Profil',
    'route.users': 'Utilisateurs',
    'route.roles': 'Rôles et permissions',
    'route.audit': 'Journal d’audit',
    'route.system': 'Système',
    'route.about': 'À propos',
    'route.login': 'Se connecter',
    'route.register': 'S’inscrire',
    'route.forgot': 'Réinitialiser la phrase de passe',
    'route.share': 'Archive partagée',
    'route.invite': 'Invitation familiale',
    'route.setup': 'Première configuration',
    'route.notFound': 'Page introuvable',
    'route.notFoundTitle': 'Page introuvable',
    'route.notFoundDesc': 'L’adresse demandée n’existe pas ou a été déplacée.',
    'route.notFoundBack': 'Retour à la vue d’ensemble',
    'route.loadFailedTitle': 'Échec du chargement',
    'route.loadFailedDesc': 'Les ressources de la page n’ont pas pu être chargées. Vérifiez le réseau ou actualisez après une mise à jour.',
    'route.loadFailedRetry': 'Actualiser',
    'viewsFamilyView.grantCreatedItem': 'Accordé (élément unique)',
    'viewsFamilyView.grantCreatedCategory': 'Accordé (catégorie)',
    'viewsFamilyView.grantCreatedSubject': 'Accordé (sujet entier)',
    'about.linkAria': '{label} · {description} ({newWindow})',
    'viewsArchiveView.batchUnchanged': '; {count} inchangés (accès refusé ou déjà supprimés)',
  },
}

// 合并 codemod 生成的目录：**手写基线优先**（后者覆盖前者）。
// 三语目录键集合保持一致；缺键 / 空串 / 含未替换占位符时统一由 t() 兜底。
catalogs['zh-CN'] = { ...catalogZh, ...catalogs['zh-CN'] }
catalogs['en'] = { ...catalogEn, ...catalogs['en'] }
catalogs['fr'] = { ...catalogFr, ...catalogs['fr'] }

/** 取文案：缺键 / 空串 / 含未替换占位符时回退到 fallback（默认传中文文案），保证不空白。 */
export function t(key: string, fallback?: string, vars?: Record<string, string | number>): string {
  const dict = catalogs[locale.value] ?? catalogs[defaultLocale]
  // 【关键】空串必须视为「未翻译」（原实现用 ?? 只判 null/undefined 会踩坑）。
  const v = dict[key]
  if (typeof v === 'string' && v.trim() !== '') {
    // codemod 曾把 `...${expr}...` 模板字符串原样抽成词条（死译文），浏览器里不求值；
    // 调用点的 fallback 是已插值好的真实文案，优先回退给它。
    if (v.includes('${')) {
      if (fallback && fallback.trim() !== '') return fallback
      return v
    }
    // {name} 命名占位符：只有调用点传入 vars 时才替换。
    if (/\{(\w+)\}/.test(v)) {
      if (vars) {
        return v.replace(/\{(\w+)\}/g, (m, name) =>
          Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : m)
      }
      // 未提供 vars：回退到调用点已插值的中文 fallback，绝不显示 {n} 字面量。
      if (fallback && fallback.trim() !== '') return fallback
    }
    return v
  }
  if (fallback && fallback.trim() !== '') return fallback
  const base = catalogs[defaultLocale][key]
  if (typeof base === 'string' && base.trim() !== '' && !base.includes('${')) return base
  return key
}

export function setLocale(v: Locale): void {
  locale.value = v
}

watch(locale, (v) => {
  localStorage.setItem(STORAGE_KEY, v)
  document.documentElement.setAttribute('lang', v)
})

// 初始化时同步一次 <html lang>
document.documentElement.setAttribute('lang', locale.value)
