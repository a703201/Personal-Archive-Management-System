<script setup lang="ts">
/**
 * 角色与权限管理（FR-CFG-002 / FR-ACL-002）。
 *
 * 接口（权限 acl:manage）：
 *   GET    /api/roles                  角色列表
 *   GET    /api/perms                  权限点目录
 *   POST   /api/roles                  新建自定义角色
 *   DELETE /api/roles/:code            删除自定义角色
 *   POST   /api/roles/:code/perms      设置角色权限（整集替换）
 *
 * 说明：后端 assignPerms 为「整集替换」语义，且暂未提供「读角色当前权限」的接口，
 * 因此本页对【自定义角色】采用「整集设置」模式（打开即空选，保存即覆盖），
 * 对【内置角色】仅展示权限目录（只读），避免误清空 org_admin 等系统角色权限。
 */
import { ref, onMounted, computed } from 'vue'
import { api } from '../api/client'
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
}
async function confirmDelete(): Promise<void> {
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

onMounted(load)
</script>

<template>
  <section>
    <div class="page-head">
      <h1 class="page-title">角色与权限</h1>
      <button class="btn-primary" type="button" @click="showCreate = true">+ 新建角色</button>
    </div>

    <p v-if="loading" class="hint">加载中…</p>
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
        <div class="role-meta">数据级别上限：{{ r.max_data_level }}</div>
        <div class="role-actions">
          <button class="btn-text" type="button" @click="openPerms(r)">权限</button>
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
    <AppSheet v-model="showCreate" title="新建角色" size="sm">
      <div class="form-grid">
        <label class="field">
          <span class="field__label">角色编码 <em>*</em></span>
          <input v-model="newRole.code" class="field-control" type="text" placeholder="如 org_admin" />
        </label>
        <label class="field">
          <span class="field__label">角色名称 <em>*</em></span>
          <input v-model="newRole.name" class="field-control" type="text" placeholder="如 机构管理员" />
        </label>
        <label class="field field--full">
          <span class="field__label">描述</span>
          <input v-model="newRole.description" class="field-control" type="text" placeholder="选填" />
        </label>
        <label class="field field--full">
          <span class="field__label">数据级别上限</span>
          <input v-model.number="newRole.maxDataLevel" class="field-control" type="number" min="1" max="5" />
        </label>
      </div>
      <template #footer>
        <button class="btn-ghost" type="button" @click="showCreate = false">取消</button>
        <button class="btn-primary" type="button" :disabled="creating" @click="createRole">
          {{ creating ? '创建中…' : '创建' }}
        </button>
      </template>
    </AppSheet>

    <!-- 权限设置 -->
    <AppSheet v-model="showPerms" :title="`权限设置 · ${permTarget?.name ?? ''}`" size="lg">
      <div v-if="isBuiltin(permTarget)" class="notice">
        内置角色由系统管理，此处仅展示权限目录（只读）。如需调整，请新建自定义角色后分配。
      </div>
      <p v-else class="notice notice--warn">
        保存将<b>整集覆盖</b>该角色的权限，请完整勾选所需权限后再保存。
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
                  <span v-if="p.is_sensitive" class="tag-sens">敏感</span>
                </span>
                <span class="u-sub">{{ p.code }} · {{ p.description || '—' }}</span>
              </span>
            </label>
          </div>
        </div>
      </div>

      <template #footer>
        <span class="sel-count">已选 {{ selected.size }} 项</span>
        <button class="btn-ghost" type="button" @click="showPerms = false">取消</button>
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

    <!-- 删除确认 -->
    <AppSheet v-model="showDelete" title="确认删除" size="sm" :dismissible="!deleting">
      <p class="hint" v-if="deleteTarget">
        确定删除自定义角色 <b>{{ deleteTarget.name }}</b>（{{ deleteTarget.code }}）吗？
      </p>
      <template #footer>
        <button class="btn-ghost" type="button" :disabled="deleting" @click="showDelete = false">取消</button>
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

@media (max-width: 639px) {
  .form-grid,
  .perm-list {
    grid-template-columns: 1fr;
  }
}
</style>
