<script setup lang="ts">
/**
 * 条目附件面板（FR-ATT-001/004/005/006 + P1：008 水印 / 009 版本对比 / 010 批量）。
 *
 * 后端接口一览：
 *   GET    /attachments?itemId=           列表
 *   POST   /attachments?itemId=&fileName= 上传（原始字节体）
 *   GET    /attachments/:id/download      下载（base64）
 *   GET    /attachments/:id/versions      版本列表
 *   GET    /attachments/:id/versions/compare?from=&to=  元数据差异
 *   GET    /attachments/:id/watermark     预览水印文本（含追踪号，服务端留痕）
 *   POST   /attachments/batch/download    打包下载（可选口令，ZIP）
 *   POST   /attachments/batch/tag         批量打标签
 *   POST   /attachments/batch/delete      批量删除（软删）
 */
import { computed, onMounted, ref } from 'vue'
import { api, getToken } from '../api/client'

interface Att {
  id: number
  subjectId: number
  itemId: number
  category: number
  title: string
  currentVersionId: number
  versionCount: number
  fileSize: number
  fileExt: string
  mimeType: string
  status: number
  downloadCount: number
}

interface Ver {
  id: number
  versionNo: number
  fileSize: number
  fileExt: string
  isCurrent: boolean
  status: number
  changeNote: string
  uploadedAt: number
}

interface DiffField {
  field: string
  label: string
  from: string
  to: string
  changed: boolean
}

interface Diff {
  contentChanged: boolean
  sizeDelta: number
  from: { versionNo: number }
  to: { versionNo: number }
  fields: DiffField[]
}

const props = defineProps<{ itemId: number }>()

const list = ref<Att[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const busy = ref(false)
const picked = ref<Set<number>>(new Set())
const fileInput = ref<HTMLInputElement | null>(null)

/** 预览 */
const previewOpen = ref(false)
const previewUrl = ref('')
const previewAtt = ref<Att | null>(null)
const watermark = ref('')
const previewIsImage = computed(() => {
  const m = previewAtt.value?.mimeType ?? ''
  return m.startsWith('image/') || ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].includes(
    (previewAtt.value?.fileExt ?? '').toLowerCase(),
  )
})

/** 版本与对比 */
const verOpen = ref(false)
const verList = ref<Ver[]>([])
const verAtt = ref<Att | null>(null)
const cmpFrom = ref(0)
const cmpTo = ref(0)
const diff = ref<Diff | null>(null)

/** 标签 */
const tagOpen = ref(false)
const tags = ref<{ id: number; name: string }[]>([])
const pickedTags = ref<Set<number>>(new Set())

function fmtSize(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

function fmtTime(ms: number): string {
  if (!ms) return '—'
  const d = new Date(ms)
  const p = (x: number) => String(x).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    const res = await api<{ attachments: Att[] }>(`/attachments?itemId=${props.itemId}`)
    list.value = res.attachments ?? []
    picked.value = new Set()
  } catch (e) {
    error.value = (e as Error).message || '附件加载失败'
  } finally {
    loading.value = false
  }
}

async function upload(ev: Event): Promise<void> {
  const input = ev.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  busy.value = true
  error.value = ''
  try {
    // 元数据走 query，内容走原始字节体（与后端约定一致）
    const q = new URLSearchParams({
      itemId: String(props.itemId),
      title: file.name.replace(/\.[^.]+$/, ''),
      fileName: file.name,
      category: '10',
    })
    const res = await fetch(`/api/attachments?${q.toString()}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/octet-stream',
        Authorization: `Bearer ${getToken()}`,
      },
      body: file,
    })
    if (!res.ok) {
      const j = await res.json().catch(() => ({}))
      throw new Error(j.message || `上传失败（${res.status}）`)
    }
    notice.value = `已上传 ${file.name}`
    await load()
  } catch (e) {
    error.value = (e as Error).message || '上传失败'
  } finally {
    busy.value = false
    input.value = ''
  }
}

async function fetchBlob(id: number): Promise<string> {
  const res = await api<{ base64: string }>(`/attachments/${id}/download`)
  // base64 → 二进制 → Blob URL（后端正文是 String，只能走 base64）
  const bin = atob(res.base64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
  return URL.createObjectURL(new Blob([bytes]))
}

async function openPreview(a: Att): Promise<void> {
  error.value = ''
  busy.value = true
  try {
    if (previewUrl.value) URL.revokeObjectURL(previewUrl.value)
    previewAtt.value = a
    previewUrl.value = await fetchBlob(a.id)
    // 水印由服务端签发：访问者 + 服务端时间 + 追踪号，并在审计里留痕
    const wm = await api<{ text: string }>(`/attachments/${a.id}/watermark`)
    watermark.value = wm.text
    previewOpen.value = true
  } catch (e) {
    error.value = (e as Error).message || '预览失败'
  } finally {
    busy.value = false
  }
}

function closePreview(): void {
  previewOpen.value = false
  if (previewUrl.value) {
    URL.revokeObjectURL(previewUrl.value)
    previewUrl.value = ''
  }
  previewAtt.value = null
  watermark.value = ''
}

async function openVersions(a: Att): Promise<void> {
  verAtt.value = a
  verOpen.value = true
  diff.value = null
  cmpFrom.value = 0
  cmpTo.value = 0
  try {
    const res = await api<{ versions: Ver[] }>(`/attachments/${a.id}/versions`)
    verList.value = res.versions ?? []
    if (verList.value.length >= 2) {
      cmpFrom.value = verList.value[1].id
      cmpTo.value = verList.value[0].id
    }
  } catch (e) {
    error.value = (e as Error).message || '版本加载失败'
  }
}

async function compare(): Promise<void> {
  if (!verAtt.value || !cmpFrom.value || !cmpTo.value) {
    error.value = '请选择两个版本'
    return
  }
  try {
    diff.value = await api<Diff>(
      `/attachments/${verAtt.value.id}/versions/compare?from=${cmpFrom.value}&to=${cmpTo.value}`,
    )
  } catch (e) {
    error.value = (e as Error).message || '版本对比失败'
  }
}

async function makeCurrent(v: Ver): Promise<void> {
  if (!verAtt.value) return
  try {
    await api(`/attachments/${verAtt.value.id}/versions/${v.id}/current`, { method: 'POST' })
    notice.value = `已切换到 v${v.versionNo}`
    await openVersions(verAtt.value)
  } catch (e) {
    error.value = (e as Error).message || '切换失败'
  }
}

/** 上传新版本（版本对比的数据前提） */
const verFileInput = ref<HTMLInputElement | null>(null)
const verNote = ref('')

async function uploadVersion(ev: Event): Promise<void> {
  const input = ev.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file || !verAtt.value) return
  busy.value = true
  try {
    const q = new URLSearchParams({ fileName: file.name, changeNote: verNote.value })
    const res = await fetch(`/api/attachments/${verAtt.value.id}/versions?${q.toString()}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/octet-stream',
        Authorization: `Bearer ${getToken()}`,
      },
      body: file,
    })
    if (!res.ok) {
      const j = await res.json().catch(() => ({}))
      throw new Error(j.message || `上传失败（${res.status}）`)
    }
    notice.value = `已上传新版本 ${file.name}`
    verNote.value = ''
    await openVersions(verAtt.value)
    await load()
  } catch (e) {
    error.value = (e as Error).message || '上传新版本失败'
  } finally {
    busy.value = false
    input.value = ''
  }
}

function toggle(id: number): void {
  const s = new Set(picked.value)
  if (s.has(id)) s.delete(id)
  else s.add(id)
  picked.value = s
}

function toggleAll(): void {
  if (picked.value.size === list.value.length) picked.value = new Set()
  else picked.value = new Set(list.value.map((a) => a.id))
}

async function batchDownload(): Promise<void> {
  if (picked.value.size === 0) return
  busy.value = true
  error.value = ''
  try {
    const res = await api<{ fileName: string; base64: string; size: number }>(
      '/attachments/batch/download',
      { method: 'POST', body: { ids: Array.from(picked.value) } },
    )
    const bin = atob(res.base64)
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/zip' }))
    const a = document.createElement('a')
    a.href = url
    a.download = res.fileName
    a.click()
    URL.revokeObjectURL(url)
    notice.value = `已打包 ${picked.value.size} 个附件（${fmtSize(res.size)}）`
  } catch (e) {
    error.value = (e as Error).message || '打包下载失败'
  } finally {
    busy.value = false
  }
}

async function openTag(): Promise<void> {
  if (picked.value.size === 0) return
  tagOpen.value = true
  pickedTags.value = new Set()
  try {
    // 标签列表接口返回 {items:[{id,name,color...}], total:N}
    const res = await api<{ items: { id: number; name: string }[] }>('/tags')
    tags.value = res.items ?? []
  } catch (e) {
    error.value = (e as Error).message || '标签加载失败'
  }
}

function toggleTag(id: number): void {
  const s = new Set(pickedTags.value)
  if (s.has(id)) s.delete(id)
  else s.add(id)
  pickedTags.value = s
}

async function applyTags(mode: 'add' | 'remove'): Promise<void> {
  if (pickedTags.value.size === 0) {
    error.value = '请选择标签'
    return
  }
  busy.value = true
  try {
    await api('/attachments/batch/tag', {
      method: 'POST',
      body: { ids: Array.from(picked.value), tagIds: Array.from(pickedTags.value), mode },
    })
    notice.value = mode === 'add' ? '标签已添加' : '标签已移除'
    tagOpen.value = false
  } catch (e) {
    error.value = (e as Error).message || '打标签失败'
  } finally {
    busy.value = false
  }
}

async function batchDelete(): Promise<void> {
  if (picked.value.size === 0) return
  if (!window.confirm(`确认删除所选 ${picked.value.size} 个附件？（软删除，可在后台恢复）`)) return
  busy.value = true
  try {
    await api('/attachments/batch/delete', {
      method: 'POST',
      body: { ids: Array.from(picked.value) },
    })
    notice.value = '已删除'
    await load()
  } catch (e) {
    error.value = (e as Error).message || '删除失败'
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="att">
    <div class="att__head">
      <h3 class="att__title">附件（{{ list.length }}）</h3>
      <div class="att__actions">
        <button class="btn-text" type="button" :disabled="busy" @click="fileInput?.click()">
          上传
        </button>
        <input ref="fileInput" class="hidden" type="file" @change="upload" />
      </div>
    </div>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="list.length === 0" class="hint">还没有附件。</p>
    <template v-else>
      <div class="pickbar">
        <label class="pickbar__all">
          <input
            type="checkbox"
            :checked="picked.size === list.length"
            @change="toggleAll"
          />
          全选
        </label>
        <span v-if="picked.size > 0" class="pickbar__count">已选 {{ picked.size }}</span>
        <template v-if="picked.size > 0">
          <button class="btn-text" type="button" :disabled="busy" @click="batchDownload">
            打包下载
          </button>
          <button class="btn-text" type="button" :disabled="busy" @click="openTag">打标签</button>
          <button class="btn-text btn-text--danger" type="button" :disabled="busy" @click="batchDelete">
            删除
          </button>
        </template>
      </div>

      <ul class="att-list">
        <li v-for="a in list" :key="a.id" class="att-item">
          <input
            type="checkbox"
            :checked="picked.has(a.id)"
            :aria-label="`选择 ${a.title}`"
            @change="toggle(a.id)"
          />
          <div class="att-item__main">
            <div class="att-item__title">
              {{ a.title }}
              <span v-if="a.fileExt" class="att-item__ext">.{{ a.fileExt }}</span>
              <span v-if="a.versionCount > 1" class="att-item__badge">v{{ a.versionCount }}</span>
            </div>
            <div class="att-item__sub">
              {{ fmtSize(a.fileSize) }} · 下载 {{ a.downloadCount }} 次
            </div>
          </div>
          <div class="att-item__ops">
            <button class="btn-text" type="button" @click="openPreview(a)">预览</button>
            <button class="btn-text" type="button" @click="openVersions(a)">版本</button>
          </div>
        </li>
      </ul>
    </template>

    <p v-if="notice" class="notice">{{ notice }}</p>
    <p v-if="error" class="error" role="alert">{{ error }}</p>

    <!-- 预览（水印覆盖） -->
    <div v-if="previewOpen" class="modal" role="dialog" aria-modal="true" @click.self="closePreview">
      <div class="modal__card">
        <div class="modal__head">
          <span class="modal__title">{{ previewAtt?.title }}</span>
          <button class="btn-text" type="button" @click="closePreview">关闭</button>
        </div>
        <div class="preview">
          <img v-if="previewIsImage" :src="previewUrl" class="preview__img" alt="附件预览" />
          <div v-else class="preview__fallback">该类型不支持在线预览，请使用「打包下载」。</div>
          <!-- 水印层：服务端签发的文本，斜向平铺覆盖 -->
          <div v-if="watermark" class="wm" aria-hidden="true">
            <span v-for="i in 12" :key="i" class="wm__item">{{ watermark }}</span>
          </div>
        </div>
      </div>
    </div>

    <!-- 版本与对比 -->
    <div v-if="verOpen" class="modal" role="dialog" aria-modal="true" @click.self="verOpen = false">
      <div class="modal__card">
        <div class="modal__head">
          <span class="modal__title">版本 · {{ verAtt?.title }}</span>
          <button class="btn-text" type="button" @click="verOpen = false">关闭</button>
        </div>
        <ul class="ver-list">
          <li v-for="v in verList" :key="v.id" class="ver-item">
            <div>
              <strong>v{{ v.versionNo }}</strong>
              <span v-if="v.isCurrent" class="ver-item__tag">当前</span>
              <div class="ver-item__sub">
                {{ fmtSize(v.fileSize) }} · {{ fmtTime(v.uploadedAt) }}
                <span v-if="v.changeNote"> · {{ v.changeNote }}</span>
              </div>
            </div>
            <button v-if="!v.isCurrent" class="btn-text" type="button" @click="makeCurrent(v)">
              设为当前
            </button>
          </li>
        </ul>
        <div class="ver-upload">
          <input
            v-model="verNote"
            class="ver-upload__note"
            type="text"
            placeholder="变更说明（可选）"
          />
          <button class="btn-ghost" type="button" :disabled="busy" @click="verFileInput?.click()">
            上传新版本
          </button>
          <input ref="verFileInput" class="hidden" type="file" @change="uploadVersion" />
        </div>
        <div class="cmp">
          <label>
            对比
            <select v-model.number="cmpFrom">
              <option v-for="v in verList" :key="v.id" :value="v.id">v{{ v.versionNo }}</option>
            </select>
          </label>
          <span class="cmp__arrow">→</span>
          <label>
            <select v-model.number="cmpTo">
              <option v-for="v in verList" :key="v.id" :value="v.id">v{{ v.versionNo }}</option>
            </select>
          </label>
          <button class="btn-ghost" type="button" @click="compare">开始对比</button>
        </div>
        <div v-if="diff" class="diff">
          <p class="diff__sum">
            内容{{ diff.contentChanged ? '已变化' : '未变化' }} · 大小变化
            {{ diff.sizeDelta > 0 ? '+' : '' }}{{ diff.sizeDelta }} B
          </p>
          <table class="diff__table">
            <thead>
              <tr><th>字段</th><th>v{{ diff.from.versionNo }}</th><th>v{{ diff.to.versionNo }}</th></tr>
            </thead>
            <tbody>
              <tr v-for="f in diff.fields" :key="f.field" :class="{ 'diff__row--chg': f.changed }">
                <td>{{ f.label }}</td>
                <td>{{ f.from || '—' }}</td>
                <td>{{ f.to || '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- 打标签 -->
    <div v-if="tagOpen" class="modal" role="dialog" aria-modal="true" @click.self="tagOpen = false">
      <div class="modal__card">
        <div class="modal__head">
          <span class="modal__title">给 {{ picked.size }} 个附件打标签</span>
          <button class="btn-text" type="button" @click="tagOpen = false">关闭</button>
        </div>
        <p v-if="tags.length === 0" class="hint">还没有标签，请先在「档案」页创建。</p>
        <div class="tagchips">
          <button
            v-for="t in tags"
            :key="t.id"
            class="tagchip"
            :class="{ 'tagchip--on': pickedTags.has(t.id) }"
            type="button"
            @click="toggleTag(t.id)"
          >
            {{ t.name }}
          </button>
        </div>
        <div class="cmp">
          <button class="btn-ghost" type="button" :disabled="busy" @click="applyTags('add')">
            添加标签
          </button>
          <button class="btn-ghost" type="button" :disabled="busy" @click="applyTags('remove')">
            移除标签
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.att {
  margin-top: var(--sp-4, 16px);
}
.att__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.att__title {
  margin: 0;
  font-size: 15px;
  font-weight: 600;
  color: var(--text-primary, #1f2937);
}
.hidden {
  display: none;
}
.hint {
  color: var(--text-muted, #9ca3af);
  font-size: 13px;
}
.notice {
  margin: 8px 0 0;
  font-size: 13px;
  color: var(--accent, #2563eb);
}
.error {
  margin: 8px 0 0;
  font-size: 13px;
  color: var(--danger, #dc2626);
}
.pickbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 0;
  border-bottom: 1px solid var(--border-subtle, #e5e7eb);
  font-size: 13px;
  color: var(--text-secondary, #4b5563);
}
.pickbar__all {
  display: flex;
  align-items: center;
  gap: 6px;
}
.pickbar__count {
  color: var(--text-muted, #9ca3af);
}
.att-list {
  list-style: none;
  margin: 0;
  padding: 0;
}
.att-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--border-subtle, #f1f5f9);
}
.att-item__main {
  flex: 1;
  min-width: 0;
}
.att-item__title {
  font-size: 14px;
  color: var(--text-primary, #1f2937);
}
.att-item__ext {
  color: var(--text-muted, #9ca3af);
  font-size: 12px;
}
.att-item__badge {
  margin-left: 6px;
  padding: 1px 6px;
  border-radius: 8px;
  background: rgba(37, 99, 235, 0.1);
  color: var(--accent, #2563eb);
  font-size: 11px;
}
.att-item__sub {
  font-size: 12px;
  color: var(--text-muted, #9ca3af);
}
.att-item__ops {
  display: flex;
  gap: 8px;
}
.btn-text {
  border: none;
  background: none;
  padding: 0;
  font-size: 13px;
  color: var(--accent, #2563eb);
  cursor: pointer;
}
.btn-text:disabled {
  color: var(--text-muted, #9ca3af);
  cursor: not-allowed;
}
.btn-text--danger {
  color: var(--danger, #dc2626);
}
.btn-ghost {
  border: 1px solid var(--border-subtle, #e5e7eb);
  background: var(--bg-surface, #fff);
  border-radius: var(--radius-sm, 8px);
  padding: 6px 12px;
  font-size: 13px;
  color: var(--text-primary, #1f2937);
  cursor: pointer;
}
.modal {
  position: fixed;
  inset: 0;
  z-index: 50;
  background: rgba(15, 23, 42, 0.45);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
}
.modal__card {
  width: 100%;
  max-width: 640px;
  max-height: 86vh;
  overflow: auto;
  background: var(--bg-surface, #fff);
  border-radius: var(--radius-md, 16px);
  padding: 20px;
}
.modal__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}
.modal__title {
  font-size: 15px;
  font-weight: 600;
  color: var(--text-primary, #1f2937);
}
.preview {
  position: relative;
  border-radius: var(--radius-sm, 8px);
  overflow: hidden;
  background: var(--bg-app, #eef1f6);
  min-height: 240px;
  display: flex;
  align-items: center;
  justify-content: center;
}
.preview__img {
  max-width: 100%;
  display: block;
  user-select: none;
}
.preview__fallback {
  padding: 40px 16px;
  text-align: center;
  color: var(--text-muted, #9ca3af);
  font-size: 13px;
}
.wm {
  position: absolute;
  inset: 0;
  display: flex;
  flex-wrap: wrap;
  align-content: center;
  justify-content: center;
  gap: 28px 36px;
  pointer-events: none;
  transform: rotate(-24deg);
  opacity: 0.26;
}
.wm__item {
  font-size: 12px;
  font-weight: 600;
  color: #1f2937;
  white-space: nowrap;
  user-select: none;
}
.ver-list {
  list-style: none;
  margin: 0 0 12px;
  padding: 0;
}
.ver-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 0;
  border-bottom: 1px solid var(--border-subtle, #f1f5f9);
  font-size: 14px;
}
.ver-item__tag {
  margin-left: 6px;
  padding: 1px 6px;
  border-radius: 8px;
  background: rgba(22, 163, 74, 0.12);
  color: var(--success, #16a34a);
  font-size: 11px;
}
.ver-item__sub {
  font-size: 12px;
  color: var(--text-muted, #9ca3af);
}
.cmp {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 13px;
  color: var(--text-secondary, #4b5563);
}
.ver-upload {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 12px;
}
.ver-upload__note {
  flex: 1;
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--radius-sm, 8px);
  padding: 6px 10px;
  font-size: 13px;
}
.cmp select {
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--radius-sm, 8px);
  padding: 4px 8px;
  font-size: 13px;
}
.cmp__arrow {
  color: var(--text-muted, #9ca3af);
}
.diff {
  margin-top: 14px;
}
.diff__sum {
  font-size: 13px;
  color: var(--text-secondary, #4b5563);
  margin: 0 0 8px;
}
.diff__table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.diff__table th,
.diff__table td {
  text-align: left;
  padding: 8px;
  border-bottom: 1px solid var(--border-subtle, #f1f5f9);
}
.diff__table th {
  color: var(--text-muted, #9ca3af);
  font-weight: 500;
}
.diff__row--chg td {
  background: rgba(217, 119, 6, 0.07);
}
.tagchips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 8px 0 16px;
}
.tagchip {
  border: 1px solid var(--border-subtle, #e5e7eb);
  background: var(--bg-surface, #fff);
  border-radius: 999px;
  padding: 5px 12px;
  font-size: 13px;
  color: var(--text-secondary, #4b5563);
  cursor: pointer;
}
.tagchip--on {
  border-color: var(--accent, #2563eb);
  background: rgba(37, 99, 235, 0.1);
  color: var(--accent, #2563eb);
}
</style>
