<script setup lang="ts">
/**
 * 个人主页（FR-UX-001）。
 *
 * 数据来自 /api/me：账号、昵称、掩码后的联系方式、权限点。
 * 注意后端**不会**返回任何凭据字段（口令哈希 / KDF 参数），
 * 前端也没有任何途径拿到 —— 这是设计上的保证，不是"懒得展示"。
 *
 * 【自助维护】
 *   PUT  /api/me            改昵称 / 邮箱 / 手机号
 *   POST /api/me/password   改口令（验原口令 + 策略 + 24h 间隔）
 *
 * 两个坑：
 *   ① /api/me 的邮箱与手机号是**掩码值**，不能回填到输入框再原样提交 ——
 *      否则会把真实值覆盖成星号。故输入框留空，仅提交用户实际填写的内容。
 *   ② 改口令成功后后端会吊销全部会话（含当前），必须清 token 并跳登录。
 */
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { api, clearToken } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import { useToast } from '../composables/useToast'

const router = useRouter()
const toast = useToast()

interface Me {
  id: number | string
  username: string
  nickname: string
  email: string
  phone: string
  status: number | string
  perms: string[]
}

const me = ref<Me | null>(null)
const loading = ref(true)
const error = ref('')

/** 权限点按域分组展示（域:动作:范围） */
const groupedPerms = ref<Record<string, string[]>>({})

function groupPerms(perms: string[]): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const p of perms) {
    const domain = p.split(':')[0] ?? 'other'
    ;(out[domain] ??= []).push(p)
  }
  return out
}

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    me.value = await api<Me>('/me')
    groupedPerms.value = groupPerms(me.value.perms ?? [])
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

onMounted(load)

// ---------------------------------------------------------------
// 编辑资料
// ---------------------------------------------------------------

const showEdit = ref(false)
const savingProfile = ref(false)
const editForm = ref({ nickname: '', email: '', phone: '' })

function openEdit(): void {
  const m = me.value
  if (!m) return
  // 昵称是明文可直接回填；联系方式是掩码值，留空表示不修改
  editForm.value = { nickname: m.nickname ?? '', email: '', phone: '' }
  showEdit.value = true
}

async function saveProfile(): Promise<void> {
  const m = me.value
  if (!m) return
  const body: Record<string, string> = {}
  const nick = editForm.value.nickname.trim()
  const email = editForm.value.email.trim()
  const phone = editForm.value.phone.trim()
  if (nick !== (m.nickname ?? '')) body.nickname = nick
  if (email) body.email = email
  if (phone) body.phone = phone
  if (Object.keys(body).length === 0) {
    toast.warning('没有需要保存的修改')
    return
  }
  savingProfile.value = true
  try {
    await api('/me', { method: 'PUT', body })
    toast.success('资料已更新')
    showEdit.value = false
    await load()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    savingProfile.value = false
  }
}

// ---------------------------------------------------------------
// 修改口令
// ---------------------------------------------------------------

const showPwd = ref(false)
const savingPwd = ref(false)
const pwdForm = ref({ old: '', next: '', confirm: '' })

/** 与后端 PasswordPolicy 对齐：≥12 位、≥3 类字符、无连续重复 */
const pwdPolicy = computed(() => {
  const p = pwdForm.value.next
  const classes =
    Number(/[a-z]/.test(p)) +
    Number(/[A-Z]/.test(p)) +
    Number(/[0-9]/.test(p)) +
    Number(/[^a-zA-Z0-9]/.test(p))
  return {
    length: p.length >= 12,
    classes: classes >= 3,
    noRepeat: p.length === 0 || !/(.)\1\1/.test(p),
    match: p.length > 0 && p === pwdForm.value.confirm,
    different: p.length > 0 && p !== pwdForm.value.old,
  }
})

const pwdOk = computed(
  () =>
    pwdPolicy.value.length &&
    pwdPolicy.value.classes &&
    pwdPolicy.value.noRepeat &&
    pwdPolicy.value.match &&
    pwdPolicy.value.different,
)

function openPwd(): void {
  pwdForm.value = { old: '', next: '', confirm: '' }
  showPwd.value = true
}

async function changePassword(): Promise<void> {
  if (!pwdOk.value) {
    toast.warning('新口令未满足要求，请按提示调整')
    return
  }
  savingPwd.value = true
  try {
    await api('/me/password', {
      method: 'POST',
      body: { oldPassword: pwdForm.value.old, newPassword: pwdForm.value.next },
    })
    showPwd.value = false
    toast.success('口令已修改，请用新口令重新登录')
    // 后端已吊销全部会话，本地令牌立即失效
    clearToken()
    setTimeout(() => {
      void router.replace({ name: 'login' })
    }, 900)
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    savingPwd.value = false
  }
}
</script>

<template>
  <section>
    <h1 class="page-title">个人主页</h1>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <template v-else-if="me">
      <div class="card profile">
        <div class="avatar">{{ (me.nickname || me.username).slice(0, 1) }}</div>
        <div class="profile__info">
          <div class="profile__name">{{ me.nickname || me.username }}</div>
          <div class="profile__sub">@{{ me.username }} · ID {{ me.id }}</div>
        </div>
        <div class="profile__actions">
          <button class="btn-ghost" type="button" @click="openEdit">编辑资料</button>
          <button class="btn-text" type="button" @click="openPwd">修改口令</button>
        </div>
      </div>

      <h2 class="section-title">联系方式</h2>
      <div class="card">
        <dl class="kv">
          <dt>邮箱</dt>
          <dd>{{ me.email || '—' }}</dd>
          <dt>手机号</dt>
          <dd>{{ me.phone || '—' }}</dd>
          <dt>账号状态</dt>
          <dd>{{ Number(me.status) === 0 ? '正常' : '已停用' }}</dd>
        </dl>
        <p class="hint">联系方式默认掩码展示，完整值需在各自业务场景中按权限查看。</p>
      </div>

      <h2 class="section-title">权限点（{{ me.perms.length }}）</h2>
      <div class="card">
        <div v-for="(list, domain) in groupedPerms" :key="domain" class="perm-group">
          <div class="perm-group__domain">{{ domain }}</div>
          <div class="perm-group__list">
            <code v-for="p in list" :key="p" class="perm-chip">{{ p }}</code>
          </div>
        </div>
      </div>
    </template>

    <!-- 编辑资料 -->
    <AppSheet v-model="showEdit" title="编辑资料" size="sm" :dismissible="!savingProfile">
      <div class="form">
        <label class="field">
          <span class="field__label">昵称</span>
          <input v-model="editForm.nickname" class="field-control" maxlength="32" />
        </label>
        <label class="field">
          <span class="field__label">邮箱</span>
          <input
            v-model="editForm.email"
            class="field-control"
            type="email"
            autocomplete="email"
            :placeholder="me?.email || '未设置'"
          />
        </label>
        <label class="field">
          <span class="field__label">手机号</span>
          <input
            v-model="editForm.phone"
            class="field-control"
            type="tel"
            autocomplete="tel"
            :placeholder="me?.phone || '未设置'"
          />
        </label>
      </div>
      <p class="hint">
        邮箱与手机号当前以掩码显示，输入框留空表示「保持不变」；两者至少保留一项。
      </p>
      <div class="sheet-actions">
        <button class="btn-ghost" type="button" :disabled="savingProfile" @click="showEdit = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="savingProfile" @click="saveProfile">
          {{ savingProfile ? '保存中…' : '保存' }}
        </button>
      </div>
    </AppSheet>

    <!-- 修改口令 -->
    <AppSheet v-model="showPwd" title="修改口令" size="sm" :dismissible="!savingPwd">
      <div class="form">
        <label class="field">
          <span class="field__label">原口令</span>
          <input
            v-model="pwdForm.old"
            class="field-control"
            type="password"
            autocomplete="current-password"
          />
        </label>
        <label class="field">
          <span class="field__label">新口令</span>
          <input
            v-model="pwdForm.next"
            class="field-control"
            type="password"
            autocomplete="new-password"
          />
        </label>
        <label class="field">
          <span class="field__label">确认新口令</span>
          <input
            v-model="pwdForm.confirm"
            class="field-control"
            type="password"
            autocomplete="new-password"
          />
        </label>
      </div>

      <ul class="policy">
        <li :class="{ done: pwdPolicy.length }">至少 12 位</li>
        <li :class="{ done: pwdPolicy.classes }">含至少 3 类字符（大小写 / 数字 / 符号）</li>
        <li :class="{ done: pwdPolicy.noRepeat }">不含连续重复字符</li>
        <li :class="{ done: pwdPolicy.different }">与原口令不同</li>
        <li :class="{ done: pwdPolicy.match }">两次输入一致</li>
      </ul>
      <p class="hint">修改成功后全部会话将失效，需要重新登录；两次修改间隔不得少于 24 小时。</p>

      <div class="sheet-actions">
        <button class="btn-ghost" type="button" :disabled="savingPwd" @click="showPwd = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="savingPwd || !pwdOk" @click="changePassword">
          {{ savingPwd ? '提交中…' : '确认修改' }}
        </button>
      </div>
    </AppSheet>
  </section>
</template>

<style scoped>
.page-title {
  font-size: var(--font-size-xl);
  margin: 0 0 var(--sp-4);
}
.section-title {
  font-size: var(--font-size-lg);
  margin: var(--sp-5) 0 var(--sp-3);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}

.profile {
  display: flex;
  align-items: center;
  gap: var(--sp-4);
  flex-wrap: wrap;
}

.avatar {
  width: 56px;
  height: 56px;
  border-radius: 50%;
  background: var(--accent);
  color: var(--text-inverse);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 22px;
  font-weight: 600;
  flex-shrink: 0;
}

.profile__name {
  font-size: var(--font-size-lg);
  font-weight: 600;
}
.profile__sub {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.profile__actions {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}

.kv {
  display: grid;
  grid-template-columns: 88px 1fr;
  gap: var(--sp-2) var(--sp-3);
  margin: 0 0 var(--sp-3);
  font-size: var(--font-size-md);
}
.kv dt {
  color: var(--text-secondary);
}
.kv dd {
  margin: 0;
}

.perm-group {
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border-subtle);
}
.perm-group:last-child {
  border-bottom: none;
}
.perm-group__domain {
  font-weight: 600;
  margin-bottom: var(--sp-2);
  font-size: var(--font-size-sm);
}
.perm-group__list {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
}

.perm-chip {
  font-size: 12px;
  padding: 2px var(--sp-2);
  background: var(--bg-hover);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-sm);
  color: var(--text-secondary);
}

/* 表单 */
.form {
  display: grid;
  gap: var(--sp-3);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field__label {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}
.sheet-actions {
  display: flex;
  gap: var(--sp-2);
  justify-content: flex-end;
  margin-top: var(--sp-5);
}

/* 口令策略清单 */
.policy {
  list-style: none;
  margin: var(--sp-3) 0 0;
  padding: 0;
  font-size: var(--font-size-sm);
  color: var(--text-muted);
  display: grid;
  gap: 4px;
}
.policy li::before {
  content: '○';
  margin-right: 6px;
}
.policy li.done {
  color: var(--success);
}
.policy li.done::before {
  content: '●';
}

@media (max-width: 639px) {
  .kv {
    grid-template-columns: 72px 1fr;
  }
  .profile__actions {
    margin-left: 0;
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
