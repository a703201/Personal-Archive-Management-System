<script setup lang="ts">
/**
 * 批量导入（FR-IMP-001 / 002 / 003）。
 *
 * 两条通道共用同一套「预检 → 确认 → 异步任务 → 错误报告」流程：
 *   ① CSV 导入条目：POST /api/import/precheck → /api/import/tasks
 *      请求体就是 CSV 原文（text/csv），主体走 query。
 *   ② ZIP 导入附件：POST /api/import/attachments/precheck → /attachments/tasks
 *      ZIP 内存一级目录名 → 条目标题；重名条目必须由用户手动指定。
 *      确认请求体是自定义封帧：u32le(JSON 长度) + JSON + ZIP
 *      （见后端 routes/importattach.cj 的说明）。
 *
 * 为什么必须两段：预检不落库，把「同名条目」「根目录散文件」这类歧义
 * 提前摊开；否则一步导入会静默挂错条目，而附件挂错后没有撤销。
 */
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, apiBinary, apiBlob } from '../api/client'
import { useToast } from '../composables/useToast'

const { success, error: toastError, info } = useToast()

// ---- 字典（与 docs/06 §12.3 分类模板一致）----
const CATEGORIES = [
  { code: 1, name: '个人基本信息' },
  { code: 2, name: '证件信息' },
  { code: 3, name: '教育经历' },
  { code: 4, name: '职业经历' },
  { code: 5, name: '资质证书' },
  { code: 6, name: '联系方式' },
  { code: 7, name: '家庭关系' },
  { code: 8, name: '健康信息' },
  { code: 9, name: '资产信息' },
  { code: 10, name: '影像附件' },
  { code: 11, name: '自定义分类' },
]

interface SubjectRow {
  id: string
  name: string
  isPrimary: boolean
}

interface TaskRow {
  id: string
  taskNo: string
  type: string
  status: number
  total: number
  done: number
  failed: number
  percent: number
  format: string
  error: string
  createdAt: number
}

interface RowError {
  line: number
  field: string
  message: string
}

interface CsvPlan {
  total: number
  valid: number
  invalid: number
  /** FR-IMP-004：与已有条目重复的行（不是错误，只是已存在） */
  duplicate: number
  duplicates: { line: number; message: string }[]
  duplicatesTruncated: boolean
  errors: RowError[]
  truncated: boolean
}

interface AttachRow {
  i: number
  path: string
  title: string
  file: string
  size: number
  action: string
  itemId: string
  note: string
}

interface Candidate {
  id: string
  title: string
  category: number
}

interface ConflictGroup {
  title: string
  candidates: Candidate[]
}

interface AttachPlan {
  total: number
  match: number
  create: number
  conflict: number
  skip: number
  dirs: number
  bytes: number
  indexTruncated: boolean
  rowsTruncated: boolean
  newTitles: string[]
  conflicts: ConflictGroup[]
  rows: AttachRow[]
}

// ---- 通用状态 ----
const subjects = ref<SubjectRow[]>([])
const subjectId = ref('')
const tab = ref<'csv' | 'zip' | 'bundle'>('zip')
const busy = ref(false)

// ---- CSV ----
const csvText = ref('')
const csvName = ref('')
const csvPlan = ref<CsvPlan | null>(null)

// ---- 导出包回导（FR-EXP-008）----
const bundleText = ref('')
const bundleName = ref('')
const bundlePlan = ref<CsvPlan | null>(null)

// ---- ZIP ----
const zipFile = ref<File | null>(null)
const zipName = ref('')
const zipSize = ref(0)
const zipCategory = ref(3)
const attachPlan = ref<AttachPlan | null>(null)
/** 重名目录 → 目标条目 ID（'0' 表示仍然新建条目） */
const resolutions = ref<Record<string, string>>({})
const unresolvedCount = computed(() => {
  const p = attachPlan.value
  if (!p) return 0
  return p.conflicts.filter((c) => resolutions.value[c.title] === undefined).length
})

// ---- 任务列表 ----
const tasks = ref<TaskRow[]>([])
const taskTotal = ref(0)
const tasksLoading = ref(false)
let timer: number | undefined

const STATUS_TEXT: Record<number, string> = {
  0: '排队中',
  1: '执行中',
  2: '已完成',
  3: '失败',
  4: '已取消',
  5: '已过期',
}

const activeCount = computed(
  () => tasks.value.filter((t) => t.status === 0 || t.status === 1).length,
)

function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(2)} MB`
}

function fmtTime(ms: number): string {
  if (!ms) return '—'
  const d = new Date(Number(ms))
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

const ACTION_TEXT: Record<string, string> = {
  match: '挂到已有条目',
  create: '新建条目',
  conflict: '待指定',
  skip: '跳过',
}

// ---------------------------------------------------------------
// 数据加载
// ---------------------------------------------------------------

async function loadSubjects(): Promise<void> {
  try {
    const data = await api<{ subjects: SubjectRow[] }>('/subjects')
    subjects.value = data.subjects ?? []
    const primary = subjects.value.find((s) => s.isPrimary)
    subjectId.value = primary?.id ?? subjects.value[0]?.id ?? ''
  } catch (e) {
    toastError((e as Error).message)
  }
}

async function loadTasks(): Promise<void> {
  tasksLoading.value = true
  try {
    const data = await api<{ total: number; items: TaskRow[] }>('/import/tasks?page=1&size=20')
    tasks.value = data.items ?? []
    taskTotal.value = Number(data.total) || 0
  } catch {
    /* 轮询失败静默：不打断用户正在进行的导入操作 */
  } finally {
    tasksLoading.value = false
  }
}

onMounted(async () => {
  await loadSubjects()
  await loadTasks()
  await loadTemplates()
  timer = window.setInterval(() => {
    if (activeCount.value > 0) loadTasks()
  }, 1500)
})

onUnmounted(() => {
  if (timer) window.clearInterval(timer)
})

// ---------------------------------------------------------------
// CSV
// ---------------------------------------------------------------

async function pickCsv(ev: Event): Promise<void> {
  const f = (ev.target as HTMLInputElement).files?.[0]
  if (!f) return
  csvName.value = f.name
  csvText.value = await f.text()
  csvPlan.value = null
}

async function downloadTemplate(): Promise<void> {
  try {
    const blob = await apiBlob('/import/template')
    triggerDownload(blob, 'ams-import-template.csv')
  } catch (e) {
    toastError((e as Error).message)
  }
}

async function csvPrecheck(): Promise<void> {
  if (!subjectId.value) { toastError('请先选择主体'); return }
  if (!csvText.value.trim()) { toastError('请先选择 CSV 文件或粘贴内容'); return }
  busy.value = true
  try {
    const qs = withTemplate(new URLSearchParams({ subjectId: subjectId.value }))
    const plan = await apiBinary<CsvPlan>(
      `/import/precheck?${qs.toString()}`,
      new Blob([csvText.value], { type: 'text/csv' }),
      'text/csv; charset=utf-8',
    )
    csvPlan.value = plan
    const dupTip = plan.duplicate > 0 ? `，${plan.duplicate} 行重复将跳过` : ''
    if (plan.invalid === 0) success(`预检通过：${plan.valid} 行可导入${dupTip}`)
    else toastError(`预检发现 ${plan.invalid} 行有问题${dupTip}，详见下方清单`)
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

async function csvSubmit(): Promise<void> {
  if (!csvPlan.value) return
  busy.value = true
  try {
    const qs = withTemplate(new URLSearchParams({ subjectId: subjectId.value }))
    const r = await apiBinary<{ taskNo: string }>(
      `/import/tasks?${qs.toString()}`,
      new Blob([csvText.value], { type: 'text/csv' }),
      'text/csv; charset=utf-8',
    )
    success(`已提交导入任务 ${r.taskNo}`)
    csvPlan.value = null
    csvText.value = ''
    csvName.value = ''
    await loadTasks()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

// ---------------------------------------------------------------
// 导出包回导（FR-EXP-008）
//
// 请求体就是 .amsx.json 原文，不套外层 JSON：
// 套一层会让「文件内容」在传输链路上多一次转义失败的风险。
// 后端先验签（HMAC-SM3）+ 核对 items 段 sha256，失败直接拒绝。
// ---------------------------------------------------------------

async function pickBundle(ev: Event): Promise<void> {
  const f = (ev.target as HTMLInputElement).files?.[0]
  if (!f) return
  bundleName.value = f.name
  bundleText.value = await f.text()
  bundlePlan.value = null
}

async function bundlePrecheck(): Promise<void> {
  if (!subjectId.value) { toastError('请先选择主体'); return }
  if (!bundleText.value.trim()) { toastError('请先选择导出包文件'); return }
  busy.value = true
  try {
    const plan = await apiBinary<CsvPlan>(
      `/import/bundle/precheck?subjectId=${encodeURIComponent(subjectId.value)}`,
      new Blob([bundleText.value], { type: 'application/json' }),
      'application/json',
    )
    bundlePlan.value = plan
    const dupTip = plan.duplicate > 0 ? `，${plan.duplicate} 行重复将跳过` : ''
    if (plan.invalid === 0) success(`验签通过：${plan.valid} 行可回导${dupTip}`)
    else toastError(`验签通过，但有 ${plan.invalid} 行有问题${dupTip}`)
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

async function bundleSubmit(): Promise<void> {
  if (!bundlePlan.value) return
  busy.value = true
  try {
    const r = await apiBinary<{ taskNo: string }>(
      `/import/bundle?subjectId=${encodeURIComponent(subjectId.value)}`,
      new Blob([bundleText.value], { type: 'application/json' }),
      'application/json',
    )
    success(`已提交回导任务 ${r.taskNo}`)
    bundlePlan.value = null
    bundleText.value = ''
    bundleName.value = ''
    await loadTasks()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

// ---------------------------------------------------------------
// ZIP 附件
// ---------------------------------------------------------------

/**
 * 单个压缩包上限（字节）。
 *
 * 与后端 `api.http` 的 `MAX_LARGE_BODY_BYTES`（64 MiB）保持一致：
 * 请求体在鉴权之前就被读入内存，故这两个入口（附件 / 批量导入）
 * 单独放宽到 64 MiB，其余接口仍是 1 MiB。
 *
 * 这里先在浏览器侧拦一道：超限的包传到后端只会拿到 413，
 * 用户白等一次上传（预检的意义就是别让人白等）。
 */
const MAX_ZIP_BYTES = 64 * 1024 * 1024

async function pickZip(ev: Event): Promise<void> {
  const input = ev.target as HTMLInputElement
  const f = input.files?.[0]
  if (!f) return
  if (f.size > MAX_ZIP_BYTES) {
    toastError(`压缩包 ${fmtSize(f.size)}，超过单包 ${fmtSize(MAX_ZIP_BYTES)} 上限，请拆分后分批导入`)
    input.value = ''
    zipFile.value = null
    zipName.value = ''
    zipSize.value = 0
    attachPlan.value = null
    resolutions.value = {}
    return
  }
  zipFile.value = f
  zipName.value = f.name
  zipSize.value = f.size
  attachPlan.value = null
  resolutions.value = {}
}

async function zipPrecheck(): Promise<void> {
  if (!subjectId.value) { toastError('请先选择主体'); return }
  const f = zipFile.value
  if (!f) { toastError('请先选择 ZIP 文件'); return }
  busy.value = true
  try {
    const qs = new URLSearchParams({
      subjectId: subjectId.value,
      category: String(zipCategory.value),
    })
    const plan = await apiBinary<AttachPlan>(
      `/import/attachments/precheck?${qs.toString()}`,
      f,
      'application/zip',
    )
    attachPlan.value = plan
    resolutions.value = {}
    if (plan.conflicts.length > 0) {
      info(`有 ${plan.conflicts.length} 个目录重名，需手动指定目标条目`)
    } else {
      success(`预检完成：${plan.match + plan.create} 个文件待导入`)
    }
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

/** 组装封帧请求体：u32le(JSON 长度) + JSON + ZIP */
function frameBody(json: unknown, zip: ArrayBuffer): Blob {
  const jsonBytes = new TextEncoder().encode(JSON.stringify(json))
  const head = new Uint8Array(4)
  new DataView(head.buffer).setUint32(0, jsonBytes.length, true)
  return new Blob([head, jsonBytes, new Uint8Array(zip)], {
    type: 'application/octet-stream',
  })
}

async function zipSubmit(): Promise<void> {
  const f = zipFile.value
  const plan = attachPlan.value
  if (!f || !plan) return
  if (unresolvedCount.value > 0) {
    { toastError(`还有 ${unresolvedCount.value} 个重名目录未指定目标条目`); return }
  }
  busy.value = true
  try {
    const payload: Record<string, unknown> = {
      subjectId: subjectId.value,
      category: zipCategory.value,
    }
    for (const [title, id] of Object.entries(resolutions.value)) {
      payload[`r.${title}`] = id
    }
    const r = await apiBinary<{ taskNo: string }>(
      '/import/attachments/tasks',
      frameBody(payload, await f.arrayBuffer()),
      'application/octet-stream',
    )
    success(`已提交附件导入任务 ${r.taskNo}`)
    attachPlan.value = null
    zipFile.value = null
    zipName.value = ''
    zipSize.value = 0
    resolutions.value = {}
    await loadTasks()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

// ---------------------------------------------------------------
// 任务
// ---------------------------------------------------------------

async function downloadReport(t: TaskRow): Promise<void> {
  try {
    const blob = await apiBlob(`/import/tasks/${encodeURIComponent(t.taskNo)}/report`)
    triggerDownload(blob, `导入报告-${t.taskNo}.csv`)
  } catch (e) {
    toastError((e as Error).message)
  }
}

/**
 * 重试失败项：不再上传压缩包，服务端留了原始包与失败序号清单。
 * 只重跑上次标记为 failed 的文件（跳过类不算 —— 那是规则拒绝，重试也没用）。
 */
async function retryTask(t: TaskRow): Promise<void> {
  busy.value = true
  try {
    const r = await api<{ taskNo: string; total: number }>(
      `/import/attachments/tasks/${encodeURIComponent(t.taskNo)}/retry`,
      { method: 'POST' },
    )
    success(`已提交重试任务 ${r.taskNo}（${r.total} 个文件）`)
    await loadTasks()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

async function cancelTask(t: TaskRow): Promise<void> {
  try {
    await api(`/import/tasks/${encodeURIComponent(t.taskNo)}/cancel`, { method: 'POST' })
    info('已请求取消')
    await loadTasks()
  } catch (e) {
    toastError((e as Error).message)
  }
}

function triggerDownload(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.click()
  URL.revokeObjectURL(url)
}

// ---------------------------------------------------------------
// 导入模板（FR-IMP-005 · 方案 C）
//
// 让用户把「CSV 表头 → 字段键」的映射 + 系统字段默认值保存为命名模板，
// 下次导入直接套用，免去每次重排列位。
//   GET    /api/import-templates           列出本人的全部模板
//   POST   /api/import-templates           新建
//   PUT    /api/import-templates/:id       更新（覆盖式）
//   DELETE /api/import-templates/:id       删除
// 预检 / 提交时把 templateId 透传进 query，后端据此加载 mapping / defaults。
// ---------------------------------------------------------------

interface ImportTemplate {
  id: string
  name: string
  mapping: Record<string, string>
  defaults: Record<string, string>
  createdAt: number
  updatedAt: number
}

interface FieldDefLite {
  key: string
  name: string
}

/** 系统字段（固定列序那 9 列），自定义字段键从字段定义域接口按分类拉取。 */
const SYSTEM_FIELDS: { key: string; name: string }[] = [
  { key: 'subject_id', name: '主体ID' },
  { key: 'category', name: '分类' },
  { key: 'title', name: '标题' },
  { key: 'status', name: '状态' },
  { key: 'sensitivity', name: '敏感度' },
  { key: 'issued_date', name: '签发日期' },
  { key: 'expires_at', name: '失效日期' },
  { key: 'issuer', name: '签发机构' },
  { key: 'remark', name: '备注' },
]

const SKIP = '__skip__'

const templates = ref<ImportTemplate[]>([])
const activeTemplateId = ref('')
const tplBusy = ref(false)

// 映射编辑器
const showMapper = ref(false)
const csvHeaders = ref<string[]>([])
const headerField = ref<Record<string, string>>({})
const refCategory = ref(3)
const refFieldDefs = ref<FieldDefLite[]>([])
const tplName = ref('')
const tplDefaultSubject = ref('')
const tplDefaultCategory = ref('')
const tplDefaultStatus = ref('')
const tplDefaultSensitivity = ref('')

const activeTemplate = computed(
  () => templates.value.find((t) => String(t.id) === activeTemplateId.value) ?? null,
)

/** 当前生效的目标字段选项：系统字段 + 参考分类下的自定义字段定义。 */
const fieldOptions = computed<{ key: string; name: string }[]>(() => {
  const opts = [...SYSTEM_FIELDS]
  for (const f of refFieldDefs.value) {
    if (!opts.some((o) => o.key === f.key)) opts.push(f)
  }
  return opts
})

async function loadTemplates(): Promise<void> {
  try {
    const data = await api<{ templates: ImportTemplate[] }>('/import-templates')
    templates.value = data.templates ?? []
  } catch (e) {
    toastError((e as Error).message)
  }
}

async function applyTemplate(id: string): Promise<void> {
  const t = templates.value.find((x) => String(x.id) === id)
  if (!t) return
  activeTemplateId.value = id
  csvHeaders.value = Object.keys(t.mapping)
  headerField.value = { ...t.mapping }
  tplName.value = t.name
  tplDefaultSubject.value = t.defaults.subject_id ?? ''
  tplDefaultCategory.value = t.defaults.category ?? ''
  tplDefaultStatus.value = t.defaults.status ?? ''
  tplDefaultSensitivity.value = t.defaults.sensitivity ?? ''
  success(`已套用模板「${t.name}」`)
}

async function deleteTemplate(id: string): Promise<void> {
  if (!window.confirm('确认删除该导入模板？删除后不可恢复。')) return
  try {
    await api(`/import-templates/${id}`, { method: 'DELETE' })
    templates.value = templates.value.filter((x) => String(x.id) !== id)
    if (activeTemplateId.value === id) activeTemplateId.value = ''
    success('已删除模板')
  } catch (e) {
    toastError((e as Error).message)
  }
}

function parseCsvHeaders(): void {
  const text = csvText.value.trim()
  if (!text) {
    csvHeaders.value = []
    return
  }
  const firstLine = text.split(/\r?\n/)[0] ?? ''
  csvHeaders.value = firstLine
    .split(',')
    .map((h) => h.trim())
    .filter((h) => h.length > 0)
}

async function refreshRefFieldDefs(): Promise<void> {
  try {
    const res = await api<{ fields: FieldDefLite[] }>(
      `/field-defs?category=${refCategory.value}`,
    )
    refFieldDefs.value = res.fields ?? []
  } catch {
    refFieldDefs.value = []
  }
}

/** 打开映射编辑器：先读 CSV 表头，未映射的列默认「不导入」。 */
function openMapper(): void {
  parseCsvHeaders()
  if (csvHeaders.value.length === 0) {
    toastError('请先选择 CSV 文件以读取表头')
    return
  }
  const m: Record<string, string> = {}
  for (const h of csvHeaders.value) {
    m[h] = headerField.value[h] ?? (activeTemplate.value?.mapping[h] ?? SKIP)
  }
  headerField.value = m
  showMapper.value = true
  void refreshRefFieldDefs()
}

function buildMapping(): Record<string, string> {
  const map: Record<string, string> = {}
  for (const [h, f] of Object.entries(headerField.value)) {
    if (f && f !== SKIP) map[h] = f
  }
  return map
}

function buildDefaults(): Record<string, string> {
  const d: Record<string, string> = {}
  if (tplDefaultSubject.value.trim()) d.subject_id = tplDefaultSubject.value.trim()
  if (tplDefaultCategory.value.trim()) d.category = tplDefaultCategory.value.trim()
  if (tplDefaultStatus.value.trim()) d.status = tplDefaultStatus.value.trim()
  if (tplDefaultSensitivity.value.trim()) d.sensitivity = tplDefaultSensitivity.value.trim()
  return d
}

async function saveTemplate(): Promise<void> {
  if (!tplName.value.trim()) {
    toastError('请填写模板名称')
    return
  }
  const mapping = buildMapping()
  if (Object.keys(mapping).length === 0) {
    toastError('请至少为一个表头选择目标字段')
    return
  }
  tplBusy.value = true
  try {
    if (activeTemplateId.value) {
      await api(`/import-templates/${activeTemplateId.value}`, {
        method: 'PUT',
        body: { name: tplName.value.trim(), mapping, defaults: buildDefaults() },
      })
      success('模板已更新')
    } else {
      const r = await api<{ id: string }>('/import-templates', {
        method: 'POST',
        body: { name: tplName.value.trim(), mapping, defaults: buildDefaults() },
      })
      activeTemplateId.value = String(r.id)
      success('模板已保存')
    }
    await loadTemplates()
    showMapper.value = false
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    tplBusy.value = false
  }
}

/** 把当前生效的模板 id 追加进预检 / 提交的 query。 */
function withTemplate(qs: URLSearchParams): URLSearchParams {
  if (activeTemplateId.value) qs.set('templateId', activeTemplateId.value)
  return qs
}

// 改名（内联）
const renaming = ref(false)
const renameText = ref('')

function startRename(): void {
  if (!activeTemplate.value) return
  renaming.value = true
  renameText.value = activeTemplate.value.name
}

/**
 * 改名：用既有映射 / 默认值 + 新名称做一次覆盖式 PUT。
 * 不必打开映射编辑器即可改名称。
 */
async function renameTemplate(newName: string): Promise<void> {
  const t = activeTemplate.value
  if (!t) return
  const n = newName.trim()
  if (!n) {
    toastError('名称不能为空')
    return
  }
  tplBusy.value = true
  try {
    await api(`/import-templates/${t.id}`, {
      method: 'PUT',
      body: { name: n, mapping: t.mapping, defaults: t.defaults },
    })
    renaming.value = false
    await loadTemplates()
    success('已改名')
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    tplBusy.value = false
  }
}

/** 复制：以当前模板为蓝本新建一份（名称默认为「原名 副本」）。 */
async function cloneTemplate(): Promise<void> {
  const t = activeTemplate.value
  if (!t) return
  tplBusy.value = true
  try {
    const r = await api<{ id: string }>('/import-templates', {
      method: 'POST',
      body: { cloneFrom: Number(t.id), name: `${t.name} 副本` },
    })
    await loadTemplates()
    activeTemplateId.value = String(r.id)
    success('已复制为副本')
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    tplBusy.value = false
  }
}
</script>

<template>
  <section>
    <div class="page-head">
      <div>
        <h1 class="page-title">批量导入</h1>
        <p class="page-sub">
          先预检、确认后再落库。附件包按「一级目录名 = 条目名」映射，重名条目需手动指定。
        </p>
      </div>
      <div class="seg" role="tablist">
        <button
          class="seg__btn"
          :class="{ 'seg__btn--on': tab === 'zip' }"
          role="tab"
          @click="tab = 'zip'"
        >
          附件包（ZIP）
        </button>
        <button
          class="seg__btn"
          :class="{ 'seg__btn--on': tab === 'csv' }"
          role="tab"
          @click="tab = 'csv'"
        >
          条目表（CSV）
        </button>
        <button
          class="seg__btn"
          :class="{ 'seg__btn--on': tab === 'bundle' }"
          role="tab"
          @click="tab = 'bundle'"
        >
          导出包回导
        </button>
      </div>
    </div>

    <div class="card form">
      <label class="field">
        <span class="field__label">目标主体</span>
        <select v-model="subjectId" class="field-control">
          <option v-for="s in subjects" :key="s.id" :value="s.id">
            {{ s.name }}{{ s.isPrimary ? '（本人）' : '' }}
          </option>
        </select>
      </label>
      <label v-if="tab === 'zip'" class="field">
        <span class="field__label">新建条目的分类</span>
        <select v-model.number="zipCategory" class="field-control">
          <option v-for="c in CATEGORIES" :key="c.code" :value="c.code">{{ c.name }}</option>
        </select>
      </label>
    </div>

    <!-- ---------------- ZIP ---------------- -->
    <template v-if="tab === 'zip'">
      <div class="card block">
        <h2 class="block__title">① 选择压缩包</h2>
        <p class="hint">
          包内请按 <code>条目名/文件.jpg</code> 组织。支持 jpg/jpeg/png/pdf，单文件 ≤ 50MB，
          单个压缩包 ≤ 64MB（超出请拆分成多个包分批导入）；
          文件名需为 UTF-8 或 GBK（7-Zip、macOS、Windows 资源管理器均可）。
        </p>
        <div class="picker">
          <input
            id="zipfile"
            type="file"
            accept=".zip,application/zip"
            class="picker__input"
            @change="pickZip"
          />
          <label for="zipfile" class="btn-primary picker__btn">选择 ZIP 文件</label>
          <span v-if="zipName" class="picker__name">
            {{ zipName }} · {{ fmtSize(zipSize) }}
          </span>
          <span v-else class="hint">尚未选择</span>
        </div>
        <div class="actions">
          <button class="btn-primary" :disabled="busy || !zipFile" @click="zipPrecheck">
            {{ busy ? '解析中…' : '预检并查看映射' }}
          </button>
        </div>
      </div>

      <template v-if="attachPlan">
        <div class="card block">
          <h2 class="block__title">② 映射预览（尚未写入任何数据）</h2>
          <div class="stats">
            <div class="stat">
              <span class="stat__n">{{ attachPlan.total }}</span>
              <span class="stat__k">文件</span>
            </div>
            <div class="stat stat--ok">
              <span class="stat__n">{{ attachPlan.match }}</span>
              <span class="stat__k">挂已有条目</span>
            </div>
            <div class="stat stat--new">
              <span class="stat__n">{{ attachPlan.create }}</span>
              <span class="stat__k">将新建条目</span>
            </div>
            <div class="stat stat--warn">
              <span class="stat__n">{{ attachPlan.conflict }}</span>
              <span class="stat__k">重名待指定</span>
            </div>
            <div class="stat stat--muted">
              <span class="stat__n">{{ attachPlan.skip }}</span>
              <span class="stat__k">跳过</span>
            </div>
            <div class="stat">
              <span class="stat__n">{{ attachPlan.dirs }}</span>
              <span class="stat__k">涉及条目</span>
            </div>
          </div>
          <p class="hint">合计 {{ fmtSize(attachPlan.bytes) }}；跳过项不会写入数据库。</p>

          <div v-if="attachPlan.newTitles.length" class="tagline">
            <span class="tag tag--new">将新建</span>
            <span v-for="t in attachPlan.newTitles" :key="t" class="tag">{{ t }}</span>
          </div>

          <table class="tbl">
            <thead>
              <tr>
                <th>#</th>
                <th>包内路径</th>
                <th>目标条目</th>
                <th>动作</th>
                <th>说明</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in attachPlan.rows" :key="r.i">
                <td class="mono">{{ r.i }}</td>
                <td class="path">{{ r.path }}</td>
                <td>{{ r.title || '—' }}</td>
                <td>
                  <span class="tag" :class="`tag--${r.action}`">{{ ACTION_TEXT[r.action] || r.action }}</span>
                </td>
                <td class="note">{{ r.note || (r.itemId !== '0' ? `→ ${r.itemId}` : '') }}</td>
              </tr>
            </tbody>
          </table>
          <p v-if="attachPlan.rowsTruncated" class="hint">
            仅显示前 {{ attachPlan.rows.length }} 行（导入时会处理全部文件）。
          </p>
          <p v-if="attachPlan.indexTruncated" class="hint hint--error">
            该主体条目过多，标题匹配可能不完整，请确认新建条目是否重复。
          </p>
        </div>

        <div v-if="attachPlan.conflicts.length" class="card block">
          <h2 class="block__title">③ 指定重名目录的目标条目</h2>
          <p class="hint">
            下列目录名在库中存在多个同名条目，系统不做猜测，请逐个指定；
            选择「新建条目」则会再建一个同名条目。
          </p>
          <div v-for="c in attachPlan.conflicts" :key="c.title" class="conflict">
            <div class="conflict__title">{{ c.title }}</div>
            <select v-model="resolutions[c.title]" class="field-control">
              <option :value="undefined" disabled>请选择…</option>
              <option value="0">新建条目</option>
              <option v-for="k in c.candidates" :key="k.id" :value="k.id">
                {{ k.title }} · #{{ k.id }}
              </option>
            </select>
          </div>
        </div>

        <div class="card block">
          <h2 class="block__title">④ 确认导入</h2>
          <p class="hint">
            确认后才会建条目、写附件。执行是异步的，可在下方任务列表看进度与错误报告。
          </p>
          <div class="actions">
            <button
              class="btn-primary"
              :disabled="busy || unresolvedCount > 0"
              @click="zipSubmit"
            >
              {{ busy ? '提交中…' : '确认导入' }}
            </button>
            <span v-if="unresolvedCount > 0" class="hint hint--error">
              还有 {{ unresolvedCount }} 个重名目录未指定
            </span>
          </div>
        </div>
      </template>
    </template>

    <!-- ---------------- CSV ---------------- -->
    <template v-else-if="tab === 'csv'">
      <!-- 导入模板（FR-IMP-005）：保存/套用「CSV 表头 → 字段键」映射 -->
      <div class="card block">
        <div class="block__head">
          <h2 class="block__title">导入模板</h2>
          <button class="btn-ghost" type="button" :disabled="busy || tplBusy" @click="openMapper">
            {{ activeTemplate ? '编辑当前映射' : '新建模板' }}
          </button>
        </div>
        <p class="hint">
          把「CSV 表头 → 字段键」的映射与系统字段默认值存为命名模板，下次导入直接套用，免去每次重排列位。
        </p>
        <div class="tpl-bar">
          <select v-model="activeTemplateId" class="field-control" @change="applyTemplate(activeTemplateId)">
            <option value="">— 不使用模板（固定列序）—</option>
            <option v-for="t in templates" :key="t.id" :value="String(t.id)">{{ t.name }}</option>
          </select>
          <button
            v-if="activeTemplate"
            class="btn-text"
            type="button"
            :disabled="tplBusy"
            @click="cloneTemplate"
          >
            复制
          </button>
          <button
            v-if="activeTemplate"
            class="btn-text"
            type="button"
            :disabled="tplBusy"
            @click="startRename"
          >
            改名
          </button>
          <button
            v-if="activeTemplate"
            class="btn-text"
            type="button"
            :disabled="busy"
            @click="deleteTemplate(activeTemplate.id)"
          >
            删除
          </button>
        </div>
        <div v-if="activeTemplate" class="tpl-applied">
          <template v-if="renaming">
            <input
              v-model="renameText"
              class="field-control"
              style="max-width: 240px"
              @keyup.enter="renameTemplate(renameText)"
            />
            <button class="btn-primary" type="button" :disabled="tplBusy" @click="renameTemplate(renameText)">
              确认
            </button>
            <button class="btn-ghost" type="button" :disabled="tplBusy" @click="renaming = false">
              取消
            </button>
          </template>
          <template v-else>
            <span class="tag tag--match">已套用「{{ activeTemplate.name }}」</span>
            <span class="hint">
              映射 {{ Object.keys(activeTemplate.mapping).length }} 个字段；
              预检与提交将按此模板解析（不再要求固定列序）。
            </span>
          </template>
        </div>
      </div>

      <!-- 映射编辑器（新建 / 编辑） -->
      <template v-if="showMapper">
        <div class="card block">
          <h2 class="block__title">① 设置表头映射</h2>
          <p class="hint">
            为每个 CSV 表头选择目标字段。系统字段固定；自定义字段请从下方「参考分类」加载对应分类的字段定义。
          </p>
          <table class="tbl">
            <thead>
              <tr>
                <th>CSV 表头</th>
                <th>目标字段</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="h in csvHeaders" :key="h">
                <td class="mono">{{ h }}</td>
                <td>
                  <select v-model="headerField[h]" class="field-control">
                    <option :value="SKIP">（不导入）</option>
                    <option v-for="o in fieldOptions" :key="o.key" :value="o.key">
                      {{ o.name }}（{{ o.key }}）
                    </option>
                  </select>
                </td>
              </tr>
            </tbody>
          </table>

          <h3 class="block__title">参考分类（用于加载自定义字段）</h3>
          <label class="field" style="max-width: 240px">
            <span class="field__label">分类</span>
            <select v-model.number="refCategory" class="field-control" @change="refreshRefFieldDefs">
              <option v-for="c in CATEGORIES" :key="c.code" :value="c.code">{{ c.name }}</option>
            </select>
          </label>

          <h3 class="block__title">系统字段默认值（CSV 缺列时回落）</h3>
          <div class="defaults">
            <label class="field">
              <span class="field__label">subject_id</span>
              <input v-model="tplDefaultSubject" class="field-control" placeholder="如 100" />
            </label>
            <label class="field">
              <span class="field__label">category</span>
              <input v-model="tplDefaultCategory" class="field-control" placeholder="如 3" />
            </label>
            <label class="field">
              <span class="field__label">status</span>
              <input v-model="tplDefaultStatus" class="field-control" placeholder="如 0" />
            </label>
            <label class="field">
              <span class="field__label">sensitivity</span>
              <input v-model="tplDefaultSensitivity" class="field-control" placeholder="如 1" />
            </label>
          </div>

          <label class="field" style="max-width: 360px">
            <span class="field__label">模板名称</span>
            <input v-model="tplName" class="field-control" placeholder="给这套映射起个名字" />
          </label>

          <div class="actions">
            <button class="btn-primary" :disabled="tplBusy" @click="saveTemplate">
              {{ tplBusy ? '保存中…' : (activeTemplate ? '更新模板' : '保存模板') }}
            </button>
            <button class="btn-ghost" type="button" :disabled="tplBusy" @click="showMapper = false">
              取消
            </button>
          </div>
        </div>
      </template>

      <div class="card block">
        <h2 class="block__title">② 选择 CSV 文件</h2>
        <p class="hint">
          <template v-if="activeTemplate">
            已套用模板「{{ activeTemplate.name }}」——表头由模板映射决定，无需固定列序。
            <button class="btn-text" type="button" @click="openMapper">查看 / 调整映射</button>
          </template>
          <template v-else>
            未套用模板时，表头固定为
            <code>subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark</code>。
          </template>
          <button class="btn-text" type="button" @click="downloadTemplate">下载空模板</button>
        </p>
        <div class="picker">
          <input
            id="csvfile"
            type="file"
            accept=".csv,text/csv"
            class="picker__input"
            @change="pickCsv"
          />
          <label for="csvfile" class="btn-primary picker__btn">选择 CSV 文件</label>
          <span v-if="csvName" class="picker__name">{{ csvName }}</span>
          <span v-else class="hint">尚未选择</span>
        </div>
        <div class="actions">
          <button class="btn-primary" :disabled="busy || !csvText" @click="csvPrecheck">
            {{ busy ? '校验中…' : '预检（只校验不落库）' }}
          </button>
        </div>
      </div>

      <div v-if="csvPlan" class="card block">
        <h2 class="block__title">③ 预检结果</h2>
        <div class="stats">
          <div class="stat">
            <span class="stat__n">{{ csvPlan.total }}</span>
            <span class="stat__k">数据行</span>
          </div>
          <div class="stat stat--ok">
            <span class="stat__n">{{ csvPlan.valid }}</span>
            <span class="stat__k">可导入</span>
          </div>
          <div class="stat stat--warn">
            <span class="stat__n">{{ csvPlan.invalid }}</span>
            <span class="stat__k">有问题</span>
          </div>
          <div class="stat stat--muted">
            <span class="stat__n">{{ csvPlan.duplicate }}</span>
            <span class="stat__k">重复跳过</span>
          </div>
        </div>
        <table v-if="csvPlan.errors.length" class="tbl">
          <thead>
            <tr>
              <th>行号</th>
              <th>字段</th>
              <th>问题</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(e, i) in csvPlan.errors" :key="i">
              <td class="mono">{{ e.line }}</td>
              <td class="mono">{{ e.field }}</td>
              <td>{{ e.message }}</td>
            </tr>
          </tbody>
        </table>
        <p v-if="csvPlan.truncated" class="hint">仅显示前 50 条错误，完整清单见任务报告。</p>

        <!-- FR-IMP-004：重复行清单（同主体 + 同标题已存在） -->
        <template v-if="csvPlan.duplicates.length">
          <h3 class="block__title">重复行（已存在，将跳过）</h3>
          <table class="tbl">
            <thead>
              <tr>
                <th>行号</th>
                <th>说明</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(d, i) in csvPlan.duplicates" :key="i">
                <td class="mono">{{ d.line }}</td>
                <td>{{ d.message }}</td>
              </tr>
            </tbody>
          </table>
          <p v-if="csvPlan.duplicatesTruncated" class="hint">
            仅显示前 50 条重复，其余同样会被跳过。
          </p>
        </template>

        <div class="actions">
          <button class="btn-primary" :disabled="busy || csvPlan.valid === 0" @click="csvSubmit">
            {{ busy ? '提交中…' : `确认导入 ${csvPlan.valid} 行` }}
          </button>
          <span v-if="csvPlan.duplicate > 0" class="hint">
            另有 {{ csvPlan.duplicate }} 行重复，不会重复建条目。
          </span>
        </div>
      </div>
    </template>

    <!-- ---------------- 导出包回导（FR-EXP-008）---------------- -->
    <template v-else>
      <div class="card block">
        <h2 class="block__title">① 选择导出包</h2>
        <p class="hint">
          导出包为 <code>.amsx.json</code> 单文件（由「导出」生成的可携带包）。
          回导前会先校验 <strong>签名（HMAC-SM3）</strong>与
          <strong>items 段 sha256 指纹</strong>，任一不匹配即拒绝导入 ——
          被篡改过的包一个字节都不会落库。
        </p>
        <div class="picker">
          <input
            id="bundlefile"
            type="file"
            accept=".json,.amsx.json,application/json"
            class="picker__input"
            @change="pickBundle"
          />
          <label for="bundlefile" class="btn-primary picker__btn">选择导出包</label>
          <span v-if="bundleName" class="picker__name">{{ bundleName }}</span>
          <span v-else class="hint">尚未选择</span>
        </div>
        <div class="actions">
          <button class="btn-primary" :disabled="busy || !bundleText" @click="bundlePrecheck">
            {{ busy ? '校验中…' : '验签并预检' }}
          </button>
        </div>
      </div>

      <div v-if="bundlePlan" class="card block">
        <h2 class="block__title">② 回导预检结果（签名与指纹已通过）</h2>
        <div class="stats">
          <div class="stat">
            <span class="stat__n">{{ bundlePlan.total }}</span>
            <span class="stat__k">条目</span>
          </div>
          <div class="stat stat--ok">
            <span class="stat__n">{{ bundlePlan.valid }}</span>
            <span class="stat__k">可回导</span>
          </div>
          <div class="stat stat--warn">
            <span class="stat__n">{{ bundlePlan.invalid }}</span>
            <span class="stat__k">有问题</span>
          </div>
          <div class="stat stat--muted">
            <span class="stat__n">{{ bundlePlan.duplicate }}</span>
            <span class="stat__k">重复跳过</span>
          </div>
        </div>
        <table v-if="bundlePlan.errors.length" class="tbl">
          <thead>
            <tr>
              <th>#</th>
              <th>字段</th>
              <th>问题</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(e, i) in bundlePlan.errors" :key="i">
              <td class="mono">{{ e.line }}</td>
              <td class="mono">{{ e.field }}</td>
              <td>{{ e.message }}</td>
            </tr>
          </tbody>
        </table>
        <div class="actions">
          <button
            class="btn-primary"
            :disabled="busy || bundlePlan.valid === 0"
            @click="bundleSubmit"
          >
            {{ busy ? '提交中…' : `确认回导 ${bundlePlan.valid} 条` }}
          </button>
          <span class="hint">包内主体若不在你的可写范围，将统一落到上方选择的「目标主体」。</span>
        </div>
      </div>
    </template>

    <!-- ---------------- 任务列表 ---------------- -->
    <div class="card block">
      <div class="block__head">
        <h2 class="block__title">导入任务</h2>
        <button class="btn-ghost" type="button" :disabled="tasksLoading" @click="loadTasks">
          刷新
        </button>
      </div>
      <div v-if="!tasks.length" class="empty">还没有导入任务。</div>
      <table v-else class="tbl">
        <thead>
          <tr>
            <th>任务号</th>
            <th>类型</th>
            <th>状态</th>
            <th>进度</th>
            <th>成功 / 失败</th>
            <th>创建时间</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="t in tasks" :key="t.id">
            <td class="mono">{{ t.taskNo }}</td>
            <td>
              {{ t.format === 'zip-attach' ? '附件包' : t.format === 'bundle' ? '导出包' : '条目表' }}
            </td>
            <td>
              <span class="tag" :class="`st--${t.status}`">{{ STATUS_TEXT[t.status] || t.status }}</span>
            </td>
            <td class="prog">
              <div class="bar"><i :style="{ width: `${t.percent}%` }"></i></div>
              <span class="mono">{{ t.percent }}%</span>
            </td>
            <td class="mono">{{ t.done }} / {{ t.failed }}</td>
            <td class="mono">{{ fmtTime(t.createdAt) }}</td>
            <td class="row-actions">
              <button
                v-if="t.status === 2"
                class="btn-text"
                type="button"
                @click="downloadReport(t)"
              >
                报告
              </button>
              <button
                v-if="t.status === 2 && t.format === 'zip-attach' && t.failed > 0"
                class="btn-text"
                type="button"
                :disabled="busy"
                @click="retryTask(t)"
              >
                重试失败项
              </button>
              <button
                v-if="t.status === 0 || t.status === 1"
                class="btn-text"
                type="button"
                @click="cancelTask(t)"
              >
                取消
              </button>
              <span v-if="t.status === 3" class="err" :title="t.error">{{ t.error }}</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="taskTotal > tasks.length" class="hint">共 {{ taskTotal }} 个任务，显示最近 {{ tasks.length }} 个。</p>
    </div>
  </section>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  flex-wrap: wrap;
}
.page-title {
  font-size: var(--font-size-xl);
  margin: 0;
}
.page-sub {
  margin: 4px 0 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin: 0 0 var(--sp-2);
}
.hint--error {
  color: var(--danger);
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}
code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
  background: var(--bg-hover);
  padding: 1px 5px;
  border-radius: var(--radius-sm);
}

/* 分段控件 */
.seg {
  display: inline-flex;
  padding: 3px;
  gap: 3px;
  background: var(--bg-hover);
  border-radius: var(--g3-pill, 999px);
}
.seg__btn {
  border: 0;
  background: transparent;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  padding: 6px 14px;
  border-radius: 999px;
  cursor: pointer;
  transition: background var(--spring-fast), color var(--spring-fast);
}
.seg__btn--on {
  background: var(--bg-surface);
  color: var(--text-primary);
  box-shadow: var(--shadow-sm);
}

.form {
  display: flex;
  gap: var(--sp-4);
  flex-wrap: wrap;
  padding: var(--sp-3) var(--sp-4);
  align-items: flex-end;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 200px;
}
.field__label {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}

.block {
  margin-top: var(--sp-4);
  padding: var(--sp-4);
}
.block__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.block__title {
  font-size: var(--font-size-md);
  margin: 0 0 var(--sp-2);
}

.picker {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex-wrap: wrap;
}
.picker__input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
  pointer-events: none;
}
.picker__btn {
  cursor: pointer;
}
.picker__name {
  font-size: var(--font-size-sm);
  color: var(--text-primary);
}

.actions {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  margin-top: var(--sp-3);
  flex-wrap: wrap;
}

.stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(96px, 1fr));
  gap: var(--sp-2);
  margin: var(--sp-2) 0 var(--sp-3);
}
.stat {
  background: var(--bg-hover);
  border-radius: var(--radius-md);
  padding: 10px 12px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.stat__n {
  font-size: 20px;
  font-weight: 600;
  line-height: 1.1;
}
.stat__k {
  font-size: 11px;
  color: var(--text-muted);
}
.stat--ok .stat__n {
  color: var(--success);
}
.stat--new .stat__n {
  color: var(--accent);
}
.stat--warn .stat__n {
  color: var(--warning);
}
.stat--muted .stat__n {
  color: var(--text-muted);
}

.tagline {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  margin-bottom: var(--sp-2);
}
.tag {
  display: inline-block;
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 999px;
  background: var(--bg-hover);
  color: var(--text-secondary);
  white-space: nowrap;
}
.tag--new {
  background: var(--accent-soft);
  color: var(--accent);
}
.tag--match {
  background: color-mix(in srgb, var(--success) 16%, transparent);
  color: var(--success);
}
.tag--create {
  background: var(--accent-soft);
  color: var(--accent);
}
.tag--conflict {
  background: color-mix(in srgb, var(--warning) 18%, transparent);
  color: var(--warning);
}
.tag--skip {
  background: var(--bg-hover);
  color: var(--text-muted);
}
.st--0,
.st--1 {
  background: var(--accent-soft);
  color: var(--accent);
}
.st--2 {
  background: color-mix(in srgb, var(--success) 16%, transparent);
  color: var(--success);
}
.st--3 {
  background: color-mix(in srgb, var(--danger) 16%, transparent);
  color: var(--danger);
}
.st--4,
.st--5 {
  background: var(--bg-hover);
  color: var(--text-muted);
}

.tbl {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--font-size-sm);
}
.tbl th {
  text-align: left;
  font-weight: 500;
  color: var(--text-muted);
  font-size: 12px;
  padding: 6px 8px;
  border-bottom: 1px solid var(--border-subtle);
  white-space: nowrap;
}
.tbl td {
  padding: 8px;
  border-bottom: 1px solid var(--border-subtle);
  vertical-align: top;
}
.tbl tr:last-child td {
  border-bottom: 0;
}
.path {
  word-break: break-all;
  max-width: 320px;
}
.note {
  color: var(--text-muted);
  font-size: 12px;
}

.conflict {
  display: grid;
  grid-template-columns: minmax(160px, 1fr) minmax(220px, 1.4fr);
  gap: var(--sp-3);
  align-items: center;
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border-subtle);
}
.conflict:last-child {
  border-bottom: 0;
}
.conflict__title {
  font-weight: 500;
  word-break: break-all;
}

.prog {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 120px;
}
.bar {
  flex: 1;
  height: 6px;
  border-radius: 999px;
  background: var(--bg-hover);
  overflow: hidden;
  min-width: 60px;
}
.bar i {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: 999px;
  transition: width var(--ease-out-soft);
}
.row-actions {
  display: flex;
  gap: 8px;
  align-items: center;
}
.err {
  color: var(--danger);
  font-size: 12px;
  max-width: 220px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.empty {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  padding: var(--sp-3) 0;
}

/* 导入模板（FR-IMP-005） */
.tpl-bar {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex-wrap: wrap;
  margin-top: var(--sp-2);
}
.tpl-bar .field-control {
  min-width: 280px;
}
.tpl-applied {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex-wrap: wrap;
  margin-top: var(--sp-2);
}
.defaults {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: var(--sp-3);
  margin-bottom: var(--sp-3);
}
@media (max-width: 720px) {
  .conflict {
    grid-template-columns: 1fr;
  }
  .path {
    max-width: 180px;
  }
}
</style>
