<script setup lang="ts">
/**
 * 登录页（之前只是路由占位，缺失真实实现）。
 *
 * 流程：提交 → api('/auth/login', { auth:false }) → setToken → 跳回原页面。
 * 账号/密码校验交给后端（弱口令字典、长度、字符类别等策略在 AuthService 侧）；
 * 前端只做非空提示。
 */
import { computed, onMounted, ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { api, setToken } from '../api/client'
import { t } from '../i18n'

const router = useRouter()
const route = useRoute()

/**
 * 登录页定制（FR-CFG-008）：Logo / 公告 / 页脚 / 备案号由服务端配置下发。
 *
 * 这是个**公开**接口（登录页渲染时还没有令牌），所以只取展示用字段。
 * 拉取失败一律静默降级为默认值 —— 登录页是全局入口，不能因为「品牌配置
 * 接口挂了」就白屏，登录这件事本身比品牌展示重要得多。
 */
interface Branding {
  brandName: string
  logoUrl: string
  notice: string
  footerText: string
  icpNo: string
}

const branding = ref<Branding>({
  brandName: 'AMS',
  logoUrl: '',
  notice: '',
  footerText: '',
  icpNo: '',
})

/** 标题：品牌名优先（FR-CFG-008），否则用当前语言文案（FR-CFG-009）。 */
const titleText = computed(() =>
  branding.value.brandName && branding.value.brandName !== 'AMS'
    ? branding.value.brandName
    : t('login.title', t('viewsLoginView.cc6127', '个人档案管理系统')),
)
const subtitleText = computed(() => t('login.subtitle', t('viewsLoginView.693b7f', '请登录以继续')))

onMounted(async () => {
  try {
    const b = await api<Branding>('/branding', { auth: false })
    branding.value = { ...branding.value, ...b }
  } catch {
    /* 静默降级为默认品牌信息 */
  }
})

const username = ref('')
const password = ref('')
const error = ref('')
const submitting = ref(false)
/** 双因子动态码（FR-AUTH-009）：默认收起，被后端拒绝后再展开 */
const totpCode = ref('')
const needTotp = ref(false)

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
      // 后端要跑 PBKDF2-SM3 600k 迭代做口令校验，给足预算（默认 15s 偏紧）；
      // 超时后会抛 TIMEOUT 并由下面的 catch 正常显示错误，不会卡在「登录中…」。
      timeoutMs: 30000,
      body: {
        username: username.value,
        password: password.value,
        totpCode: totpCode.value.trim(),
      },
    })
    setToken(res.accessToken)
    const redirect = (route.query.redirect as string) || '/overview'
    router.replace(redirect)
  } catch (e) {
    const msg = (e as Error).message || t('viewsLoginView.6d207e', '登录失败，请重试')
    error.value = msg
    // 「请输入 6 位动态码」「动态码不正确」「动态码已使用」都说明该账号启用了双因子
    if (msg.includes(t('viewsLoginView.dae7c8', '双因子')) || msg.includes(t('viewsLoginView.08f63a', '动态码'))) {
      needTotp.value = true
    }
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <div class="login-card">
      <div class="brand">
        <img v-if="branding.logoUrl" :src="branding.logoUrl" :alt="branding.brandName" class="brand__logo" />
        <span v-else>{{ branding.brandName }}</span>
      </div>
      <h1 class="title">{{ titleText }}</h1>
      <p class="subtitle">{{ subtitleText }}</p>

      <!-- 公告（FR-CFG-008）：有配置才显示 -->
      <p v-if="branding.notice" class="notice">{{ branding.notice }}</p>

      <form class="form" @submit.prevent="onSubmit">
        <label class="field">
          <span class="field__label">{{ t('LoginView.a1aaf3', '用户名') }}</span>
          <input
            v-model="username"
            class="field__input"
            type="text"
            autocomplete="username"
            :placeholder="t('LoginView.ad5f05', '请输入用户名')"
          />
        </label>

        <label class="field">
          <span class="field__label">{{ t('LoginView.c839a8', '密码') }}</span>
          <input
            v-model="password"
            class="field__input"
            type="password"
            autocomplete="current-password"
            :placeholder="t('LoginView.713b73', '请输入密码')"
          />
        </label>

        <label v-if="needTotp" class="field">
          <span class="field__label">{{ t('LoginView.08f63a', '动态码') }}</span>
          <input
            v-model="totpCode"
            class="field__input field__input--code"
            type="text"
            inputmode="numeric"
            maxlength="6"
            autocomplete="one-time-code"
            :placeholder="t('LoginView.39adbf', '6 位动态码')"
          />
        </label>

        <p v-if="error" class="error" role="alert">{{ error }}</p>

        <button class="submit" type="submit" :disabled="submitting">
          {{ submitting ? '登录中…' : '登录' }}
        </button>
      </form>

      <p class="switch">
        <RouterLink to="/forgot">{{ t('LoginView.926eea', '忘记口令？') }}</RouterLink>
      </p>
      <p class="switch">{{ t('LoginView.1e58e9', '还没有账号？') }}<RouterLink to="/register">{{ t('LoginView.8573cd', '立即注册') }}</RouterLink></p>

      <!-- 页脚与备案号（FR-CFG-008） -->
      <footer v-if="branding.footerText || branding.icpNo" class="login-foot">
        <span v-if="branding.footerText">{{ branding.footerText }}</span>
        <span v-if="branding.icpNo">{{ branding.icpNo }}</span>
      </footer>
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
.brand__logo {
  max-height: 44px;
  max-width: 180px;
  object-fit: contain;
}
.notice {
  margin: 0 0 16px;
  padding: 8px 12px;
  border-radius: var(--g3-sm, 10px);
  background: var(--bg-hover, #f3f4f6);
  color: var(--text-secondary, #4b5563);
  font-size: 12px;
  line-height: 1.6;
}
.login-foot {
  margin-top: 20px;
  padding-top: 12px;
  border-top: 1px solid var(--border-subtle, #e5e7eb);
  display: flex;
  flex-direction: column;
  gap: 4px;
  text-align: center;
  font-size: 11px;
  color: var(--text-muted, #9ca3af);
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
.field__input--code {
  letter-spacing: 6px;
  text-align: center;
  font-variant-numeric: tabular-nums;
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
