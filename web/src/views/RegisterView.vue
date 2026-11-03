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
import { t } from '../i18n'
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
    success(t('viewsRegisterView.5fcfe1', '注册成功，请登录'))
    const redirect = (route.query.redirect as string) || '/login'
    router.replace(redirect)
  } catch (e) {
    serverError.value = (e as Error).message || t('viewsRegisterView.ff3a15', '注册失败，请重试')
    toastError(serverError.value)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="auth">
    <aside class="auth__hero">
      <div class="auth__brand">AMS</div>
      <h1 class="auth__headline">几步创建，<br />长久安心。</h1>
      <p class="auth__tagline">本地优先、最小暴露 —— 你的档案只属于你。</p>
      <ul class="auth__points">
        <li>12 位以上强口令策略</li>
        <li>双因子可选，会话可控</li>
        <li>数据归你，随时导出</li>
      </ul>
    </aside>

    <main class="auth__panel">
      <div class="auth__card">
        <h2 class="auth__title">{{ t('RegisterView.4742b5', '创建账号') }}</h2>
        <p class="auth__subtitle">{{ t('RegisterView.cc6127', '个人档案管理系统') }}</p>

        <form class="auth__form" @submit.prevent="onSubmit">
          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.a1aaf3', '用户名') }} <em>*</em></span>
            <input v-model="username" class="field-control" type="text" autocomplete="username" :placeholder="t('RegisterView.e9fe4d', '登录用户名')" />
          </label>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.25124e', '昵称') }}</span>
            <input v-model="nickname" class="field-control" type="text" :placeholder="t('RegisterView.439569', '选填，默认同用户名')" />
          </label>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.9ed627', '邮箱') }}</span>
            <input v-model="email" class="field-control" type="email" autocomplete="email" :placeholder="t('RegisterView.924b8c', '选填')" />
          </label>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.5a9cc5', '手机号') }}</span>
            <input v-model="phone" class="field-control" type="tel" autocomplete="tel" :placeholder="t('RegisterView.924b8c', '选填')" />
          </label>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.c839a8', '密码') }} <em>*</em></span>
            <input v-model="password" class="field-control" type="password" autocomplete="new-password" :placeholder="t('RegisterView.1ef3fd', '设置登录密码')" />
          </label>

          <ul class="policy" :class="{ 'policy--ok': passwordOk }">
            <li :class="{ done: policy.length }">{{ t('RegisterView.f8249b', '至少 12 位') }}</li>
            <li :class="{ done: policy.classes }">{{ t('RegisterView.8e568b', '含至少 3 类字符（大小写/数字/符号）') }}</li>
            <li :class="{ done: policy.noRepeat }">{{ t('RegisterView.bb306f', '无连续重复字符（如 aaa）') }}</li>
            <li :class="{ done: policy.noUsername }">{{ t('RegisterView.00fcd5', '不包含用户名') }}</li>
          </ul>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.1d0167', '确认密码') }} <em>*</em></span>
            <input v-model="confirm" class="field-control" type="password" autocomplete="new-password" :placeholder="t('RegisterView.f27a15', '再次输入密码')" />
            <span v-if="policy.match === false" class="reg-err">{{ t('RegisterView.3e2b22', '两次输入的密码不一致') }}</span>
          </label>

          <p v-if="serverError" class="reg-error">{{ serverError }}</p>

          <button class="btn-primary auth__submit" type="submit" :disabled="submitting">
            {{ submitting ? '提交中…' : '注册' }}
          </button>
        </form>

        <p class="auth__switch">
          已有账号？<RouterLink to="/login">{{ t('RegisterView.6c01b0', '去登录') }}</RouterLink>
        </p>
      </div>
    </main>
  </div>
</template>

<style scoped>
.auth__card {
  animation: ams-enter-rise 0.5s var(--ease-apple) both;
}
.auth__submit {
  margin-top: var(--sp-2);
  width: 100%;
}
.auth__label em {
  color: var(--danger);
  font-style: normal;
}
.reg-err {
  font-size: 12px;
  color: var(--danger);
}
.reg-error {
  margin: 0;
  color: var(--danger);
  font-size: 13px;
}
.policy {
  list-style: none;
  margin: calc(var(--sp-2) * -1) 0 0;
  padding: 8px 12px;
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
  font-size: 12px;
  color: var(--text-muted);
  display: grid;
  gap: 2px;
}
.policy li::before {
  content: '○ ';
}
.policy li.done {
  color: var(--success);
}
.policy li.done::before {
  content: '● ';
}
.policy--ok {
  border: 1px solid color-mix(in srgb, var(--success) 40%, transparent);
}
.auth__switch {
  margin: var(--sp-4) 0 0;
  text-align: center;
  font-size: 13px;
  color: var(--text-muted);
}
</style>
