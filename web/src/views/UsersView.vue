<script setup lang="ts">
/**
 * 用户管理（FR-CFG-001）。
 *
 * 接口（后端 management.cj，权限 user:read:any / user:manage）：
 *   GET    /api/users                 列表（keyword/page/size）
 *   POST   /api/users                 新建
 *   POST   /api/users/:id/password    重置口令
 *   POST   /api/users/:id/status      启/停用（status 0/1）
 *   POST   /api/users/:id/unlock      解锁
 *   DELETE /api/users/:id            软删除
 *   GET/POST/DELETE /api/users/:id/roles  角色分配
 *   GET    /api/roles                 角色下拉
 *
 * 口令哈希永不出现在任何响应；前端不碰凭据。所有写操作以 Toast 反馈。
 */
import { ref, onMounted, computed } from 'vue'
import { api } from '../api/client'
import { useToast } from '../composables/useToast'
import AppSheet from '../components/AppSheet.vue'

const { success, error: toastError } = useToast()

/**
 * 注意：后端 rowToJson 把所有列都序列化为字符串（id/status/created_at_ms 均是），
 * 故这里按实际类型声明为 string，使用处用 Number() 归一化。
 */
interface UserRow {
  id: string | number
  username: string
  email: string | null
  phone: string | null
  nickname: string | null
  status: string | number
  failed_attempts: string | number
  perm_version: string | number
  kdf_cost: string | number
  created_at_ms: string | number
  version: string | number
}

interface Role {
  id: number
  code: string
  name: string
  is_builtin: boolean
  description: string
  max_data_level: number
}

/** listUserRoles 的列：code / name / subject_id / category / expires_ms */
interface UserRole {
  code: string
  name: string
  subject_id: string | number
  category: string | number
  expires_ms: string | number
}

const users = ref<UserRow[]>([])
const total = ref(0)
const page = ref(1)
const size = ref(10)
const keyword = ref('')
const loading = ref(false)
const error = ref('')

const roleOptions = ref<Role[]>([])

/** 新建用户 */
const showCreate = ref(false)
const newUser = ref({ username: '', nickname: '', email: '', phone: '', password: '' })
const creating = ref(false)

/** 重置口令 */
const showPwd = ref(false)
const pwdTarget = ref<UserRow | null>(null)
const newPwd = ref('')
const confirmPwd = ref('')
const resetting = ref(false)

/** 删除确认 */
const showDelete = ref(false)
const deleteTarget = ref<UserRow | null>(null)
const deleting = ref(false)

/** 角色管理 */
const showRoles = ref(false)
const roleTarget = ref<UserRow | null>(null)
const currentRoles = ref<UserRole[]>([])
const pickRole = ref('')
const savingRole = ref(false)

const totalPages = computed(() => Math.max(1, Math.ceil(total.value / size.value)))

const passwordOk = computed(() => {
  const p = newPwd.value
  const classes =
    (/[a-z]/.test(p) ? 1 : 0) +
    (/[A-Z]/.test(p) ? 1 : 0) +
    (/\d/.test(p) ? 1 : 0) +
    (/[^A-Za-z0-9]/.test(p) ? 1 : 0)
  return (
    p.length >= 8 &&
    classes >= 3 &&
    !/(.)\1\1/.test(p) &&
    (!pwdTarget.value || !p.toLowerCase().includes(pwdTarget.value.username.toLowerCase())) &&
    p === confirmPwd.value
  )
})

/** status 0 = 正常（后端 AuthService 以 status != 0 拒绝登录），非 0 = 停用 */
function isActive(u: UserRow): boolean {
  return Number(u.status) === 0
}

function maskEmail(v: string | null | undefined): string {
  if (!v) return '—'
  const [u, d] = v.split('@')
  if (!d) return v
  if (u.length <= 2) return `${u[0]}*@${d}`
  return `${u.slice(0, 2)}***@${d}`
}
function maskPhone(v: string | null | undefined): string {
  return v ? v.replace(/(\d{3})\d{4}(\d{4})/, '$1****$2') : '—'
}
function fmtTime(ms: string | number): string {
  const n = Number(ms)
  if (!n) return '—'
  const d = new Date(n)
  const pad = (n2: number) => String(n2).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

async function loadUsers(): Promise<void> {
  loading.value = true
  error.value = ''
  const qs = new URLSearchParams({
    keyword: keyword.value,
    page: String(page.value),
    size: String(size.value),
  }).toString()
  try {
    const data = await api<{ items: UserRow[]; total: number | string }>(`/users?${qs}`)
    users.value = data.items ?? []
    total.value = Number(data.total) || 0
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

function search(): void {
  page.value = 1
  loadUsers()
}

async function loadRoles(): Promise<void> {
  try {
    const data = await api<{ items: Role[] }>('/roles')
    roleOptions.value = data.items ?? []
  } catch {
    roleOptions.value = []
  }
}

async function createUser(): Promise<void> {
  if (!newUser.value.username || !newUser.value.password) {
    toastError('用户名与口令不能为空')
    return
  }
  creating.value = true
  try {
    await api<{ id: number }>('/users', {
      method: 'POST',
      body: {
        username: newUser.value.username,
        password: newUser.value.password,
        nickname: newUser.value.nickname || undefined,
        email: newUser.value.email || undefined,
        phone: newUser.value.phone || undefined,
      },
    })
    showCreate.value = false
    newUser.value = { username: '', nickname: '', email: '', phone: '', password: '' }
    success('用户已创建')
    loadUsers()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    creating.value = false
  }
}

function openReset(u: UserRow): void {
  pwdTarget.value = u
  newPwd.value = ''
  confirmPwd.value = ''
  showPwd.value = true
}
async function resetPassword(): Promise<void> {
  if (!passwordOk.value || !pwdTarget.value) {
    toastError('口令不满足安全策略或两次不一致')
    return
  }
  resetting.value = true
  try {
    await api<{ updated: boolean }>(`/users/${pwdTarget.value.id}/password`, {
      method: 'POST',
      body: { password: newPwd.value },
    })
    showPwd.value = false
    success('口令已重置')
    loadUsers()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    resetting.value = false
  }
}

async function toggleStatus(u: UserRow): Promise<void> {
  // status 0 = 正常，1 = 停用
  const next = isActive(u) ? 1 : 0
  try {
    await api(`/users/${u.id}/status`, { method: 'POST', body: { status: next } })
    success(next === 0 ? '已启用' : '已停用')
    loadUsers()
  } catch (e) {
    toastError((e as Error).message)
  }
}

async function unlock(u: UserRow): Promise<void> {
  try {
    await api(`/users/${u.id}/unlock`, { method: 'POST' })
    success('已解锁')
    loadUsers()
  } catch (e) {
    toastError((e as Error).message)
  }
}

function askDelete(u: UserRow): void {
  deleteTarget.value = u
  showDelete.value = true
}
async function confirmDelete(): Promise<void> {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    await api(`/users/${deleteTarget.value.id}`, { method: 'DELETE' })
    showDelete.value = false
    success('用户已删除')
    loadUsers()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    deleting.value = false
  }
}

async function openRoles(u: UserRow): Promise<void> {
  roleTarget.value = u
  pickRole.value = ''
  currentRoles.value = []
  showRoles.value = true
  try {
    const data = await api<{ items: UserRole[] }>(`/users/${u.id}/roles`)
    currentRoles.value = data.items ?? []
  } catch (e) {
    toastError((e as Error).message)
  }
}
async function assignRole(): Promise<void> {
  if (!roleTarget.value || !pickRole.value) return
  savingRole.value = true
  try {
    await api(`/users/${roleTarget.value.id}/roles`, {
      method: 'POST',
      body: { roleCode: pickRole.value },
    })
    pickRole.value = ''
    success('已分配角色')
    const data = await api<{ items: UserRole[] }>(`/users/${roleTarget.value.id}/roles`)
    currentRoles.value = data.items ?? []
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    savingRole.value = false
  }
}
async function revokeRole(roleCode: string): Promise<void> {
  if (!roleTarget.value) return
  try {
    await api(`/users/${roleTarget.value.id}/roles/${roleCode}`, { method: 'DELETE' })
    success('已移除角色')
    currentRoles.value = currentRoles.value.filter((r) => r.code !== roleCode)
  } catch (e) {
    toastError((e as Error).message)
  }
}

const availableRoles = computed(() =>
  roleOptions.value.filter((r) => !currentRoles.value.some((c) => c.code === r.code)),
)

function changePage(delta: number): void {
  const next = page.value + delta
  if (next < 1 || next > totalPages.value) return
  page.value = next
  loadUsers()
}

onMounted(() => {
  loadUsers()
  loadRoles()
})
</script>

<template>
  <section>
    <div class="page-head">
      <h1 class="page-title">用户管理</h1>
      <button class="btn-primary" type="button" @click="showCreate = true">+ 新建用户</button>
    </div>

    <div class="toolbar">
      <input
        v-model="keyword"
        class="field-control search"
        type="search"
        placeholder="搜索用户名 / 昵称 / 邮箱"
        @keyup.enter="search"
      />
      <button class="btn-ghost" type="button" @click="search">搜索</button>
    </div>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <div v-else class="card table-card">
      <table class="tbl">
        <thead>
          <tr>
            <th>用户</th>
            <th>联系方式</th>
            <th>状态</th>
            <th>失败次数</th>
            <th>创建时间</th>
            <th class="tbl__act">操作</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="u in users" :key="u.id">
            <td>
              <div class="u-name">{{ u.nickname || u.username }}</div>
              <div class="u-sub">@{{ u.username }} · ID {{ u.id }}</div>
            </td>
            <td>
              <div class="u-sub">{{ maskEmail(u.email) }}</div>
              <div class="u-sub">{{ maskPhone(u.phone) }}</div>
            </td>
            <td>
              <span class="badge" :class="isActive(u) ? 'badge--ok' : 'badge--off'">
                {{ isActive(u) ? '正常' : '已停用' }}
              </span>
            </td>
            <td>{{ u.failed_attempts }}</td>
            <td class="u-sub">{{ fmtTime(u.created_at_ms) }}</td>
            <td class="tbl__act">
              <div class="row-actions">
                <button class="btn-text" type="button" @click="openRoles(u)">角色</button>
                <button class="btn-text" type="button" @click="openReset(u)">改口令</button>
                <button class="btn-text" type="button" @click="toggleStatus(u)">
                  {{ isActive(u) ? '停用' : '启用' }}
                </button>
                <button class="btn-text" type="button" @click="unlock(u)">解锁</button>
                <button class="btn-text danger" type="button" @click="askDelete(u)">删除</button>
              </div>
            </td>
          </tr>
          <tr v-if="users.length === 0">
            <td colspan="6" class="empty">暂无用户</td>
          </tr>
        </tbody>
      </table>

      <div class="pager">
        <button class="btn-ghost" type="button" :disabled="page <= 1" @click="changePage(-1)">上一页</button>
        <span class="pager__info">第 {{ page }} / {{ totalPages }} 页 · 共 {{ total }} 人</span>
        <button class="btn-ghost" type="button" :disabled="page >= totalPages" @click="changePage(1)">下一页</button>
      </div>
    </div>

    <!-- 新建用户 -->
    <AppSheet v-model="showCreate" title="新建用户" size="md">
      <div class="form-grid">
        <label class="field">
          <span class="field__label">用户名 <em>*</em></span>
          <input v-model="newUser.username" class="field-control" type="text" autocomplete="username" placeholder="登录用户名" />
        </label>
        <label class="field">
          <span class="field__label">昵称</span>
          <input v-model="newUser.nickname" class="field-control" type="text" placeholder="选填" />
        </label>
        <label class="field">
          <span class="field__label">邮箱</span>
          <input v-model="newUser.email" class="field-control" type="email" placeholder="选填" />
        </label>
        <label class="field">
          <span class="field__label">手机号</span>
          <input v-model="newUser.phone" class="field-control" type="tel" placeholder="选填" />
        </label>
        <label class="field field--full">
          <span class="field__label">初始口令 <em>*</em></span>
          <input v-model="newUser.password" class="field-control" type="password" autocomplete="new-password" placeholder="至少 8 位，含 3 类字符" />
        </label>
      </div>
      <template #footer>
        <button class="btn-ghost" type="button" @click="showCreate = false">取消</button>
        <button class="btn-primary" type="button" :disabled="creating" @click="createUser">
          {{ creating ? '创建中…' : '创建' }}
        </button>
      </template>
    </AppSheet>

    <!-- 重置口令 -->
    <AppSheet v-model="showPwd" title="重置口令" size="sm">
      <p class="hint" v-if="pwdTarget">为用户 <b>{{ pwdTarget.username }}</b> 设置新口令</p>
      <div class="form-grid">
        <label class="field field--full">
          <span class="field__label">新口令 <em>*</em></span>
          <input v-model="newPwd" class="field-control" type="password" autocomplete="new-password" placeholder="至少 8 位，含 3 类字符" />
        </label>
        <label class="field field--full">
          <span class="field__label">确认新口令 <em>*</em></span>
          <input v-model="confirmPwd" class="field-control" type="password" autocomplete="new-password" placeholder="再次输入" />
        </label>
      </div>
      <template #footer>
        <button class="btn-ghost" type="button" @click="showPwd = false">取消</button>
        <button class="btn-primary" type="button" :disabled="!passwordOk || resetting" @click="resetPassword">
          {{ resetting ? '保存中…' : '保存' }}
        </button>
      </template>
    </AppSheet>

    <!-- 删除确认 -->
    <AppSheet v-model="showDelete" title="确认删除" size="sm" :dismissible="!deleting">
      <p class="hint" v-if="deleteTarget">
        确定删除用户 <b>{{ deleteTarget.username }}</b> 吗？该操作软删除，可在数据库恢复。
      </p>
      <template #footer>
        <button class="btn-ghost" type="button" :disabled="deleting" @click="showDelete = false">取消</button>
        <button class="btn-danger" type="button" :disabled="deleting" @click="confirmDelete">
          {{ deleting ? '删除中…' : '删除' }}
        </button>
      </template>
    </AppSheet>

    <!-- 角色管理 -->
    <AppSheet v-model="showRoles" :title="`角色管理 · ${roleTarget?.username ?? ''}`" size="lg">
      <div class="roles">
        <div class="roles__col">
          <h3 class="roles__h">当前角色</h3>
          <ul class="role-list">
            <li v-for="r in currentRoles" :key="r.code" class="role-chip">
              <span><b>{{ r.name }}</b> <span class="u-sub">{{ r.code }}</span></span>
              <button class="btn-text danger" type="button" @click="revokeRole(r.code)">移除</button>
            </li>
            <li v-if="currentRoles.length === 0" class="u-sub">尚未分配角色</li>
          </ul>
        </div>
        <div class="roles__col">
          <h3 class="roles__h">分配新角色</h3>
          <div class="assign">
            <select v-model="pickRole" class="field-control">
              <option value="" disabled>选择角色…</option>
              <option v-for="r in availableRoles" :key="r.code" :value="r.code">{{ r.name }}（{{ r.code }}）</option>
            </select>
            <button class="btn-primary" type="button" :disabled="!pickRole || savingRole" @click="assignRole">
              {{ savingRole ? '分配中…' : '分配' }}
            </button>
          </div>
        </div>
      </div>
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

.toolbar {
  display: flex;
  gap: var(--sp-2);
  margin: var(--sp-4) 0;
}
.search {
  max-width: 360px;
}

.table-card {
  padding: 0;
  overflow: hidden;
}
.tbl {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--font-size-sm);
}
.tbl th,
.tbl td {
  text-align: left;
  padding: var(--sp-3) var(--sp-4);
  border-bottom: 1px solid var(--border-subtle);
  vertical-align: middle;
}
.tbl th {
  color: var(--text-secondary);
  font-weight: 600;
  background: var(--bg-surface);
  position: sticky;
  top: 0;
}
.tbl tbody tr:hover {
  background: var(--bg-hover);
}
.tbl__act {
  width: 1%;
  white-space: nowrap;
}
.row-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 2px;
}
.u-name {
  font-weight: 600;
  color: var(--text-primary);
}
.u-sub {
  color: var(--text-muted);
  font-size: 12px;
}
.empty {
  text-align: center;
  color: var(--text-muted);
  padding: var(--sp-5);
}

.badge--ok {
  background: var(--success);
  color: #fff;
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}
.badge--off {
  background: var(--text-muted);
  color: #fff;
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}

.btn-text.danger {
  color: var(--danger);
}

.pager {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
}
.pager__info {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

/* 表单网格 */
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

/* 角色管理 */
.roles {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-5);
}
.roles__h {
  font-size: var(--font-size-md);
  margin: 0 0 var(--sp-3);
}
.role-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.role-chip {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-2);
  padding: var(--sp-2) var(--sp-3);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
}
.assign {
  display: flex;
  gap: var(--sp-2);
}
.assign .field-control {
  flex: 1;
}

@media (max-width: 900px) {
  .roles {
    grid-template-columns: 1fr;
  }
}
@media (max-width: 639px) {
  .form-grid {
    grid-template-columns: 1fr;
  }
  .tbl thead {
    display: none;
  }
  .tbl,
  .tbl tbody,
  .tbl tr,
  .tbl td {
    display: block;
    width: 100%;
  }
  .tbl tr {
    border-bottom: 1px solid var(--border-subtle);
    padding: var(--sp-2) 0;
  }
  .tbl td {
    border: none;
    padding: 4px var(--sp-4);
  }
  .tbl__act {
    white-space: normal;
  }
}
</style>
