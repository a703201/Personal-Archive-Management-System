<script setup lang="ts">
/**
 * 找回口令（FR-AUTH-008）。
 *
 * 三步链路，与后端一一对应：
 *   ① /auth/password/forgot  → 发验证码（邮件入队，10 分钟内有效）
 *   ② /auth/password/verify  → 校验验证码，换取一次性重置令牌
 *   ③ /auth/password/reset   → 改口令，后端强制下线该账号全部会话
 *
 * 前端不缓存任何令牌到 localStorage：重置令牌只放在组件内存里，
 * 页面刷新即丢弃（重新走验证码），减少泄漏面。
 */
import { computed, onBeforeUnmount, ref } from 'vue'
import { t } from '../i18n'
import { useRouter } from 'vue-router'
import { api } from '../api/client'

type Step = 1 | 2 | 3 | 4

const router = useRouter()

const step = ref<Step>(1)
const account = ref('')
const code = ref('')
const password = ref('')
const password2 = ref('')

const error = ref('')
const notice = ref('')
const masked = ref('')
const busy = ref(false)

/** 重置令牌只存内存 */
let resetToken = ''

/** 重发倒计时（秒） */
const cooldown = ref(0)
let timer: number | undefined

const steps = [
  { n: 1, label: '验证账号' },
  { n: 2, label: '输入验证码' },
  { n: 3, label: '设置新口令' },
]

const pwdHint = computed(() => {
  if (!password.value) return ''
  if (password.value.length < 10) return '至少 10 位'
  if (!/[a-z]/.test(password.value)) return '需含小写字母'
  if (!/[A-Z]/.test(password.value)) return '需含大写字母'
  if (!/[0-9]/.test(password.value)) return '需含数字'
  return ''
})

function startCooldown(seconds: number): void {
  cooldown.value = Math.max(0, Math.floor(seconds))
  if (timer !== undefined) window.clearInterval(timer)
  timer = window.setInterval(() => {
    cooldown.value -= 1
    if (cooldown.value <= 0 && timer !== undefined) {
      window.clearInterval(timer)
      timer = undefined
    }
  }, 1000)
}

onBeforeUnmount(() => {
  if (timer !== undefined) window.clearInterval(timer)
})

async function sendCode(): Promise<void> {
  error.value = ''
  notice.value = ''
  if (!account.value.trim()) {
    error.value = '请输入用户名、邮箱或手机号'
    return
  }
  busy.value = true
  try {
    const res = await api<{
      sent: boolean
      channel: string
      masked: string
      expiresIn: number
      notice: string
    }>('/auth/password/forgot', {
      method: 'POST',
      auth: false,
      body: { account: account.value.trim() },
    })
    if (!res.sent) {
      // 后端已给出人话原因（账号不存在 / 未绑定邮箱 / 请求过频）
      error.value = res.notice || '验证码发送失败'
      return
    }
    masked.value = res.masked
    notice.value = `${res.notice}（${res.masked}），${Math.floor(res.expiresIn / 60)} 分钟内有效`
    step.value = 2
    startCooldown(60)
  } catch (e) {
    error.value = (e as Error).message || '验证码发送失败'
  } finally {
    busy.value = false
  }
}

async function verifyCode(): Promise<void> {
  error.value = ''
  if (!/^\d{6}$/.test(code.value.trim())) {
    error.value = '请输入 6 位数字验证码'
    return
  }
  busy.value = true
  try {
    const res = await api<{ resetToken: string; expiresIn: number }>('/auth/password/verify', {
      method: 'POST',
      auth: false,
      body: { account: account.value.trim(), code: code.value.trim() },
    })
    resetToken = res.resetToken
    notice.value = `验证通过，请在 ${Math.floor(res.expiresIn / 60)} 分钟内设置新口令`
    step.value = 3
  } catch (e) {
    error.value = (e as Error).message || '验证码校验失败'
  } finally {
    busy.value = false
  }
}

async function submitReset(): Promise<void> {
  error.value = ''
  if (pwdHint.value) {
    error.value = `口令不符合要求：${pwdHint.value}`
    return
  }
  if (password.value !== password2.value) {
    error.value = '两次输入的新口令不一致'
    return
  }
  busy.value = true
  try {
    await api<{ reset: boolean; username: string }>('/auth/password/reset', {
      method: 'POST',
      auth: false,
      body: { resetToken, newPassword: password.value },
    })
    resetToken = ''
    notice.value = ''
    step.value = 4
  } catch (e) {
    error.value = (e as Error).message || '口令重置失败'
  } finally {
    busy.value = false
  }
}

function back(): void {
  error.value = ''
  notice.value = ''
  if (step.value === 2) step.value = 1
  else if (step.value === 3) step.value = 2
}

function goLogin(): void {
  router.replace('/login')
}
</script>

<template>
  <div class="wrap">
    <div class="card">
      <div class="brand">AMS</div>
      <h1 class="title">{{ t('ForgotPasswordView.37cccf', '找回口令') }}</h1>

      <ol v-if="step < 4" class="stepper">
        <li
          v-for="s in steps"
          :key="s.n"
          class="stepper__item"
          :class="{
            'stepper__item--done': step > s.n,
            'stepper__item--active': step === s.n,
          }"
        >
          <span class="stepper__dot">{{ step > s.n ? '✓' : s.n }}</span>
          <span class="stepper__label">{{ s.label }}</span>
        </li>
      </ol>

      <!-- ① 验证账号 -->
      <form v-if="step === 1" class="form" @submit.prevent="sendCode">
        <label class="field">
          <span class="field__label">{{ t('ForgotPasswordView.0c9acc', '用户名 / 邮箱 / 手机号') }}</span>
          <input
            v-model="account"
            class="field__input"
            type="text"
            autocomplete="username"
            :placeholder="t('ForgotPasswordView.51d3b6', '请输入注册时使用的账号')"
          />
        </label>
        <p class="hint-block">
          我们会向账号绑定的邮箱发送 6 位验证码。未绑定邮箱的账号需联系管理员重置。
        </p>
        <p v-if="error" class="error" role="alert">{{ error }}</p>
        <button class="submit" type="submit" :disabled="busy">
          {{ busy ? '发送中…' : '发送验证码' }}
        </button>
      </form>

      <!-- ② 输入验证码 -->
      <form v-else-if="step === 2" class="form" @submit.prevent="verifyCode">
        <p v-if="notice" class="notice">{{ notice }}</p>
        <label class="field">
          <span class="field__label">{{ t('ForgotPasswordView.83a302', '6 位验证码') }}</span>
          <input
            v-model="code"
            class="field__input field__input--code"
            type="text"
            inputmode="numeric"
            maxlength="6"
            autocomplete="one-time-code"
            placeholder="000000"
          />
        </label>
        <p v-if="error" class="error" role="alert">{{ error }}</p>
        <button class="submit" type="submit" :disabled="busy">
          {{ busy ? '校验中…' : '下一步' }}
        </button>
        <div class="row">
          <button class="btn-text" type="button" @click="back">{{ t('ForgotPasswordView.75ef12', '上一步') }}</button>
          <button
            class="btn-text"
            type="button"
            :disabled="busy || cooldown > 0"
            @click="sendCode"
          >
            {{ cooldown > 0 ? `重新发送（${cooldown}s）` : '重新发送' }}
          </button>
        </div>
      </form>

      <!-- ③ 设置新口令 -->
      <form v-else-if="step === 3" class="form" @submit.prevent="submitReset">
        <p v-if="notice" class="notice">{{ notice }}</p>
        <label class="field">
          <span class="field__label">{{ t('ForgotPasswordView.2a1f04', '新口令') }}</span>
          <input
            v-model="password"
            class="field__input"
            type="password"
            autocomplete="new-password"
            :placeholder="t('ForgotPasswordView.005732', '至少 10 位，含大小写与数字')"
          />
          <span v-if="pwdHint" class="field__hint">{{ pwdHint }}</span>
        </label>
        <label class="field">
          <span class="field__label">{{ t('ForgotPasswordView.2109a9', '确认新口令') }}</span>
          <input
            v-model="password2"
            class="field__input"
            type="password"
            autocomplete="new-password"
            :placeholder="t('ForgotPasswordView.9ac6d3', '再次输入新口令')"
          />
        </label>
        <p class="hint-block">{{ t('ForgotPasswordView.2d7650', '重置成功后，该账号在所有设备上的登录状态将立即失效，需重新登录。') }}</p>
        <p v-if="error" class="error" role="alert">{{ error }}</p>
        <button class="submit" type="submit" :disabled="busy">
          {{ busy ? '提交中…' : '重置口令' }}
        </button>
        <div class="row">
          <button class="btn-text" type="button" @click="back">{{ t('ForgotPasswordView.75ef12', '上一步') }}</button>
        </div>
      </form>

      <!-- ④ 完成 -->
      <div v-else class="form">
        <div class="done" role="status">✓</div>
        <p class="done-text">{{ t('ForgotPasswordView.19d326', '口令已重置') }}</p>
        <p class="hint-block">
          为了安全，原会话已全部下线。请使用新口令重新登录；若账号已启用双因子，登录时还需输入动态码。
        </p>
        <button class="submit" type="button" @click="goLogin">{{ t('ForgotPasswordView.6c01b0', '去登录') }}</button>
      </div>

      <p v-if="step < 4" class="switch">
        想起来了？<RouterLink to="/login">{{ t('ForgotPasswordView.f2fe4e', '返回登录') }}</RouterLink>
      </p>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-app, #eef1f6);
  padding: var(--sp-4, 16px);
}
.card {
  width: 100%;
  max-width: 400px;
  background: var(--bg-surface, #fff);
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--g3-lg, 24px);
  padding: 32px;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.06);
}
.brand {
  font-weight: 700;
  font-size: 24px;
  color: var(--accent, #2563eb);
  text-align: center;
}
.title {
  font-size: 18px;
  margin: 8px 0 20px;
  text-align: center;
  color: var(--text-primary, #1f2937);
}
.stepper {
  display: flex;
  gap: 8px;
  list-style: none;
  margin: 0 0 24px;
  padding: 0;
}
.stepper__item {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-muted, #9ca3af);
}
.stepper__dot {
  width: 24px;
  height: 24px;
  line-height: 24px;
  border-radius: 50%;
  text-align: center;
  font-size: 12px;
  font-weight: 600;
  background: var(--bg-app, #eef1f6);
  color: var(--text-muted, #9ca3af);
}
.stepper__item--active .stepper__dot {
  background: var(--accent, #2563eb);
  color: #fff;
}
.stepper__item--active .stepper__label {
  color: var(--text-primary, #1f2937);
  font-weight: 600;
}
.stepper__item--done .stepper__dot {
  background: var(--success, #16a34a);
  color: #fff;
}
.form {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.field__label {
  font-size: 14px;
  color: var(--text-secondary, #4b5563);
}
.field__input {
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--radius-sm, 8px);
  padding: 12px;
  font-size: 15px;
  color: var(--text-primary, #1f2937);
  background: var(--bg-surface, #fff);
}
.field__input:focus {
  outline: none;
  border-color: var(--accent, #2563eb);
  box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.12);
}
.field__input--code {
  letter-spacing: 8px;
  text-align: center;
  font-size: 20px;
  font-variant-numeric: tabular-nums;
}
.field__hint {
  font-size: 12px;
  color: var(--warning, #d97706);
}
.hint-block {
  margin: 0;
  font-size: 13px;
  line-height: 1.6;
  color: var(--text-muted, #9ca3af);
}
.notice {
  margin: 0;
  padding: 10px 12px;
  border-radius: var(--radius-sm, 8px);
  background: rgba(37, 99, 235, 0.08);
  color: var(--accent, #2563eb);
  font-size: 13px;
  line-height: 1.5;
}
.error {
  margin: 0;
  color: var(--danger, #dc2626);
  font-size: 13px;
}
.submit {
  border: none;
  border-radius: var(--radius-sm, 8px);
  padding: 12px;
  font-size: 15px;
  font-weight: 600;
  color: #fff;
  background: var(--accent, #2563eb);
  cursor: pointer;
}
.submit:hover {
  filter: brightness(1.05);
}
.submit:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
.row {
  display: flex;
  justify-content: space-between;
}
.btn-text {
  border: none;
  background: none;
  padding: 0;
  font-size: 13px;
  color: var(--accent, #2563eb);
  cursor: pointer;
}
.btn-text:disabled {
  color: var(--text-muted, #9ca3af);
  cursor: not-allowed;
}
.done {
  width: 48px;
  height: 48px;
  line-height: 48px;
  margin: 0 auto;
  border-radius: 50%;
  text-align: center;
  font-size: 24px;
  color: #fff;
  background: var(--success, #16a34a);
}
.done-text {
  margin: 0;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--text-primary, #1f2937);
}
.switch {
  margin: 16px 0 0;
  text-align: center;
  font-size: 13px;
  color: var(--text-muted, #9ca3af);
}
</style>
