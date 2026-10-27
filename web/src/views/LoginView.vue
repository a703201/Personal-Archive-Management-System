<script setup lang="ts">
/**
 * 登录页（之前只是路由占位，缺失真实实现）。
 *
 * 流程：提交 → api('/auth/login', { auth:false }) → setToken → 跳回原页面。
 * 账号/密码校验交给后端（弱口令字典、长度、字符类别等策略在 AuthService 侧）；
 * 前端只做非空提示。
 */
import { ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api, setToken } from '../api/client'

const router = useRouter()
const route = useRoute()

const username = ref('')
const password = ref('')
const error = ref('')
const submitting = ref(false)

async function onSubmit(): Promise<void> {
  error.value = ''
  if (!username.value || !password.value) {
    error.value = '请输入用户名和密码'
    return
  }
  submitting.value = true
  try {
    const res = await api<{ accessToken: string }>('/auth/login', {
      method: 'POST',
      auth: false,
      body: { username: username.value, password: password.value },
    })
    setToken(res.accessToken)
    const redirect = (route.query.redirect as string) || '/overview'
    router.replace(redirect)
  } catch (e) {
    error.value = (e as Error).message || '登录失败，请重试'
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <div class="login-card">
      <div class="brand">AMS</div>
      <h1 class="title">个人档案管理系统</h1>
      <p class="subtitle">请登录以继续</p>

      <form class="form" @submit.prevent="onSubmit">
        <label class="field">
          <span class="field__label">用户名</span>
          <input
            v-model="username"
            class="field__input"
            type="text"
            autocomplete="username"
            placeholder="请输入用户名"
          />
        </label>

        <label class="field">
          <span class="field__label">密码</span>
          <input
            v-model="password"
            class="field__input"
            type="password"
            autocomplete="current-password"
            placeholder="请输入密码"
          />
        </label>

        <p v-if="error" class="error">{{ error }}</p>

        <button class="submit" type="submit" :disabled="submitting">
          {{ submitting ? '登录中…' : '登录' }}
        </button>
      </form>

      <p class="switch">
        还没有账号？<RouterLink to="/register">立即注册</RouterLink>
      </p>
    </div>
  </div>
</template>

<style scoped>
.login-wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-app, #eef1f6);
  padding: var(--sp-4, 16px);
}
.login-card {
  width: 100%;
  max-width: 380px;
  background: var(--bg-surface, #fff);
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--g3-lg, 24px);
  padding: 32px;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.06);
  corner-style: continuous;
}
.switch {
  margin: 16px 0 0;
  text-align: center;
  font-size: 13px;
  color: var(--text-muted, #9ca3af);
}
.brand {
  font-weight: 700;
  font-size: 24px;
  color: var(--accent, #2563eb);
  text-align: center;
}
.title {
  font-size: 18px;
  margin: 8px 0 0;
  text-align: center;
  color: var(--text-primary, #1f2937);
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
</style>
