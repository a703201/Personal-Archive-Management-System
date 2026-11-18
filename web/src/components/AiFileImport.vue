<script setup lang="ts">
/**
 * 新建档案时的 AI 文件导入预填（docs/20 §5.6）。
 *
 * 与 AiIntakePanel 的区别：不依赖已存在的 itemId——选本地文件 → base64 直送
 * POST /api/ai/parse-file（不落库）→ 展示字段候选 → 用户采纳后预填到新建表单。
 * 关闭态由父级 AiFeatureGate 整块移除。
 */
import { ref } from 'vue'
import { api } from '../api/client'
import { t as tr } from '../i18n'
import { resizeImageForAi } from '../utils/imageResize'

const props = defineProps<{ category: number; subjectId: string }>()
const emit = defineEmits<{
  (e: 'adopt', payload: { code: string; label: string; value: string }[]): void
  (e: 'fileSelected', file: File | null): void
}>()

interface Candidate {
  code: string
  label: string
  value: string
  confidence: number
  sourcePage: number
  needsReview: boolean
}

const fileName = ref('')
const fileSize = ref(0)
const fields = ref<Candidate[]>([])
const engine = ref('')
const reason = ref('')
const busy = ref(false)

const pct = (c: number) => `${Math.round(c * 100)}%`

function onFileChange(ev: Event): void {
  const input = ev.target as HTMLInputElement
  const f = input.files?.[0]
  if (!f) return
  fileName.value = f.name
  fileSize.value = f.size
  fields.value = []
  reason.value = ''
  engine.value = ''
  // 通知父组件暂存原图：新建档案保存后自动上传为附件
  emit('fileSelected', f)
}

async function parse(): Promise<void> {
  if (!fileName.value || busy.value) return
  const input = document.querySelector('#ai-file-input') as HTMLInputElement | null
  const f = input?.files?.[0]
  if (!f) return
  if (!['jpg', 'jpeg', 'png', 'pdf'].includes(f.name.split('.').pop()?.toLowerCase() ?? '')) {
    reason.value = 'unsupported_format'
    return
  }
  if (f.size > 50 * 1024 * 1024) {
    reason.value = 'read_failed'
    return
  }
  busy.value = true
  fields.value = []
  reason.value = ''
  try {
    // 超大原图先缩到长边 1600px：避免 1MB 网关 413 + 大幅缩短 CPU 推理时间
    const { data } = await resizeImageForAi(f)
    const res = await api<{ fields: Candidate[]; engine: string; reason: string }>('/ai/parse-file', {
      method: 'POST',
      // 视觉模型处理大图可达数分钟，默认 15s 会误判为失败
      timeoutMs: 300000,
      body: {
        data,
        fileName: f.name,
        category: props.category,
        subjectId: props.subjectId || '0',
      },
    })
    fields.value = res.fields ?? []
    engine.value = res.engine ?? ''
    reason.value = res.reason ?? ''
    if (!res.reason && fields.value.length === 0) reason.value = 'no_fields'
  } catch {
    reason.value = 'parse_failed'
  } finally {
    busy.value = false
  }
}

function adoptOne(c: Candidate): void {
  if (c.value) emit('adopt', [{ code: c.code, label: c.label, value: c.value }])
}

function adoptAll(): void {
  const usable = fields.value.filter((f) => f.value).map((f) => ({
    code: f.code, label: f.label, value: f.value,
  }))
  if (usable.length) emit('adopt', usable)
}

function reasonText(r: string): string {
  const map: Record<string, string> = {
    no_fields: tr('aiIntake.noFields', '未能识别到可提取的字段，请确认图片清晰或手工填写'),
    parse_failed: tr('aiIntake.parseFailed', 'AI 识别暂不可用，可直接手工填写，不影响保存'),
    unsupported_format: tr('aiIntake.badFormat', '暂不支持该格式，请上传 JPG、PNG 或 PDF 文件'),
    read_failed: tr('aiIntake.readFailed', '文件无法读取，请确认文件未损坏且未加密'),
    disabled: tr('aiIntake.disabled', '当前未启用 AI 辅助'),
  }
  return map[r] ?? tr('aiIntake.failed', '识别失败，请手工填写')
}
</script>

<template>
  <section class="ai-file-import" data-ai-feature="vision">
    <header class="ai-file-import__head">
      <h4>{{ tr('aiFileImport.title', '从文件导入并预填') }}</h4>
      <span>{{ tr('aiFileImport.hint', '上传证书/表格图片，AI 识别后预填到下方字段，确认后再保存') }}</span>
    </header>

    <div class="ai-file-import__row">
      <input
        id="ai-file-input"
        class="ai-file-import__input"
        type="file"
        accept=".jpg,.jpeg,.png,.pdf"
        @change="onFileChange"
      />
      <button class="btn-primary" type="button" :disabled="!fileName || busy" @click="parse">
        {{ busy ? tr('aiIntake.parsing', '识别中…') : tr('aiFileImport.parse', '识别并预填') }}
      </button>
    </div>
    <p v-if="busy" class="ai-file-import__waiting">{{ tr('aiFileImport.waiting', 'CPU 环境下识别大图可能需要 3-5 分钟，请稍候…') }}</p>
    <p v-if="fileName" class="ai-file-import__meta">
      {{ fileName }} · {{ Math.round(fileSize / 1024) }} KB · JPG/PNG/PDF ≤ 50MB
    </p>

    <div v-if="fields.length" class="ai-file-import__result">
      <ul class="ai-file-import__fields">
        <li v-for="f in fields" :key="f.code" class="ai-file-import__field">
          <div class="ai-file-import__field-head">
            <strong>{{ f.label }}</strong>
            <span :class="{ low: f.needsReview }">{{ pct(f.confidence) }}<template v-if="f.needsReview"> · {{ tr('aiIntake.review', '待确认') }}</template></span>
          </div>
          <div class="ai-file-import__val">{{ f.value || '—' }}</div>
          <div class="ai-file-import__src">
            {{ tr('aiIntake.source', '来源') }}: {{ f.sourcePage }}
            <button type="button" @click="adoptOne(f)">{{ tr('aiIntake.adopt', '采纳') }}</button>
          </div>
        </li>
      </ul>
      <button class="btn-ghost" type="button" @click="adoptAll">
        {{ tr('aiIntake.adoptAll', '采纳全部（仅填空字段）') }}
      </button>
    </div>
    <p v-if="reason" class="ai-file-import__reason">{{ reasonText(reason) }}</p>
    <p v-if="engine" class="ai-file-import__engine">{{ tr('aiIntake.engine', '引擎') }}: {{ engine }}</p>
  </section>
</template>

<style scoped>
.ai-file-import {
  border: 1px solid var(--border-subtle); background: var(--bg-inset);
  border-radius: var(--g3-md); padding: var(--sp-4); margin: var(--sp-4) 0;
}
.ai-file-import__head { display: grid; gap: 2px; margin-bottom: var(--sp-3); }
.ai-file-import__head h4 { margin: 0; font-size: var(--font-size-md); font-weight: 500; }
.ai-file-import__head span { font-size: var(--font-size-sm); color: var(--text-secondary); }
.ai-file-import__row { display: flex; gap: var(--sp-2); flex-wrap: wrap; }
.ai-file-import__input { flex: 1; min-width: 200px; font-size: var(--font-size-sm); }
.ai-file-import__meta { margin: var(--sp-2) 0 0; font-size: var(--font-size-xs); color: var(--text-muted); }
.ai-file-import__waiting { margin: var(--sp-2) 0 0; font-size: var(--font-size-xs); color: var(--accent); }
.ai-file-import__result { margin-top: var(--sp-3); display: grid; gap: var(--sp-2); }
.ai-file-import__fields { list-style: none; margin: 0; padding: 0; display: grid; gap: var(--sp-2); }
.ai-file-import__field {
  border: 1px solid var(--border-subtle); border-radius: var(--g3-sm);
  padding: var(--sp-2) var(--sp-3); background: var(--bg-surface);
}
.ai-file-import__field-head { display: flex; justify-content: space-between; gap: var(--sp-2); font-size: var(--font-size-sm); }
.ai-file-import__field-head span { color: var(--text-secondary); font-size: var(--font-size-xs); }
.ai-file-import__field-head span.low { color: var(--warning, #b8860b); }
.ai-file-import__val { margin-top: 4px; font-size: var(--font-size-md); word-break: break-all; }
.ai-file-import__src { margin-top: 4px; font-size: var(--font-size-xs); color: var(--text-secondary); }
.ai-file-import__src button {
  margin-left: var(--sp-2); background: none; border: none;
  color: var(--accent); cursor: pointer; padding: 0; font-size: var(--font-size-xs);
}
.ai-file-import__reason, .ai-file-import__engine { margin: var(--sp-2) 0 0; font-size: var(--font-size-xs); color: var(--text-secondary); }
</style>
