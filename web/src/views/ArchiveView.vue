<script setup lang="ts">
/**
 * 档案页（FR-ARCH-001 ~ 008 的前端入口）。
 *
 * 结构：主体切换 → 筛选 → 列表 → 新建/编辑/详情浮层。
 *
 * 为什么先有「主体」这一层：
 *   arc_items.subject_id 是归属锚点，后端 createItem 会校验该主体
 *   属于调用者的可访问集合（FR-ACL-006）。故建档必须先有主体，
 *   而 GET /api/subjects 会为首访用户懒建「本人」主体 —— 前端只需正常拉取。
 *
 * 扩展字段（arc_item_fields）：
 *   分类决定字段模板（GET /api/field-defs?category=N），
 *   值走扁平对象 PUT /api/items/:id/fields。
 *   ⚠️ 敏感字段读回时是**掩码值**（FR-SRC-006）。若把掩码值原样回写，
 *   就会把真实值覆盖成星号 —— 因此编辑时只提交「用户实际改动过」的字段
 *   （见 changedFields），未触碰的敏感字段一律不提交。
 */
import { ref, computed, onMounted } from 'vue'
import { t as tr } from '../i18n'
import { api } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import AttachmentPanel from '../components/AttachmentPanel.vue'
import ShareLinkPanel from '../components/ShareLinkPanel.vue'
import DatePicker from '../components/DatePicker.vue'
import { CATEGORY_DEFS as CATEGORIES, categoryName, categorySensitivity } from '../composables/useCatalog'
import { useToast } from '../composables/useToast'

const toast = useToast()

// ---------------------------------------------------------------
// 字典（与 docs/06 §12.3 的分类模板一一对应）
// 分类名与默认敏感度统一取自 `composables/useCatalog`，本页不再自带副本
// —— 此前该映射在本页与 OverviewView 各有一份且已漂移。
// ---------------------------------------------------------------

/** 条目状态：0=草稿 1=正常 2=已归档 */
const STATUS_OPTS = [
  { value: -1, label: tr('viewsArchiveView.1a4c26', '全部状态') },
  { value: 0, label: tr('viewsArchiveView.0f4368', '草稿') },
  { value: 1, label: tr('viewsArchiveView.f78d03', '正常') },
  { value: 2, label: tr('viewsArchiveView.5cfbea', '已归档') },
]

const RELATION_OPTS = [
  { value: 0, label: tr('viewsArchiveView.24f3c1', '本人') },
  { value: 1, label: tr('viewsArchiveView.38ef0f', '配偶') },
  { value: 2, label: tr('viewsArchiveView.13bc78', '子女') },
  { value: 3, label: tr('viewsArchiveView.4590bf', '父母') },
  { value: 4, label: tr('viewsArchiveView.1a26ed', '其他') },
]

/** 本页历史别名，指向共享字典（保留调用点不变，减少改动面） */
const catName = categoryName
const catSensitivity = categorySensitivity

function statusLabel(v: number | string): string {
  return STATUS_OPTS.find((s) => s.value === Number(v))?.label ?? '—'
}

function sensLabel(v: number | string): string {
  const n = Number(v)
  return n >= 3 ? '高敏' : n === 2 ? '敏感' : tr('viewsArchiveView.7cda07', '普通')
}

/**
 * 来源系统枚举（与后端 arc_items.source 一致）：
 * 0=手动 1=CSV导入 2=克隆 3=OCR 4=附件导入 5=导出包回导（FR-EXP-008）
 */
const SOURCE_LABELS: Record<number, string> = {
  0: tr('viewsArchiveView.2a4a4d', '手动'),
  1: tr('viewsArchiveView.b7d837', 'CSV 导入'),
  2: tr('viewsArchiveView.6e6045', '克隆'),
  3: 'OCR',
  4: tr('viewsArchiveView.1e77ab', '附件导入'),
  5: tr('viewsArchiveView.3685ba', '导出包回导'),
}
function sourceLabel(v: number | string): string {
  return SOURCE_LABELS[Number(v)] ?? tr('viewsArchiveView.2a4a4d', '手动')
}

function fmtTime(ms: number | string | undefined): string {
  const n = Number(ms ?? 0)
  if (!n) return '—'
  const d = new Date(n)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleDateString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit' })
}

// ---------------------------------------------------------------
// 类型
// ---------------------------------------------------------------

interface Subject {
  id: string
  name: string
  alias: string
  relation: number | string
  isPrimary: boolean | string
  status: number | string
  completeness: number | string
  summary: string
  version: number | string
}

interface Item {
  id: string
  subjectId: string
  category: number | string
  title: string
  status: number | string
  sensitivity: number | string
  issuer: string
  remark: string
  version: number | string
  source: number | string
  createdAt: number | string
  updatedAt: number | string
}

interface FieldDef {
  id: number | string
  fieldKey: string
  fieldName: string
  dataType: number | string
  sensitivity: number | string
  isRequired: boolean | string
  defaultValue: string
}

interface FieldValue {
  fieldKey: string
  fieldName: string
  dataType: number | string
  sensitivity: number | string
  value: string
}

// ---------------------------------------------------------------
// 列表状态
// ---------------------------------------------------------------

const subjects = ref<Subject[]>([])
const activeSubjectId = ref('')
const items = ref<Item[]>([])
const total = ref(0)
const page = ref(1)
const size = 10
const keyword = ref('')
const category = ref(0)
const status = ref(-1)
// FR-SRC-010：来源系统筛选 + 创建时间范围
const source = ref(0)
const createdFrom = ref('')
const createdTo = ref('')

const loading = ref(true)
const error = ref('')

const totalPages = computed(() => Math.max(1, Math.ceil(total.value / size)))
const activeSubject = computed<Subject | null>(
  () => subjects.value.find((s) => s.id === activeSubjectId.value) ?? null,
)

async function loadSubjects(): Promise<void> {
  const res = await api<{ subjects: Subject[]; total: number }>('/subjects')
  subjects.value = res.subjects ?? []
  if (!activeSubjectId.value && subjects.value.length) {
    const primary = subjects.value.find((s) => s.isPrimary === true || s.isPrimary === 'true')
    activeSubjectId.value = (primary ?? subjects.value[0]).id
  }
}

async function loadItems(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    const q = new URLSearchParams()
    if (activeSubjectId.value) q.set('subjectId', activeSubjectId.value)
    if (category.value > 0) q.set('category', String(category.value))
    if (status.value >= 0) q.set('status', String(status.value))
    if (source.value > 0) q.set('source', String(source.value))
    if (createdFrom.value) q.set('createdFrom', createdFrom.value)
    if (createdTo.value) q.set('createdTo', createdTo.value)
    if (keyword.value.trim()) q.set('keyword', keyword.value.trim())
    q.set('page', String(page.value))
    q.set('size', String(size))
    const res = await api<{ items: Item[]; total: number }>(`/items?${q.toString()}`)
    items.value = res.items ?? []
    total.value = Number(res.total ?? 0)
  } catch (e) {
    error.value = (e as Error).message
    items.value = []
    total.value = 0
  } finally {
    loading.value = false
  }
}

async function reload(): Promise<void> {
  page.value = 1
  await loadItems()
}

function selectSubject(id: string): void {
  activeSubjectId.value = id
  void reload()
}

function goPage(next: number): void {
  if (next < 1 || next > totalPages.value) return
  page.value = next
  void loadItems()
}

// ---------------------------------------------------------------
// 批量选择（FR-UX-006）
// ---------------------------------------------------------------
const selected = ref<Set<string>>(new Set())
const selectedCount = computed(() => selected.value.size)
const allSelected = computed(
  () => items.value.length > 0 && items.value.every((i) => selected.value.has(String(i.id))),
)

function toggleSelect(id: string): void {
  const s = new Set(selected.value)
  if (s.has(id)) {
    s.delete(id)
  } else {
    s.add(id)
  }
  selected.value = s
}

function toggleSelectAll(): void {
  if (allSelected.value) {
    selected.value = new Set()
  } else {
    selected.value = new Set(items.value.map((i) => String(i.id)))
  }
}

const batchDeleting = ref(false)

/**
 * 批量编辑（FR-ARCH-013）：一次改多个条目的分类 / 有效期 / 标签。
 *
 * 三个字段都是**可选**的：不填的字段不会动（后端是打补丁语义）。
 * 与批量删除一样走「单接口 + 服务端按可访问主体过滤」，
 * 越权条目根本不会被更新，响应的 updated 与实际选中数不一致即为信号。
 */
const batchEditing = ref(false)
const editCategory = ref<number | null>(null)
const editExpiresAt = ref('')
const editTagId = ref('')
/** 批量加标签的下拉选项（登录页级别的轻量加载，失败也不阻断列表） */
const tagOptions = ref<{ id: string; name: string }[]>([])

async function batchEdit(): Promise<void> {
  if (selected.value.size === 0) return
  if (editCategory.value === null && !editExpiresAt.value && !editTagId.value) {
    toast.error(tr('viewsArchiveView.a9ec37', '请至少选择一项要修改的内容（分类 / 有效期 / 标签）'))
    return
  }
  batchEditing.value = true
  try {
    const body: Record<string, unknown> = { ids: Array.from(selected.value) }
    if (editCategory.value !== null) body.category = editCategory.value
    if (editExpiresAt.value) body.expiresAt = editExpiresAt.value
    if (editTagId.value) body.tagIds = [editTagId.value]
    const res = await api<{ requested: number; updated: number; tagged: number }>(
      '/items/batch/edit',
      { method: 'POST', body },
    )
    const skipped = res.requested - res.updated
    toast.success(
      tr('viewsArchiveView.9fead2', `已更新 ${res.updated} 条${res.tagged ? `，打标 ${res.tagged} 次` : ''}`) +
        (skipped > 0 ? `；${skipped} 条未变更（可能无权限或已删除）` : ''),
    )
    selected.value = new Set()
    editCategory.value = null
    editExpiresAt.value = ''
    editTagId.value = ''
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    batchEditing.value = false
  }
}

async function batchDelete(): Promise<void> {
  if (selected.value.size === 0) return
  batchDeleting.value = true
  try {
    const ids = Array.from(selected.value)
    let ok = 0
    for (const id of ids) {
      const it = items.value.find((x) => String(x.id) === id)
      try {
        await api(`/items/${id}`, {
          method: 'DELETE',
          body: { version: Number(it?.version ?? 1) },
        })
        ok++
      } catch {
        // 单条失败不阻断其余已选项
      }
    }
    toast.success(tr('viewsArchiveView.f36211', `已删除 ${ok} 条（移入回收站）`))
    selected.value = new Set()
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    batchDeleting.value = false
  }
}

async function loadTags(): Promise<void> {
  try {
    const res = await api<{ items: { id: string; name: string }[] }>('/tags')
    tagOptions.value = (res.items ?? []).map((t) => ({ id: String(t.id), name: t.name }))
  } catch {
    /* 标签加载失败不阻断档案列表，只是批量加标签的下拉为空 */
  }
}

onMounted(async () => {
  try {
    // 先拉主体（后端会为首访用户补建「本人」），再拉条目
    await loadSubjects()
  } catch (e) {
    error.value = (e as Error).message
  }
  await loadItems()
  await loadTags()
})

// ---------------------------------------------------------------
// 主体维护
// ---------------------------------------------------------------

const showSubject = ref(false)
const subjectMode = ref<'create' | 'edit'>('create')
const subjectForm = ref({ name: '', alias: '', relation: 0, summary: '' })
const subjectVersion = ref(0)
const subjectSaving = ref(false)

function openSubjectCreate(): void {
  subjectMode.value = 'create'
  subjectForm.value = { name: '', alias: '', relation: 0, summary: '' }
  showSubject.value = true
}

function openSubjectEdit(): void {
  const s = activeSubject.value
  if (!s) return
  subjectMode.value = 'edit'
  subjectVersion.value = Number(s.version ?? 0)
  subjectForm.value = {
    name: s.name,
    alias: s.alias ?? '',
    relation: Number(s.relation ?? 0),
    summary: s.summary ?? '',
  }
  showSubject.value = true
}

async function saveSubject(): Promise<void> {
  const f = subjectForm.value
  if (!f.name.trim()) {
    toast.warning(tr('viewsArchiveView.c5d55c', '请填写主体姓名'))
    return
  }
  subjectSaving.value = true
  try {
    if (subjectMode.value === 'create') {
      const res = await api<{ id: string }>('/subjects', {
        method: 'POST',
        body: {
          name: f.name.trim(),
          alias: f.alias,
          relation: f.relation,
          summary: f.summary,
        },
      })
      await loadSubjects()
      activeSubjectId.value = String(res.id)
      toast.success(tr('viewsArchiveView.5370b6', '主体已创建'))
    } else {
      await api(`/subjects/${activeSubjectId.value}`, {
        method: 'PUT',
        body: {
          name: f.name.trim(),
          alias: f.alias,
          relation: f.relation,
          summary: f.summary,
          version: subjectVersion.value,
        },
      })
      await loadSubjects()
      toast.success(tr('viewsArchiveView.68508a', '主体已更新'))
    }
    showSubject.value = false
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    subjectSaving.value = false
  }
}

async function deleteSubject(): Promise<void> {
  if (!activeSubjectId.value) return
  subjectSaving.value = true
  try {
    await api(`/subjects/${activeSubjectId.value}`, { method: 'DELETE' })
    toast.success(tr('viewsArchiveView.ddddd8', '主体已删除'))
    showSubject.value = false
    activeSubjectId.value = ''
    await loadSubjects()
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    subjectSaving.value = false
  }
}

// ---------------------------------------------------------------
// 新建 / 编辑
// ---------------------------------------------------------------

const showForm = ref(false)
const formMode = ref<'create' | 'edit'>('create')
const saving = ref(false)
const editingId = ref('')
const editingVersion = ref(0)

const form = ref({
  title: '',
  category: 1,
  sensitivity: 1,
  issuedDate: '',
  expiresAt: '',
  issuer: '',
  remark: '',
})

const fieldDefs = ref<FieldDef[]>([])
const fieldValues = ref<Record<string, string>>({})
/** 打开编辑时的初始值，用于「只提交改动过的字段」 */
const originalValues = ref<Record<string, string>>({})

function resetForm(): void {
  form.value = {
    title: '',
    category: category.value > 0 ? category.value : 1,
    sensitivity: catSensitivity(category.value > 0 ? category.value : 1),
    issuedDate: '',
    expiresAt: '',
    issuer: '',
    remark: '',
  }
  fieldValues.value = {}
  originalValues.value = {}
  editingId.value = ''
  editingVersion.value = 0
}

async function loadFieldDefs(cat: number): Promise<void> {
  try {
    const res = await api<{ fields: FieldDef[] }>(`/field-defs?category=${cat}`)
    fieldDefs.value = res.fields ?? []
    // 预填默认值（仅对空值生效，不覆盖用户已输入内容）
    for (const fd of fieldDefs.value) {
      if (!(fd.fieldKey in fieldValues.value) && fd.defaultValue) {
        fieldValues.value[fd.fieldKey] = fd.defaultValue
      }
    }
  } catch {
    fieldDefs.value = []
  }
}

async function openCreate(): Promise<void> {
  resetForm()
  formMode.value = 'create'
  showForm.value = true
  await loadFieldDefs(form.value.category)
}

/** 切换分类：清空上一套字段值，并按分类默认敏感度重置 */
async function onCategoryChange(): Promise<void> {
  if (formMode.value === 'create') {
    fieldValues.value = {}
    originalValues.value = {}
    form.value.sensitivity = catSensitivity(form.value.category)
  }
  await loadFieldDefs(form.value.category)
}

async function openEdit(it: Item): Promise<void> {
  resetForm()
  formMode.value = 'edit'
  editingId.value = String(it.id)
  editingVersion.value = Number(it.version ?? 1)
  form.value = {
    title: it.title,
    category: Number(it.category),
    sensitivity: Number(it.sensitivity ?? 1),
    issuedDate: '',
    expiresAt: '',
    issuer: it.issuer ?? '',
    remark: it.remark ?? '',
  }
  showForm.value = true
  await loadFieldDefs(form.value.category)
  // 读回现有字段值（敏感字段为掩码值，仅用于展示）
  try {
    const res = await api<{ fields: FieldValue[] }>(`/items/${it.id}/fields`)
    const values: Record<string, string> = {}
    for (const f of res.fields ?? []) {
      values[f.fieldKey] = f.value ?? ''
    }
    fieldValues.value = { ...values }
    originalValues.value = { ...values }
  } catch {
    // 字段读取失败不影响基础字段编辑
  }
}

/** 只提交用户实际改过、且非空的字段 */
function changedFields(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, v] of Object.entries(fieldValues.value)) {
    const value = (v ?? '').trim()
    if (!value) continue
    if (formMode.value === 'edit' && value === (originalValues.value[k] ?? '')) continue
    out[k] = value
  }
  return out
}

async function save(): Promise<void> {
  if (!form.value.title.trim()) {
    toast.warning(tr('viewsArchiveView.0eeb5d', '请填写标题'))
    return
  }
  if (formMode.value === 'create' && !activeSubjectId.value) {
    toast.warning(tr('viewsArchiveView.4a0d72', '请先选择或创建一个主体'))
    return
  }
  saving.value = true
  try {
    let itemId = editingId.value
    if (formMode.value === 'create') {
      const res = await api<{ id: string }>('/items', {
        method: 'POST',
        body: {
          subjectId: activeSubjectId.value,
          category: form.value.category,
          title: form.value.title.trim(),
          // 1 = 正常（后端默认 0 = 草稿；用户手填的档案直接生效）
          status: 1,
          sensitivity: form.value.sensitivity,
          issuedDate: form.value.issuedDate,
          expiresAt: form.value.expiresAt,
          issuer: form.value.issuer,
          remark: form.value.remark,
        },
      })
      itemId = String(res.id)
    } else {
      await api(`/items/${itemId}`, {
        method: 'PUT',
        body: {
          title: form.value.title.trim(),
          sensitivity: form.value.sensitivity,
          issuedDate: form.value.issuedDate,
          expiresAt: form.value.expiresAt,
          issuer: form.value.issuer,
          remark: form.value.remark,
          version: editingVersion.value,
        },
      })
    }
    // 扩展字段：扁平对象覆盖写入（只含改动项）
    const fields = changedFields()
    if (Object.keys(fields).length > 0) {
      await api(`/items/${itemId}/fields`, { method: 'PUT', body: fields })
    }
    toast.success(formMode.value === 'create' ? '档案已创建' : tr('viewsArchiveView.06ad0b', '档案已更新'))
    showForm.value = false
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    saving.value = false
  }
}

// ---------------------------------------------------------------
// 详情
// ---------------------------------------------------------------

const showDetail = ref(false)
const detailItem = ref<Item | null>(null)
const detailFields = ref<FieldValue[]>([])
const detailLoading = ref(false)

async function openDetail(it: Item): Promise<void> {
  detailItem.value = it
  detailFields.value = []
  showDetail.value = true
  detailLoading.value = true
  try {
    const res = await api<{ fields: FieldValue[] }>(`/items/${it.id}/fields`)
    detailFields.value = res.fields ?? []
  } catch {
    detailFields.value = []
  } finally {
    detailLoading.value = false
  }
}

/** 从详情切到编辑（先关详情，避免两个浮层叠加） */
function editFromDetail(): void {
  const it = detailItem.value
  if (!it) return
  showDetail.value = false
  void openEdit(it)
}

// ---------------------------------------------------------------
// ---------------------------------------------------------------
// 回收站
// ---------------------------------------------------------------

const showRecycle = ref(false)
const recycleItems = ref<Item[]>([])
const recycleLoading = ref(false)
const restoring = ref('')

async function openRecycle(): Promise<void> {
  showRecycle.value = true
  recycleLoading.value = true
  try {
    const res = await api<{ items: Item[]; total: number }>('/items/recycle-bin')
    recycleItems.value = res.items ?? []
  } catch (e) {
    toast.error((e as Error).message)
    recycleItems.value = []
  } finally {
    recycleLoading.value = false
  }
}

async function restoreItem(it: Item): Promise<void> {
  restoring.value = String(it.id)
  try {
    await api(`/items/${it.id}/restore`, { method: 'POST' })
    toast.success(tr('viewsArchiveView.6aa9ad', '已恢复'))
    recycleItems.value = recycleItems.value.filter((x) => x.id !== it.id)
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    restoring.value = ''
  }
}

// ---------------------------------------------------------------
// 删除
// ---------------------------------------------------------------
const showDelete = ref(false)
const deleteTarget = ref<Item | null>(null)
const deleting = ref(false)

function askDelete(it: Item): void {
  deleteTarget.value = it
  showDelete.value = true
}

async function confirmDelete(): Promise<void> {
  const t = deleteTarget.value
  if (!t) return
  deleting.value = true
  try {
    // 软删除走乐观锁：后端要求带 version（缺省会被判为非法请求体）
    await api(`/items/${t.id}`, { method: 'DELETE', body: { version: Number(t.version ?? 1) } })
    toast.success(tr('viewsArchiveView.54e2ac', '已移入回收站'))
    showDelete.value = false
    await loadItems()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    deleting.value = false
  }
}

// 克隆（FR-ARCH-009）：复制为新草稿
const cloningId = ref('')

async function cloneItem(it: Item): Promise<void> {
  cloningId.value = String(it.id)
  try {
    const res = await api<{ id: string }>(`/items/${it.id}/clone`, { method: 'POST', body: {} })
    toast.success(tr('viewsArchiveView.7484d8', '已复制为新草稿'))
    await loadItems()
    void res
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    cloningId.value = ''
  }
}

// ---------------------------------------------------------------
// 字段渲染
// ---------------------------------------------------------------

function isBool(t: number | string): boolean {
  return Number(t) === 6
}

function inputType(t: number | string): string {
  switch (Number(t)) {
    case 2:
      return 'number'
    case 3:
      return 'date'
    case 7:
      return 'email'
    case 8:
      return 'tel'
    case 10:
      return 'url'
    default:
      return 'text'
  }
}
</script>

<template>
  <section class="archive">
    <header class="page-head">
      <div>
        <h1 class="page-title">{{ tr('ArchiveView.3ca928', '档案') }}</h1>
        <p class="page-sub">
          共 {{ total }} 条
          <template v-if="activeSubject"> {{ tr('ArchiveView.2eaeb7', '· 当前主体') }} {{ activeSubject.name }}</template>
        </p>
      </div>
      <button class="btn-primary" type="button" @click="openCreate">{{ tr('ArchiveView.88b10e', '新建档案') }}</button>
    </header>

    <!-- 主体切换：一行胶囊，横向可滚（移动端不换行挤压） -->
    <div class="subjects" role="tablist" :aria-label="tr('ArchiveView.74bc27', '档案主体')">
      <button
        v-for="s in subjects"
        :key="s.id"
        class="subject-chip"
        :class="{ 'subject-chip--on': s.id === activeSubjectId }"
        type="button"
        role="tab"
        :aria-selected="s.id === activeSubjectId"
        @click="selectSubject(s.id)"
      >
        <span class="subject-chip__avatar">{{ s.name.slice(0, 1) || '?' }}</span>
        <span class="subject-chip__name">{{ s.name }}</span>
        <span v-if="s.isPrimary === true || s.isPrimary === 'true'" class="subject-chip__tag">{{ tr('ArchiveView.fbf713', '主') }}</span>
      </button>
      <button class="subject-chip subject-chip--add" type="button" @click="openSubjectCreate">
        + 主体
      </button>
      <button
        v-if="activeSubject"
        class="btn-text subjects__manage"
        type="button"
        @click="openSubjectEdit"
      >
        管理主体
      </button>
    </div>

    <!-- 筛选 -->
    <div class="toolbar">
      <input
        v-model="keyword"
        class="field-control toolbar__search"
        :placeholder="tr('ArchiveView.efc001', '搜索标题或备注')"
        @keyup.enter="reload"
      />
      <select v-model.number="category" class="field-control" @change="reload">
        <option :value="0">{{ tr('ArchiveView.a8e369', '全部分类') }}</option>
        <option v-for="c in CATEGORIES" :key="c.code" :value="c.code">{{ c.name }}</option>
      </select>
      <select v-model.number="status" class="field-control" @change="reload">
        <option v-for="s in STATUS_OPTS" :key="s.value" :value="s.value">{{ s.label }}</option>
      </select>
      <select v-model.number="source" class="field-control" @change="reload" :title="tr('ArchiveView.c63f79', '来源')">
        <option :value="0">{{ tr('ArchiveView.f8d22f', '全部来源') }}</option>
        <option :value="1">{{ tr('ArchiveView.b7d837', 'CSV 导入') }}</option>
        <option :value="2">{{ tr('ArchiveView.aae2d0', '克隆生成') }}</option>
        <option :value="3">{{ tr('ArchiveView.bb5ace', 'OCR 识别') }}</option>
        <option :value="4">{{ tr('ArchiveView.1e77ab', '附件导入') }}</option>
        <option :value="5">{{ tr('ArchiveView.3685ba', '导出包回导') }}</option>
      </select>
      <div class="toolbar__dates">
        <DatePicker
          v-model="createdFrom"
          class="field-control"
          :title="tr('ArchiveView.12ec01', '创建时间起')"
          @change="reload"
        />
        <span class="toolbar__dash">~</span>
        <DatePicker
          v-model="createdTo"
          class="field-control"
          :title="tr('ArchiveView.a7bc27', '创建时间止')"
          @change="reload"
        />
      </div>
      <button class="btn-ghost" type="button" @click="reload">{{ tr('ArchiveView.711363', '查询') }}</button>
      <button class="btn-text" type="button" @click="openRecycle">{{ tr('ArchiveView.64ea87', '回收站') }}</button>
    </div>

    <p v-if="error" class="hint hint--error">{{ error }}</p>
    <div v-else-if="loading" class="list" aria-hidden="true">
      <div v-for="n in 6" :key="n" class="card item item--skeleton">
        <div class="skeleton skeleton--title" />
        <div class="skeleton skeleton--line" style="width: 70%" />
        <div class="skeleton skeleton--line" style="width: 40%" />
      </div>
    </div>
    <div v-else-if="items.length === 0" class="card empty">
      <div class="empty__title">{{ tr('ArchiveView.a5135e', '还没有档案') }}</div>
      <p class="empty__sub">{{ tr('ArchiveView.f35149', '点击右上角「新建档案」，为当前主体添加第一条记录。') }}</p>
    </div>

    <div v-else class="list">
      <article
        v-for="it in items"
        :key="it.id"
        class="card item"
        :class="{ 'item--selected': selected.has(String(it.id)) }"
        tabindex="0"
        :aria-pressed="selected.has(String(it.id))"
        @click="openDetail(it)"
        @keyup.enter="openDetail(it)"
      >
        <label class="item__check" @click.stop @keyup.stop>
          <input
            type="checkbox"
            class="item__checkbox"
            :checked="selected.has(String(it.id))"
            ::aria-label="tr('ArchiveView.888021', '`选择 ${it.title}`')"
            @change="toggleSelect(String(it.id))"
          />
        </label>
        <div class="item__main">
          <div class="item__title">{{ it.title }}</div>
          <div class="item__meta">
            <span class="badge">{{ catName(it.category) }}</span>
            <span class="sens" :class="`sens--${Number(it.sensitivity)}`">
              {{ sensLabel(it.sensitivity) }}
            </span>
            <span class="item__status">{{ statusLabel(it.status) }}</span>
            <span v-if="it.issuer" class="item__issuer">{{ it.issuer }}</span>
            <span class="item__source">{{ sourceLabel(it.source) }}</span>
            <span class="item__time">{{ fmtTime(it.updatedAt) }}</span>
          </div>
        </div>
        <div class="item__actions">
          <button class="btn-text" type="button" @click.stop="openEdit(it)">编辑</button>
          <button
            class="btn-text"
            type="button"
            :disabled="cloningId === String(it.id)"
            @click.stop="cloneItem(it)"
          >
            {{ cloningId === String(it.id) ? '复制中…' : '复制' }}
          </button>
          <button class="btn-text btn-text--danger" type="button" @click.stop="askDelete(it)">
            删除
          </button>
        </div>
      </article>
    </div>

    <!-- 批量操作浮出栏（FR-UX-006）：选中后浮出 -->
    <div
      v-if="selectedCount > 0"
      class="batchbar"
      role="region"
      :aria-label="tr('ArchiveView.eae7c2', '批量操作')"
    >
      <label class="batchbar__count">
        <input
          type="checkbox"
          :checked="allSelected"
          ::aria-label="allSelected ? tr('ArchiveView.c2eb1c.on', '取消全选') : tr('ArchiveView.c2eb1c.off', '全选本页')"
          @change="toggleSelectAll"
        />
        已选 {{ selectedCount }} 项
      </label>
      <span class="batchbar__spacer" />
      <!-- FR-ARCH-013 批量编辑：三项都可选，不填的字段不改 -->
      <label class="batchbar__field">
        <span>{{ tr('ArchiveView.3b6209', '改分类') }}</span>
        <select v-model="editCategory" class="field-control field-control--sm">
          <option :value="null">{{ tr('ArchiveView.47de0d', '（不改）') }}</option>
          <option v-for="c in CATEGORIES" :key="c.code" :value="c.code">{{ c.name }}</option>
        </select>
      </label>
      <label class="batchbar__field">
        <span>{{ tr('ArchiveView.222460', '有效期') }}</span>
        <DatePicker v-model="editExpiresAt" class="field-control field-control--sm" />
      </label>
      <label class="batchbar__field">
        <span>{{ tr('ArchiveView.eaf58d', '加标签') }}</span>
        <select v-model="editTagId" class="field-control field-control--sm">
          <option value="">{{ tr('ArchiveView.37b3b3', '（不加）') }}</option>
          <option v-for="t in tagOptions" :key="t.id" :value="t.id">{{ t.name }}</option>
        </select>
      </label>
      <button class="btn-primary" type="button" :disabled="batchEditing" @click="batchEdit">
        {{ batchEditing ? '提交中…' : '应用修改' }}
      </button>
      <button class="btn-ghost" type="button" @click="selected = new Set()">取消</button>
      <button
        class="btn-danger"
        type="button"
        :disabled="batchDeleting"
        @click="batchDelete"
      >
        {{ batchDeleting ? '删除中…' : '批量删除' }}
      </button>
    </div>

    <div v-if="!loading && total > size" class="pager">
      <button class="btn-ghost" type="button" :disabled="page <= 1" @click="goPage(page - 1)">
        上一页
      </button>
      <span class="pager__info">{{ page }} / {{ totalPages }}</span>
      <button
        class="btn-ghost"
        type="button"
        :disabled="page >= totalPages"
        @click="goPage(page + 1)"
      >
        下一页
      </button>
    </div>

    <!-- 新建 / 编辑 -->
    <AppSheet
      v-model="showForm"
      ::title="formMode === 'create' ? tr('ArchiveView.a7c2c1.new', '新建档案') : tr('ArchiveView.a7c2c1.edit', '编辑档案')"
      size="lg"
      :dismissible="!saving"
    >
      <div class="form">
        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.748d7d', '标题') }} <em>*</em></span>
          <input
            v-model="form.title"
            class="field-control"
            maxlength="120"
            :placeholder="tr('ArchiveView.61c119', '如：居民身份证 / 本科毕业证')"
          />
        </label>

        <label v-if="formMode === 'create'" class="field">
          <span class="field__label">{{ tr('ArchiveView.435c52', '分类') }}</span>
          <select
            v-model.number="form.category"
            class="field-control"
            @change="onCategoryChange"
          >
            <option v-for="c in CATEGORIES" :key="c.code" :value="c.code">{{ c.name }}</option>
          </select>
        </label>

        <label class="field">
          <span class="field__label">{{ tr('ArchiveView.c8165b', '敏感度') }}</span>
          <select v-model.number="form.sensitivity" class="field-control">
            <option :value="1">{{ tr('ArchiveView.7cda07', '普通') }}</option>
            <option :value="2">{{ tr('ArchiveView.e4d1f0', '敏感') }}</option>
            <option :value="3">{{ tr('ArchiveView.4bdda7', '高敏') }}</option>
          </select>
        </label>

        <label class="field">
          <span class="field__label">{{ tr('ArchiveView.0b8bcd', '签发日期') }}</span>
          <DatePicker v-model="form.issuedDate" class="field-control" />
        </label>

        <label class="field">
          <span class="field__label">{{ tr('ArchiveView.e3e626', '到期日期') }}</span>
          <DatePicker v-model="form.expiresAt" class="field-control" />
        </label>

        <label class="field">
          <span class="field__label">{{ tr('ArchiveView.8eb731', '签发机构') }}</span>
          <input v-model="form.issuer" class="field-control" maxlength="128" />
        </label>

        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.e03614', '备注') }}</span>
          <textarea v-model="form.remark" class="field-control" rows="2" />
        </label>
      </div>

      <template v-if="fieldDefs.length">
        <h3 class="form__section">{{ catName(form.category) }} · 专属字段</h3>
        <p v-if="formMode === 'edit'" class="hint">
          敏感字段读回时为掩码值；未改动的字段不会被提交，避免把掩码覆盖成真实值。
        </p>
        <div class="form">
          <label v-for="f in fieldDefs" :key="f.id" class="field">
            <span class="field__label">
              {{ f.fieldName }}
              <em v-if="f.isRequired === true || f.isRequired === 't'">*</em>
              <span v-if="Number(f.sensitivity) >= 2" class="field__sens">{{ tr('ArchiveView.e4d1f0', '敏感') }}</span>
            </span>
            <select v-if="isBool(f.dataType)" v-model="fieldValues[f.fieldKey]" class="field-control">
              <option value="">{{ tr('ArchiveView.287a1d', '未填写') }}</option>
              <option value="true">{{ tr('ArchiveView.30160a', '是') }}</option>
              <option value="false">{{ tr('ArchiveView.8bf5c1', '否') }}</option>
            </select>
            <input
              v-else
              v-model="fieldValues[f.fieldKey]"
              class="field-control"
              :type="inputType(f.dataType)"
            />
          </label>
        </div>
      </template>

      <div class="sheet-actions">
        <button class="btn-ghost" type="button" :disabled="saving" @click="showForm = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="saving" @click="save">
          {{ saving ? '保存中…' : '保存' }}
        </button>
      </div>
    </AppSheet>

    <!-- 详情 -->
    <AppSheet v-model="showDetail" ::title="detailItem?.title ?? tr('ArchiveView.79abb2', '档案详情')" size="md">
      <template v-if="detailItem">
        <dl class="kv">
          <dt>{{ tr('ArchiveView.435c52', '分类') }}</dt>
          <dd>{{ catName(detailItem.category) }}</dd>
          <dt>{{ tr('ArchiveView.62e951', '状态') }}</dt>
          <dd>{{ statusLabel(detailItem.status) }}</dd>
          <dt>{{ tr('ArchiveView.c8165b', '敏感度') }}</dt>
          <dd>{{ sensLabel(detailItem.sensitivity) }}</dd>
          <dt>{{ tr('ArchiveView.8eb731', '签发机构') }}</dt>
          <dd>{{ detailItem.issuer || '—' }}</dd>
          <dt>{{ tr('ArchiveView.e03614', '备注') }}</dt>
          <dd>{{ detailItem.remark || '—' }}</dd>
          <dt>{{ tr('ArchiveView.093dea', '更新时间') }}</dt>
          <dd>{{ fmtTime(detailItem.updatedAt) }}</dd>
        </dl>

        <h3 class="form__section">{{ tr('ArchiveView.1537dc', '扩展字段') }}</h3>
        <p v-if="detailLoading" class="hint">{{ tr('ArchiveView.300ee3', '加载中…') }}</p>
        <p v-else-if="detailFields.length === 0" class="hint">{{ tr('ArchiveView.ac4833', '该分类还没有填写专属字段。') }}</p>
        <dl v-else class="kv">
          <template v-for="f in detailFields" :key="f.fieldKey">
            <dt>
              {{ f.fieldName }}
              <span v-if="Number(f.sensitivity) >= 2" class="field__sens">{{ tr('ArchiveView.e4d1f0', '敏感') }}</span>
            </dt>
            <dd>{{ f.value || '—' }}</dd>
          </template>
        </dl>

        <!-- 附件（上传 / 预览水印 / 版本对比 / 批量操作） -->
        <AttachmentPanel v-if="detailItem" :item-id="Number(detailItem.id)" />

        <!-- 共享链接（FR-ACL-011 / FR-ACL-012） -->
        <ShareLinkPanel v-if="detailItem" :item-id="Number(detailItem.id)" />
      </template>
      <div class="sheet-actions">
        <button class="btn-ghost" type="button" @click="showDetail = false">{{ tr('ArchiveView.6c14bd', '关闭') }}</button>
        <button
          v-if="detailItem"
          class="btn-primary"
          type="button"
          @click="editFromDetail"
        >
          编辑
        </button>
      </div>
    </AppSheet>

    <!-- 主体新建 / 编辑 -->
    <AppSheet
      v-model="showSubject"
      ::title="subjectMode === 'create' ? tr('ArchiveView.70990b.new', '新增主体') : tr('ArchiveView.70990b.manage', '管理主体')"
      size="sm"
      :dismissible="!subjectSaving"
    >
      <div class="form form--single">
        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.be4c26', '姓名') }} <em>*</em></span>
          <input v-model="subjectForm.name" class="field-control" maxlength="64" />
        </label>
        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.5046f3', '与我的关系') }}</span>
          <select v-model.number="subjectForm.relation" class="field-control">
            <option v-for="r in RELATION_OPTS" :key="r.value" :value="r.value">{{ r.label }}</option>
          </select>
        </label>
        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.198978', '别称') }}</span>
          <input v-model="subjectForm.alias" class="field-control" maxlength="64" />
        </label>
        <label class="field field--full">
          <span class="field__label">{{ tr('ArchiveView.e03614', '备注') }}</span>
          <textarea v-model="subjectForm.summary" class="field-control" rows="2" />
        </label>
      </div>
      <p class="hint">{{ tr('ArchiveView.abe4ab', '姓名以密文形式存储（SM4-CBC + HMAC-SM3）。') }}</p>
      <div class="sheet-actions">
        <button
          v-if="subjectMode === 'edit'"
          class="btn-danger"
          type="button"
          :disabled="subjectSaving"
          @click="deleteSubject"
        >
          删除
        </button>
        <span class="sheet-actions__spacer" />
        <button class="btn-ghost" type="button" :disabled="subjectSaving" @click="showSubject = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="subjectSaving" @click="saveSubject">
          {{ subjectSaving ? '保存中…' : '保存' }}
        </button>
      </div>
    </AppSheet>

    <!-- 回收站 -->
    <AppSheet v-model="showRecycle" :title="tr('ArchiveView.64ea87', '回收站')" size="md">
      <p v-if="recycleLoading" class="hint">{{ tr('ArchiveView.300ee3', '加载中…') }}</p>
      <p v-else-if="recycleItems.length === 0" class="hint">{{ tr('ArchiveView.8c1269', '回收站是空的。') }}</p>
      <div v-else class="recycle">
        <div v-for="it in recycleItems" :key="it.id" class="recycle__row">
          <div class="recycle__main">
            <div class="item__title">{{ it.title }}</div>
            <div class="item__meta">
              <span class="badge">{{ catName(it.category) }}</span>
              <span class="item__time">{{ fmtTime(it.updatedAt) }}</span>
            </div>
          </div>
          <button
            class="btn-ghost"
            type="button"
            :disabled="restoring === String(it.id)"
            @click="restoreItem(it)"
          >
            {{ restoring === String(it.id) ? '恢复中…' : '恢复' }}
          </button>
        </div>
      </div>
      <div class="sheet-actions">
        <button class="btn-ghost" type="button" @click="showRecycle = false">{{ tr('ArchiveView.6c14bd', '关闭') }}</button>
      </div>
    </AppSheet>

    <!-- 删除确认 -->
    <AppSheet v-model="showDelete" :title="tr('ArchiveView.298cbe', '移入回收站')" size="sm" :dismissible="!deleting">
      <p class="confirm-text">
        确定要删除「{{ deleteTarget?.title }}」吗？条目将进入回收站，可在回收站中恢复。
      </p>
      <div class="sheet-actions">
        <button class="btn-ghost" type="button" :disabled="deleting" @click="showDelete = false">
          取消
        </button>
        <button class="btn-danger" type="button" :disabled="deleting" @click="confirmDelete">
          {{ deleting ? '删除中…' : '删除' }}
        </button>
      </div>
    </AppSheet>
  </section>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  margin-bottom: var(--sp-4);
}
.page-title {
  font-size: var(--font-size-xl);
  margin: 0;
}
.page-sub {
  margin: var(--sp-1) 0 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

/* 主体胶囊 */
.subjects {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  overflow-x: auto;
  padding-bottom: var(--sp-2);
  margin-bottom: var(--sp-3);
  scrollbar-width: none;
}
.subjects::-webkit-scrollbar {
  display: none;
}
.subject-chip {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 6px 14px 6px 6px;
  border-radius: var(--g3-pill, 999px);
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  color: var(--text-primary);
  font-size: var(--font-size-sm);
  white-space: nowrap;
  cursor: pointer;
  transition:
    background var(--spring-fast) var(--ease-apple),
    border-color var(--spring-fast) var(--ease-apple),
    transform var(--spring-fast) var(--ease-apple);
}
.subject-chip:hover {
  background: var(--bg-hover);
}
.subject-chip:active {
  transform: scale(0.97);
}
.subject-chip--on {
  background: var(--accent-soft);
  border-color: var(--accent);
  color: var(--accent);
}
.subject-chip__avatar {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background: var(--accent);
  color: var(--text-inverse);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 600;
}
.subject-chip--on .subject-chip__avatar {
  background: var(--accent);
}
.subject-chip__tag {
  font-size: 10px;
  padding: 0 4px;
  border-radius: var(--g3-sm, 12px);
  background: var(--accent);
  color: var(--text-inverse);
}
.subject-chip--add {
  padding: 6px 14px;
  border-style: dashed;
  color: var(--text-secondary);
  background: transparent;
}
.subjects__manage {
  margin-left: auto;
  flex-shrink: 0;
}

/* 工具栏 */
.toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
  margin-bottom: var(--sp-4);
}
.toolbar__search {
  flex: 1 1 200px;
  min-width: 160px;
}
.toolbar__dates {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-1);
}
.toolbar__dates .field-control {
  width: auto;
}
.toolbar__dash {
  color: var(--text-soft);
}

/* 列表 */
.list {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  cursor: pointer;
  transition:
    transform var(--spring-fast) var(--ease-apple),
    box-shadow var(--spring-fast) var(--ease-apple);
}
.item:hover {
  box-shadow: var(--shadow-md);
}
.item:active {
  transform: scale(0.995);
}
.item--selected {
  border-color: var(--accent);
  background: var(--accent-soft);
}
.item--skeleton {
  cursor: default;
  pointer-events: none;
}
.item__check {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 2px;
  cursor: pointer;
}
.item__checkbox {
  width: 18px;
  height: 18px;
  accent-color: var(--accent);
  cursor: pointer;
}
.item__title {
  font-weight: 600;
  font-size: var(--font-size-md);
  margin-bottom: 2px;
}
.item__meta {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--sp-2);
  font-size: var(--font-size-sm);
  color: var(--text-muted);
}
.item__time {
  margin-left: auto;
}
.item__source {
  padding: 1px 6px;
  border-radius: var(--g3-sm, 12px);
  font-size: 11px;
  background: var(--bg-soft, #f0f1f5);
  color: var(--text-soft);
}
.item__actions {
  display: flex;
  gap: var(--sp-1);
  flex-shrink: 0;
}
.sens {
  padding: 1px 6px;
  border-radius: var(--g3-sm, 12px);
  font-size: 11px;
  border: 1px solid currentColor;
}
.sens--1 {
  color: var(--sens-normal);
}
.sens--2 {
  color: var(--sens-sensitive);
}
.sens--3 {
  color: var(--sens-high);
}

/* 空态 / 翻页 */
.empty {
  text-align: center;
  padding: var(--sp-6) var(--sp-4);
}
.empty__title {
  font-weight: 600;
  margin-bottom: var(--sp-1);
}
.empty__sub {
  margin: 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--sp-3);
  margin-top: var(--sp-4);
}
.pager__info {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}

/* 表单 */
.form {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-3);
}
.form--single {
  grid-template-columns: 1fr;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field--full {
  grid-column: 1 / -1;
}
.field__label {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  display: flex;
  align-items: center;
  gap: 6px;
}
.field__label em {
  color: var(--danger);
  font-style: normal;
}
.field__sens {
  font-size: 10px;
  padding: 0 4px;
  border-radius: var(--g3-sm, 12px);
  border: 1px solid var(--sens-sensitive);
  color: var(--sens-sensitive);
}
.form__section {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  margin: var(--sp-4) 0 var(--sp-2);
  letter-spacing: 0.02em;
}
.sheet-actions {
  display: flex;
  gap: var(--sp-2);
  justify-content: flex-end;
  margin-top: var(--sp-5);
}
.sheet-actions__spacer {
  flex: 1;
}
.confirm-text {
  margin: 0;
  color: var(--text-secondary);
  font-size: var(--font-size-md);
}

.recycle {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.recycle__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-3);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-sm, 12px);
}
.recycle__main {
  min-width: 0;
}

/* `.kv`（键值描述列表）已提升到 styles/theme.css 作为全局类，
   避免各页面各写一份、并在未定义的页面退化成浏览器默认缩进。 */

.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}

@media (max-width: 639px) {
  .form {
    grid-template-columns: 1fr;
  }
  .item {
    flex-direction: column;
    align-items: flex-start;
  }
  .item__actions {
    align-self: flex-end;
  }
  .item__time {
    margin-left: 0;
  }
}
</style>
