<script setup lang="ts">
/**
 * Q 域问答式搜索（docs/20 §5.3）。
 *
 * 输入自然语言问题 → POST /api/search/ask → 展示解析出的条件与命中条目。
 * 归属由服务端注入，前端只展示；模型不可用时后端降级为普通关键词搜索。
 * 关闭态由父级 AiFeatureGate(domain=query) 整块移除。
 */
import { ref } from 'vue'
import { api } from '../api/client'
import { t as tr } from '../i18n'
import { useRouter } from 'vue-router'

interface AskResult {
  query: string
  keyword: string
  category: number[]
  expiresTo: string
  itemIds: number[]
  reason: string
}

const router = useRouter()
const question = ref('')
const result = ref<AskResult | null>(null)
const busy = ref(false)
const open = ref(false)

const CAT_NAMES: Record<number, string> = {
  1: '个人基本信息', 2: '证件信息', 3: '教育经历', 4: '职业经历',
  5: '资质证书', 6: '联系方式', 7: '家庭关系', 8: '健康信息',
  9: '资产信息', 10: '影像附件', 11: '自定义分类',
}

async function ask(): Promise<void> {
  if (!question.value.trim() || busy.value) return
  busy.value = true
  result.value = null
  open.value = true
  try {
    result.value = await api<AskResult>('/search/ask', {
      method: 'POST', body: { question: question.value.trim() },
    })
  } catch {
    result.value = { query: question.value, keyword: '', category: [], expiresTo: '', itemIds: [], reason: 'failed' }
  } finally {
    busy.value = false
  }
}

function categoryText(codes: number[]): string {
  return codes.map((c) => CAT_NAMES[c] ?? String(c)).join('、')
}

function goItem(id: number): void {
  open.value = false
  void router.push({ name: 'archive', query: { detail: String(id) } })
}
</script>

<template>
  <div class="ai-ask" data-ai-feature="query">
    <div class="ai-ask__row">
      <input
        v-model="question"
        class="ai-ask__input"
        type="text"
        :placeholder="tr('aiAsk.placeholder', '用一句话描述要找的档案，如：快过期的驾驶证')"
        :aria-label="tr('aiAsk.placeholder', '用一句话描述要找的档案，如：快过期的驾驶证')"
        @keyup.enter="ask"
      />
      <button class="btn-ghost" type="button" :disabled="busy" @click="ask">
        {{ busy ? tr('aiAsk.busy', '搜索中…') : tr('aiAsk.ask', 'AI 搜索') }}
      </button>
    </div>

    <div v-if="open && result" class="ai-ask__result">
      <p class="ai-ask__cond">
        <span>{{ tr('aiAsk.understood', '理解条件') }}：</span>
        <code v-if="result.keyword">{{ result.keyword }}</code>
        <code v-if="result.category.length">{{ categoryText(result.category) }}</code>
        <code v-if="result.expiresTo">{{ tr('aiAsk.expiresBefore', '有效期至') }} {{ result.expiresTo }}</code>
        <em v-if="!result.keyword && !result.category.length && !result.expiresTo">
          {{ tr('aiAsk.noCond', '未解析出筛选条件') }}
        </em>
      </p>

      <p v-if="result.reason" class="ai-ask__reason">
        {{ result.reason === 'failed'
          ? tr('aiAsk.failed', 'AI 搜索暂不可用，请改用普通搜索')
          : tr('aiAsk.rejected', '查询条件含不支持的字段，已拒绝') }}
      </p>

      <p v-else-if="result.itemIds.length === 0" class="ai-ask__empty">
        {{ tr('aiAsk.notFound', '未找到相关内容') }}
      </p>
      <ul v-else class="ai-ask__hits">
        <li v-for="id in result.itemIds" :key="id">
          <button type="button" @click="goItem(id)">#{{ id }}</button>
        </li>
      </ul>
    </div>
  </div>
</template>

<style scoped>
.ai-ask { display: grid; gap: 8px; }
.ai-ask__row { display: flex; gap: 8px; }
.ai-ask__input {
  flex: 1; min-width: 180px;
  background: var(--bg-primary); color: var(--text-primary);
  border: 1px solid var(--border); border-radius: 8px; padding: 7px 10px; font-size: 13px;
}
.ai-ask__result {
  border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px;
  font-size: 12px; background: var(--bg-secondary, rgba(127,127,127,0.05));
}
.ai-ask__cond { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; margin: 0; }
.ai-ask__cond code {
  background: var(--bg-hover); padding: 2px 6px; border-radius: 4px; color: var(--text-primary);
}
.ai-ask__reason, .ai-ask__empty { margin: 8px 0 0; color: var(--text-secondary); }
.ai-ask__hits { list-style: none; margin: 8px 0 0; padding: 0; display: flex; gap: 6px; flex-wrap: wrap; }
.ai-ask__hits button {
  background: var(--bg-hover); color: var(--accent, #378add);
  border: 1px solid var(--border); border-radius: 6px; padding: 3px 8px; cursor: pointer;
}
</style>
