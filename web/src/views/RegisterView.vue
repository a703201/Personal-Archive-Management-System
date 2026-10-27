<script setup lang="ts">
/**
 * 注册页（公开，无需登录）。
 *
 * 调用 POST /api/auth/register（auth:false）：
 *   { username, password, email?, phone?, nickname? }
 * 口令策略由后端 PasswordValidator 强制（长度/字符类别/弱口令/含用户名/连续重复），
 * 前端只做非空与一致性提示，并以实时清单提示策略，降低提交失败率。
 * 成功 → Toast 提示 → 跳登录页。
 */
import { ref, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api } from '../api/client'
import { useToast } from '../composables/useToast'

const router = useRouter()
const route = useRoute()
const { success, error: toastError } = useToast()

const username = ref('')
const nickname = ref('')
const email = ref('')
const phone = ref('')
const password = ref('')
const confirm = ref('')

const submitting = ref(false)
const serverError = ref('')

/** 口令策略实时清单（与后端策略对齐的轻量前端校验） */
const policy = computed(() => {
  const p = password.value
  const classes =
    (/[a-z]/.test(p) ? 1 : 0) +
    (/[A-Z]/.test(p) ? 1 : 0) +
    (/\d/.test(p) ? 1 : 0) +
    (/[^A-Za-z0-9]/.test(p) ? 1 : 0)
  return {
    length: p.length >= 12,
    classes: classes >= 3,
    noRepeat: !/(.)\1\1/.test(p),
    noUsername: !username.value || !p.toLowerCase().includes(username.value.toLowerCase()),
    match: confirm.value === '' || p === confirm.value,
  }
})
const passwordOk = computed(() => Object.values(policy.value).every(Boolean))

const emailValid = computed(() => {
  if (!email.value) return true // 选填
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.value)
})
const phoneValid = computed(() => {
  if (!phone.value) return true
  return /^1[3-9]\d{9}$/.test(phone.value)
})

async function onSubmit(): Promise<void> {
  serverError.value = ''
  if (!username.value || !password.value) {
    serverError.value = '请输入用户名和密码'
    return
  }
  if (!passwordOk.value) {
    serverError.value = '口令不满足安全策略，请检查下方提示'
    return
  }
  if (!emailValid.value) {
    serverError.value = '邮箱格式不正确'
    return
  }
  if (!phoneValid.value) {
    serverError.value = '手机号格式不正确'
    return
  }

  submitting.value = true
  try {
    await api<{ id: number }>('/auth/register', {
      method: 'POST',
      auth: false,
      body: {
        username: username.value,
        password: password.value,
        nickname: nickname.value || undefined,
        email: email.value || undefined,
        phone: phone.value || undefined,
      },
    })
    success('注册成功，请登录')
    const redirect = (route.query.redirect as string) || '/login'
    router.replace(redirect)
  } catch (e) {
    serverError.value = (e as Error).message || '注册失败，请重试'
    toastError(serverError.value)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="reg-wrap">
    <div class="reg-card">
      <div class="brand">AMS</div>
      <h1 class="title">创建账号</h1>
      <p class="subtitle">个人档案管理系统</p>

      <form class="form" @submit.prevent="onSubmit">
        <label class="field">
          <span class="field__label">用户名 <em>*</em></span>
          <input v-model="username" class="field-control" type="text" autocomplete="username" placeholder="登录用户名" />
        </label>

        <label class="field">
          <span class="field__label">昵称</span>
          <input v-model="nickname" class="field-control" type="text" placeholder="选填，默认同用户名" />
        </label>

        <label class="field">
          <span class="field__label">邮箱</span>
          <input v-model="email" class="field-control" type="email" autocomplete="email" placeholder="选填" />
        </label>

        <label class="field">
          <span class="field__label">手机号</span>
          <input v-model="phone" class="field-control" type="tel" autocomplete="tel" placeholder="选填" />
        </label>

        <label class="field">
          <span class="field__label">密码 <em>*</em></span>
          <input v-model="password" class="field-control" type="password" autocomplete="new-password" placeholder="设置登录密码" />
        </label>

        <ul class="policy" :class="{ 'policy--ok': passwordOk }">
          <li :class="{ done: policy.length }">至少 12 位</li>
          <li :class="{ done: policy.classes }">含至少 3 类字符（大小写/数字/符号）</li>
          <li :class="{ done: policy.noRepeat }">无连续重复字符（如 aaa）</li>
          <li :class="{ done: policy.noUsername }">不包含用户名</li>
        </ul>

        <label class="field">
          <span class="field__label">确认密码 <em>*</em></span>
          <input v-model="confirm" class="field-control" type="password" autocomplete="new-password" placeholder="再次输入密码" />
          <span v-if="policy.match === false" class="field__err">两次输入的密码不一致</span>
        </label>

        <p v-if="serverError" class="error">{{ serverError }}</p>

        <button class="btn-primary submit" type="submit" :disabled="submitting">
          {{ submitting ? '提交中…' : '注册' }}
        </button>
      </form>

      <p class="switch">
        已有账号？<RouterLink to="/login">去登录</RouterLink>
      </p>
    </div>
  </div>
</template>

<style scoped>
.reg-wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-app, #eef1f6);
  padding: var(--sp-4, 16px);
}
.reg-card {
  width: 100%;
  max-width: 400px;
  background: var(--bg-surface, #fff);
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--g3-lg, 24px);
  padding: 32px;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.06);
  corner-style: continuous;
}
.brand {
  font-weight: 700;
  font-size: 24px;
  color: var(--accent, #2563eb);
  text-align: center;
}
.title {
  font-size: 20px;
  margin: 8px 0 0;
  text-align: center;
  color: var(--text-primary, #1f2937);
  letter-spacing: -0.02em;
}
.subtitle {
  margin: 4px 0 24px;
  text-align: center;
  color: var(--text-muted, #9ca3af);
  font-size: 14px;
}
.form {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3, 12px);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field__label {
  font-size: 13px;
  color: var(--text-secondary, #4b5563);
}
.field__label em {
  color: var(--danger, #dc2626);
  font-style: normal;
}
.field__err {
  font-size: 12px;
  color: var(--danger, #dc2626);
}
.policy {
  list-style: none;
  margin: -4px 0 0;
  padding: 8px 12px;
  background: var(--bg-hover, #f3f4f6);
  border-radius: var(--g3-sm, 12px);
  font-size: 12px;
  color: var(--text-muted, #9ca3af);
  display: grid;
  gap: 2px;
}
.policy li::before {
  content: '○ ';
}
.policy li.done {
  color: var(--success, #16a34a);
}
.policy li.done::before {
  content: '● ';
}
.policy--ok {
  border: 1px solid color-mix(in srgb, var(--success, #16a34a) 40%, transparent);
}
.error {
  margin: 0;
  color: var(--danger, #dc2626);
  font-size: 13px;
}
.submit {
  margin-top: 4px;
  border: none;
  border-radius: var(--g3-sm, 12px);
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
.switch {
  margin: 16px 0 0;
  text-align: center;
  font-size: 13px;
  color: var(--text-muted, #9ca3af);
}
</style>
