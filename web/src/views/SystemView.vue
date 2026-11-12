<script setup lang="ts">
/**
 * 系统运维（P1）
 *   FR-CFG-005 系统健康看板 · FR-CFG-003 策略配置中心
 *   FR-CFG-007 密钥管理界面  · FR-CFG-006 备份与恢复
 *   FR-NTF-003 定时任务调度
 *
 * 五个能力共用一套「分段控件 + 卡片」布局：它们都是**低频、高权限**的
 * 运维动作，塞进同一个页面比散落五个菜单更容易被找到，也便于统一守卫
 * （本页路由 meta.admin=true，且每个接口在服务端再校验 system:admin）。
 */
import { ref, computed, onMounted } from 'vue'
import { t as tr } from '../i18n'
import { api } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import { useToast } from '../composables/useToast'

const toast = useToast()

type TabKey = 'health' | 'config' | 'jobs' | 'keys' | 'backup' | 'deployment' | 'storage'

const TABS: { key: TabKey; label: string }[] = [
  { key: 'health', label: tr('viewsSystemView.9ac566', '健康看板') },
  { key: 'config', label: tr('viewsSystemView.f95386', '配置中心') },
  { key: 'jobs', label: tr('viewsSystemView.c97ffb', '定时任务') },
  { key: 'keys', label: tr('viewsSystemView.25c51c', '密钥管理') },
  { key: 'backup', label: tr('viewsSystemView.823396', '备份恢复') },
  { key: 'deployment', label: tr('viewsSystemView.deploy', '部署配置') },
  { key: 'storage', label: tr('SystemView.storageTab', '存储平台') },
]

const tab = ref<TabKey>('health')
const loading = ref(true)
const error = ref('')

// ---------------------------------------------------------------
// 健康看板
// ---------------------------------------------------------------

interface Health {
  uptimeMs: number | string
  requests: number | string
  error4xx: number | string
  error5xx: number | string
  errorRatePermille: number | string
  onlineSessions: number | string
  dbLatencyMs: number | string
  storageBytes: number | string
  storageFiles: number | string
  tables: { table: string; rows: number | string }[]
}
const health = ref<Health | null>(null)

function fmtBytes(n: number | string): string {
  const v = Number(n ?? 0)
  if (v < 1024) return `${v} B`
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(1)} KB`
  if (v < 1024 * 1024 * 1024) return `${(v / 1024 / 1024).toFixed(1)} MB`
  return `${(v / 1024 / 1024 / 1024).toFixed(2)} GB`
}

function fmtUptime(ms: number | string): string {
  const total = Number(ms ?? 0)
  if (!Number.isFinite(total) || total < 0) return '—'
  const s = Math.floor(total / 1000)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  // 词条含 {h}/{m}/{s} 占位符，由 t() 用 vars 统一替换（三语均生效）；
  // 中文输出仍为「2 小时 5 分」「5 分 30 秒」，格式不变。
  if (h > 0) {
    return tr('viewsSystemView.uptimeHours', `${h} 小时 ${m} 分`, { h, m })
  }
  return tr('viewsSystemView.b0ec90', `${m} 分 ${s % 60} 秒`, { m, s: s % 60 })
}

const errorRateText = computed(() => {
  const n = Number(health.value?.errorRatePermille ?? 0)
  return `${(n / 10).toFixed(1)}%`
})

// ---------------------------------------------------------------
// 配置中心
// ---------------------------------------------------------------

interface Setting {
  key: string
  value: string
  valueType: string
  isSecret: boolean | string
  description: string
  updatedAt: number | string
  version: number | string
}
const settings = ref<Setting[]>([])
const showSetting = ref(false)
const settingMode = ref<'create' | 'edit'>('create')
const settingForm = ref({ scope: 'system', key: '', value: '', valueType: 'string', description: '' })
const savingSetting = ref(false)

async function loadConfig(): Promise<void> {
  const res = await api<{ scope: string; settings: Setting[] }>('/admin/config?scope=system')
  settings.value = res.settings ?? []
}

function openSettingCreate(): void {
  settingMode.value = 'create'
  settingForm.value = { scope: 'system', key: '', value: '', valueType: 'string', description: '' }
  showSetting.value = true
}

function openSettingEdit(s: Setting): void {
  settingMode.value = 'edit'
  settingForm.value = {
    scope: 'system',
    key: s.key,
    value: s.isSecret === true || s.isSecret === 't' ? '' : s.value,
    valueType: s.valueType || 'string',
    description: s.description,
  }
  showSetting.value = true
}

async function saveSetting(): Promise<void> {
  const f = settingForm.value
  if (!f.key.trim()) {
    toast.warning(tr('viewsSystemView.90df98', '请填写配置键名'))
    return
  }
  if (settingMode.value === 'edit' && !f.value) {
    toast.warning(tr('viewsSystemView.d2c41d', '敏感项留空表示不修改，请先输入新值'))
    return
  }
  savingSetting.value = true
  try {
    await api('/admin/config', { method: 'PUT', body: { ...f, key: f.key.trim() } })
    toast.success(tr('viewsSystemView.c4e4c1', '配置已保存'))
    showSetting.value = false
    await loadConfig()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    savingSetting.value = false
  }
}

async function removeSetting(s: Setting): Promise<void> {
  try {
    await api(`/admin/config?scope=system&key=${encodeURIComponent(s.key)}`, { method: 'DELETE' })
    toast.success(tr('viewsSystemView.20c4d9', `已删除 ${s.key}`, { key: s.key }))
    await loadConfig()
  } catch (e) {
    toast.error((e as Error).message)
  }
}

// ---------------------------------------------------------------
// 定时任务
// ---------------------------------------------------------------

interface Job {
  name: string
  description: string
  lastRunAt: number | string
}
const jobs = ref<Job[]>([])
const runningJob = ref('')

async function loadJobs(): Promise<void> {
  const res = await api<{ jobs: Job[] }>('/admin/jobs')
  jobs.value = res.jobs ?? []
}

async function runJob(j: Job): Promise<void> {
  runningJob.value = j.name
  try {
    const res = await api<{ ran: boolean; affected: number }>(
      `/admin/jobs/${encodeURIComponent(j.name)}/run`,
      { method: 'POST', body: {} },
    )
    toast.success(tr('viewsSystemView.20eed4', `${j.name} 执行完成，影响 ${res.affected} 条`, { name: j.name, count: res.affected }))
    await loadJobs()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    runningJob.value = ''
  }
}

// ---------------------------------------------------------------
// 密钥管理
// ---------------------------------------------------------------

interface KeyRow {
  id: string
  keyId: string
  version: number | string
  alg: number | string
  purpose: string
  status: number | string
  note: string
  createdAt: number | string
  retiredAt: number | string
  revokedAt: number | string
}
const keys = ref<KeyRow[]>([])
const keyBusy = ref(false)

const KEY_STATUS: Record<number, { label: string; cls: string }> = {
  1: { label: tr('viewsSystemView.595aab', '启用中'), cls: 'st st--ok' },
  2: { label: tr('viewsSystemView.0c9e06', '已退役'), cls: 'st st--warn' },
  3: { label: tr('viewsSystemView.7fdb5a', '已吊销'), cls: 'st st--bad' },
}

async function loadKeys(): Promise<void> {
  const res = await api<{ keys: KeyRow[] }>('/admin/keys')
  keys.value = res.keys ?? []
}

async function rotateKey(): Promise<void> {
  keyBusy.value = true
  try {
    const res = await api<{ id: string; version: number }>('/admin/keys/rotate', {
      method: 'POST',
      body: { keyId: 'ams-data', purpose: 'data', note: tr('viewsSystemView.2648f1', '管理界面手动轮换') },
    })
    toast.success(tr('viewsSystemView.26ff29', `已登记新版本 v${res.version}`, { version: res.version }))
    await loadKeys()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    keyBusy.value = false
  }
}

async function changeKeyStatus(k: KeyRow, kind: 'retire' | 'revoke'): Promise<void> {
  keyBusy.value = true
  try {
    await api(`/admin/keys/${k.id}/${kind}`, { method: 'POST', body: {} })
    toast.success(kind === 'retire' ? tr('SystemView.x5b109a', '已退役') : tr('viewsSystemView.7fdb5a', '已吊销'))
    await loadKeys()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    keyBusy.value = false
  }
}

// ---------------------------------------------------------------
// 备份恢复
// ---------------------------------------------------------------

interface BackupMeta {
  file: string
  size: number | string
  createdAt: number | string
}
const backups = ref<BackupMeta[]>([])
const backupBusy = ref(false)

async function loadBackups(): Promise<void> {
  const res = await api<{ backups: BackupMeta[] }>('/admin/backups')
  backups.value = res.backups ?? []
}

async function createBackup(): Promise<void> {
  backupBusy.value = true
  try {
    await api('/admin/backup', { method: 'POST', body: {} })
    toast.success(tr('viewsSystemView.d1b36f', '配置快照已生成'))
    await loadBackups()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    backupBusy.value = false
  }
}

async function restoreBackup(b: BackupMeta): Promise<void> {
  backupBusy.value = true
  try {
    const res = await api<{ restored: number }>('/admin/backup/restore', {
      method: 'POST',
      body: { file: b.file },
    })
    toast.success(tr('viewsSystemView.a82657', `已恢复 ${res.restored} 项配置`, { count: res.restored }))
    await loadConfig()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    backupBusy.value = false
  }
}

// ---------------------------------------------------------------

async function loadAll(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    const h = await api<Health>('/admin/health')
    health.value = h
  } catch (e) {
    error.value = (e as Error).message
    loading.value = false
    return
  }
  // 其余面板按需加载失败不阻断首屏（可能是权限或配置问题）
  try {
    await loadConfig()
  } catch {
    toast.warning(tr('SystemView.configLoadFailed', '配置中心加载失败'))
  }
  try {
    await loadJobs()
  } catch {
    toast.warning(tr('SystemView.jobsLoadFailed', '定时任务加载失败'))
  }
  try {
    await loadKeys()
  } catch {
    toast.warning(tr('SystemView.keysLoadFailed', '密钥信息加载失败'))
  }
  try {
    await loadBackups()
  } catch {
    toast.warning(tr('SystemView.backupsLoadFailed', '备份列表加载失败'))
  }
  try {
    await loadDeployment()
  } catch {
    toast.warning(tr('SystemView.deployLoadFailed', '部署配置加载失败'))
  }
  try {
    await loadStorage()
  } catch {
    toast.warning(tr('SystemView.storageLoadFailed', '存储配置加载失败'))
  }
  loading.value = false
}


// ---------------------------------------------------------------
// 部署配置：数据库连接 + 邮件服务（/api/admin/deployment）
// 与「配置中心」的区别：这里写的是容器持久卷上的 deployment.env，
// 决定服务连哪个库、邮件怎么发；修改数据库后需重启服务生效。
// ---------------------------------------------------------------
interface DeployDb { host: string; port: string; name: string; user: string; password: string }
interface DeployMail {
  enabled: boolean; host: string; port: string; user: string
  fromAddr: string; secure: string; password: string
}
const depDb = ref<DeployDb>({ host: '', port: '', name: '', user: '', password: '' })
const depMail = ref<DeployMail>({ enabled: false, host: '', port: '465', user: '', fromAddr: '', secure: 'ssl', password: '' })
const depBusy = ref(false)

async function loadDeployment(): Promise<void> {
  const d = await api<{ database: DeployDb; mail: DeployMail }>('/admin/deployment')
  if (d.database) depDb.value = { ...d.database, password: '' }
  if (d.mail) depMail.value = { ...d.mail, password: '' }
}
async function saveDeploymentDb(): Promise<void> {
  depBusy.value = true
  try {
    const r = await api<{ message: string }>('/admin/deployment/database', { method: 'PUT', body: { ...depDb.value } })
    toast.success(r.message || tr('SystemView.deploySaved', '已保存'))
    depDb.value.password = ''
  } catch (e) { toast.error((e as Error).message) } finally { depBusy.value = false }
}
async function testDeploymentDb(): Promise<void> {
  depBusy.value = true
  try {
    const r = await api<{ ok: boolean; message: string }>('/admin/deployment/test-db', { method: 'POST', body: { ...depDb.value } })
    if (r.ok) toast.success(tr('SystemView.dbOk', '数据库连接成功'))
    else toast.error(r.message || tr('SystemView.dbFail', '连接失败'))
  } catch (e) { toast.error((e as Error).message) } finally { depBusy.value = false }
}
async function resetDeploymentDb(): Promise<void> {
  depBusy.value = true
  try {
    const r = await api<{ message: string }>('/admin/deployment/database', { method: 'DELETE' })
    toast.success(r.message || tr('SystemView.deployReset', '已恢复默认'))
    await loadDeployment()
  } catch (e) { toast.error((e as Error).message) } finally { depBusy.value = false }
}
async function saveDeploymentMail(): Promise<void> {
  depBusy.value = true
  try {
    await api('/admin/deployment/mail', {
      method: 'PUT',
      body: { ...depMail.value, enabled: String(depMail.value.enabled), password: depMail.value.password || undefined },
    })
    toast.success(tr('SystemView.mailSaved', '邮件配置已保存，重启服务后生效'))
    depMail.value.password = ''
  } catch (e) { toast.error((e as Error).message) } finally { depBusy.value = false }
}
async function testDeploymentMail(): Promise<void> {
  if (!depMail.value.fromAddr) { toast.warning(tr('SystemView.needFrom', '请先填写发件邮箱')); return }
  depBusy.value = true
  try {
    await saveDeploymentMail()
    const r = await api<{ ok: boolean; message: string }>('/admin/deployment/test-mail', {
      method: 'POST', body: { to: depMail.value.fromAddr },
    })
    if (r.ok) toast.success(tr('SystemView.mailQueued', '测试邮件已进入发送队列'))
    else toast.info(r.message)
  } catch (e) { toast.error((e as Error).message) } finally { depBusy.value = false }
}

// ---------------------------------------------------------------
// 存储平台（Q2 方案 A · /api/admin/storage/*）
//   GET  /api/admin/storage/providers  8 个可选平台 + 当前生效平台
//   GET  /api/admin/storage/config     当前配置（凭据脱敏回显）
//   PUT  /api/admin/storage/config     全量写 deployment.env，重启生效；
//        库内已有附件时改 provider/endpoint/bucket 由后端以 Conflict 拒绝。
// ---------------------------------------------------------------
interface StorageProviderOption {
  code: string
  name: string
  kind: string
  signature: string
  endpointTemplate: string
  regionHint: string
  pathStyle: boolean
  virtualHost: boolean
  needsCredentials: boolean
  bucketRule: string
  notes: string
  docsUrl: string
  ready: boolean
}
interface StorageProvidersResp {
  current: string
  configured: string
  requiresRestart: boolean
  transportReady: boolean
  providers: StorageProviderOption[]
}
interface StorageConfigResp {
  provider: string
  configuredProvider: string
  requiresRestart: boolean
  endpoint: string
  bucket: string
  region: string
  pathStyle: boolean
  accessKey: string
  secretKey: string
  transportReady: boolean
}
const storageProviders = ref<StorageProviderOption[]>([])
const storageCurrent = ref('')
const storageRestart = ref(false)
const storageTransportReady = ref(false)
const storageMask = ref({ accessKey: '', secretKey: '' })
const storageBusy = ref(false)
const storageForm = ref({
  provider: '',
  endpoint: '',
  bucket: '',
  region: '',
  accessKey: '',
  secretKey: '',
  pathStyle: true,
})

// 已有附件 → 锁定定位三元组。数据源是健康看板的 storageFiles 快照；
// 权威判定在服务端（PUT 的 countAll() > 0 → Conflict），此处只做前置提示。
const attachmentCount = computed(() => Number(health.value?.storageFiles ?? 0))
const locatorLocked = computed(() => attachmentCount.value > 0)
const selectedProvider = computed(
  () => storageProviders.value.find((p) => p.code === storageForm.value.provider) ?? null,
)

async function loadStorage(): Promise<void> {
  const [list, cfg] = await Promise.all([
    api<StorageProvidersResp>('/admin/storage/providers'),
    api<StorageConfigResp>('/admin/storage/config'),
  ])
  storageProviders.value = list.providers ?? []
  storageCurrent.value = cfg.provider || list.current
  storageRestart.value = Boolean(cfg.requiresRestart || list.requiresRestart)
  storageTransportReady.value = Boolean(cfg.transportReady)
  // 后端只给脱敏值，绝不预填进表单（预填会把 *** 写回配置文件）。
  storageMask.value = { accessKey: cfg.accessKey ?? '', secretKey: cfg.secretKey ?? '' }
  storageForm.value = {
    provider: cfg.provider || list.current,
    endpoint: cfg.endpoint ?? '',
    bucket: cfg.bucket ?? '',
    region: cfg.region ?? '',
    accessKey: '',
    secretKey: '',
    pathStyle: Boolean(cfg.pathStyle),
  }
}

async function saveStorage(): Promise<void> {
  const f = storageForm.value
  if (f.provider !== 'local' && (!f.endpoint.trim() || !f.bucket.trim())) {
    toast.warning(tr('SystemView.storageNeedEndpoint', '对象存储平台需要填写 Endpoint 与 Bucket'))
    return
  }
  storageBusy.value = true
  try {
    await api('/admin/storage/config', {
      method: 'PUT',
      body: {
        provider: f.provider,
        endpoint: f.endpoint.trim(),
        bucket: f.bucket.trim(),
        region: f.region.trim(),
        accessKey: f.accessKey,
        secretKey: f.secretKey,
        pathStyle: String(f.pathStyle),
      },
    })
    toast.success(tr('SystemView.storageSaved', '存储配置已保存，重启后端实例后生效'))
    await loadStorage()
  } catch (e) {
    const err = e as Error & { status?: number }
    if (err.status === 409) {
      toast.error(err.message + ' ' + tr('SystemView.storageConflictHint', '请先完成数据迁移（见 docs/16-对象存储迁移方案.md）后重试。'))
    } else {
      toast.error(err.message)
    }
  } finally {
    storageBusy.value = false
  }
}

onMounted(loadAll)

function fmtTime(ms: number | string | undefined): string {
  const n = Number(ms ?? 0)
  if (!n) return '—'
  return new Date(n).toLocaleString('zh-CN', { hour12: false })
}
</script>

<template>
  <section>
    <h1 class="page-title">{{ tr('SystemView.08f206', '系统运维') }}</h1>

    <div class="tabs" role="tablist">
      <button
        v-for="t in TABS"
        :key="t.key"
        class="tab"
        :class="{ 'tab--on': tab === t.key }"
        type="button"
        role="tab"
        :aria-selected="tab === t.key"
        @click="tab = t.key"
      >
        {{ t.label }}
      </button>
    </div>

    <p v-if="loading" class="hint">{{ tr('SystemView.300ee3', '加载中…') }}</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <!-- 健康看板 -->
    <template v-else-if="tab === 'health' && health">
      <div class="metrics">
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.66836c', '运行时长') }}</div>
          <div class="metric__value">{{ fmtUptime(health.uptimeMs) }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.b28376', '请求数') }}</div>
          <div class="metric__value">{{ health.requests }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.10a54c', '服务端错误率') }}</div>
          <div class="metric__value" :class="{ 'metric__value--bad': Number(health.errorRatePermille) >= 10 }">
            {{ errorRateText }}
          </div>
          <div class="metric__sub">4xx {{ health.error4xx }} · 5xx {{ health.error5xx }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.22e4bf', '在线会话') }}</div>
          <div class="metric__value">{{ health.onlineSessions }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.16f794', '数据库延迟') }}</div>
          <div class="metric__value">{{ health.dbLatencyMs }} ms</div>
          <div class="metric__sub">{{ tr('SystemView.9716a2', 'SELECT 1 往返') }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">{{ tr('SystemView.b0eca7', '附件存储') }}</div>
          <div class="metric__value">{{ fmtBytes(health.storageBytes) }}</div>
          <div class="metric__sub">{{ tr('SystemView.filesMetric', '{n} 个文件', { n: String(health.storageFiles) }) }}</div>
        </div>
      </div>

      <h2 class="section-title">{{ tr('SystemView.e8e6fc', '数据表行数') }}</h2>
      <div class="card">
        <div class="rows">
          <div v-for="t in health.tables" :key="t.table" class="rows__row">
            <code>{{ t.table }}</code>
            <span class="rows__n">{{ t.rows }}</span>
          </div>
        </div>
      </div>
    </template>

    <!-- 配置中心 -->
    <template v-else-if="tab === 'config'">
      <div class="bar">
        <p class="bar__hint">{{ tr('SystemView.b845a2', '敏感配置的值不会展示，编辑时留空表示不修改。') }}</p>
        <button class="btn-primary" type="button" @click="openSettingCreate">{{ tr('SystemView.679b34', '新增配置') }}</button>
      </div>
      <div class="card">
        <p v-if="settings.length === 0" class="hint">{{ tr('SystemView.ab13c3', '暂无配置项') }}</p>
        <div v-for="s in settings" :key="s.key" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title">
              <code>{{ s.key }}</code>
              <span v-if="s.isSecret === true || s.isSecret === 't'" class="st st--warn">{{ tr('SystemView.e4d1f0', '敏感') }}</span>
            </div>
            <div class="rowitem__sub">{{ s.description || '—' }}</div>
            <div class="rowitem__value">{{ s.value }}</div>
          </div>
          <div class="rowitem__actions">
            <button class="btn-text" type="button" @click="openSettingEdit(s)">编辑</button>
            <button class="btn-text btn-text--danger" type="button" @click="removeSetting(s)">
              删除
            </button>
          </div>
        </div>
      </div>
    </template>

    <!-- 定时任务 -->
    <template v-else-if="tab === 'jobs'">
      <div class="card">
        <p v-if="jobs.length === 0" class="hint">{{ tr('SystemView.c992a4', '没有已登记的任务。') }}</p>
        <div v-for="j in jobs" :key="j.name" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title"><code>{{ j.name }}</code></div>
            <div class="rowitem__sub">{{ j.description }}</div>
            <div class="rowitem__value">{{ tr('SystemView.eec850', '上次执行：') }}{{ fmtTime(j.lastRunAt) }}</div>
          </div>
          <div class="rowitem__actions">
            <button
              class="btn-ghost"
              type="button"
              :disabled="runningJob === j.name"
              @click="runJob(j)"
            >
              {{ runningJob === j.name ? tr('SystemView.running', '执行中…') : tr('SystemView.runNow', '立即执行') }}
            </button>
          </div>
        </div>
      </div>
      <p class="hint">{{ tr('SystemView.685acd', '立即执行会跳过 24 小时的间隔闸门，用于手工触发或演练。') }}</p>
    </template>

    <!-- 密钥管理 -->
    <template v-else-if="tab === 'keys'">
      <div class="bar">
        <p class="bar__hint">{{ tr('SystemView.4ea666', '此处只展示密钥的版本与状态，不存储也不展示任何密钥材料。') }}</p>
        <button class="btn-primary" type="button" :disabled="keyBusy" @click="rotateKey">
          轮换密钥
        </button>
      </div>
      <div class="card">
        <p v-if="keys.length === 0" class="hint">{{ tr('SystemView.6f78c4', '还没有登记任何密钥版本。') }}</p>
        <div v-for="k in keys" :key="k.id" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title">
              <code>{{ k.keyId }}</code> · v{{ k.version }}
              <span :class="(KEY_STATUS[Number(k.status)] ?? KEY_STATUS[1]).cls">
                {{ (KEY_STATUS[Number(k.status)] ?? KEY_STATUS[1]).label }}
              </span>
            </div>
            <div class="rowitem__sub">{{ tr('SystemView.7c49c8', '用途') }} {{ k.purpose }} {{ tr('SystemView.1fdf0d', '·') }} {{ k.note || tr('SystemView.noNote', '无备注') }}</div>
            <div class="rowitem__value">{{ tr('SystemView.f3b01f', '创建于') }} {{ fmtTime(k.createdAt) }}</div>
          </div>
          <div class="rowitem__actions" v-if="Number(k.status) === 1">
            <button class="btn-text" type="button" :disabled="keyBusy" @click="changeKeyStatus(k, 'retire')">
              退役
            </button>
            <button
              class="btn-text btn-text--danger"
              type="button"
              :disabled="keyBusy"
              @click="changeKeyStatus(k, 'revoke')"
            >
              吊销
            </button>
          </div>
        </div>
      </div>
      <p class="hint">
        退役 = 不再用于加密新数据，历史密文仍可解；吊销 = 禁止再被使用。
        已用旧密钥加密的附件不会自动重新包裹，需要独立的重包裹任务。
      </p>
    </template>

    <!-- 备份恢复 -->
    <template v-else-if="tab === 'backup'">
      <div class="bar">
        <p class="bar__hint">{{ tr('SystemView.478ab7', '生成配置快照；行数据请用数据库自带工具（openGauss gs_dump）备份。') }}</p>
        <button class="btn-primary" type="button" :disabled="backupBusy" @click="createBackup">
          生成快照
        </button>
      </div>
      <div class="card">
        <p v-if="backups.length === 0" class="hint">{{ tr('SystemView.366fe0', '暂无备份') }}</p>
        <div v-for="b in backups" :key="b.file" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title"><code>{{ b.file }}</code></div>
            <div class="rowitem__sub">{{ fmtBytes(b.size) }} · {{ fmtTime(b.createdAt) }}</div>
          </div>
          <div class="rowitem__actions">
            <button class="btn-ghost" type="button" :disabled="backupBusy" @click="restoreBackup(b)">
              恢复
            </button>
          </div>
        </div>
      </div>

    <!-- 部署配置：数据库连接 + 邮件服务 -->
    </template>

    <template v-else-if="tab === 'deployment'">
      <div class="card deploy">
        <h2 class="deploy__title">{{ tr('SystemView.dbTitle', '数据库连接') }}</h2>
        <p class="hint">{{ tr('SystemView.dbDesc', '默认与项目部署在同一服务器。指向外部数据库时请先测试连接；保存后需重启服务生效。') }}</p>
        <div class="deploy__grid">
          <label class="field"><span class="field__label">{{ tr('SystemView.dbHost', '连接 IP / 主机') }}</span><input v-model="depDb.host" class="field-control" type="text" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.dbPort', '端口') }}</span><input v-model="depDb.port" class="field-control" type="text" inputmode="numeric" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.dbName', '数据库名') }}</span><input v-model="depDb.name" class="field-control" type="text" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.dbUser', '数据库用户名') }}</span><input v-model="depDb.user" class="field-control" type="text" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.dbPassword', '数据库密码（留空不修改）') }}</span><input v-model="depDb.password" class="field-control" type="password" /></label>
        </div>
        <div class="deploy__actions">
          <button class="btn-primary" type="button" :disabled="depBusy" @click="saveDeploymentDb">{{ tr('SystemView.save', '保存') }}</button>
          <button class="btn-ghost" type="button" :disabled="depBusy" @click="testDeploymentDb">{{ tr('SystemView.testDb', '测试连接') }}</button>
          <button class="btn-text" type="button" :disabled="depBusy" @click="resetDeploymentDb">{{ tr('SystemView.resetDefault', '恢复为环境变量默认') }}</button>
        </div>
      </div>

      <div class="card deploy">
        <h2 class="deploy__title">{{ tr('SystemView.mailTitle', '邮件服务（SMTP）') }}</h2>
        <p class="hint">{{ tr('SystemView.mailDesc', '用于找回口令时发送验证码。启用后由容器内投递服务通过 SMTP 真实发送。') }}</p>
        <label class="deploy__switch">
          <input v-model="depMail.enabled" type="checkbox" />
          <span>{{ tr('SystemView.mailEnable', '启用 SMTP 邮件发送') }}</span>
        </label>
        <div class="deploy__grid">
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpHost', 'SMTP 服务器') }}</span><input v-model="depMail.host" class="field-control" type="text" placeholder="smtp.example.com" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpPort', '端口') }}</span><input v-model="depMail.port" class="field-control" type="text" inputmode="numeric" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpSecure', '加密方式') }}</span>
            <select v-model="depMail.secure" class="field-control"><option value="ssl">SSL / 465</option><option value="starttls">STARTTLS / 587</option></select>
          </label>
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpUser', 'SMTP 账号') }}</span><input v-model="depMail.user" class="field-control" type="text" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpPassword', 'SMTP 密码（留空不修改）') }}</span><input v-model="depMail.password" class="field-control" type="password" /></label>
          <label class="field"><span class="field__label">{{ tr('SystemView.smtpFrom', '发件邮箱') }}</span><input v-model="depMail.fromAddr" class="field-control" type="email" /></label>
        </div>
        <div class="deploy__actions">
          <button class="btn-primary" type="button" :disabled="depBusy" @click="saveDeploymentMail">{{ tr('SystemView.save', '保存') }}</button>
          <button class="btn-ghost" type="button" :disabled="depBusy" @click="testDeploymentMail">{{ tr('SystemView.testMail', '发送测试邮件') }}</button>
        </div>
      </div>
    </template>

    <!-- 存储平台（Q2 方案 A） -->
    <template v-else-if="tab === 'storage'">
      <div class="card deploy">
        <h2 class="deploy__title">{{ tr('SystemView.storageTitle', '存储平台配置') }}</h2>
        <p class="hint">{{ tr('SystemView.storageDesc', '选择附件存储后端。配置写入 deployment.env，保存后需重启服务生效；凭据仅脱敏回显。') }}</p>

        <p v-if="storageRestart" class="storage-note storage-note--warn">
          {{ tr('SystemView.storageRestart', '配置已写入，需重启后端实例后生效。') }}
        </p>

        <div class="storage-meta">
          <span>{{ tr('SystemView.storageCurrent', '当前生效平台') }}：<code>{{ storageCurrent }}</code></span>
          <span :class="storageTransportReady ? 'st st--ok' : 'st st--warn'">
            {{ storageTransportReady ? tr('SystemView.storageTransportReady', '传输层已就绪') : tr('SystemView.storageTransportNotReady', '传输层未就绪') }}
          </span>
        </div>

        <p v-if="locatorLocked" class="storage-note storage-note--lock">
          {{ tr('SystemView.storageLocked').replace('{n}', String(attachmentCount)) }}
        </p>

        <div class="deploy__grid">
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageProvider', '存储平台') }}</span>
            <select v-model="storageForm.provider" class="field-control" :disabled="locatorLocked">
              <option v-for="p in storageProviders" :key="p.code" :value="p.code">{{ p.name }}</option>
            </select>
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageEndpoint', 'Endpoint') }}</span>
            <input v-model="storageForm.endpoint" class="field-control" type="text" :disabled="locatorLocked" />
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageBucket', 'Bucket') }}</span>
            <input v-model="storageForm.bucket" class="field-control" type="text" :disabled="locatorLocked" />
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageRegion', 'Region') }}</span>
            <input v-model="storageForm.region" class="field-control" type="text" />
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageAccessKey', 'Access Key') }}</span>
            <input v-model="storageForm.accessKey" class="field-control" type="password" autocomplete="off" :placeholder="storageMask.accessKey || tr('SystemView.storageNotSet', '未设置')" />
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storageSecretKey', 'Secret Key') }}</span>
            <input v-model="storageForm.secretKey" class="field-control" type="password" autocomplete="off" :placeholder="storageMask.secretKey || tr('SystemView.storageNotSet', '未设置')" />
          </label>
          <label class="field">
            <span class="field__label">{{ tr('SystemView.storagePathStyle', '寻址风格') }}</span>
            <select v-model="storageForm.pathStyle" class="field-control">
              <option :value="true">{{ tr('SystemView.storagePathStyleOn', 'Path-style') }}</option>
              <option :value="false">{{ tr('SystemView.storagePathStyleOff', 'Virtual-host') }}</option>
            </select>
          </label>
        </div>

        <p class="hint">{{ tr('SystemView.storageCredentialHint', '凭据脱敏回显，留空表示本次不重写（回退环境变量注入）。') }}</p>

        <div v-if="selectedProvider" class="storage-provider-hint">
          <div class="deploy__title">{{ tr('SystemView.storageHintTitle', '平台配置提示') }}</div>
          <div class="hint">Endpoint 模板：<code>{{ selectedProvider.endpointTemplate || '—' }}</code></div>
          <div class="hint">Region 建议：<code>{{ selectedProvider.regionHint || '—' }}</code> · 签名：<code>{{ selectedProvider.signature }}</code></div>
          <div class="hint">桶命名：{{ selectedProvider.bucketRule }}</div>
          <div class="hint">{{ selectedProvider.notes }}</div>
        </div>

        <div class="deploy__actions">
          <button class="btn-primary" type="button" :disabled="storageBusy" @click="saveStorage">{{ tr('SystemView.storageSave', '保存') }}</button>
        </div>
      </div>
    </template>
  </section>

  <!-- 配置项编辑浮层（放在 v-if/v-else-if 链之外：
       v-else-if 必须紧邻上一个分支，中间夹其它元素会让整条链失效） -->
  <AppSheet
    v-model="showSetting"
    :title="settingMode === 'create' ? tr('SystemView.227e8e.new', '新增配置') : tr('SystemView.227e8e.edit', '编辑配置')"
    size="sm"
    :dismissible="!savingSetting"
  >
    <div class="form">
      <label v-if="settingMode === 'create'" class="field">
        <span class="field__label">{{ tr('SystemView.f0b357', '键名') }} <em>*</em></span>
        <input v-model="settingForm.key" class="field-control" :placeholder="tr('SystemView.140598', '如 archive.retention_days')" />
      </label>
      <label class="field">
        <span class="field__label">{{ tr('SystemView.321b95', '值') }}</span>
        <input v-model="settingForm.value" class="field-control" />
      </label>
      <label class="field">
        <span class="field__label">{{ tr('SystemView.e4e46c', '类型') }}</span>
        <select v-model="settingForm.valueType" class="field-control">
          <option value="string">string</option>
          <option value="int">int</option>
          <option value="bool">bool</option>
          <option value="json">json</option>
        </select>
      </label>
      <label class="field">
        <span class="field__label">{{ tr('SystemView.26670d', '说明') }}</span>
        <input v-model="settingForm.description" class="field-control" />
      </label>
    </div>
    <p class="hint">{{ tr('SystemView.7d17b0', '敏感配置的值不会展示，编辑时留空表示不修改。') }}</p>
    <div class="sheet-actions">
      <button class="btn-ghost" type="button" :disabled="savingSetting" @click="showSetting = false">
        取消
      </button>
      <button class="btn-primary" type="button" :disabled="savingSetting" @click="saveSetting">
        {{ savingSetting ? tr('SystemView.saving', '保存中…') : tr('SystemView.save', '保存') }}
      </button>
    </div>
  </AppSheet>
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

/* 分段控件 */
.tabs {
  display: flex;
  gap: var(--sp-1);
  padding: var(--sp-1);
  background: var(--bg-hover);
  border-radius: var(--g3-sm, 12px);
  margin-bottom: var(--sp-4);
  overflow-x: auto;
}
.tab {
  flex: 1 0 auto;
  padding: 8px 14px;
  border: none;
  background: transparent;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  border-radius: calc(var(--g3-sm, 12px) - 4px);
  cursor: pointer;
  white-space: nowrap;
  transition:
    background var(--spring-fast) var(--ease-apple),
    color var(--spring-fast) var(--ease-apple);
}
.tab--on {
  background: var(--bg-surface);
  color: var(--text-primary);
  box-shadow: var(--shadow-sm);
}

/* 指标卡 */
.metrics {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
  gap: var(--sp-3);
}
.metric__label {
  font-size: var(--font-size-sm);
  color: var(--text-muted);
}
.metric__value {
  font-size: 24px;
  font-weight: 600;
  margin-top: var(--sp-1);
}
.metric__value--bad {
  color: var(--danger);
}
.metric__sub {
  font-size: 12px;
  color: var(--text-muted);
  margin-top: 2px;
}

.rows__row {
  display: flex;
  justify-content: space-between;
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border-subtle);
  font-size: var(--font-size-md);
}
.rows__row:last-child {
  border-bottom: none;
}
.rows__n {
  color: var(--text-secondary);
}

/* 操作条 */
.bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  margin-bottom: var(--sp-3);
  flex-wrap: wrap;
}
.bar__hint {
  margin: 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

/* 行列表 */
.rowitem {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-3) 0;
  border-bottom: 1px solid var(--border-subtle);
}
.rowitem:last-child {
  border-bottom: none;
}
.rowitem__title {
  font-weight: 600;
  font-size: var(--font-size-md);
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}
.rowitem__sub {
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  margin-top: 2px;
}
.rowitem__value {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin-top: 2px;
  word-break: break-all;
}
.rowitem__actions {
  display: flex;
  gap: var(--sp-1);
  flex-shrink: 0;
}

.st {
  font-size: 12px;
  padding: 1px 6px;
  border-radius: var(--g3-sm, 12px);
  border: 1px solid currentColor;
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
.field__label em {
  color: var(--danger);
  font-style: normal;
}
.sheet-actions {
  display: flex;
  gap: var(--sp-2);
  justify-content: flex-end;
  margin-top: var(--sp-5);
}

@media (max-width: 639px) {
  .rowitem {
    flex-direction: column;
  }
  .rowitem__actions {
    align-self: flex-end;
  }
}

/* 部署配置面板 */
.deploy { margin-bottom: var(--sp-4); }
.deploy__title { font-size: var(--font-size-lg); font-weight: 600; margin: 0 0 var(--sp-2); }
.deploy__grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--sp-3);
  margin-top: var(--sp-4);
}
.deploy__actions {
  display: flex; align-items: center; flex-wrap: wrap; gap: var(--sp-2);
  margin-top: var(--sp-5);
}
.deploy__switch {
  display: inline-flex; align-items: center; gap: var(--sp-2);
  margin-top: var(--sp-3); font-size: var(--font-size-sm); color: var(--text-secondary); cursor: pointer;
}
.deploy__switch input { width: 18px; height: 18px; accent-color: var(--accent); }
@media (max-width: 639px) { .deploy__grid { grid-template-columns: 1fr; } }

/* 存储平台面板（与部署配置共用白卡 / 胶囊按钮 / 单一强调蓝，零投影） */
.storage-note {
  margin: var(--sp-3) 0 0;
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--g3-sm, 12px);
  font-size: var(--font-size-sm);
  line-height: 1.5;
}
.storage-note--warn {
  background: var(--bg-hover);
  color: var(--text-secondary);
}
.storage-note--lock {
  border: 1px solid var(--danger);
  color: var(--danger);
}
.storage-meta {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex-wrap: wrap;
  margin-top: var(--sp-3);
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}
.storage-provider-hint {
  margin-top: var(--sp-3);
  padding: var(--sp-3);
  background: var(--bg-hover);
  border-radius: var(--g3-sm, 12px);
  display: grid;
  gap: 4px;
}
</style>
