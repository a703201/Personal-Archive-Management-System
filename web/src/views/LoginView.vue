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
    error.value = '请输入用户名和口令'
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
    const msg = (e as Error).message || t('viewsLoginView.6d207e', '登录失败，请检查用户名与口令后重试')
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
  <div class="auth">
    <aside class="auth__hero stagger">
      <div class="auth__brand">
        <img v-if="branding.logoUrl" :src="branding.logoUrl" :alt="branding.brandName" />
        <span v-else>{{ branding.brandName }}</span>
      </div>
      <p class="auth__eyebrow">PRIVATE ARCHIVE</p>
      <h1 class="auth__headline">你的私人档案，<br />安全归位。</h1>
      <p class="auth__tagline">证件、学历、资产、健康 —— 一处归集，端到端加密。</p>
      <ul class="auth__points">
        <li>11 类分类模板，一键归档</li>
        <li>字段级国密加密，密钥不经服务端</li>
        <li>条目级共享，精准到一条</li>
      </ul>
      <div v-if="branding.footerText || branding.icpNo" class="auth__legal">
        <span v-if="branding.footerText">{{ branding.footerText }}</span>
        <span v-if="branding.icpNo">{{ branding.icpNo }}</span>
      </div>
    </aside>

    <main class="auth__panel">
      <div class="auth__card">
        <h2 class="auth__title">{{ titleText }}</h2>
        <p class="auth__subtitle">{{ subtitleText }}</p>

        <p v-if="branding.notice" class="notice">{{ branding.notice }}</p>

        <form class="auth__form" @submit.prevent="onSubmit">
          <label class="auth__field">
            <span class="auth__label">{{ t('LoginView.a1aaf3', '用户名') }}</span>
            <input
              v-model="username"
              class="field-control"
              type="text"
              autocomplete="username"
              :placeholder="t('LoginView.ad5f05', '请输入用户名')"
            />
          </label>

          <label class="auth__field">
            <span class="auth__label">{{ t('LoginView.c839a8', '口令') }}</span>
            <input
              v-model="password"
              class="field-control"
              type="password"
              autocomplete="current-password"
              :placeholder="t('LoginView.713b73', '请输入口令')"
            />
          </label>

          <label v-if="needTotp" class="auth__field">
            <span class="auth__label">{{ t('LoginView.08f63a', '动态码') }}</span>
            <input
              v-model="totpCode"
              class="field-control field-control--code"
              type="text"
              inputmode="numeric"
              maxlength="6"
              autocomplete="one-time-code"
              :placeholder="t('LoginView.39adbf', '6 位动态码')"
            />
          </label>

          <p v-if="error" class="error" role="alert">{{ error }}</p>

          <button class="btn-primary auth__submit" type="submit" :disabled="submitting">
            {{ submitting ? '登录中…' : '登录' }}
          </button>
        </form>

        <p class="auth__switch">
          <RouterLink to="/forgot">{{ t('LoginView.926eea', '忘记口令？') }}</RouterLink>
        </p>
        <p class="auth__switch">
          {{ t('LoginView.1e58e9', '还没有账号？') }}
          <RouterLink to="/register">{{ t('LoginView.8573cd', '立即注册') }}</RouterLink>
        </p>
      </div>
    </main>
  </div>
</template>

<style scoped>
.notice {
  margin: 0 0 var(--sp-4);
  padding: 10px 12px;
  border-radius: var(--g3-sm);
  background: var(--bg-hover);
  color: var(--text-secondary);
  font-size: 12px;
  line-height: 1.6;
}
.auth__submit {
  margin-top: var(--sp-2);
  width: 100%;
}
.error {
  margin: 0;
  color: var(--danger);
  font-size: 13px;
}
.auth__switch {
  margin: var(--sp-3) 0 0;
  text-align: center;
  font-size: 13px;
  color: var(--text-muted);
}
.auth__switch a {
  margin-left: 4px;
}
.field-control--code {
  letter-spacing: 6px;
  text-align: center;
  font-variant-numeric: tabular-nums;
}
</style>
