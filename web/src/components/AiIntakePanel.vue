<script setup lang="ts">
/**
 * AI 录入辅助面板（docs/20 §5.6）。
 *
 * 流程：选附件 → POST /api/attachments/:id/ai-parse → 展示字段候选
 * （来源页 + 置信度 + 待复核标记）→ 用户复制值到表单确认后保存。
 *
 * 【边界·如实标注】本面板只做「候选展示 + 复制值」；实际写库走既有
 * 条目编辑接口，由用户确认（P10 建议不自动执行）。关闭态由父级
 * AiFeatureGate 整块移除，本组件自身不渲染任何 AI 入口判断。
 */
import { ref, computed, onMounted } from 'vue'
import { api } from '../api/client'
import { t as tr } from '../i18n'

const props = defineProps<{ itemId: string }>()
/** 采纳候选：把 {字段 code, 值} 交给父级写入编辑表单 */
const emit = defineEmits<{
  (e: 'adopt', payload: { code: string; label: string; value: string }[]): void
}>()

interface Att {
  id: number
  title: string
  fileExt: string
}
interface Candidate {
  code: string
  label: string
  value: string
  confidence: number
  sourcePage: number
  needsReview: boolean
}

const atts = ref<Att[]>([])
const selected = ref<number>(0)
const fields = ref<Candidate[]>([])
const engine = ref('')
const reason = ref('')
const busy = ref(false)

const pct = (c: number) => `${Math.round(c * 100)}%`
const hasResult = computed(() => fields.value.length > 0 || !!reason.value)

onMounted(async () => {
  try {
    const res = await api<{ attachments: Att[] }>(`/attachments?itemId=${props.itemId}`)
    atts.value = (res.attachments ?? []).filter(
      (a) => ['jpg', 'jpeg', 'png', 'pdf'].includes((a.fileExt || '').toLowerCase())
    )
    if (atts.value.length > 0) selected.value = atts.value[0].id
  } catch {
    atts.value = []
  }
})

async function parse(): Promise<void> {
  if (!selected.value || busy.value) return
  busy.value = true
  fields.value = []
  reason.value = ''
  engine.value = ''
  try {
    const res = await api<{
      fields: Candidate[]
      engine: string
      reason: string
    }>(`/attachments/${selected.value}/ai-parse`, {
      method: 'POST',
      // 视觉模型处理大图可达 1-2 分钟，默认 15s 会误判为失败
      timeoutMs: 300000,
    })
    fields.value = res.fields ?? []
    engine.value = res.engine ?? ''
    reason.value = res.reason ?? ''
    if (!res.reason && fields.value.length === 0) {
      reason.value = 'no_fields'
    }
  } catch {
    reason.value = 'parse_failed'
  } finally {
    busy.value = false
  }
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

/** 采纳单条候选：交给父级写入表单（仅填空值，不覆盖用户已填） */
function adoptOne(c: Candidate): void {
  if (!c.value) return
  emit('adopt', [{ code: c.code, label: c.label, value: c.value }])
}

/** 采纳全部候选（父级按"仅填空值"规则写入） */
function adoptAll(): void {
  const usable = fields.value.filter((f) => f.value).map((f) => ({
    code: f.code, label: f.label, value: f.value
  }))
  if (usable.length > 0) emit('adopt', usable)
}
</script>

<template>
  <section class="ai-intake" :data-ai-feature="'vision'">
    <header class="ai-intake__head">
      <h4>{{ tr('aiIntake.title', 'AI 录入辅助') }}</h4>
      <span class="ai-intake__hint">{{
        tr('aiIntake.hint', '识别附件内容并预填字段，确认后再保存')
      }}</span>
    </header>

    <div v-if="atts.length === 0" class="ai-intake__empty">
      {{ tr('aiIntake.noAttach', '该条目暂无可识别的图片或 PDF 附件') }}
    </div>
    <div v-else class="ai-intake__body">
      <div class="ai-intake__row">
        <select v-model.number="selected" class="ai-intake__select">
          <option v-for="a in atts" :key="a.id" :value="a.id">
            {{ a.title }} ({{ a.fileExt }})
          </option>
        </select>
        <button class="btn-primary" type="button" :disabled="busy" @click="parse">
          {{ busy ? tr('aiIntake.parsing', '识别中…') : tr('aiIntake.parse', 'AI 识别并预填') }}
        </button>
      </div>

      <div v-if="hasResult" class="ai-intake__result">
        <ul v-if="fields.length" class="ai-intake__fields">
          <li v-for="f in fields" :key="f.code" class="ai-intake__field">
            <div class="ai-intake__field-head">
              <strong>{{ f.label }}</strong>
              <span class="ai-intake__conf" :class="{ low: f.needsReview }">
                {{ pct(f.confidence) }}
                <template v-if="f.needsReview">
                  · {{ tr('aiIntake.review', '待确认') }}
                </template>
              </span>
            </div>
            <div class="ai-intake__field-val">{{ f.value || '—' }}</div>
            <div class="ai-intake__field-src">
              {{ tr('aiIntake.source', '来源') }}: {{ f.sourcePage }}
              <button class="ai-intake__copy" type="button" @click="adoptOne(f)">
                {{ tr('aiIntake.adopt', '采纳') }}
              </button>
            </div>
          </li>
        </ul>
        <div v-if="fields.length" class="ai-intake__actions">
          <button class="btn-primary" type="button" @click="adoptAll">
            {{ tr('aiIntake.adoptAll', '采纳全部（仅填空字段）') }}
          </button>
        </div>
        <p v-if="reason" class="ai-intake__reason">{{ reasonText(reason) }}</p>
        <p v-if="engine" class="ai-intake__engine">
          {{ tr('aiIntake.engine', '引擎') }}: {{ engine }}
        </p>
      </div>
    </div>
  </section>
</template>

<style scoped>
.ai-intake {
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 14px;
  margin: 12px 0;
  background: var(--bg-secondary, rgba(127, 127, 127, 0.05));
}
.ai-intake__head {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex-wrap: wrap;
}
.ai-intake__head h4 { margin: 0; font-size: 14px; font-weight: 500; }
.ai-intake__hint { font-size: 12px; color: var(--text-secondary); }
.ai-intake__empty { margin-top: 10px; font-size: 13px; color: var(--text-secondary); }
.ai-intake__row { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
.ai-intake__select {
  flex: 1; min-width: 160px;
  background: var(--bg-primary); color: var(--text-primary);
  border: 1px solid var(--border); border-radius: 8px; padding: 6px 10px;
}
.ai-intake__fields { list-style: none; margin: 12px 0 0; padding: 0; display: grid; gap: 8px; }
.ai-intake__field {
  border: 1px solid var(--border); border-radius: 8px;
  padding: 8px 10px; background: var(--bg-primary);
}
.ai-intake__field-head { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; }
.ai-intake__conf { color: var(--text-secondary); font-size: 12px; }
.ai-intake__conf.low { color: var(--warning, #b8860b); }
.ai-intake__field-val { margin-top: 4px; font-size: 14px; word-break: break-all; }
.ai-intake__field-src { margin-top: 4px; font-size: 12px; color: var(--text-secondary); }
.ai-intake__copy {
  margin-left: 8px; background: none; border: none;
  color: var(--accent, #378add); cursor: pointer; padding: 0;
}
.ai-intake__actions { margin-top: 12px; display: flex; gap: 8px; }
.ai-intake__reason, .ai-intake__engine { margin: 10px 0 0; font-size: 12px; color: var(--text-secondary); }
</style>
