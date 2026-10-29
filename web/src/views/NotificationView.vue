<script setup lang="ts">
/**
 * 通知中心（FR-NTF-001~005 的前端入口）。
 *
 * 接口（权限 notify:read:own，仅能读自己名下的通知）：
 *   GET    /api/notifications           列表（page/size/unread=true|false）
 *   GET    /api/notifications/unread    未读数量
 *   POST   /api/notifications/:id/read  标记单条已读
 *   POST   /api/notifications/read-all  全部已读
 *
 * 后端 rowToJson 把所有列序列化为字符串（id/is_read/created_at_ms 等），
 * 故以下字段按实际类型声明为 string | number，使用处用 Number() 归一化；
 * 布尔 is_read 序列化为 "t"/"f" 字符串，需按值判断。
 */
import { ref, onMounted } from 'vue'
import { api } from '../api/client'
import { useToast } from '../composables/useToast'

const toast = useToast()

interface Notification {
  id: string | number
  user_id: string | number
  category: string | number
  title: string
  body: string
  link: string | null
  priority: string | number
  is_read: string | boolean
  created_at_ms: string | number
}

const items = ref<Notification[]>([])
const total = ref(0)
const page = ref(1)
const size = ref(15)
const onlyUnread = ref(false)
const loading = ref(false)
const error = ref('')
const markingAll = ref(false)
const markingId = ref<string | number>('')

const totalPages = () => Math.max(1, Math.ceil(total.value / size.value))

/** 类别标签（后端当前默认 category=0，预留扩展） */
const CATEGORY_LABELS: Record<number, string> = {
  0: '通知',
  1: '提醒',
  2: '安全预警',
  3: '系统',
}
function categoryLabel(v: string | number): string {
  return CATEGORY_LABELS[Number(v)] ?? '通知'
}

function isUnread(n: Notification): boolean {
  return !(n.is_read === true || n.is_read === 't' || n.is_read === 'true')
}

function isImportant(n: Notification): boolean {
  return Number(n.priority) >= 2
}

function fmtTime(ms: string | number): string {
  const n = Number(ms)
  if (!n) return '—'
  const d = new Date(n)
  const pad = (x: number) => String(x).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  const qs = new URLSearchParams({
    page: String(page.value),
    size: String(size.value),
  })
  if (onlyUnread.value) qs.set('unread', 'true')
  try {
    const data = await api<{ items: Notification[]; total: number | string }>(
      `/notifications?${qs.toString()}`,
    )
    items.value = data.items ?? []
    total.value = Number(data.total) || 0
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

function changeFilter(): void {
  page.value = 1
  load()
}

function changePage(delta: number): void {
  const next = page.value + delta
  if (next < 1 || next > totalPages()) return
  page.value = next
  load()
}

async function markRead(n: Notification): Promise<void> {
  markingId.value = n.id
  try {
    await api(`/notifications/${n.id}/read`, { method: 'POST', body: {} })
    // 乐观更新：避免整列刷新打断阅读
    items.value = items.value.map((x) =>
      x.id === n.id ? { ...x, is_read: 't' } : x,
    )
    toast.success('已标记为已读')
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    markingId.value = ''
  }
}

async function markAllRead(): Promise<void> {
  markingAll.value = true
  try {
    await api('/notifications/read-all', { method: 'POST', body: {} })
    items.value = items.value.map((x) => ({ ...x, is_read: 't' }))
    toast.success('已将全部通知标为已读')
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    markingAll.value = false
  }
}

onMounted(load)
</script>

<template>
  <section>
    <div class="page-head">
      <h1 class="page-title">通知中心</h1>
      <button
        class="btn-ghost"
        type="button"
        :disabled="markingAll || items.length === 0"
        @click="markAllRead"
      >
        {{ markingAll ? '处理中…' : '全部已读' }}
      </button>
    </div>

    <div class="toolbar">
      <label class="switch">
        <input v-model="onlyUnread" type="checkbox" @change="changeFilter" />
        <span>仅看未读</span>
      </label>
      <span class="count">共 {{ total }} 条</span>
    </div>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <div v-else-if="items.length === 0" class="card empty">
      <div class="empty__title">暂无通知</div>
      <p class="empty__sub">档案到期提醒、安全预警等都会出现在这里。</p>
    </div>

    <div v-else class="list">
      <article
        v-for="n in items"
        :key="n.id"
        class="card note"
        :class="{ 'note--unread': isUnread(n) }"
      >
        <div class="note__dot" v-if="isUnread(n)" aria-hidden="true" />
        <div class="note__body">
          <div class="note__head">
            <span class="badge badge--cat">{{ categoryLabel(n.category) }}</span>
            <span v-if="isImportant(n)" class="tag-imp">重要</span>
            <span class="note__title">{{ n.title }}</span>
          </div>
          <p class="note__text">{{ n.body }}</p>
          <div class="note__foot">
            <span class="note__time">{{ fmtTime(n.created_at_ms) }}</span>
            <a v-if="n.link" class="btn-text" :href="n.link">查看</a>
          </div>
        </div>
        <div class="note__actions" v-if="isUnread(n)">
          <button
            class="btn-text"
            type="button"
            :disabled="markingId === n.id"
            @click="markRead(n)"
          >
            {{ markingId === n.id ? '处理中…' : '标为已读' }}
          </button>
        </div>
      </article>
    </div>

    <div v-if="!loading && total > size" class="pager">
      <button class="btn-ghost" type="button" :disabled="page <= 1" @click="changePage(-1)">
        上一页
      </button>
      <span class="pager__info">第 {{ page }} / {{ totalPages() }} 页</span>
      <button
        class="btn-ghost"
        type="button"
        :disabled="page >= totalPages()"
        @click="changePage(1)"
      >
        下一页
      </button>
    </div>
  </section>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  margin-bottom: var(--sp-4);
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

.toolbar {
  display: flex;
  align-items: center;
  gap: var(--sp-4);
  margin-bottom: var(--sp-4);
}
.switch {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  cursor: pointer;
}
.switch input {
  accent-color: var(--accent);
}
.count {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

.list {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.note {
  display: flex;
  align-items: flex-start;
  gap: var(--sp-3);
  padding: var(--sp-4);
  position: relative;
  transition: box-shadow var(--spring-fast) var(--ease-apple);
}
.note--unread {
  border-color: var(--accent);
  background: var(--accent-soft);
}
.note__dot {
  flex-shrink: 0;
  width: 8px;
  height: 8px;
  margin-top: 7px;
  border-radius: 50%;
  background: var(--accent);
}
.note__body {
  flex: 1;
  min-width: 0;
}
.note__head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--sp-2);
  margin-bottom: var(--sp-1);
}
.note__title {
  font-weight: 600;
  font-size: var(--font-size-md);
}
.badge--cat {
  background: var(--bg-hover);
  color: var(--text-secondary);
  display: inline-block;
  padding: 1px var(--sp-2);
  border-radius: var(--g3-pill);
  font-size: 11px;
}
.tag-imp {
  background: color-mix(in srgb, var(--warning) 16%, transparent);
  color: var(--warning);
  font-size: 11px;
  padding: 1px 6px;
  border-radius: var(--g3-pill);
}
.note__text {
  margin: 0;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  line-height: 1.5;
  word-break: break-word;
}
.note__foot {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  margin-top: var(--sp-2);
}
.note__time {
  color: var(--text-muted);
  font-size: 12px;
}
.note__actions {
  flex-shrink: 0;
}

.empty {
  text-align: center;
  padding: var(--sp-6) var(--sp-4);
}
.empty__title {
  font-weight: 600;
  margin-bottom: var(--sp-1);
}
.empty__sub {
  margin: 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

.pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--sp-3);
  margin-top: var(--sp-4);
}
.pager__info {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

.btn-text {
  border: none;
  background: transparent;
  color: var(--accent);
  font-size: var(--font-size-sm);
  font-weight: 500;
  cursor: pointer;
}

@media (max-width: 639px) {
  .note {
    flex-direction: column;
  }
  .note__actions {
    align-self: flex-end;
  }
}
</style>
