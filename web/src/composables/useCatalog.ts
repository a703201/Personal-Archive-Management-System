/**
 * 档案字典（分类 / 状态 / 敏感度 / 来源）。
 *
 * 为什么单独抽出来：
 *   这些中文名先前在 ArchiveView 与 OverviewView 各写了一遍，且已经出现漂移
 *   （分类 2 在一处叫「证件信息」、另一处叫「身份证明」）。同一个编码在
 *   不同页面显示不同名字，用户会以为是两类数据。此处以 docs/06 §12.3 的
 *   分类模板为唯一口径。
 *
 * ⚠️ 与后端一致性：编码区间（1–11）与 `ArchiveCategory` 枚举必须一致；
 *    敏感度默认值只用于「新建表单的初始值」，落库值始终由用户确认。
 *
 * 三语：每个名称都有 zh / en / fr 三份，UI 通过 catName / statusLabel /
 *   sourceLabel / sensitivityLabel 按当前 locale 取值；缺译回退 zh。
 *   旧的导出（categoryName / statusName / sourceName / sensitivityName）
 *   仍返回 zh 基线，供单测断言，请勿在 UI 中继续使用。
 */

import { locale } from '../i18n'

export interface CategoryDef {
  code: number
  name: string
  nameEn: string
  nameFr: string
  /** 该分类的默认敏感度（1 普通 / 2 敏感 / 3 高敏） */
  sensitivity: number
}

/** 按 locale 选取三语文案，缺译回退 zh。 */
function pick(zh: string, en: string, fr: string): string {
  if (locale.value === 'en') return en && en.trim() ? en : zh
  if (locale.value === 'fr') return fr && fr.trim() ? fr : zh
  return zh
}

/** 分类模板（docs/06 §12.3） */
export const CATEGORY_DEFS: CategoryDef[] = [
  { code: 1, name: '个人基本信息', nameEn: 'Personal Info', nameFr: 'Informations personnelles', sensitivity: 1 },
  { code: 2, name: '证件信息', nameEn: 'ID Documents', nameFr: 'Pièces d’identité', sensitivity: 2 },
  { code: 3, name: '教育经历', nameEn: 'Education', nameFr: 'Formation', sensitivity: 1 },
  { code: 4, name: '职业经历', nameEn: 'Career', nameFr: 'Parcours professionnel', sensitivity: 1 },
  { code: 5, name: '资质证书', nameEn: 'Certifications', nameFr: 'Certificats', sensitivity: 1 },
  { code: 6, name: '联系方式', nameEn: 'Contact', nameFr: 'Coordonnées', sensitivity: 2 },
  { code: 7, name: '家庭关系', nameEn: 'Family Relations', nameFr: 'Relations familiales', sensitivity: 2 },
  { code: 8, name: '健康信息', nameEn: 'Health', nameFr: 'Santé', sensitivity: 3 },
  { code: 9, name: '资产信息', nameEn: 'Assets', nameFr: 'Patrimoine', sensitivity: 3 },
  { code: 10, name: '影像附件', nameEn: 'Media Attachments', nameFr: 'Pièces jointes multimédias', sensitivity: 1 },
  { code: 11, name: '自定义分类', nameEn: 'Custom Category', nameFr: 'Catégorie personnalisée', sensitivity: 1 },
]

/** 条目状态（0 草稿 / 1 正常 / 2 已归档 / 3 已删除） */
export const STATUS_DEFS: Array<{ value: number; label: string; labelEn: string; labelFr: string }> = [
  { value: 0, label: '草稿', labelEn: 'Draft', labelFr: 'Brouillon' },
  { value: 1, label: '正常', labelEn: 'Active', labelFr: 'Actif' },
  { value: 2, label: '已归档', labelEn: 'Archived', labelFr: 'Archivé' },
  { value: 3, label: '已删除', labelEn: 'Deleted', labelFr: 'Supprimé' },
]

/** 来源系统（与后端 arc_items.source 一致） */
export const SOURCE_DEFS: Array<{ value: number; label: string; labelEn: string; labelFr: string }> = [
  { value: 0, label: '手动', labelEn: 'Manual', labelFr: 'Manuel' },
  { value: 1, label: 'CSV 导入', labelEn: 'CSV Import', labelFr: 'Import CSV' },
  { value: 2, label: '克隆', labelEn: 'Cloned', labelFr: 'Cloné' },
  { value: 3, label: 'OCR', labelEn: 'OCR', labelFr: 'OCR' },
  { value: 4, label: '附件导入', labelEn: 'Attachment Import', labelFr: 'Import de pièce jointe' },
  { value: 5, label: '导出包回导', labelEn: 'Export Re-import', labelFr: 'Réimportation du paquet' },
]

/** 分类名（locale 感知） */
export function catName(code: number | string): string {
  const c = CATEGORY_DEFS.find((x) => x.code === Number(code))
  if (!c) return pick(`分类 ${code}`, `Category ${code}`, `Catégorie ${code}`)
  return pick(c.name, c.nameEn, c.nameFr)
}

/** 状态名（locale 感知） */
export function statusLabel(v: number | string): string {
  const s = STATUS_DEFS.find((x) => x.value === Number(v))
  return s ? pick(s.label, s.labelEn, s.labelFr) : '—'
}

/** 来源名（locale 感知） */
export function sourceLabel(v: number | string): string {
  const s = SOURCE_DEFS.find((x) => x.value === Number(v))
  return s ? pick(s.label, s.labelEn, s.labelFr) : pick('手动', 'Manual', 'Manuel')
}

/** 敏感度名（locale 感知） */
export function sensitivityLabel(v: number | string): string {
  const n = Number(v)
  if (n >= 3) return pick('高敏', 'High', 'Élevée')
  if (n === 2) return pick('敏感', 'Sensitive', 'Sensible')
  return pick('普通', 'Normal', 'Normal')
}

// —— 以下为 zh 基线兼容导出（供单测断言，UI 请改用上面的 locale 感知 helper）——
export function categoryName(code: number | string): string {
  return CATEGORY_DEFS.find((c) => c.code === Number(code))?.name ?? `分类 ${code}`
}

export function categorySensitivity(code: number | string): number {
  return CATEGORY_DEFS.find((c) => c.code === Number(code))?.sensitivity ?? 1
}

export function statusName(v: number | string): string {
  return STATUS_DEFS.find((s) => s.value === Number(v))?.label ?? '—'
}

export function sensitivityName(v: number | string): string {
  const n = Number(v)
  if (n >= 3) return '高敏'
  if (n === 2) return '敏感'
  return '普通'
}

export function sourceName(v: number | string): string {
  return SOURCE_DEFS.find((s) => s.value === Number(v))?.label ?? '手动'
}

/** 毫秒时间戳 → `YYYY-MM-DD HH:mm`（空值给破折号） */
export function formatTime(ms: number | string | undefined | null): string {
  const n = Number(ms ?? 0)
  if (!n) return '—'
  const d = new Date(n)
  const p = (x: number): string => String(x).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}
