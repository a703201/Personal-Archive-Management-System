<script setup lang="ts">
/**
 * 首次部署初始化向导。
 *
 * 仅在后端「尚无管理员且 SETUP_INITIALIZED != true」时可访问（后端接口
 * 亦有防重放）。四步：数据库连接 → 创建管理员 → 邮件服务（可跳过）→ 完成。
 *
 * 所有请求 auth:false：此时还没有任何账号与令牌。
 * 视觉沿用 .auth 分屏外壳与全局设计令牌，不引入新的样式语言。
 */
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api/client'
import { t } from '../i18n'
import { useToast } from '../composables/useToast'

interface DbCfg {
  host: string
  port: string
  name: string
  user: string
  password: string
  configured: boolean
}
interface MailCfg {
  enabled: boolean
  host: string
  port: string
  user: string
  fromAddr: string
  secure: string
  password: string
}
interface SetupStatus {
  initialized: boolean
  database: DbCfg
  mail: MailCfg
}

const router = useRouter()
const toast = useToast()

const loading = ref(true)
const initialized = ref(false)
const loadError = ref('')
const step = ref(1)
const busy = ref(false)
const testing = ref(false)

const db = ref<DbCfg>({ host: '', port: '', name: '', user: '', password: '', configured: false })
const mail = ref<MailCfg>({ enabled: false, host: '', port: '465', user: '', fromAddr: '', secure: 'ssl', password: '' })
const admin = ref({ username: '', nickname: '', password: '', confirm: '', email: '', phone: '' })

const steps = [
  { n: 1, label: t('setup.step1', '数据库') },
  { n: 2, label: t('setup.step2', '管理员') },
  { n: 3, label: t('setup.step3', '邮件服务') },
  { n: 4, label: t('setup.step4', '完成') },
]

const canNext = computed(() => {
  if (step.value === 1) {
    return !!(db.value.host && db.value.port && db.value.name && db.value.user)
  }
  if (step.value === 2) {
    return !!(admin.value.username && admin.value.password &&
      admin.value.password === admin.value.confirm &&
      (admin.value.email || admin.value.phone))
  }
  return true
})

async function load(): Promise<void> {
  loading.value = true
  loadError.value = ''
  try {
    const s = await api<SetupStatus>('/setup/status', { auth: false })
    initialized.value = s.initialized
    if (s.database) db.value = { ...s.database, password: '' }
    if (s.mail) mail.value = { ...s.mail, password: '' }
  } catch (e) {
    // 后端为旧版本（无 /setup/status）时不影响既有登录流程
    loadError.value = (e as Error).message
  } finally {
    loading.value = false
  }
}
onMounted(load)

async function testDb(): Promise<void> {
  testing.value = true
  try {
    const r = await api<{ ok: boolean; message: string }>('/setup/test-db', {
      method: 'POST', auth: false,
      body: { ...db.value, password: db.value.password || undefined },
    })
    if (r.ok) toast.success(t('setup.dbOk', '数据库连接成功'))
    else toast.error(r.message || t('setup.dbFail', '连接失败'))
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    testing.value = false
  }
}

async function saveDb(): Promise<boolean> {
  try {
    const r = await api<{ needRestart: boolean }>('/setup/database', {
      method: 'POST', auth: false,
      body: { ...db.value, password: db.value.password || undefined },
    })
    return !r.needRestart || confirm(t('setup.restartTip',
      '数据库配置已保存，需要重启服务后才会生效。\n\n若只是使用同服务器默认数据库，可直接继续；若修改了连接信息，建议现在重启服务，再回到本向导继续创建管理员。\n\n点击「确定」继续创建管理员。'))
  } catch (e) {
    toast.error((e as Error).message)
    return false
  }
}

async function saveMail(): Promise<boolean> {
  try {
    await api('/setup/mail', {
      method: 'POST', auth: false,
      body: { ...mail.value, enabled: String(mail.value.enabled), password: mail.value.password || undefined },
    })
    return true
  } catch (e) {
    toast.error((e as Error).message)
    return false
  }
}

async function testMail(): Promise<void> {
  if (!mail.value.fromAddr) { toast.warning(t('setup.needFrom', '请先填写发件邮箱')); return }
  testing.value = true
  try {
    await saveMail()
    const r = await api<{ ok: boolean; message: string }>('/setup/test-mail', {
      method: 'POST', auth: false, body: { to: mail.value.fromAddr },
    })
    if (r.ok) toast.success(t('setup.mailQueued', '测试邮件已进入发送队列'))
    else toast.info(r.message)
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    testing.value = false
  }
}

async function next(): Promise<void> {
  if (!canNext.value || busy.value) return
  busy.value = true
  try {
    if (step.value === 1) {
      // 未修改连接信息时可跳过写入，保持 compose 环境变量默认
      const changed = db.value.host || db.value.password
      if (changed && !(await saveDb())) return
    }
    if (step.value === 2) {
      if (admin.value.password !== admin.value.confirm) {
        toast.warning(t('setup.pwdMismatch', '两次输入的口令不一致')); return
      }
      await api('/setup/admin', {
        method: 'POST', auth: false,
        body: {
          username: admin.value.username,
          nickname: admin.value.nickname,
          password: admin.value.password,
          email: admin.value.email,
          phone: admin.value.phone,
        },
      })
    }
    if (step.value === 3 && !(await saveMail())) return
    step.value += 1
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    busy.value = false
  }
}

function back(): void {
  if (step.value > 1 && step.value < 4) step.value -= 1
}

function finish(): void {
  // 整页刷新，清空前端路由里缓存的初始化状态
  window.location.assign('/login')
}

function goLogin(): void {
  router.replace('/login')
}
</script>

<template>
  <div class="auth">
    <aside class="auth__hero stagger">
      <div class="auth__brand">AMS</div>
      <p class="auth__eyebrow">FIRST RUN SETUP</p>
      <h1 class="auth__headline">几步完成，<br />开始使用。</h1>
      <p class="auth__tagline">配置数据库、创建管理员、接入邮件服务。全部信息只保存在你自己的服务器上。</p>
      <ul class="auth__points">
        <li>数据库默认与项目同服务器，也可指向外部</li>
        <li>首个账号自动成为管理员，无需手动授权</li>
        <li>邮件服务可稍后在系统运维中修改</li>
      </ul>
    </aside>

    <main class="auth__panel">
      <div class="auth__card setup">
        <template v-if="loading">
          <p class="setup__hint">{{ t('setup.loading', '正在检查初始化状态…') }}</p>
        </template>

        <template v-else-if="loadError">
          <h2 class="auth__title">{{ t('setup.unavailable', '无法读取初始化状态') }}</h2>
          <p class="auth__subtitle">{{ loadError }}</p>
          <button class="btn-primary" type="button" @click="load">{{ t('setup.retry', '重试') }}</button>
          <button class="btn-ghost" type="button" @click="goLogin">{{ t('setup.toLogin', '返回登录') }}</button>
        </template>

        <template v-else-if="initialized">
          <h2 class="auth__title">{{ t('setup.doneTitle', '系统已完成初始化') }}</h2>
          <p class="auth__subtitle">{{ t('setup.doneDesc', '管理员已创建，首次部署向导已关闭。请直接登录。') }}</p>
          <button class="btn-primary setup__wide" type="button" @click="goLogin">{{ t('setup.toLogin', '返回登录') }}</button>
        </template>

        <template v-else>
          <ol class="setup__steps" :aria-label="t('setup.progress', '初始化进度')">
            <li v-for="s in steps" :key="s.n" :class="{ 'is-active': step === s.n, 'is-done': step > s.n }">
              <span class="setup__dot">{{ step > s.n ? '✓' : s.n }}</span>
              <span>{{ s.label }}</span>
            </li>
          </ol>

          <!-- ① 数据库 -->
          <section v-if="step === 1" class="setup__section">
            <h2 class="auth__title">{{ t('setup.dbTitle', '数据库连接') }}</h2>
            <p class="auth__subtitle">{{ t('setup.dbDesc', '默认与项目同服务器。只有需要连接外部数据库时才修改。') }}</p>
            <div class="setup__grid">
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.dbHost', '连接 IP / 主机') }}</span>
                <input v-model="db.host" class="field-control" type="text" placeholder="172.28.0.10" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.dbPort', '端口') }}</span>
                <input v-model="db.port" class="field-control" type="text" inputmode="numeric" placeholder="5432" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.dbName', '数据库名') }}</span>
                <input v-model="db.name" class="field-control" type="text" placeholder="ams" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.dbUser', '数据库用户名') }}</span>
                <input v-model="db.user" class="field-control" type="text" placeholder="gaussdb" />
              </label>
              <label class="auth__field setup__full">
                <span class="auth__label">{{ t('setup.dbPassword', '数据库密码（留空不修改）') }}</span>
                <input v-model="db.password" class="field-control" type="password" autocomplete="new-password" />
              </label>
            </div>
            <div class="setup__actions">
              <button class="btn-ghost" type="button" :disabled="testing" @click="testDb">
                {{ testing ? t('setup.testing', '测试中…') : t('setup.testDb', '测试连接') }}
              </button>
              <span class="setup__tip">{{ t('setup.dbTip', '修改连接信息后需重启服务生效') }}</span>
            </div>
          </section>

          <!-- ② 管理员 -->
          <section v-else-if="step === 2" class="setup__section">
            <h2 class="auth__title">{{ t('setup.adminTitle', '创建管理员') }}</h2>
            <p class="auth__subtitle">{{ t('setup.adminDesc', '首个账号将自动获得所有者与机构管理员权限。') }}</p>
            <div class="setup__grid">
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.username', '用户名') }} <em>*</em></span>
                <input v-model="admin.username" class="field-control" type="text" autocomplete="username" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.nickname', '昵称') }}</span>
                <input v-model="admin.nickname" class="field-control" type="text" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.password', '口令') }} <em>*</em></span>
                <input v-model="admin.password" class="field-control" type="password" autocomplete="new-password" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.confirm', '确认口令') }} <em>*</em></span>
                <input v-model="admin.confirm" class="field-control" type="password" autocomplete="new-password" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.email', '邮箱') }}</span>
                <input v-model="admin.email" class="field-control" type="email" autocomplete="email" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.phone', '手机号') }}</span>
                <input v-model="admin.phone" class="field-control" type="tel" autocomplete="tel" />
              </label>
            </div>
            <p class="setup__tip">{{ t('setup.adminTip', '邮箱或手机号至少填一项，用于找回口令。口令策略沿用系统规则。') }}</p>
          </section>

          <!-- ③ 邮件服务 -->
          <section v-else-if="step === 3" class="setup__section">
            <h2 class="auth__title">{{ t('setup.mailTitle', '邮件服务') }}</h2>
            <p class="auth__subtitle">{{ t('setup.mailDesc', '用于找回口令时发送验证码。可以跳过，之后在「系统运维 → 部署配置」中配置。') }}</p>
            <label class="setup__switch">
              <input v-model="mail.enabled" type="checkbox" />
              <span>{{ t('setup.mailEnable', '启用 SMTP 邮件发送') }}</span>
            </label>
            <div v-if="mail.enabled" class="setup__grid">
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.smtpHost', 'SMTP 服务器') }}</span>
                <input v-model="mail.host" class="field-control" type="text" placeholder="smtp.example.com" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.smtpPort', '端口') }}</span>
                <input v-model="mail.port" class="field-control" type="text" inputmode="numeric" placeholder="465" />
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.smtpSecure', '加密方式') }}</span>
                <select v-model="mail.secure" class="field-control">
                  <option value="ssl">SSL / 465</option>
                  <option value="starttls">STARTTLS / 587</option>
                </select>
              </label>
              <label class="auth__field">
                <span class="auth__label">{{ t('setup.smtpUser', 'SMTP 账号') }}</span>
                <input v-model="mail.user" class="field-control" type="text" autocomplete="username" />
              </label>
              <label class="auth__field setup__full">
                <span class="auth__label">{{ t('setup.smtpPassword', 'SMTP 密码（留空不修改）') }}</span>
                <input v-model="mail.password" class="field-control" type="password" autocomplete="new-password" />
              </label>
              <label class="auth__field setup__full">
                <span class="auth__label">{{ t('setup.smtpFrom', '发件邮箱') }}</span>
                <input v-model="mail.fromAddr" class="field-control" type="email" />
              </label>
            </div>
            <div class="setup__actions">
              <button v-if="mail.enabled" class="btn-ghost" type="button" :disabled="testing" @click="testMail">
                {{ t('setup.testMail', '发送测试邮件') }}
              </button>
              <span class="setup__tip">{{ t('setup.mailTip', '保存后重启服务开始真实投递') }}</span>
            </div>
          </section>

          <!-- ④ 完成 -->
          <section v-else class="setup__section setup__finish">
            <div class="setup__check">✓</div>
            <h2 class="auth__title">{{ t('setup.finishTitle', '初始化完成') }}</h2>
            <p class="auth__subtitle">{{ t('setup.finishDesc', '管理员账号已创建。请使用刚设置的账号登录，随后可在「系统运维 → 部署配置」中随时调整数据库与邮件服务。') }}</p>
            <button class="btn-primary setup__wide" type="button" @click="finish">{{ t('setup.goLogin', '返回登录') }}</button>
          </section>

          <div v-if="step < 4" class="setup__nav">
            <button v-if="step > 1" class="btn-ghost" type="button" @click="back">{{ t('setup.back', '上一步') }}</button>
            <span class="setup__spacer" />
            <button v-if="step === 3" class="btn-text" type="button" @click="step = 4">{{ t('setup.skip', '跳过') }}</button>
            <button class="btn-primary" type="button" :disabled="!canNext || busy" @click="next">
              {{ busy ? t('setup.processing', '处理中…') : t('setup.next', '下一步') }}
            </button>
          </div>
        </template>
      </div>
    </main>
  </div>
</template>

<style scoped>
.setup { max-width: 520px; }
.setup__hint { color: var(--text-muted); font-size: var(--font-size-sm); }
.setup__wide { width: 100%; margin-top: var(--sp-4); }
.setup__steps {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  list-style: none;
  margin: 0 0 var(--sp-5);
  padding: 0;
  font-size: var(--font-size-xs);
  color: var(--text-muted);
}
.setup__steps li { display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; }
.setup__steps li + li::before {
  content: '';
  width: 14px;
  height: 1px;
  margin-right: var(--sp-1);
  background: var(--border-strong);
}
.setup__steps li.is-active { color: var(--accent); font-weight: 600; }
.setup__steps li.is-done { color: var(--text-secondary); }
.setup__dot {
  display: grid;
  place-items: center;
  width: 20px;
  height: 20px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  font-size: 11px;
}
.is-active .setup__dot { background: var(--accent); color: #fff; }
.is-done .setup__dot { background: var(--success-soft); color: var(--success); }
.setup__section { margin-top: var(--sp-2); }
.setup__grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-3);
  margin-top: var(--sp-4);
}
.setup__full { grid-column: 1 / -1; }
.setup__actions {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  margin-top: var(--sp-4);
  flex-wrap: wrap;
}
.setup__tip { font-size: var(--font-size-xs); color: var(--text-muted); line-height: 1.5; }
.setup__switch {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  margin-top: var(--sp-3);
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  cursor: pointer;
}
.setup__switch input { width: 18px; height: 18px; accent-color: var(--accent); }
.setup__nav {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  margin-top: var(--sp-6);
  padding-top: var(--sp-4);
  border-top: 1px solid var(--hairline);
}
.setup__spacer { flex: 1; }
.setup__finish { text-align: center; }
.setup__check {
  width: 48px;
  height: 48px;
  margin: 0 auto var(--sp-4);
  display: grid;
  place-items: center;
  border-radius: var(--g3-pill);
  background: var(--success-soft);
  color: var(--success);
  font-size: 22px;
  font-weight: 600;
}
@media (max-width: 639px) {
  .setup__grid { grid-template-columns: 1fr; }
  .setup__steps { flex-wrap: wrap; }
  .setup__steps li + li::before { display: none; }
}
</style>
