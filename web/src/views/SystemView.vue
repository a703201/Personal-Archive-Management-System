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
import { api } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import { useToast } from '../composables/useToast'

const toast = useToast()

type TabKey = 'health' | 'config' | 'jobs' | 'keys' | 'backup'

const TABS: { key: TabKey; label: string }[] = [
  { key: 'health', label: '健康看板' },
  { key: 'config', label: '配置中心' },
  { key: 'jobs', label: '定时任务' },
  { key: 'keys', label: '密钥管理' },
  { key: 'backup', label: '备份恢复' },
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
  const s = Math.floor(Number(ms ?? 0) / 1000)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return h > 0 ? `${h} 小时 ${m} 分` : `${m} 分 ${s % 60} 秒`
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
    toast.warning('请填写配置键名')
    return
  }
  if (settingMode.value === 'edit' && !f.value) {
    toast.warning('敏感项留空表示不修改，请先输入新值')
    return
  }
  savingSetting.value = true
  try {
    await api('/admin/config', { method: 'PUT', body: { ...f, key: f.key.trim() } })
    toast.success('配置已保存')
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
    toast.success(`已删除 ${s.key}`)
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
    toast.success(`${j.name} 执行完成，影响 ${res.affected} 条`)
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
  1: { label: '启用中', cls: 'st st--ok' },
  2: { label: '已退役', cls: 'st st--warn' },
  3: { label: '已吊销', cls: 'st st--bad' },
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
      body: { keyId: 'ams-data', purpose: 'data', note: '管理界面手动轮换' },
    })
    toast.success(`已登记新版本 v${res.version}`)
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
    toast.success(kind === 'retire' ? '已退役' : '已吊销')
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
    toast.success('配置快照已生成')
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
    toast.success(`已恢复 ${res.restored} 项配置`)
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
    /* 忽略：配置面板单独提示 */
  }
  try {
    await loadJobs()
  } catch {
    /* 忽略 */
  }
  try {
    await loadKeys()
  } catch {
    /* 忽略 */
  }
  try {
    await loadBackups()
  } catch {
    /* 忽略 */
  }
  loading.value = false
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
    <h1 class="page-title">系统运维</h1>

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

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <!-- 健康看板 -->
    <template v-else-if="tab === 'health' && health">
      <div class="metrics">
        <div class="card metric">
          <div class="metric__label">运行时长</div>
          <div class="metric__value">{{ fmtUptime(health.uptimeMs) }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">请求数</div>
          <div class="metric__value">{{ health.requests }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">服务端错误率</div>
          <div class="metric__value" :class="{ 'metric__value--bad': Number(health.errorRatePermille) >= 10 }">
            {{ errorRateText }}
          </div>
          <div class="metric__sub">4xx {{ health.error4xx }} · 5xx {{ health.error5xx }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">在线会话</div>
          <div class="metric__value">{{ health.onlineSessions }}</div>
        </div>
        <div class="card metric">
          <div class="metric__label">数据库延迟</div>
          <div class="metric__value">{{ health.dbLatencyMs }} ms</div>
          <div class="metric__sub">SELECT 1 往返</div>
        </div>
        <div class="card metric">
          <div class="metric__label">附件存储</div>
          <div class="metric__value">{{ fmtBytes(health.storageBytes) }}</div>
          <div class="metric__sub">{{ health.storageFiles }} 个文件</div>
        </div>
      </div>

      <h2 class="section-title">数据表行数</h2>
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
        <p class="bar__hint">敏感配置项的值以 *** 展示，编辑时需重新输入；留空表示不修改。</p>
        <button class="btn-primary" type="button" @click="openSettingCreate">新增配置</button>
      </div>
      <div class="card">
        <p v-if="settings.length === 0" class="hint">还没有配置项。</p>
        <div v-for="s in settings" :key="s.key" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title">
              <code>{{ s.key }}</code>
              <span v-if="s.isSecret === true || s.isSecret === 't'" class="st st--warn">敏感</span>
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
        <p v-if="jobs.length === 0" class="hint">没有已登记的任务。</p>
        <div v-for="j in jobs" :key="j.name" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title"><code>{{ j.name }}</code></div>
            <div class="rowitem__sub">{{ j.description }}</div>
            <div class="rowitem__value">上次执行：{{ fmtTime(j.lastRunAt) }}</div>
          </div>
          <div class="rowitem__actions">
            <button
              class="btn-ghost"
              type="button"
              :disabled="runningJob === j.name"
              @click="runJob(j)"
            >
              {{ runningJob === j.name ? '执行中…' : '立即执行' }}
            </button>
          </div>
        </div>
      </div>
      <p class="hint">立即执行会跳过 24 小时的间隔闸门，用于手工触发或演练。</p>
    </template>

    <!-- 密钥管理 -->
    <template v-else-if="tab === 'keys'">
      <div class="bar">
        <p class="bar__hint">此处只展示密钥的**版本与状态**，不存储也不展示任何密钥材料。</p>
        <button class="btn-primary" type="button" :disabled="keyBusy" @click="rotateKey">
          轮换密钥
        </button>
      </div>
      <div class="card">
        <p v-if="keys.length === 0" class="hint">还没有登记任何密钥版本。</p>
        <div v-for="k in keys" :key="k.id" class="rowitem">
          <div class="rowitem__main">
            <div class="rowitem__title">
              <code>{{ k.keyId }}</code> · v{{ k.version }}
              <span :class="(KEY_STATUS[Number(k.status)] ?? KEY_STATUS[1]).cls">
                {{ (KEY_STATUS[Number(k.status)] ?? KEY_STATUS[1]).label }}
              </span>
            </div>
            <div class="rowitem__sub">用途 {{ k.purpose }} · {{ k.note || '无备注' }}</div>
            <div class="rowitem__value">创建于 {{ fmtTime(k.createdAt) }}</div>
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
        <p class="bar__hint">生成配置快照；行数据请用数据库自带工具（openGauss gs_dump）备份。</p>
        <button class="btn-primary" type="button" :disabled="backupBusy" @click="createBackup">
          生成快照
        </button>
      </div>
      <div class="card">
        <p v-if="backups.length === 0" class="hint">还没有备份。</p>
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
    </template>
  </section>

  <!-- 配置项编辑浮层（放在 v-if/v-else-if 链之外：
       v-else-if 必须紧邻上一个分支，中间夹其它元素会让整条链失效） -->
  <AppSheet
    v-model="showSetting"
    :title="settingMode === 'create' ? '新增配置' : '编辑配置'"
    size="sm"
    :dismissible="!savingSetting"
  >
    <div class="form">
      <label v-if="settingMode === 'create'" class="field">
        <span class="field__label">键名 <em>*</em></span>
        <input v-model="settingForm.key" class="field-control" placeholder="如 archive.retention_days" />
      </label>
      <label class="field">
        <span class="field__label">值</span>
        <input v-model="settingForm.value" class="field-control" />
      </label>
      <label class="field">
        <span class="field__label">类型</span>
        <select v-model="settingForm.valueType" class="field-control">
          <option value="string">string</option>
          <option value="int">int</option>
          <option value="bool">bool</option>
          <option value="json">json</option>
        </select>
      </label>
      <label class="field">
        <span class="field__label">说明</span>
        <input v-model="settingForm.description" class="field-control" />
      </label>
    </div>
    <p class="hint">敏感配置的值不会展示，编辑时留空表示不修改。</p>
    <div class="sheet-actions">
      <button class="btn-ghost" type="button" :disabled="savingSetting" @click="showSetting = false">
        取消
      </button>
      <button class="btn-primary" type="button" :disabled="savingSetting" @click="saveSetting">
        {{ savingSetting ? '保存中…' : '保存' }}
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
  corner-style: continuous;
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
  corner-style: continuous;
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
  font-size: 11px;
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
</style>