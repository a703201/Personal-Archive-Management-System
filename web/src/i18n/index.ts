/**
 * 轻量多语言框架（FR-CFG-009 · 框架预留）
 *
 * 设计取舍：不引入 vue-i18n 依赖，用一组 reactive 的 locale 状态 +
 * 文案目录即可满足「默认 zh-CN、可切换 en、刷新后保持」的框架需求。
 * 后续接入更多语言：在 catalogs 下追加目录并在 supported 登记即可。
 *
 * 用法：
 *   import { t, locale, availableLocales } from '../i18n'
 *   t('login.title')          // 取当前语言的文案
 *   t('common.query', '查询')  // 目录缺键时回退到传入的默认文案
 *   locale.value = 'en'        // 切换语言（自动持久化）
 */
import { ref, watch } from 'vue'

// codemod 自动生成/增量维护的目录（.tmp/i18n_codemod.py 产出，勿手改）
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
  const nav = navigator.language || 'zh-CN'
  return nav.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en'
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
  },
}

// 合并 codemod 生成的目录：**手写基线优先**（后者覆盖前者），
// 生成目录里未翻译的条目是空串，由 t() 负责回退，不会显示空白。
catalogs['zh-CN'] = { ...catalogZh, ...catalogs['zh-CN'] }
catalogs['en'] = { ...catalogEn, ...catalogs['en'] }
catalogs['fr'] = { ...catalogFr, ...catalogs['fr'] }

/** 取文案：目录缺键时回退到 fallback（默认传中文文案），保证不空白。 */
export function t(key: string, fallback?: string): string {
  const dict = catalogs[locale.value] ?? catalogs[defaultLocale]
  // 【关键】空串必须视为「未翻译」：codemod 产出的 en 目录默认全为空串，
  // 若直接返回，界面会大片空白（原实现用 ?? 只判 null/undefined，会踩这个坑）。
  const v = dict[key]
  if (typeof v === 'string' && v.trim() !== '') return v
  if (fallback && fallback.trim() !== '') return fallback
  const base = catalogs[defaultLocale][key]
  if (typeof base === 'string' && base.trim() !== '') return base
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
