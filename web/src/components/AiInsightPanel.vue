<script setup lang="ts">
/**
 * S/A 域详情洞察卡（docs/20 §5.2 / §5.4）。
 *
 * S：条目摘要 + 关键词（Grounded，不编造）
 * A：分类归属建议（候选，采纳走既有编辑接口，P10）
 * 两者都不自动写库；关闭态由父级 AiFeatureGate 分别门控。
 */
import { ref } from 'vue'
import { api } from '../api/client'
import { t as tr } from '../i18n'
import { useToast } from '../composables/useToast'

const props = defineProps<{ itemId: string; domain: 'summary' | 'advice' }>()
const emit = defineEmits<{ (e: 'adoptCategory', code: number): void }>()

const toast = useToast()
const text = ref('')
const keywords = ref<string[]>([])
const reason = ref('')
const busy = ref(false)
const loaded = ref(false)

const CAT_NAMES: Record<number, string> = {
  1: '个人基本信息', 2: '证件信息', 3: '教育经历', 4: '职业经历',
  5: '资质证书', 6: '联系方式', 7: '家庭关系', 8: '健康信息',
  9: '资产信息', 10: '影像附件', 11: '自定义分类',
}

async function generate(): Promise<void> {
  if (busy.value) return
  busy.value = true
  text.value = ''
  keywords.value = []
  reason.value = ''
  try {
    const path = props.domain === 'summary'
      ? `/summary/items/${props.itemId}`
      : `/advice/items/${props.itemId}`
    const r = await api<{ kind: string; text: string; keywords: string[]; reason: string }>(
      path, { method: 'POST' })
    text.value = r.text ?? ''
    keywords.value = r.keywords ?? []
    reason.value = r.reason ?? ''
  } catch {
    reason.value = 'failed'
  } finally {
    busy.value = false
    loaded.value = true
  }
}

const adviceCode = (): number | null => {
  if (props.domain !== 'advice' || !text.value) return null
  const code = Number(text.value.split('|')[0])
  return code >= 1 && code <= 11 ? code : null
}

function reasonText(r: string): string {
  const map: Record<string, string> = {
    failed: tr('aiInsight.failed', 'AI 服务暂不可用，可稍后重试'),
    disabled: tr('aiInsight.disabled', '当前未启用该 AI 能力'),
    not_found: tr('aiInsight.notFound', '条目不存在'),
    invalid_json: tr('aiInsight.badJson', '模型返回格式异常，请重试'),
  }
  return map[r] ?? tr('aiInsight.failed', 'AI 服务暂不可用，可稍后重试')
}

function adopt(): void {
  const code = adviceCode()
  if (code === null) return
  emit('adoptCategory', code)
  toast.success(tr('aiInsight.adopted', '建议在表单中确认后生效'))
}
</script>

<template>
  <section class="ai-insight" :data-ai-feature="domain">
    <header class="ai-insight__head">
      <h4 v-if="domain === 'summary'">{{ tr('aiInsight.summaryTitle', 'AI 摘要') }}</h4>
      <h4 v-else>{{ tr('aiInsight.adviceTitle', 'AI 分类建议') }}</h4>
      <button class="btn-ghost" type="button" :disabled="busy" @click="generate">
        {{ busy ? tr('aiInsight.busy', '生成中…') : tr('aiInsight.generate', '重新生成') }}
      </button>
    </header>

    <p v-if="reason" class="ai-insight__reason">{{ reasonText(reason) }}</p>
    <template v-else-if="loaded">
      <p v-if="domain === 'summary'" class="ai-insight__text">{{ text || tr('aiInsight.empty', '未生成摘要') }}</p>
      <p v-else class="ai-insight__text">
        <template v-if="adviceCode()">
          {{ tr('aiInsight.suggest', '建议分类') }}：{{ CAT_NAMES[adviceCode()!] }}
          <small v-if="text.split('|')[1]"> · {{ text.split('|')[1] }}</small>
        </template>
        <template v-else>{{ tr('aiInsight.noAdvice', '暂无建议') }}</template>
      </p>

      <div v-if="keywords.length" class="ai-insight__kw">
        <span v-for="(k, i) in keywords" :key="i">{{ k }}</span>
      </div>
      <div v-if="domain === 'advice' && adviceCode()" class="ai-insight__actions">
        <button class="btn-primary" type="button" @click="adopt">
          {{ tr('aiInsight.adopt', '采纳到表单') }}
        </button>
      </div>
      <p class="ai-insight__note">{{ tr('aiInsight.note', '仅为候选，确认后保存才生效') }}</p>
    </template>
  </section>
</template>

<style scoped>
.ai-insight {
  border: 1px solid var(--border); border-radius: 12px; padding: 12px 14px; margin: 10px 0;
  background: var(--bg-secondary, rgba(127,127,127,0.05));
}
.ai-insight__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ai-insight__head h4 { margin: 0; font-size: 14px; font-weight: 500; }
.ai-insight__text { margin: 10px 0 0; font-size: 13px; line-height: 1.6; }
.ai-insight__text small { color: var(--text-secondary); }
.ai-insight__reason { margin: 10px 0 0; font-size: 12px; color: var(--text-secondary); }
.ai-insight__kw { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 8px; }
.ai-insight__kw span {
  background: var(--bg-hover); border-radius: 6px; padding: 2px 7px; font-size: 12px;
}
.ai-insight__actions { margin-top: 10px; }
.ai-insight__note { margin: 8px 0 0; font-size: 11px; color: var(--text-secondary); }
</style>
