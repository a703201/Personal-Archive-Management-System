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

// ---------------------------------------------------------------
// 双因子（FR-AUTH-009）
// ---------------------------------------------------------------
const twofa = ref<{ bound: boolean; enabled: boolean }>({ bound: false, enabled: false })
const twofaBusy = ref(false)
const twofaMsg = ref('')
const twofaErr = ref('')
const totpSecret = ref('')
const totpUrl = ref('')
const totpCode = ref('')

async function load2fa(): Promise<void> {
  try {
    twofa.value = await api<{ bound: boolean; enabled: boolean }>('/me/2fa')
  } catch {
    /* 未登录等场景由全局拦截处理，这里静默 */
  }
}

async function setup2fa(): Promise<void> {
  twofaErr.value = ''
  twofaMsg.value = ''
  twofaBusy.value = true
  try {
    const res = await api<{ secret: string; otpauthUrl: string }>('/me/2fa/setup', {
      method: 'POST',
      body: {},
    })
    totpSecret.value = res.secret
    totpUrl.value = res.otpauthUrl
    twofaMsg.value = '密钥已生成，请用验证器录入后输入动态码完成绑定'
  } catch (e) {
    twofaErr.value = (e as Error).message || '生成密钥失败'
  } finally {
    twofaBusy.value = false
  }
}

/**
 * enable / disable 的请求体是**纯文本动态码**（后端 req.bodyText()），
 * 故不能走 api() 的 JSON 封装，这里直接用 fetch。
 */
async function postCode(path: string, code: string): Promise<{ ok: boolean; msg: string }> {
  const token = sessionStorage.getItem('ams.accessToken') ?? ''
  const res = await fetch(`/api${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain', Authorization: `Bearer ${token}` },
    body: code,
  })
  const j = await res.json().catch(() => ({}))
  return { ok: res.ok, msg: j.message ?? '' }
}

async function enable2fa(): Promise<void> {
  twofaErr.value = ''
  twofaMsg.value = ''
  if (!/^\d{6}$/.test(totpCode.value.trim())) {
    twofaErr.value = '请输入 6 位动态码'
    return
  }
  twofaBusy.value = true
  try {
    const r = await postCode('/me/2fa/enable', totpCode.value.trim())
    if (!r.ok) {
      twofaErr.value = r.msg || '启用失败'
      return
    }
    twofaMsg.value = '双因子已启用，下次登录需输入动态码'
    totpSecret.value = ''
    totpUrl.value = ''
    totpCode.value = ''
    await load2fa()
  } finally {
    twofaBusy.value = false
  }
}

async function disable2fa(): Promise<void> {
  twofaErr.value = ''
  twofaMsg.value = ''
  const code = window.prompt('请输入当前 6 位动态码以停用双因子')
  if (!code) return
  twofaBusy.value = true
  try {
    const r = await postCode('/me/2fa/disable', code.trim())
    if (!r.ok) {
      twofaErr.value = r.msg || '停用失败'
      return
    }
    twofaMsg.value = '双因子已停用'
    await load2fa()
  } finally {
    twofaBusy.value = false
  }
}

onMounted(() => {
  void load()
  void loadSessions()
  void load2fa()
  void loadNotifyPrefs()
})

// ---------------------------------------------------------------
// 会话与设备（FR-AUTH-007）
// ---------------------------------------------------------------

interface SessionRow {
  sid: string
  ip: string
  userAgent: string
  createdAt: number | string
  lastActiveAt: number | string
  current: boolean | string
}

const sessions = ref<SessionRow[]>([])
const sessionBusy = ref('')

async function loadSessions(): Promise<void> {
  try {
    const res = await api<{ sessions: SessionRow[] }>('/me/sessions')
    sessions.value = res.sessions ?? []
  } catch {
    sessions.value = []
  }
}

async function kick(s: SessionRow): Promise<void> {
  sessionBusy.value = s.sid
  try {
    await api(`/me/sessions/${encodeURIComponent(s.sid)}`, { method: 'DELETE' })
    toast.success('该设备已登出')
    await loadSessions()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    sessionBusy.value = ''
  }
}

async function kickOthers(): Promise<void> {
  sessionBusy.value = '__others'
  try {
    const res = await api<{ revoked: number }>('/me/sessions', { method: 'DELETE' })
    toast.success(`已登出其他 ${res.revoked} 台设备`)
    await loadSessions()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    sessionBusy.value = ''
  }
}

function fmtTime(ms: number | string | undefined): string {
  const n = Number(ms ?? 0)
  if (!n) return '—'
  return new Date(n).toLocaleString('zh-CN', { hour12: false })
}

// ---------------------------------------------------------------
// 通知偏好中心（FR-NTF-006 / FR-NTF-007）
// ---------------------------------------------------------------
interface NotifyPrefs {
  dndEnabled: boolean
  dndStart: string
  dndEnd: string
  channelInApp: boolean
  channelEmail: boolean
  freq: string
}

const notifyPrefs = ref<NotifyPrefs>({
  dndEnabled: false,
  dndStart: '22:00',
  dndEnd: '08:00',
  channelInApp: true,
  channelEmail: false,
  freq: 'realtime',
})
const notifyBusy = ref(false)

async function loadNotifyPrefs(): Promise<void> {
  try {
    const r = await api<NotifyPrefs>('/notify/prefs')
    notifyPrefs.value = { ...notifyPrefs.value, ...r }
  } catch {
    /* 静默：使用默认值 */
  }
}

async function saveNotifyPrefs(): Promise<void> {
  notifyBusy.value = true
  try {
    await api('/notify/prefs', { method: 'PUT', body: { ...notifyPrefs.value } })
    toast.success('通知偏好已保存')
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    notifyBusy.value = false
  }
}

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

      <h2 class="section-title">安全设置</h2>
      <div class="card">
        <div class="sec-row">
          <div>
            <div class="sec-row__title">
              双因子认证（TOTP）
              <span class="sec-row__tag" :class="{ 'sec-row__tag--on': twofa.enabled }">
                {{ twofa.enabled ? '已启用' : '未启用' }}
              </span>
            </div>
            <div class="sec-row__sub">
              {{
                twofa.enabled
                  ? '登录时除口令外还需输入验证器上的 6 位动态码'
                  : '建议启用：口令泄露时仍有一道动态码保护'
              }}
            </div>
          </div>
          <button
            v-if="twofa.enabled"
            class="btn-text btn-text--danger"
            type="button"
            :disabled="twofaBusy"
            @click="disable2fa"
          >
            停用
          </button>
          <button
            v-else
            class="btn-ghost"
            type="button"
            :disabled="twofaBusy"
            @click="setup2fa"
          >
            开始绑定
          </button>
        </div>

        <div v-if="totpSecret" class="sec-setup">
          <p class="hint">
            ① 在验证器 App（如 Microsoft Authenticator / Google Authenticator）中手动添加密钥：
          </p>
          <code class="sec-setup__secret">{{ totpSecret }}</code>
          <p class="hint">② 录入后输入 App 显示的 6 位动态码完成绑定：</p>
          <div class="sec-setup__row">
            <input
              v-model="totpCode"
              class="sec-setup__input"
              type="text"
              inputmode="numeric"
              maxlength="6"
              placeholder="000000"
            />
            <button class="btn-ghost" type="button" :disabled="twofaBusy" @click="enable2fa">
              确认启用
            </button>
          </div>
          <p class="hint sec-setup__url">{{ totpUrl }}</p>
        </div>

        <p v-if="twofaMsg" class="hint sec-msg">{{ twofaMsg }}</p>
        <p v-if="twofaErr" class="hint hint--error">{{ twofaErr }}</p>
      </div>

      <h2 class="section-title">
        会话与设备（{{ sessions.length }}）
        <button
          v-if="sessions.length > 1"
          class="btn-text section-title__action"
          type="button"
          :disabled="sessionBusy === '__others'"
          @click="kickOthers"
        >
          {{ sessionBusy === '__others' ? '处理中…' : '登出其他设备' }}
        </button>
      </h2>
      <div class="card">
        <p v-if="sessions.length === 0" class="hint">没有活跃会话。</p>
        <div v-for="s in sessions" :key="s.sid" class="sess">
          <div class="sess__main">
            <div class="sess__title">
              {{ s.userAgent || '未知设备' }}
              <span v-if="s.current === true || s.current === 'true'" class="sess__tag">当前</span>
            </div>
            <div class="sess__sub">{{ s.ip }} · 最近活动 {{ fmtTime(s.lastActiveAt) }}</div>
          </div>
          <button
            v-if="!(s.current === true || s.current === 'true')"
            class="btn-text btn-text--danger"
            type="button"
            :disabled="sessionBusy === s.sid"
            @click="kick(s)"
          >
            {{ sessionBusy === s.sid ? '处理中…' : '登出' }}
          </button>
        </div>
      </div>

      <h2 class="section-title">通知偏好</h2>
      <div class="card notify">
        <div class="sec-row">
          <div>
            <div class="sec-row__title">免打扰（静默时段）</div>
            <div class="sec-row__sub">在设定的时间段内不推送通知（按类别静默）</div>
          </div>
          <label class="switch">
            <input v-model="notifyPrefs.dndEnabled" type="checkbox" />
            <span class="switch__track" />
          </label>
        </div>
        <div v-if="notifyPrefs.dndEnabled" class="notify__times">
          <label class="field field--inline">
            <span class="field__label">开始</span>
            <input v-model="notifyPrefs.dndStart" class="field-control" type="time" />
          </label>
          <label class="field field--inline">
            <span class="field__label">结束</span>
            <input v-model="notifyPrefs.dndEnd" class="field-control" type="time" />
          </label>
        </div>

        <div class="sec-row">
          <div>
            <div class="sec-row__title">接收渠道</div>
            <div class="sec-row__sub">选择希望接收通知的方式</div>
          </div>
        </div>
        <div class="notify__channels">
          <label class="chk">
            <input v-model="notifyPrefs.channelInApp" type="checkbox" />
            <span>站内信</span>
          </label>
          <label class="chk">
            <input v-model="notifyPrefs.channelEmail" type="checkbox" />
            <span>邮件</span>
          </label>
        </div>

        <div class="sec-row">
          <div>
            <div class="sec-row__title">推送频率</div>
            <div class="sec-row__sub">合并通知以降低打扰</div>
          </div>
          <select v-model="notifyPrefs.freq" class="field-control notify__freq">
            <option value="realtime">实时</option>
            <option value="digest_daily">每日汇总</option>
            <option value="digest_weekly">每周汇总</option>
            <option value="off">关闭</option>
          </select>
        </div>

        <div class="sheet-actions">
          <button class="btn-primary" type="button" :disabled="notifyBusy" @click="saveNotifyPrefs">
            {{ notifyBusy ? '保存中…' : '保存偏好' }}
          </button>
        </div>
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

/* 双因子卡片 */
.sec-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
}
.sec-row__title {
  font-size: var(--font-size-sm);
  font-weight: 600;
  color: var(--text-primary);
}
.sec-row__tag {
  margin-left: 6px;
  padding: 1px 6px;
  border-radius: 8px;
  background: rgba(148, 163, 184, 0.18);
  color: var(--text-muted);
  font-size: 11px;
  font-weight: 500;
}
.sec-row__tag--on {
  background: rgba(22, 163, 74, 0.14);
  color: var(--success);
}
.sec-row__sub {
  margin-top: 4px;
  font-size: var(--font-size-sm);
  color: var(--text-muted);
}
.sec-setup {
  margin-top: var(--sp-3);
  padding-top: var(--sp-3);
  border-top: 1px dashed var(--border-subtle);
}
.sec-setup__secret {
  display: inline-block;
  margin: 4px 0 8px;
  padding: 6px 10px;
  border-radius: var(--radius-sm);
  background: var(--bg-app);
  font-family: var(--font-mono, monospace);
  font-size: 13px;
  letter-spacing: 1px;
  word-break: break-all;
}
.sec-setup__row {
  display: flex;
  align-items: center;
  gap: 8px;
}
.sec-setup__input {
  width: 120px;
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-sm);
  padding: 8px 10px;
  font-size: 15px;
  letter-spacing: 4px;
  text-align: center;
}
.sec-setup__url {
  margin-top: 8px;
  word-break: break-all;
  font-size: 11px;
}
.sec-msg {
  margin-top: var(--sp-2);
  color: var(--accent);
}

/* 通知偏好 */
.notify {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}
.notify__times {
  display: flex;
  gap: var(--sp-4);
  flex-wrap: wrap;
}
.field--inline {
  flex-direction: row;
  align-items: center;
  gap: var(--sp-2);
}
.field--inline .field__label {
  margin: 0;
}
.notify__channels {
  display: flex;
  gap: var(--sp-4);
}
.chk {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: var(--font-size-sm);
}
.notify__freq {
  width: auto;
}

/* 开关（toggle） */
.switch {
  position: relative;
  display: inline-block;
  width: 44px;
  height: 24px;
  flex-shrink: 0;
}
.switch input {
  position: absolute;
  opacity: 0;
  width: 100%;
  height: 100%;
  margin: 0;
  cursor: pointer;
}
.switch__track {
  position: absolute;
  inset: 0;
  background: var(--border-strong, #cbd5e1);
  border-radius: 999px;
  transition: background var(--ease-apple) 0.2s;
}
.switch__track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 20px;
  height: 20px;
  background: #fff;
  border-radius: 50%;
  transition: transform var(--ease-apple) 0.2s;
}
.switch input:checked + .switch__track {
  background: var(--accent, #2563eb);
}
.switch input:checked + .switch__track::after {
  transform: translateX(20px);
}
</style>
