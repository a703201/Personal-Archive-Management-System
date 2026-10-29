<script setup lang="ts">
/**
 * 家庭邀请落地页（FR-ACL-010 · 公开）。
 *
 * 路由 `/invite/:token` 标记 `meta.public`，未登录也能打开 —— 这正是
 * 邀请链接的用途：先把「谁邀请你进哪个组」摆出来让人核对，再要求登录。
 *
 * 安全约定（与后端 FamilyRoutes.inviteMeta 对齐）：
 *   ① 失效邀请不报错，而是渲染成正常页面的「已失效」态 ——
 *      接口报错会让用户以为是网络问题、反复重试；
 *   ② **失效后连组名都不再返回**，所以模板里不能在失效态残留
 *      `meta.groupName`（后端已置空，这里也不做任何兜底猜测）；
 *   ③ 邀请码是第二因子：链接（token）泄露也进不来，必须再输 8 位码。
 *      输错达到上限后邀请自动作废，次数由后端累计，本页只显示结果。
 */
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { api, ApiError, getToken } from '../api/client'

const route = useRoute()
const router = useRouter()
const token = String(route.params.token ?? '')

interface InviteMeta {
  valid: boolean
  groupName: string
  inviter: string
  expiresAt: number
  remainingUses: number
}

interface AcceptResult {
  groupId: string
  groupName: string
  role: string
  alreadyMember: boolean
}

const loading = ref(true)
const meta = ref<InviteMeta | null>(null)
const metaError = ref('')
const loggedIn = ref(false)

const code = ref('')
const submitting = ref(false)
const acceptError = ref('')
const accepted = ref<AcceptResult | null>(null)

const ROLE_LABEL: Record<string, string> = {
  owner: '所有者',
  manager: '管理员',
  member: '成员',
}

const roleText = computed(() => ROLE_LABEL[accepted.value?.role ?? ''] ?? '成员')

/** 剩余可用次数为 1 时提示「仅剩最后一次」，避免分享后被别人兑掉 */
const lastChance = computed(() => (meta.value?.remainingUses ?? 0) === 1)

function fmt(ms: number): string {
  if (!ms) return '—'
  const d = new Date(ms)
  const p = (x: number): string => String(x).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

/** 输入即规范化：去空白与连字符、小写转大写，与后端 InviteCode.normalize 一致 */
function onInput(e: Event): void {
  const el = e.target as HTMLInputElement
  const norm = el.value.replace(/[\s-]/g, '').toUpperCase().slice(0, 8)
  code.value = norm
  // 手写回写 DOM：若规范化结果与 code 现值相同，Vue 不会重渲染，
  // 用户输入的空格/小写就会残留在输入框里（看起来像没生效）。
  if (el.value !== norm) el.value = norm
}
async function load(): Promise<void> {
  loading.value = true
  metaError.value = ''
  try {
    meta.value = await api<InviteMeta>(`/family/invites/${token}`, { auth: false })
  } catch (e) {
    metaError.value = (e as ApiError).message || '加载失败'
  } finally {
    loading.value = false
  }
}

async function accept(): Promise<void> {
  if (code.value.length < 8) {
    acceptError.value = '请输入完整的 8 位邀请码'
    return
  }
  submitting.value = true
  acceptError.value = ''
  try {
    accepted.value = await api<AcceptResult>('/family/invites/accept', {
      method: 'POST',
      body: { token, code: code.value },
    })
  } catch (e) {
    const err = e as ApiError
    if (err.status === 401) {
      goLogin()
      return
    }
    acceptError.value = err.message || '加入失败'
    // 失败后重新拉一次元数据：可能已被他人用尽或因错误过多而作废
    await load()
  } finally {
    submitting.value = false
  }
}

function goLogin(): void {
  router.push({ name: 'login', query: { redirect: `/invite/${token}` } })
}

onMounted(() => {
  loggedIn.value = !!getToken()
  load()
})
</script>

<template>
  <div class="invite-page">
    <header class="invite-page__head">
      <span class="invite-page__brand">AMS</span>
      <span class="invite-page__tag">家庭邀请</span>
    </header>

    <main class="invite-card">
      <p v-if="loading" class="invite-hint">加载中…</p>
      <p v-else-if="metaError" class="invite-error">{{ metaError }}</p>

      <!-- 已成功加入 -->
      <div v-else-if="accepted" class="invite-done">
        <h1 class="invite-done__title">
          {{ accepted.alreadyMember ? '你已在该家庭组中' : '已加入家庭组' }}
        </h1>
        <p class="invite-done__group">{{ accepted.groupName }}</p>
        <p class="invite-done__desc">
          你的角色：{{ roleText }}
          <template v-if="accepted.alreadyMember">（无需重复加入）</template>
        </p>
        <p class="invite-done__note">
          家庭成员只读：你能看到组内为你授权的档案条目，但不能编辑、导出或再分享。
        </p>
        <button class="btn-primary" type="button" @click="router.push('/family')">
          前往家庭协作
        </button>
      </div>

      <!-- 邀请失效 -->
      <div v-else-if="meta && !meta.valid" class="invite-dead">
        <h1 class="invite-dead__title">邀请已失效</h1>
        <p class="invite-dead__desc">
          该邀请可能已过期、已被撤销、已被使用完毕，或因邀请码输错次数过多而自动作废。
          请让邀请人重新生成一条。
        </p>
      </div>

      <!-- 有效邀请：先核对，再输码 -->
      <div v-else-if="meta" class="invite-body">
        <h1 class="invite-title">邀请你加入家庭组</h1>
        <p class="invite-group">{{ meta.groupName }}</p>
        <p v-if="meta.inviter" class="invite-from">邀请人：{{ meta.inviter }}</p>

        <dl class="invite-kv">
          <dt>有效期至</dt>
          <dd>{{ fmt(meta.expiresAt) }}</dd>
          <dt>剩余可用</dt>
          <dd :class="{ 'invite-kv__warn': lastChance }">
            {{ meta.remainingUses }} 次{{ lastChance ? '（仅剩最后一次）' : '' }}
          </dd>
        </dl>

        <template v-if="!loggedIn">
          <p class="invite-note">
            需要先登录或注册一个账号，再输入邀请码加入。登录后会自动回到本页。
          </p>
          <button class="btn-primary" type="button" @click="goLogin">登录后加入</button>
        </template>

        <template v-else>
          <label class="invite-label" for="invite-code">输入邀请码</label>
          <input
            id="invite-code"
            :value="code"
            class="field-control invite-code"
            inputmode="text"
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            maxlength="8"
            placeholder="8 位字符"
            autofocus
            @input="onInput"
            @keyup.enter="accept"
          />
          <p class="invite-note">
            邀请码由邀请人当面或电话告知，区分大小写不敏感。输错次数过多会使该邀请作废。
          </p>
          <p v-if="acceptError" class="invite-error">{{ acceptError }}</p>
          <button class="btn-primary" type="button" :disabled="submitting" @click="accept">
            {{ submitting ? '加入中…' : '加入家庭组' }}
          </button>
        </template>
      </div>
    </main>

    <p class="invite-page__foot">本页由 AMS 个人档案管理系统生成 · 加入后仅获得被授权的只读内容</p>
  </div>
</template>

<style scoped>
.invite-page {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: var(--sp-6) var(--sp-4);
  gap: var(--sp-4);
  background: var(--bg-app, var(--bg-base, #f5f5f7));
}

.invite-page__head {
  width: 100%;
  max-width: 520px;
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}
.invite-page__brand {
  font-weight: 700;
  font-size: var(--font-size-lg);
  color: var(--accent);
  letter-spacing: 0.02em;
}
.invite-page__tag {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  color: var(--text-muted);
}

.invite-card {
  width: 100%;
  max-width: 520px;
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  padding: var(--sp-5);
  box-shadow: var(--shadow-card, 0 1px 2px rgb(0 0 0 / 0.04));
}

.invite-hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin: 0;
}
.invite-error {
  color: var(--danger);
  font-size: var(--font-size-sm);
  margin: 0;
}

.invite-body,
.invite-done,
.invite-dead {
  display: grid;
  gap: var(--sp-2);
  justify-items: start;
}

.invite-title {
  margin: 0;
  font-size: var(--font-size-xl);
  line-height: 1.3;
}
.invite-group {
  margin: 0;
  font-size: var(--font-size-lg);
  font-weight: 600;
  color: var(--accent);
  word-break: break-word;
}
.invite-from {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}

.invite-kv {
  display: grid;
  grid-template-columns: 76px 1fr;
  gap: 4px var(--sp-3);
  margin: var(--sp-2) 0 0;
  width: 100%;
}
.invite-kv dt {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.invite-kv dd {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-primary);
}
.invite-kv__warn {
  color: var(--warning);
}

.invite-note {
  margin: 0;
  font-size: 12px;
  color: var(--text-muted);
  line-height: 1.6;
}

.invite-label {
  margin-top: var(--sp-2);
  font-size: 13px;
  color: var(--text-secondary);
}
.invite-code {
  width: 100%;
  font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 22px;
  letter-spacing: 0.2em;
  text-align: center;
  text-transform: uppercase;
}

.invite-done__title,
.invite-dead__title {
  margin: 0;
  font-size: var(--font-size-xl);
  font-weight: 600;
}
.invite-done__group {
  margin: 0;
  font-size: var(--font-size-lg);
  color: var(--accent);
  font-weight: 600;
  word-break: break-word;
}
.invite-done__desc,
.invite-done__note,
.invite-dead__desc {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  line-height: 1.6;
}
.invite-done__note {
  font-size: 12px;
  color: var(--text-muted);
}
.invite-done .btn-primary {
  margin-top: var(--sp-2);
}

.invite-page__foot {
  margin: 0;
  font-size: 12px;
  color: var(--text-muted);
  text-align: center;
}

@media (max-width: 639px) {
  .invite-card {
    padding: var(--sp-4);
  }
  .invite-code {
    font-size: 18px;
  }
}
</style>
