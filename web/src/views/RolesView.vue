<script setup lang="ts">
/**
 * 角色与权限管理（FR-CFG-002 / FR-ACL-002 / FR-ACL-013）。
 *
 * 接口（权限 acl:manage）：
 *   GET    /api/roles                  角色列表
 *   GET    /api/perms                  权限点目录
 *   POST   /api/roles                  新建自定义角色
 *   DELETE /api/roles/:code            删除自定义角色
 *   POST   /api/roles/:code/perms      设置角色权限（整集替换）
 *   GET    /api/admin/permission-preview?role=<code>[&userId=]  权限预览
 *
 * 说明：后端 assignPerms 为「整集替换」语义，且暂未提供「读角色当前权限」的接口，
 * 因此本页对【自定义角色】采用「整集设置」模式（打开即空选，保存即覆盖），
 * 对【内置角色】仅展示权限目录（只读），避免误清空 org_admin 等系统角色权限。
 *
 * 权限预览（FR-ACL-013 · 方案 A）刻意只给**统计口径**：可见条目数、分类分布、
 * 字段可见上限。不返回任何条目内容 —— 预览是「验证配置」的工具，
 * 不是「以他人身份浏览数据」的后门。
 */
import { ref, onMounted, computed } from 'vue'
import { t } from '../i18n'
import { api } from '../api/client'
import { categoryName } from '../composables/useCatalog'
import { useToast } from '../composables/useToast'
import AppSheet from '../components/AppSheet.vue'

const { success, error: toastError } = useToast()

/**
 * 后端把布尔序列化为 "t"/"f" 字符串、数字序列化为字符串，
 * 故 is_builtin 需按值归一化，不能直接当 boolean 用（"f" 也是真值）。
 */
interface Role {
  id: string | number
  code: string
  name: string
  is_builtin: string | boolean
  description: string | null
  max_data_level: string | number
}
interface Perm {
  id: number
  code: string
  name: string
  domain: string
  action: string
  scope: string
  is_sensitive: boolean
  description: string
}

const roles = ref<Role[]>([])
const perms = ref<Perm[]>([])
const loading = ref(false)
const error = ref('')

/** 新建角色 */
const showCreate = ref(false)
const newRole = ref({ code: '', name: '', description: '', maxDataLevel: 1 })
const creating = ref(false)

/** 权限编辑器 */
const showPerms = ref(false)
const permTarget = ref<Role | null>(null)
const selected = ref<Set<string>>(new Set())
const savingPerms = ref(false)

/** 删除确认 */
const showDelete = ref(false)
const deleteTarget = ref<Role | null>(null)
const deleting = ref(false)

/** 权限预览（FR-ACL-013 · 方案 A） */
interface PreviewData {
  role: { code: string; name: string; maxDataLevel: number }
  scope: string
  userCount: number
  subjectCount: number
  visibleItemCount: number
  perms: string[]
  categories: Array<{ category: number; count: number }>
  fields: {
    maxDataLevel: number
    visibleLevels: number[]
    maskedLevels: number[]
    policy: string
  }
  note: string
}
const showPreview = ref(false)
const previewTarget = ref<Role | null>(null)
const previewData = ref<PreviewData | null>(null)
const previewLoading = ref(false)
const previewError = ref('')
const previewUserId = ref('')

function isBuiltin(r: Role | null | undefined): boolean {
  if (!r) return false
  const v = r.is_builtin
  return v === true || v === 't' || v === 'true' || v === '1'
}

const permsByDomain = computed(() => {
  const map: Record<string, Perm[]> = {}
  for (const p of perms.value) {
    ;(map[p.domain] ??= []).push(p)
  }
  return map
})
const domainNames = computed(() => Object.keys(permsByDomain.value).sort())

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    const [r, p] = await Promise.all([
      api<{ items: Role[] }>('/roles'),
      api<{ items: Perm[] }>('/perms'),
    ])
    roles.value = r.items ?? []
    perms.value = p.items ?? []
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

async function createRole(): Promise<void> {
  if (!newRole.value.code || !newRole.value.name) {
    toastError('角色编码与名称不能为空')
    return
  }
  creating.value = true
  try {
    await api<{ id: number }>('/roles', {
      method: 'POST',
      body: {
        code: newRole.value.code,
        name: newRole.value.name,
        description: newRole.value.description,
        maxDataLevel: newRole.value.maxDataLevel,
      },
    })
    showCreate.value = false
    newRole.value = { code: '', name: '', description: '', maxDataLevel: 1 }
    success('角色已创建')
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    creating.value = false
  }
}

function openPerms(r: Role): void {
  permTarget.value = r
  selected.value = new Set()
  showPerms.value = true
}
async function savePerms(): Promise<void> {
  if (!permTarget.value) return
  savingPerms.value = true
  try {
    await api(`/roles/${permTarget.value.code}/perms`, {
      method: 'POST',
      body: { perms: [...selected.value] },
    })
    success(`已为「${permTarget.value.name}」设置 ${selected.value.size} 项权限`)
    showPerms.value = false
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    savingPerms.value = false
  }
}
function togglePerm(code: string): void {
  const s = new Set(selected.value)
  if (s.has(code)) s.delete(code)
  else s.add(code)
  selected.value = s
}

function askDelete(r: Role): void {
  deleteTarget.value = r
  showDelete.value = true
}async function confirmDelete(): Promise<void> {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    await api(`/roles/${deleteTarget.value.code}`, { method: 'DELETE' })
    showDelete.value = false
    success('角色已删除')
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    deleting.value = false
  }
}

// ---- 权限预览（FR-ACL-013） ----

function openPreview(r: Role): void {
  previewTarget.value = r
  previewUserId.value = ''
  previewData.value = null
  previewError.value = ''
  showPreview.value = true
  loadPreview()
}

async function loadPreview(): Promise<void> {
  if (!previewTarget.value) return
  previewLoading.value = true
  previewError.value = ''
  try {
    const q = new URLSearchParams({ role: previewTarget.value.code })
    const uid = previewUserId.value.trim()
    if (uid) q.set('userId', uid)
    previewData.value = await api<PreviewData>(`/admin/permission-preview?${q.toString()}`)
  } catch (e) {
    previewError.value = (e as Error).message
    previewData.value = null
  } finally {
    previewLoading.value = false
  }
}

/** 主体范围的可读说明 */
function scopeText(d: PreviewData): string {
  if (d.scope === 'any') return '全机构主体'
  if (d.scope.startsWith('user:')) return `指定用户（ID ${d.scope.slice(5)}）的可访问主体`
  return '仅本人范围（该角色不含 archive:*:any，故不猜测他人主体）'
}

/** 分类分布按数量倒序，只取前 6 个展示 */
const previewCategories = computed(() => {
  const list = previewData.value?.categories ?? []
  return [...list].sort((a, b) => b.count - a.count).slice(0, 6)
})

onMounted(load)
</script>

<template>
  <section>
    <div class="page-head">
      <h1 class="page-title">{{ t('RolesView.0c1a09', '角色与权限') }}</h1>
      <button class="btn-primary" type="button" @click="showCreate = true">{{ t('RolesView.e40632', '+ 新建角色') }}</button>
    </div>

    <p v-if="loading" class="hint">{{ t('RolesView.300ee3', '加载中…') }}</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <div v-else class="grid">
      <div v-for="r in roles" :key="r.id" class="card role-card">
        <div class="role-card__top">
          <div>
            <div class="role-name">{{ r.name }}</div>
            <div class="u-sub">{{ r.code }}</div>
          </div>
          <span class="badge" :class="isBuiltin(r) ? 'badge--builtin' : 'badge--custom'">
            {{ isBuiltin(r) ? '内置' : '自定义' }}
          </span>
        </div>
        <p class="role-desc">{{ r.description || '（无描述）' }}</p>
        <div class="role-meta">{{ t('RolesView.bff342', '数据级别上限：') }}{{ r.max_data_level }}</div>
        <div class="role-actions">
          <button class="btn-text" type="button" @click="openPerms(r)">{{ t('RolesView.560165', '权限') }}</button>
          <button class="btn-text" type="button" @click="openPreview(r)">{{ t('RolesView.de61aa', '预览') }}</button>
          <button
            v-if="!isBuiltin(r)"
            class="btn-text danger"
            type="button"
            @click="askDelete(r)"
          >
            删除
          </button>
        </div>
      </div>
    </div>

    <!-- 新建角色 -->
    <AppSheet v-model="showCreate" :title="t('RolesView.7a0524', '新建角色')" size="sm">
      <div class="form-grid">
        <label class="field">
          <span class="field__label">{{ t('RolesView.c12ace', '角色编码') }} <em>*</em></span>
          <input v-model="newRole.code" class="field-control" type="text" :placeholder="t('RolesView.e330ea', '如 org_admin')" />
        </label>
        <label class="field">
          <span class="field__label">{{ t('RolesView.3aa1f0', '角色名称') }} <em>*</em></span>
          <input v-model="newRole.name" class="field-control" type="text" :placeholder="t('RolesView.234da4', '如 机构管理员')" />
        </label>
        <label class="field field--full">
          <span class="field__label">{{ t('RolesView.412f54', '描述') }}</span>
          <input v-model="newRole.description" class="field-control" type="text" :placeholder="t('RolesView.924b8c', '选填')" />
        </label>
        <label class="field field--full">
          <span class="field__label">{{ t('RolesView.4f7896', '数据级别上限') }}</span>
          <input v-model.number="newRole.maxDataLevel" class="field-control" type="number" min="1" max="5" />
        </label>
      </div>
      <template #footer>
        <button class="btn-ghost" type="button" @click="showCreate = false">{{ t('RolesView.4d0b46', '取消') }}</button>
        <button class="btn-primary" type="button" :disabled="creating" @click="createRole">
          {{ creating ? '创建中…' : '创建' }}
        </button>
      </template>
    </AppSheet>

    <!-- 权限设置 -->
    <AppSheet v-model="showPerms" ::title="`权限设置 · ${permTarget?.name ?? ''}`" size="lg">
      <div v-if="isBuiltin(permTarget)" class="notice">
        内置角色由系统管理，此处仅展示权限目录（只读）。如需调整，请新建自定义角色后分配。
      </div>
      <p v-else class="notice notice--warn">
        保存将<b>{{ t('RolesView.d9ba52', '整集覆盖') }}</b>该角色的权限，请完整勾选所需权限后再保存。
      </p>

      <div class="perm-domains">
        <div v-for="dom in domainNames" :key="dom" class="perm-domain">
          <h3 class="perm-domain__h">
            {{ dom }}
            <span class="u-sub">{{ permsByDomain[dom].length }} 项</span>
          </h3>
          <div class="perm-list">
            <label
              v-for="p in permsByDomain[dom]"
              :key="p.code"
              class="perm-item"
              :class="{ 'perm-item--on': selected.has(p.code) }"
            >
              <input
                type="checkbox"
                :checked="selected.has(p.code)"
                :disabled="isBuiltin(permTarget)"
                @change="togglePerm(p.code)"
              />
              <span class="perm-item__body">
                <span class="perm-item__name">
                  {{ p.name }}
                  <span v-if="p.is_sensitive" class="tag-sens">{{ t('RolesView.e4d1f0', '敏感') }}</span>
                </span>
                <span class="u-sub">{{ p.code }} · {{ p.description || '—' }}</span>
              </span>
            </label>
          </div>
        </div>
      </div>

      <template #footer>
        <span class="sel-count">{{ t('RolesView.f24ddc', '已选') }} {{ selected.size }} {{ t('RolesView.64728a', '项') }}</span>
        <button class="btn-ghost" type="button" @click="showPerms = false">{{ t('RolesView.4d0b46', '取消') }}</button>
        <button
          class="btn-primary"
          type="button"
          :disabled="isBuiltin(permTarget) || savingPerms"
          @click="savePerms"
        >
          {{ savingPerms ? '保存中…' : '保存' }}
        </button>
      </template>
    </AppSheet>

    <!-- 权限预览（FR-ACL-013 · 方案 A） -->
    <AppSheet
      v-model="showPreview"
      ::title="`权限预览 · ${previewTarget?.name ?? ''}`"
      size="md"
    >
      <div class="notice">
        预览只统计「能看见多少」，<b>{{ t('RolesView.7fe718', '不展示任何条目内容') }}</b>。可见性口径与档案列表页一致：
        可访问主体内 + 敏感度 ≤ 该角色的数据级别上限。
      </div>

      <div class="preview-user">
        <label class="field">
          <span class="field__label">{{ t('RolesView.fc8a67', '按某用户的真实主体计算（选填用户 ID）') }}</span>
          <input
            v-model="previewUserId"
            class="field-control"
            type="text"
            inputmode="numeric"
            :placeholder="t('RolesView.a7caa7', '留空则按角色声明的范围统计')"
          />
        </label>
        <button class="btn-ghost" type="button" :disabled="previewLoading" @click="loadPreview">
          重新计算
        </button>
      </div>

      <p v-if="previewLoading" class="hint">{{ t('RolesView.701173', '计算中…') }}</p>
      <p v-else-if="previewError" class="hint hint--error">{{ previewError }}</p>

      <div v-else-if="previewData" class="preview">
        <div class="preview-stats">
          <div class="stat">
            <span class="stat__num">{{ previewData.visibleItemCount }}</span>
            <span class="stat__label">{{ t('RolesView.f1bd1d', '可见条目') }}</span>
          </div>
          <div class="stat">
            <span class="stat__num">{{ previewData.subjectCount }}</span>
            <span class="stat__label">{{ t('RolesView.944f85', '覆盖主体') }}</span>
          </div>
          <div class="stat">
            <span class="stat__num">{{ previewData.userCount }}</span>
            <span class="stat__label">{{ t('RolesView.432f86', '拥有该角色的用户') }}</span>
          </div>
        </div>

        <dl class="kv">
          <dt>{{ t('RolesView.584428', '主体范围') }}</dt>
          <dd>{{ scopeText(previewData) }}</dd>
          <dt>{{ t('RolesView.4f7896', '数据级别上限') }}</dt>
          <dd>{{ previewData.fields.maxDataLevel }}</dd>
          <dt>{{ t('RolesView.087d90', '可见敏感度') }}</dt>
          <dd>{{ previewData.fields.visibleLevels.join(' / ') || '—' }}</dd>
          <dt>{{ t('RolesView.79255c', '掩码敏感度') }}</dt>
          <dd>
            {{ previewData.fields.maskedLevels.join(' / ') || '无（该角色可见全部级别）' }}
          </dd>
          <dt>{{ t('RolesView.b298af', '权限点数') }}</dt>
          <dd>{{ previewData.perms.length }} 项</dd>
        </dl>

        <h3 class="form__section">{{ t('RolesView.6c3aef', '可见条目按分类分布') }}</h3>
        <p v-if="previewCategories.length === 0" class="hint">{{ t('RolesView.85d965', '该范围内没有可见条目。') }}</p>
        <ul v-else class="cat-list">
          <li v-for="c in previewCategories" :key="c.category" class="cat-row">
            <span class="cat-row__name">{{ categoryName(c.category) }}</span>
            <span class="cat-row__bar">
              <span
                class="cat-row__fill"
                :style="{
                  width: `${Math.round((c.count / Math.max(1, previewData.visibleItemCount)) * 100)}%`,
                }"
              />
            </span>
            <span class="cat-row__num">{{ c.count }}</span>
          </li>
        </ul>

        <p class="preview-policy">{{ previewData.fields.policy }}</p>
        <p class="preview-note">{{ previewData.note }}</p>
      </div>

      <template #footer>
        <button class="btn-ghost" type="button" @click="showPreview = false">{{ t('RolesView.6c14bd', '关闭') }}</button>
      </template>
    </AppSheet>

    <!-- 删除确认 -->
    <AppSheet v-model="showDelete" :title="t('RolesView.3c06ab', '确认删除')" size="sm" :dismissible="!deleting">
      <p class="hint" v-if="deleteTarget">
        确定删除自定义角色 <b>{{ deleteTarget.name }}</b>（{{ deleteTarget.code }}）吗？
      </p>
      <template #footer>
        <button class="btn-ghost" type="button" :disabled="deleting" @click="showDelete = false">{{ t('RolesView.4d0b46', '取消') }}</button>
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
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  flex-wrap: wrap;
}
.page-title {
  font-size: var(--font-size-xl);
  margin: 0;
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}
.u-sub {
  color: var(--text-muted);
  font-size: 12px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: var(--sp-4);
  margin-top: var(--sp-4);
}
.role-card {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.role-card__top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-2);
}
.role-name {
  font-weight: 600;
  font-size: var(--font-size-lg);
}
.role-desc {
  margin: 0;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  flex: 1;
}
.role-meta {
  font-size: 12px;
  color: var(--text-muted);
}
.role-actions {
  display: flex;
  gap: var(--sp-2);
  border-top: 1px solid var(--border-subtle);
  padding-top: var(--sp-2);
}

.badge--builtin {
  background: var(--accent-soft, #e8f0fe);
  color: var(--accent);
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}
.badge--custom {
  background: var(--bg-hover);
  color: var(--text-secondary);
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}

.btn-text.danger {
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

.notice {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
  padding: var(--sp-3);
  margin-bottom: var(--sp-4);
}
.notice--warn {
  color: var(--warning);
  background: color-mix(in srgb, var(--warning) 12%, transparent);
}

.perm-domains {
  display: grid;
  gap: var(--sp-4);
}
.perm-domain__h {
  font-size: var(--font-size-md);
  margin: 0 0 var(--sp-2);
  display: flex;
  align-items: baseline;
  gap: var(--sp-2);
}
.perm-list {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-2);
}
.perm-item {
  display: flex;
  gap: var(--sp-2);
  align-items: flex-start;
  padding: var(--sp-2) var(--sp-3);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-sm);
  cursor: pointer;
  transition: background-color var(--spring-fast) ease-out, border-color var(--spring-fast) ease-out;
}
.perm-item:hover {
  background: var(--bg-hover);
}
.perm-item--on {
  border-color: var(--accent);
  background: var(--accent-soft);
}
.perm-item input {
  margin-top: 3px;
  accent-color: var(--accent);
}
.perm-item__body {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.perm-item__name {
  font-weight: 500;
  font-size: var(--font-size-sm);
}
.tag-sens {
  background: var(--sens-high);
  color: #fff;
  font-size: 11px;
  padding: 1px 6px;
  border-radius: var(--g3-pill);
  margin-left: 4px;
}

.sel-count {
  margin-right: auto;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  align-self: center;
}

/* ---- 权限预览（FR-ACL-013） ---- */
.preview-user {
  display: flex;
  align-items: flex-end;
  gap: var(--sp-2);
  margin-bottom: var(--sp-4);
}
.preview-user .field {
  flex: 1;
}
.preview-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: var(--sp-2);
  margin-bottom: var(--sp-4);
}
.stat {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: var(--sp-3);
  background: var(--bg-hover);
  border-radius: var(--g3-md);
}
.stat__num {
  font-size: var(--font-size-xl);
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  color: var(--text-primary);
}
.stat__label {
  font-size: 12px;
  color: var(--text-muted);
}

.cat-list {
  list-style: none;
  padding: 0;
  margin: 0 0 var(--sp-3);
  display: grid;
  gap: var(--sp-2);
}
.cat-row {
  display: grid;
  grid-template-columns: 96px 1fr 40px;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--font-size-sm);
}
.cat-row__name {
  color: var(--text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cat-row__bar {
  height: 6px;
  background: var(--bg-hover);
  border-radius: var(--g3-pill);
  overflow: hidden;
}
.cat-row__fill {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: var(--g3-pill);
}
.cat-row__num {
  text-align: right;
  color: var(--text-muted);
  font-variant-numeric: tabular-nums;
}

.preview-policy,
.preview-note {
  margin: 0 0 var(--sp-2);
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-secondary);
}
.preview-note {
  color: var(--text-muted);
  padding-top: var(--sp-2);
  border-top: 1px solid var(--border-subtle);
}

@media (max-width: 639px) {
  .form-grid,
  .perm-list {
    grid-template-columns: 1fr;
  }
  .preview-stats {
    grid-template-columns: 1fr;
  }
  .preview-user {
    flex-direction: column;
    align-items: stretch;
  }
  .cat-row {
    grid-template-columns: 76px 1fr 32px;
  }
}
</style>
