<script setup lang="ts">
/**
 * 条目共享链接面板（FR-ACL-011 / FR-ACL-012 · 方案 A：条目级）。
 *
 * 接口：
 *   POST   /api/share-links         创建（itemId / password? / expiresInHours / maxFails）
 *   GET    /api/share-links         本人全部链接（前端按 itemId 过滤出本条目）
 *   DELETE /api/share-links/:id     撤销
 *
 * 设计取舍：
 *   · 链接是「数据出口」，因此本面板**只做创建/撤销**，不提供「查看内容预览」——
 *     预览容易让人误以为公开页会展示全部字段。实际公开页只给展示字段，
 *     高敏条目连签发机构与备注都不给（后端 publicView 负责）。
 *   · 过期时间用「小时」传，UI 用「天」表达：小时是给后端钳制用的稳定单位。
 *   · token 一经创建不再展示二次确认，但**始终显示完整 URL** —— 这是唯一一次
 *     能拿到的机会（后端不存明文 token 以外的凭据），避免用户撤销后无法核对。
 */
import { computed, ref } from 'vue'
import { t } from '../i18n'
import { api } from '../api/client'
import { formatTime as fmtTime } from '../composables/useCatalog'
import { useToast } from '../composables/useToast'

const props = defineProps<{ itemId: number }>()

const { success, error: toastError } = useToast()

interface ShareLink {
  id: string
  token: string
  itemId: string
  revoked: boolean
  expired: boolean
  viewCount: number
  failCount: number
  expiresAt: number
  createdAt: number
  lastAccessAt: number
}

const links = ref<ShareLink[]>([])
const loading = ref(false)
const loadError = ref('')
const creating = ref(false)
const revoking = ref('')

/** 新建表单 */
const showForm = ref(false)
const form = ref({
  password: '',
  days: 7,
  maxFails: 5,
})

/** 刚创建的链接（本次唯一一次完整展示机会） */
const created = ref<{ url: string; fullUrl: string; protected: boolean } | null>(null)

const myLinks = computed(() => links.value.filter((l) => String(l.itemId) === String(props.itemId)))

const DAY_OPTIONS = [
  { label: '1 天', value: 1 },
  { label: '7 天', value: 7 },
  { label: '30 天', value: 30 },
  { label: '90 天', value: 90 },
  { label: '365 天', value: 365 },
]

function stateOf(l: ShareLink): { text: string; cls: string } {
  if (l.revoked) return { text: '已失效', cls: 'chip--dead' }
  if (l.expired) return { text: '已过期', cls: 'chip--dead' }
  return { text: '生效中', cls: 'chip--live' }
}

function fullUrlOf(token: string): string {
  return `${window.location.origin}/share/${token}`
}

async function load(): Promise<void> {
  loading.value = true
  loadError.value = ''
  try {
    const r = await api<{ total: number; items: ShareLink[] }>('/share-links?page=1&size=100')
    links.value = r.items ?? []
  } catch (e) {
    loadError.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

async function create(): Promise<void> {
  creating.value = true
  try {
    const hours = Math.max(1, Math.round(form.value.days * 24))
    const r = await api<{
      id: string
      token: string
      url: string
      protected: boolean
      maxFails: number
      expiresAt: number
    }>('/share-links', {
      method: 'POST',
      body: {
        itemId: props.itemId,
        password: form.value.password.trim(),
        expiresInHours: hours,
        maxFails: form.value.maxFails,
      },
    })
    created.value = {
      url: r.url,
      fullUrl: fullUrlOf(r.token),
      protected: r.protected,
    }
    showForm.value = false
    form.value = { password: '', days: 7, maxFails: 5 }
    success('共享链接已创建')
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    creating.value = false
  }
}

async function revoke(l: ShareLink): Promise<void> {
  revoking.value = l.id
  try {
    await api(`/share-links/${l.id}`, { method: 'DELETE' })
    success('链接已撤销')
    load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    revoking.value = ''
  }
}

async function copy(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text)
    success('已复制到剪贴板')
  } catch {
    // 非安全上下文（http）下 clipboard 不可用，退回选中提示
    toastError('复制失败，请手动选中链接复制')
  }
}

// 首次挂载即加载（面板只在详情面板展开时渲染）
load()
defineExpose({ load })
</script>

<template>
  <section class="share">
    <div class="share__head">
      <h3 class="share__title">{{ t('ShareLinkPanel.e7b1c3', '共享链接') }}</h3>
      <button class="btn-ghost share__new" type="button" @click="showForm = !showForm">
        {{ showForm ? '收起' : '+ 创建链接' }}
      </button>
    </div>

    <p class="share__desc">
      生成一个免登录只读链接。默认 7 天有效，可设访问密码；密码错误达到上限后链接立即失效。
    </p>

    <!-- 创建表单 -->
    <div v-if="showForm" class="share__form">
      <label class="field">
        <span class="field__label">{{ t('ShareLinkPanel.2a8f82', '访问密码（选填）') }}</span>
        <input
          v-model="form.password"
          class="field-control"
          type="text"
          :placeholder="t('ShareLinkPanel.6b65e8', '留空则任何人拿到链接即可查看')"
          autocomplete="new-password"
        />
      </label>
      <div class="share__row">
        <label class="field">
          <span class="field__label">{{ t('ShareLinkPanel.222460', '有效期') }}</span>
          <select v-model.number="form.days" class="field-control">
            <option v-for="d in DAY_OPTIONS" :key="d.value" :value="d.value">{{ d.label }}</option>
          </select>
        </label>
        <label class="field">
          <span class="field__label">{{ t('ShareLinkPanel.ff0e99', '密码错误上限') }}</span>
          <input
            v-model.number="form.maxFails"
            class="field-control"
            type="number"
            min="1"
            max="20"
          />
        </label>
      </div>
      <div class="share__actions">
        <button
          class="btn-primary"
          type="button"
          :disabled="creating"
          @click="create"
        >
          {{ creating ? '创建中…' : '创建链接' }}
        </button>
      </div>
    </div>

    <!-- 新建结果 -->
    <div v-if="created" class="share__result">
      <div class="share__result-top">
        <span class="share__result-badge">{{ created.protected ? '密码保护' : '公开只读' }}</span>
        <button class="btn-text" type="button" @click="created = null">{{ t('ShareLinkPanel.6c14bd', '关闭') }}</button>
      </div>
      <code class="share__url">{{ created.fullUrl }}</code>
      <button class="btn-ghost" type="button" @click="copy(created.fullUrl)">{{ t('ShareLinkPanel.abb22b', '复制链接') }}</button>
    </div>

    <!-- 已有链接 -->
    <p v-if="loading" class="hint">{{ t('ShareLinkPanel.300ee3', '加载中…') }}</p>
    <p v-else-if="loadError" class="hint hint--error">{{ loadError }}</p>
    <p v-else-if="myLinks.length === 0" class="hint">{{ t('ShareLinkPanel.ef4fa7', '该条目还没有共享链接。') }}</p>

    <ul v-else class="share__list">
      <li v-for="l in myLinks" :key="l.id" class="share__item">
        <div class="share__item-main">
          <div class="share__item-top">
            <span class="chip" :class="stateOf(l).cls">{{ stateOf(l).text }}</span>
            <span class="u-sub">{{ t('ShareLinkPanel.ef23ea', '浏览') }} {{ l.viewCount }} {{ t('ShareLinkPanel.5e5b81', '次') }}</span>
            <span v-if="l.failCount > 0" class="u-sub u-sub--warn">
              密码错误 {{ l.failCount }} 次
            </span>
          </div>
          <code class="share__token">{{ fullUrlOf(l.token) }}</code>
          <span class="u-sub">{{ t('ShareLinkPanel.8066e0', '到期') }} {{ fmtTime(l.expiresAt) }}</span>
        </div>
        <div class="share__item-actions">
          <button class="btn-text" type="button" @click="copy(fullUrlOf(l.token))">{{ t('ShareLinkPanel.4edd1d', '复制') }}</button>
          <button
            v-if="!l.revoked && !l.expired"
            class="btn-text danger"
            type="button"
            :disabled="revoking === l.id"
            @click="revoke(l)"
          >
            {{ revoking === l.id ? '撤销中…' : '撤销' }}
          </button>
        </div>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.share {
  margin-top: var(--sp-4);
  padding-top: var(--sp-3);
  border-top: 1px solid var(--border-subtle);
}
.share__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-2);
}
.share__title {
  font-size: var(--font-size-md);
  margin: 0;
}
.share__new {
  font-size: var(--font-size-sm);
}
.share__desc {
  margin: var(--sp-1) 0 var(--sp-3);
  font-size: 12px;
  color: var(--text-muted);
  line-height: 1.5;
}

.share__form {
  display: grid;
  gap: var(--sp-3);
  padding: var(--sp-3);
  background: var(--bg-hover);
  border-radius: var(--g3-md);
  margin-bottom: var(--sp-3);
}
.share__row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-3);
}
.share__actions {
  display: flex;
  justify-content: flex-end;
}

.share__result {
  display: grid;
  gap: var(--sp-2);
  padding: var(--sp-3);
  border: 1px solid var(--accent);
  border-radius: var(--g3-md);
  background: var(--accent-soft);
  margin-bottom: var(--sp-3);
}
.share__result-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.share__result-badge {
  font-size: 12px;
  font-weight: 600;
  color: var(--accent);
}

.share__list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: grid;
  gap: var(--sp-2);
}
.share__item {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-2);
  padding: var(--sp-3);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-md);
}
.share__item-main {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.share__item-top {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
}
.share__item-actions {
  display: flex;
  gap: var(--sp-1);
  flex-shrink: 0;
}

.share__token,
.share__url {
  font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 12px;
  color: var(--text-secondary);
  word-break: break-all;
}

.chip {
  font-size: 11px;
  padding: 1px 8px;
  border-radius: var(--g3-pill);
  font-weight: 600;
}
.chip--live {
  background: color-mix(in srgb, var(--success, #2e9e5b) 16%, transparent);
  color: var(--success, #2e9e5b);
}
.chip--dead {
  background: var(--bg-hover);
  color: var(--text-muted);
}

.u-sub {
  color: var(--text-muted);
  font-size: 12px;
}
.u-sub--warn {
  color: var(--warning);
}
.btn-text.danger {
  color: var(--danger);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field__label {
  font-size: 13px;
  color: var(--text-secondary);
}

@media (max-width: 639px) {
  .share__row {
    grid-template-columns: 1fr;
  }
}
</style>
