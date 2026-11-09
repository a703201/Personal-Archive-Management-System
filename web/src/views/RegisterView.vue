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
import { ref, computed, onMounted } from 'vue'
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

/**
 * 图形验证码（FR-AUTH-011）：注册接口强制要求，故本页常显。
 * SVG 用 <img :src> 渲染，禁止 v-html 注入。
 */
const captchaId = ref('')
const captchaSvg = ref('')
const captchaCode = ref('')
const captchaSrc = computed(() =>
  captchaSvg.value ? 'data:image/svg+xml,' + encodeURIComponent(captchaSvg.value) : '',
)

/** 拉取（或刷新）验证码；带 old=<旧 ID> 让后端作废旧挑战。 */
async function refreshCaptcha(): Promise<void> {
  const old = captchaId.value
  try {
    const q = old ? `?old=${encodeURIComponent(old)}` : ''
    const res = await api<{ captchaId: string; svg: string; expiresAt: number }>(
      `/auth/captcha${q}`,
      { auth: false },
    )
    captchaId.value = res.captchaId
    captchaSvg.value = res.svg
    captchaCode.value = ''
  } catch {
    // 静默降级：用户可点图片/刷新按钮重试
  }
}

// 注册页常显验证码，进入即加载一张
onMounted(() => {
  void refreshCaptcha()
})

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
    serverError.value = '请输入用户名和口令'
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
        // FR-AUTH-011：注册强制图形验证码
        captchaId: captchaId.value,
        captchaCode: captchaCode.value.trim(),
      },
    })
    success(t('viewsRegisterView.5fcfe1', '注册成功，请登录'))
    const redirect = (route.query.redirect as string) || '/login'
    router.replace(redirect)
  } catch (e) {
    serverError.value = (e as Error).message || t('viewsRegisterView.ff3a15', '注册失败，请稍后重试')
    toastError(serverError.value)
    // challenge 一次性消费 / 错误 / 过期后都需换新图
    void refreshCaptcha()
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="auth">
    <aside class="auth__hero stagger">
      <div class="auth__brand">AMS</div>
      <p class="auth__eyebrow">GET STARTED</p>
      <h1 class="auth__headline">{{ t('RegisterView.heroHeadlineA', '几步创建，') }}<br />{{ t('RegisterView.heroHeadlineB', '长久安心。') }}</h1>
      <p class="auth__tagline">{{ t('RegisterView.heroTagline', '本地优先、最小暴露 —— 你的档案只属于你。') }}</p>
      <ul class="auth__points">
        <li>{{ t('RegisterView.heroPoint1', '12 位以上强口令策略') }}</li>
        <li>{{ t('RegisterView.heroPoint2', '双因子可选，会话可控') }}</li>
        <li>{{ t('RegisterView.heroPoint3', '数据归你，随时导出') }}</li>
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
            <span class="auth__label">{{ t('RegisterView.c839a8', '口令') }} <em>*</em></span>
            <input v-model="password" class="field-control" type="password" autocomplete="new-password" :placeholder="t('RegisterView.1ef3fd', '设置登录口令')" />
          </label>

          <ul class="policy" :class="{ 'policy--ok': passwordOk }">
            <li :class="{ done: policy.length }">{{ t('RegisterView.f8249b', '至少 12 位') }}</li>
            <li :class="{ done: policy.classes }">{{ t('RegisterView.8e568b', '含至少 3 类字符（大小写/数字/符号）') }}</li>
            <li :class="{ done: policy.noRepeat }">{{ t('RegisterView.bb306f', '无连续重复字符（如 aaa）') }}</li>
            <li :class="{ done: policy.noUsername }">{{ t('RegisterView.00fcd5', '不包含用户名') }}</li>
          </ul>

          <label class="auth__field">
            <span class="auth__label">{{ t('RegisterView.1d0167', '确认口令') }} <em>*</em></span>
            <input v-model="confirm" class="field-control" type="password" autocomplete="new-password" :placeholder="t('RegisterView.f27a15', '再次输入口令')" />
            <span v-if="policy.match === false" class="reg-err">{{ t('RegisterView.3e2b22', '两次输入的口令不一致') }}</span>
          </label>

          <div class="auth__field">
            <span class="auth__label">{{ t('RegisterView.captchaLabel', '验证码') }} <em>*</em></span>
            <div class="captcha-row">
              <img
                v-if="captchaSrc"
                class="captcha-img"
                :src="captchaSrc"
                :alt="t('RegisterView.captchaAlt', '验证码，点击可刷新')"
                @click="refreshCaptcha"
              />
              <button class="captcha-refresh" type="button" @click="refreshCaptcha">
                {{ t('RegisterView.captchaRefresh', '刷新') }}
              </button>
            </div>
            <input
              v-model="captchaCode"
              class="field-control"
              type="text"
              maxlength="6"
              autocomplete="off"
              :placeholder="t('RegisterView.captchaPlaceholder', '请输入上图中的字符')"
            />
          </div>

          <p v-if="serverError" class="reg-error">{{ serverError }}</p>

          <button class="btn-primary auth__submit" type="submit" :disabled="submitting">
            {{ submitting ? '注册中…' : '注册' }}
          </button>
        </form>

        <p class="auth__switch">
          已有账号？<RouterLink to="/login">{{ t('RegisterView.6c01b0', '返回登录') }}</RouterLink>
        </p>
      </div>
    </main>
  </div>
</template>

<style scoped>
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
.captcha-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 8px;
}
.captcha-img {
  width: 180px;
  height: 52px;
  border: 1px solid var(--border, #d7dce3);
  border-radius: var(--g3-sm);
  cursor: pointer;
  background: #fff;
}
.captcha-refresh {
  border: none;
  background: none;
  color: var(--accent);
  cursor: pointer;
  font-size: 13px;
  padding: 4px;
}
</style>
