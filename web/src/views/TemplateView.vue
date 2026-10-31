<script setup lang="ts">
/**
 * 条目模板（FR-ARCH-012 · 方案 C：条目骨架 + 字段默认值）。
 *
 * 接口：
 *   GET    /api/item-templates            本人模板
 *   POST   /api/item-templates            新建
 *   PUT    /api/item-templates/:id        修改
 *   DELETE /api/item-templates/:id        删除
 *   POST   /api/item-templates/:id/apply  套用（subjectId + count）
 *
 * 设计取舍：
 *   · 模板是「个人常用条目」，不是「机构共享模板」——后者属于 FR-IMP-005，
 *     混在一起会让「为什么同事看不到我的模板」变成产品歧义；
 *   · 有效期只存偏移天数，不存绝对日期：模板会被长期复用，
 *     存绝对日期的模板第二次套用就产出一批已过期档案；
 *   · 套用上限 50 条（后端硬约束），超过应走 CSV 导入（那边有预检与错误报告）。
 */
import { computed, onMounted, ref } from 'vue'
import { t as tr } from '../i18n'
import { api } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import {
  CATEGORY_DEFS,
  categoryName,
  formatTime,
  sensitivityName,
  statusName,
} from '../composables/useCatalog'
import { useToast } from '../composables/useToast'

const { success, error: toastError } = useToast()

interface Template {
  id: string
  name: string
  category: number
  title: string
  status: number
  sensitivity: number
  issuer: string
  remark: string
  expiresOffsetDays: number
  extra: unknown
  updatedAt: number
}

interface Subject {
  id: string
  name: string
}

const templates = ref<Template[]>([])
const subjects = ref<Subject[]>([])
const loading = ref(true)
const loadError = ref('')

/** 编辑 / 新建 */
const showEdit = ref(false)
const editingId = ref('')
const saving = ref(false)
const form = ref({
  name: '',
  category: 2,
  title: '',
  status: 0,
  sensitivity: 2,
  issuer: '',
  remark: '',
  expiresOffsetDays: 0,
  extraText: '{}',
})

/** 套用 */
const showApply = ref(false)
const applyTarget = ref<Template | null>(null)
const applying = ref(false)
const applyForm = ref({ subjectId: '', count: 1 })

/** 删除 */
const showDelete = ref(false)
const deleteTarget = ref<Template | null>(null)
const deleting = ref(false)

const isEditing = computed(() => editingId.value !== '')

const categoryOptions = CATEGORY_DEFS
const statusOptions = [
  { value: 0, label: tr('viewsTemplateView.0f4368', '草稿') },
  { value: 1, label: tr('viewsTemplateView.f78d03', '正常') },
  { value: 2, label: tr('viewsTemplateView.5cfbea', '已归档') },
]
const sensitivityOptions = [
  { value: 1, label: tr('viewsTemplateView.7cda07', '普通') },
  { value: 2, label: tr('viewsTemplateView.e4d1f0', '敏感') },
  { value: 3, label: tr('viewsTemplateView.4bdda7', '高敏') },
]

async function load(): Promise<void> {
  loading.value = true
  loadError.value = ''
  try {
    const [t, s] = await Promise.all([
      api<{ items: Template[] }>('/item-templates'),
      api<{ subjects: Subject[] }>('/subjects'),
    ])
    templates.value = t.items ?? []
    subjects.value = s.subjects ?? []
  } catch (e) {
    loadError.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

function emptyForm(): void {
  editingId.value = ''
  form.value = {
    name: '',
    category: 2,
    title: '',
    status: 0,
    sensitivity: 2,
    issuer: '',
    remark: '',
    expiresOffsetDays: 0,
    extraText: '{}',
  }
}

function openCreate(): void {
  emptyForm()
  showEdit.value = true
}

function openEdit(t: Template): void {
  editingId.value = t.id
  form.value = {
    name: t.name,
    category: Number(t.category),
    title: t.title,
    status: Number(t.status),
    sensitivity: Number(t.sensitivity),
    issuer: t.issuer ?? '',
    remark: t.remark ?? '',
    expiresOffsetDays: Number(t.expiresOffsetDays) || 0,
    extraText: JSON.stringify(t.extra ?? {}, null, 2),
  }
  showEdit.value = true
}

/** 分类变化时把敏感度拉到该分类默认值（用户仍可改） */
function onCategoryChange(): void {
  const def = CATEGORY_DEFS.find((c) => c.code === Number(form.value.category))
  if (def) form.value.sensitivity = def.sensitivity
}

async function save(): Promise<void> {
  if (!form.value.name.trim()) {
    toastError(tr('viewsTemplateView.150115', '模板名称不能为空'))
    return
  }
  if (!form.value.title.trim()) {
    toastError(tr('viewsTemplateView.b38378', '标题模板不能为空'))
    return
  }
  // 前端先校验一次 JSON 对象，避免把非法文本发给数据库的 ::jsonb
  const extra = form.value.extraText.trim() || '{}'
  try {
    const parsed: unknown = JSON.parse(extra)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      toastError(tr('viewsTemplateView.62af7b', '扩展字段默认值必须是 JSON 对象，如 {"发证机关": "市公安局"}'))
      return
    }
  } catch {
    toastError(tr('viewsTemplateView.5e8fbe', '扩展字段默认值不是合法 JSON'))
    return
  }

  saving.value = true
  try {
    const body = {
      name: form.value.name.trim(),
      category: Number(form.value.category),
      title: form.value.title.trim(),
      status: Number(form.value.status),
      sensitivity: Number(form.value.sensitivity),
      issuer: form.value.issuer.trim(),
      remark: form.value.remark.trim(),
      expiresOffsetDays: Number(form.value.expiresOffsetDays) || 0,
      extra,
    }
    if (isEditing.value) {
      await api(`/item-templates/${editingId.value}`, { method: 'PUT', body })
      success(tr('viewsTemplateView.7c16ee', '模板已更新'))
    } else {
      await api('/item-templates', { method: 'POST', body })
      success(tr('viewsTemplateView.101d6d', '模板已创建'))
    }
    showEdit.value = false
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    saving.value = false
  }
}

function openApply(t: Template): void {
  applyTarget.value = t
  applyForm.value = {
    subjectId: subjects.value[0]?.id ?? '',
    count: 1,
  }
  showApply.value = true
}

async function apply(): Promise<void> {
  if (!applyTarget.value) return
  if (!applyForm.value.subjectId) {
    toastError(tr('viewsTemplateView.40daf9', '请选择目标主体'))
    return
  }
  applying.value = true
  try {
    const r = await api<{ created: number; ids: string[] }>(
      `/item-templates/${applyTarget.value.id}/apply`,
      {
        method: 'POST',
        body: {
          subjectId: Number(applyForm.value.subjectId),
          count: Math.min(50, Math.max(1, Number(applyForm.value.count) || 1)),
        },
      },
    )
    showApply.value = false
    success(tr('viewsTemplateView.408fdc', `已按模板创建 ${r.created} 条档案`))
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    applying.value = false
  }
}

function askDelete(t: Template): void {
  deleteTarget.value = t
  showDelete.value = true
}

async function confirmDelete(): Promise<void> {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    await api(`/item-templates/${deleteTarget.value.id}`, { method: 'DELETE' })
    showDelete.value = false
    success(tr('viewsTemplateView.8911a9', '模板已删除'))
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    deleting.value = false
  }
}

/** 标题预览：让用户在建模板时就看到 `{n}` 的实际效果 */
const titlePreview = computed(() => {
  const base = form.value.title.trim()
  if (!base) return ''
  if (base.includes('{n}')) return base.replaceAll('{n}', '1')
  return base
})

onMounted(load)
</script>

<template>
  <section>
    <div class="page-head">
      <div>
        <h1 class="page-title">{{ tr('TemplateView.dad23e', '条目模板') }}</h1>
        <p class="page-desc">
          把常用档案的骨架存成模板，套用时一次生成多条，省去重复填写。
        </p>
      </div>
      <button class="btn-primary" type="button" @click="openCreate">{{ tr('TemplateView.1eaf5c', '+ 新建模板') }}</button>
    </div>

    <p v-if="loading" class="hint">{{ tr('TemplateView.300ee3', '加载中…') }}</p>
    <p v-else-if="loadError" class="hint hint--error">{{ loadError }}</p>
    <p v-else-if="templates.length === 0" class="hint">
      还没有模板。点「新建模板」把常建的档案存下来（如「身份证」「职业资格证」）。
    </p>

    <ul v-else class="tpl-list">
      <li v-for="t in templates" :key="t.id" class="tpl-item">
        <div class="tpl-item__main">
          <div class="tpl-item__top">
            <span class="tpl-item__name">{{ t.name }}</span>
            <span class="chip">{{ categoryName(t.category) }}</span>
            <span class="chip chip--sens" :class="`chip--sens${t.sensitivity}`">
              {{ sensitivityName(t.sensitivity) }}
            </span>
          </div>
          <p class="tpl-item__title">{{ t.title }}</p>
          <div class="tpl-item__meta">
            <span>{{ statusName(t.status) }}</span>
            <span v-if="Number(t.expiresOffsetDays) > 0">
              有效期 +{{ t.expiresOffsetDays }} 天
            </span>
            <span v-if="t.issuer">{{ tr('TemplateView.89de45', '签发：') }}{{ t.issuer }}</span>
            <span>{{ tr('TemplateView.d9db02', '更新') }} {{ formatTime(t.updatedAt) }}</span>
          </div>
        </div>
        <div class="tpl-item__actions">
          <button class="btn-text" type="button" @click="openApply(t)">{{ tr('TemplateView.ed8305', '套用') }}</button>
          <button class="btn-text" type="button" @click="openEdit(t)">编辑</button>
          <button class="btn-text danger" type="button" @click="askDelete(t)">{{ tr('TemplateView.3755f5', '删除') }}</button>
        </div>
      </li>
    </ul>

    <!-- 新建 / 编辑 -->
    <AppSheet
      v-model="showEdit"
      ::title="isEditing ? tr('TemplateView.bbc586.edit', '编辑模板') : tr('TemplateView.bbc586.new', '新建模板')"
      size="md"
      :dismissible="!saving"
    >
      <div class="form-grid">
        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.bbc511', '模板名称') }} <em>*</em></span>
          <input
            v-model="form.name"
            class="field-control"
            type="text"
            maxlength="100"
            :placeholder="tr('TemplateView.635d03', '如 身份证（本人）')"
          />
        </label>

        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.016b05', '标题模板') }} <em>*</em></span>
          <input
            v-model="form.title"
            class="field-control"
            type="text"
            maxlength="200"
            :placeholder="tr('TemplateView.a339e5', '如 身份证-{n}，{n} 会替换为序号')"
          />
          <span v-if="titlePreview" class="field__hint">{{ tr('TemplateView.ad5aba', '预览：') }}{{ titlePreview }}</span>
        </label>

        <label class="field">
          <span class="field__label">{{ tr('TemplateView.435c52', '分类') }}</span>
          <select v-model.number="form.category" class="field-control" @change="onCategoryChange">
            <option v-for="c in categoryOptions" :key="c.code" :value="c.code">
              {{ c.name }}
            </option>
          </select>
        </label>
        <label class="field">
          <span class="field__label">{{ tr('TemplateView.c8165b', '敏感度') }}</span>
          <select v-model.number="form.sensitivity" class="field-control">
            <option v-for="s in sensitivityOptions" :key="s.value" :value="s.value">
              {{ s.label }}
            </option>
          </select>
        </label>

        <label class="field">
          <span class="field__label">{{ tr('TemplateView.a6bc04', '初始状态') }}</span>
          <select v-model.number="form.status" class="field-control">
            <option v-for="s in statusOptions" :key="s.value" :value="s.value">{{ s.label }}</option>
          </select>
        </label>
        <label class="field">
          <span class="field__label">{{ tr('TemplateView.236128', '有效期偏移（天）') }}</span>
          <input
            v-model.number="form.expiresOffsetDays"
            class="field-control"
            type="number"
            min="0"
            max="3650"
          />
          <span class="field__hint">{{ tr('TemplateView.91745b', '0 表示不设有效期；否则按套用当天 + N 天计算') }}</span>
        </label>

        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.8eb731', '签发机构') }}</span>
          <input v-model="form.issuer" class="field-control" type="text" :placeholder="tr('TemplateView.924b8c', '选填')" />
        </label>

        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.e03614', '备注') }}</span>
          <textarea v-model="form.remark" class="field-control" rows="2" :placeholder="tr('TemplateView.924b8c', '选填')" />
        </label>

        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.dd1b8e', '扩展字段默认值（JSON 对象）') }}</span>
          <textarea
            v-model="form.extraText"
            class="field-control field-control--mono"
            rows="4"
            spellcheck="false"
            placeholder='{"发证机关": "市公安局"}'
          />
          <span class="field__hint">{{ tr('TemplateView.63ac22', '套用时会原样写入每个新条目的扩展字段') }}</span>
        </label>
      </div>

      <template #footer>
        <button class="btn-ghost" type="button" :disabled="saving" @click="showEdit = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="saving" @click="save">
          {{ saving ? '保存中…' : '保存' }}
        </button>
      </template>
    </AppSheet>

    <!-- 套用 -->
    <AppSheet
      v-model="showApply"
      ::title="tr('TemplateView.f8231a', '`套用模板 · ${applyTarget?.name ?? \'\'}`')"
      size="sm"
      :dismissible="!applying"
    >
      <div v-if="subjects.length === 0" class="notice notice--warn">
        你还没有可用的档案主体，请先到「档案」页新建一个主体。
      </div>
      <div class="form-grid">
        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.3a138d', '目标主体') }} <em>*</em></span>
          <select v-model="applyForm.subjectId" class="field-control">
            <option v-for="s in subjects" :key="s.id" :value="s.id">{{ s.name }}</option>
          </select>
        </label>
        <label class="field field--full">
          <span class="field__label">{{ tr('TemplateView.918e10', '生成条数（1–50）') }}</span>
          <input
            v-model.number="applyForm.count"
            class="field-control"
            type="number"
            min="1"
            max="50"
          />
          <span class="field__hint">
            超过 1 条时，标题会按序号展开（`{n}` 占位或自动追加 ` (i)`）
          </span>
        </label>
      </div>
      <template #footer>
        <button class="btn-ghost" type="button" :disabled="applying" @click="showApply = false">
          取消
        </button>
        <button
          class="btn-primary"
          type="button"
          :disabled="applying || subjects.length === 0"
          @click="apply"
        >
          {{ applying ? '生成中…' : '生成档案' }}
        </button>
      </template>
    </AppSheet>

    <!-- 删除 -->
    <AppSheet v-model="showDelete" :title="tr('TemplateView.be7d83', '确认删除模板')" size="sm" :dismissible="!deleting">
      <p v-if="deleteTarget" class="hint">
        确定删除模板 <b>{{ deleteTarget.name }}</b> 吗？已按该模板生成的档案不受影响。
      </p>
      <template #footer>
        <button class="btn-ghost" type="button" :disabled="deleting" @click="showDelete = false">
          取消
        </button>
        <button class="btn-danger" type="button" :disabled="deleting" @click="confirmDelete">
          {{ deleting ? '删除中…' : '删除' }}
        </button>
      </template>
    </AppSheet>
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
.page-desc {
  margin: var(--sp-1) 0 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  line-height: 1.6;
  max-width: 640px;
}

.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin-top: var(--sp-4);
}
.hint--error {
  color: var(--danger);
}

.tpl-list {
  list-style: none;
  padding: 0;
  margin: var(--sp-4) 0 0;
  display: grid;
  gap: var(--sp-3);
}
.tpl-item {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-4);
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  transition: border-color var(--spring-fast) ease-out;
}
.tpl-item:hover {
  border-color: var(--border-strong, var(--border-subtle));
}
.tpl-item__main {
  min-width: 0;
  display: grid;
  gap: 6px;
}
.tpl-item__top {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
}
.tpl-item__name {
  font-weight: 600;
  font-size: var(--font-size-md);
}
.tpl-item__title {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  word-break: break-word;
}
.tpl-item__meta {
  display: flex;
  gap: var(--sp-3);
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-muted);
}
.tpl-item__actions {
  display: flex;
  gap: var(--sp-1);
  flex-shrink: 0;
}
.btn-text.danger {
  color: var(--danger);
}

.chip {
  font-size: 11px;
  padding: 1px 8px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  color: var(--text-secondary);
}
.chip--sens2 {
  background: color-mix(in srgb, var(--warning) 16%, transparent);
  color: var(--warning);
}
.chip--sens3 {
  background: color-mix(in srgb, var(--danger) 16%, transparent);
  color: var(--danger);
}

.form-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-3);
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
  font-size: 13px;
  color: var(--text-secondary);
}
.field__label em {
  color: var(--danger);
  font-style: normal;
}
.field__hint {
  font-size: 12px;
  color: var(--text-muted);
  line-height: 1.5;
}
.field-control--mono {
  font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 12px;
}

.notice {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
  padding: var(--sp-3);
  margin-bottom: var(--sp-3);
}
.notice--warn {
  color: var(--warning);
  background: color-mix(in srgb, var(--warning) 12%, transparent);
}

@media (max-width: 639px) {
  .form-grid {
    grid-template-columns: 1fr;
  }
  .tpl-item {
    flex-direction: column;
  }
  .tpl-item__actions {
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
