<script setup lang="ts">
/**
 * 全局搜索入口（FR-UX-005）。
 *
 * - Cmd/Ctrl + K 唤起；Esc 关闭；点击遮罩关闭
 * - 输入防抖 250ms 后请求 /api/search
 * - 结果只展示后端**已掩码**的字段：敏感字段明文需要走展开接口并留痕，
 *   前端不持有、也不缓存任何明文（FR-SRC-006）
 */
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import { t } from '../i18n'
import { api } from '../api/client'

interface SearchItem {
  id: number
  category: number
  title: string
  status: number
  sensitivity: number
  issuer: string
  issuedDate: string
  expiresDate: string
  attachmentCount: number
  updatedAt: number
}

interface SearchData {
  items: SearchItem[]
  hasMore: boolean
  size: number
  nextCursor: string
}

const open = ref(false)
const keyword = ref('')
const items = ref<SearchItem[]>([])
const hasMore = ref(false)
const loading = ref(false)
const error = ref('')
let timer: number | undefined
let controller: AbortController | undefined

const SENS_LABEL: Record<number, string> = { 1: t('componentsGlobalSearch.7cda07', '普通'), 2: t('componentsGlobalSearch.e4d1f0', '敏感'), 3: t('componentsGlobalSearch.4bdda7', '高敏') }
const SENS_CLASS: Record<number, string> = {
  1: 'badge badge--normal',
  2: 'badge badge--sensitive',
  3: 'badge badge--high',
}

async function runSearch(): Promise<void> {
  controller?.abort()
  controller = new AbortController()
  loading.value = true
  error.value = ''
  try {
    const q = new URLSearchParams({ keyword: keyword.value, size: '20' })
    const data = await api<SearchData>(`/search?${q.toString()}`, {
      signal: controller.signal,
    })
    items.value = data.items
    hasMore.value = data.hasMore
  } catch (e) {
    if ((e as Error).name !== 'AbortError') {
      error.value = (e as Error).message
      items.value = []
    }
  } finally {
    loading.value = false
  }
}

function onInput(): void {
  window.clearTimeout(timer)
  timer = window.setTimeout(runSearch, 250)
}

function show(): void {
  open.value = true
  if (keyword.value) runSearch()
}

function hide(): void {
  open.value = false
  controller?.abort()
}

function onKeydown(e: KeyboardEvent): void {
  // Cmd+K (macOS) / Ctrl+K (Windows/Linux)
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault()
    open.value ? hide() : show()
  } else if (e.key === 'Escape' && open.value) {
    hide()
  }
}

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown)
  window.clearTimeout(timer)
  controller?.abort()
})

watch(open, (v) => {
  if (v) {
    // 打开后聚焦输入框
    requestAnimationFrame(() => {
      const el = document.getElementById('global-search-input')
      el?.focus()
    })
  }
})
</script>

<template>
  <!-- 触发按钮：同时提示快捷键 -->
  <button class="search-trigger" type="button" @click="show" :aria-label="t('GlobalSearch.0d8465', '搜索档案…')">
    <svg class="search-trigger__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true">
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.6-3.6" />
    </svg>
    <span>{{ t('GlobalSearch.0d8465', '搜索档案…') }}</span>
    <kbd>⌘K</kbd>
  </button>

  <!--
    ⚠️ 遮罩必须传送到 body：
    历史 bug —— .topbar 曾设 backdrop-filter，会为后代 position:fixed 建立包含块，
    导致 .mask 的 inset:0 只覆盖顶栏、搜索面板错位。顶栏现已改为不透明实底，
    但 Teleport 仍保留：任何祖先将来带 transform/filter/backdrop-filter/contain
    都会重演该问题，传送到 body 是唯一稳定的保证。
  -->
  <Teleport to="body">
    <div v-if="open" class="mask" @click.self="hide">
      <div class="dialog" role="dialog" aria-modal="true" :aria-label="t('GlobalSearch.a38e3c', '全局搜索')">
        <div class="dialog__head">
          <input
            id="global-search-input"
            v-model="keyword"
            class="dialog__input"
            type="search"
            :placeholder="t('GlobalSearch.e80e90', '输入关键词搜索标题、机构、字段内容…')"
            @input="onInput"
          />
          <button class="dialog__close" type="button" :aria-label="t('GlobalSearch.6c14bd', '关闭')" @click="hide">✕</button>
        </div>

        <div class="dialog__body">
          <p v-if="loading" class="hint">{{ t('GlobalSearch.8a88cd', '搜索中…') }}</p>
          <p v-else-if="error" class="hint hint--error">{{ error }}</p>
          <p v-else-if="items.length === 0 && keyword" class="hint">{{ t('GlobalSearch.acc634', '没有匹配的档案') }}</p>
          <p v-else-if="items.length === 0" class="hint">{{ t('GlobalSearch.ea13f4', '输入关键词开始搜索') }}</p>

          <ul v-else class="results">
            <li v-for="it in items" :key="it.id" class="result">
              <div class="result__title">{{ it.title }}</div>
              <div class="result__meta">
                <span :class="SENS_CLASS[it.sensitivity]">{{ SENS_LABEL[it.sensitivity] }}</span>
                <span v-if="it.issuer">· {{ it.issuer }}</span>
                <span v-if="it.expiresDate">{{ t('GlobalSearch.fe3baf', '· 到期') }} {{ it.expiresDate }}</span>
                <span>{{ t('GlobalSearch.af31a0', '· 附件') }} {{ it.attachmentCount }}</span>
              </div>
            </li>
          </ul>

          <p v-if="hasMore" class="hint">{{ t('GlobalSearch.2ca07b', '还有更多结果，请细化关键词') }}</p>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.search-trigger {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  min-height: 38px;
  padding: 0 var(--sp-4);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-pill);
  background: var(--bg-surface);
  color: var(--text-secondary);
  cursor: pointer;
  font-size: var(--font-size-sm);
  min-width: 220px;
}
.search-trigger:hover {
  background: var(--bg-hover);
}
.search-trigger__icon {
  width: 17px;
  height: 17px;
  flex: none;
  display: block;
}
.search-trigger kbd {
  font-family: var(--font-sans);
  font-size: 12px;
  padding: 2px 6px;
  margin-left: auto;
  border: 1px solid var(--hairline);
  border-radius: var(--g3-xs);
  color: var(--text-muted);
  background: var(--bg-app);
}

.mask {
  position: fixed;
  inset: 0;
  background: var(--material-scrim);
  display: flex;
  justify-content: center;
  align-items: flex-start;
  padding-top: 10vh;
  z-index: 100;
}

.dialog {
  width: min(640px, calc(100vw - 32px));
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  box-shadow: var(--shadow-pop);
  overflow: hidden;
}

.dialog__head {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-4) var(--sp-5);
  border-bottom: 1px solid var(--hairline);
}

.dialog__input {
  flex: 1;
  border: none;
  outline: none;
  background: transparent;
  color: var(--text-primary);
  font-size: var(--font-size-md);
  letter-spacing: var(--tracking-body);
  font-family: var(--font-sans);
}

.dialog__close {
  display: grid;
  place-items: center;
  width: 30px;
  height: 30px;
  border: none;
  background: var(--bg-hover);
  border-radius: var(--g3-pill);
  color: var(--text-secondary);
  cursor: pointer;
  font-size: 13px;
}

.dialog__body {
  max-height: 50vh;
  overflow-y: auto;
  padding: var(--sp-3);
}

.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin: var(--sp-2) 0;
}
.hint--error {
  color: var(--danger);
}

.results {
  list-style: none;
  margin: 0;
  padding: 0;
}

.result {
  padding: var(--sp-3);
  border-radius: var(--radius-sm);
  cursor: default;
}
.result:hover {
  background: var(--bg-hover);
}

.result__title {
  font-weight: 600;
  margin-bottom: var(--sp-1);
}

.result__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}

/* 移动端：对话框贴顶铺满，便于单手操作 */
@media (max-width: 639px) {
  .mask {
    padding-top: 0;
  }
  .dialog {
    width: 100vw;
    border-radius: 0;
    height: 100%;
  }
  .search-trigger {
    min-width: 0;
    flex: 1;
  }
}
</style>
