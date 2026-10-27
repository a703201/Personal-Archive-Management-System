<script setup lang="ts">
/**
 * 审计日志（FR-AUD-003 / FR-AUD-004）。
 *
 * 接口（权限 audit:read）：
 *   GET /api/audit                  多维查询（actorId/subjectId/category/action/result/from/to/clientIp/page/size）
 *   GET /api/audit/verify-chain     区块链完整性校验
 *
 * result 字段：0=成功，非 0=失败（后端约定）。链校验返回 ok/broken/tampered/missing。
 */
import { ref, onMounted, computed } from 'vue'
import { api } from '../api/client'
import { useToast } from '../composables/useToast'

const { success, error: toastError } = useToast()

interface AuditRow {
  chainSeq: number | string
  actorId: string
  action: string
  actionDesc: string
  targetType: string
  targetId: string
  subjectId: string
  category: number | string
  result: number | string
  errorCode: string
  clientIp: string
  traceId: string
  occurredAt: number | string
}

const rows = ref<AuditRow[]>([])
const total = ref(0)
const page = ref(1)
const size = ref(20)
const loading = ref(false)
const error = ref('')

const filters = ref({ actorId: '', action: '', clientIp: '', result: '' as string })

const chainStatus = ref<{ ok: boolean; message: string } | null>(null)
const verifying = ref(false)

const totalPages = computed(() => Math.max(1, Math.ceil(total.value / size.value)))

function fmtTime(ms: number | string): string {
  const n = Number(ms)
  if (!n) return '—'
  const d = new Date(n)
  const pad = (n2: number) => String(n2).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}
const resultText = (r: number | string) => (Number(r) === 0 ? '成功' : '失败')

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  chainStatus.value = null
  const qs = new URLSearchParams()
  qs.set('page', String(page.value))
  qs.set('size', String(size.value))
  if (filters.value.actorId) qs.set('actorId', filters.value.actorId)
  if (filters.value.action) qs.set('action', filters.value.action)
  if (filters.value.clientIp) qs.set('clientIp', filters.value.clientIp)
  if (filters.value.result !== '') qs.set('result', filters.value.result)
  try {
    const data = await api<{ items: AuditRow[]; total: number | string }>(`/audit?${qs.toString()}`)
    rows.value = data.items ?? []
    total.value = Number(data.total) || 0
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

function search(): void {
  page.value = 1
  load()
}
function reset(): void {
  filters.value = { actorId: '', action: '', clientIp: '', result: '' }
  page.value = 1
  load()
}
function changePage(delta: number): void {
  const next = page.value + delta
  if (next < 1 || next > totalPages.value) return
  page.value = next
  load()
}

async function verifyChain(): Promise<void> {
  verifying.value = true
  try {
    const data = await api<{ status: string; message: string }>('/audit/verify-chain?from=1&limit=1000')
    chainStatus.value = { ok: data.status === 'ok', message: data.message }
    if (data.status === 'ok') success('审计链完整，未被篡改')
    else toastError(`链校验异常：${data.message}`)
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    verifying.value = false
  }
}

onMounted(load)
</script>

<template>
  <section>
    <div class="page-head">
      <h1 class="page-title">审计日志</h1>
      <button class="btn-ghost" type="button" :disabled="verifying" @click="verifyChain">
        {{ verifying ? '校验中…' : '校验审计链' }}
      </button>
    </div>

    <div v-if="chainStatus" class="chain" :class="chainStatus.ok ? 'chain--ok' : 'chain--bad'">
      <span class="chain__icon">{{ chainStatus.ok ? '✓' : '!' }}</span>
      <span>{{ chainStatus.message }}</span>
    </div>

    <div class="filters card">
      <input v-model="filters.actorId" class="field-control" type="text" placeholder="操作者 ID" />
      <input v-model="filters.action" class="field-control" type="text" placeholder="操作（如 login）" />
      <input v-model="filters.clientIp" class="field-control" type="text" placeholder="客户端 IP" />
      <select v-model="filters.result" class="field-control">
        <option value="">全部结果</option>
        <option value="0">成功</option>
        <option value="1">失败</option>
      </select>
      <div class="filters__btns">
        <button class="btn-primary" type="button" @click="search">查询</button>
        <button class="btn-ghost" type="button" @click="reset">重置</button>
      </div>
    </div>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <div v-else class="card table-card">
      <table class="tbl">
        <thead>
          <tr>
            <th>链序号</th>
            <th>时间</th>
            <th>操作</th>
            <th>描述</th>
            <th>目标</th>
            <th>操作者</th>
            <th>结果</th>
            <th>IP</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="a in rows" :key="a.chainSeq">
            <td class="u-sub">#{{ a.chainSeq }}</td>
            <td class="u-sub">{{ fmtTime(a.occurredAt) }}</td>
            <td><code class="mono">{{ a.action }}</code></td>
            <td>{{ a.actionDesc || '—' }}</td>
            <td class="u-sub">
              <span v-if="a.targetType">{{ a.targetType }}:{{ a.targetId }}</span>
              <span v-else>—</span>
            </td>
            <td class="u-sub">{{ a.actorId }}</td>
            <td>
              <span class="badge" :class="Number(a.result) === 0 ? 'badge--ok' : 'badge--off'">
                {{ resultText(a.result) }}
              </span>
            </td>
            <td class="u-sub">{{ a.clientIp || '—' }}</td>
          </tr>
          <tr v-if="rows.length === 0">
            <td colspan="8" class="empty">暂无审计记录</td>
          </tr>
        </tbody>
      </table>

      <div class="pager">
        <button class="btn-ghost" type="button" :disabled="page <= 1" @click="changePage(-1)">上一页</button>
        <span class="pager__info">第 {{ page }} / {{ totalPages }} 页 · 共 {{ total }} 条</span>
        <button class="btn-ghost" type="button" :disabled="page >= totalPages" @click="changePage(1)">下一页</button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  flex-wrap: wrap;
}
.page-title {
  font-size: var(--font-size-xl);
  margin: 0;
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}
.u-sub {
  color: var(--text-muted);
  font-size: 12px;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}

.chain {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  margin: var(--sp-4) 0 0;
  padding: var(--sp-3) var(--sp-4);
  border-radius: var(--g3-md);
  font-size: var(--font-size-sm);
}
.chain--ok {
  background: color-mix(in srgb, var(--success) 14%, transparent);
  color: var(--success);
}
.chain--bad {
  background: color-mix(in srgb, var(--danger) 14%, transparent);
  color: var(--danger);
}
.chain__icon {
  width: 20px;
  height: 20px;
  border-radius: var(--g3-pill);
  background: currentColor;
  color: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
}

.filters {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
  margin: var(--sp-4) 0;
}
.filters .field-control {
  width: auto;
  flex: 1 1 160px;
  min-width: 140px;
}
.filters__btns {
  display: flex;
  gap: var(--sp-2);
}

.table-card {
  padding: 0;
  overflow: hidden;
}
.tbl {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--font-size-sm);
}
.tbl th,
.tbl td {
  text-align: left;
  padding: var(--sp-3) var(--sp-4);
  border-bottom: 1px solid var(--border-subtle);
  vertical-align: middle;
}
.tbl th {
  color: var(--text-secondary);
  font-weight: 600;
  position: sticky;
  top: 0;
  background: var(--bg-surface);
}
.tbl tbody tr:hover {
  background: var(--bg-hover);
}
.empty {
  text-align: center;
  color: var(--text-muted);
  padding: var(--sp-5);
}

.badge--ok {
  background: var(--success);
  color: #fff;
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}
.badge--off {
  background: var(--danger);
  color: #fff;
  display: inline-block;
  padding: 2px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 12px;
}

.pager {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
}
.pager__info {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

@media (max-width: 639px) {
  .tbl thead {
    display: none;
  }
  .tbl,
  .tbl tbody,
  .tbl tr,
  .tbl td {
    display: block;
    width: 100%;
  }
  .tbl tr {
    border-bottom: 1px solid var(--border-subtle);
    padding: var(--sp-2) 0;
  }
  .tbl td {
    border: none;
    padding: 4px var(--sp-4);
  }
}
</style>
