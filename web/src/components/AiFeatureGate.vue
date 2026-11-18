<script setup lang="ts">
/**
 * AI 功能门控容器（docs/20 §6.9）。
 *
 * 关闭态（用户 opt-out / 系统关闭 / 能力发现失败）时整块不渲染：
 *   - 用 v-if 而非 v-show，DOM 中不残留 AI 节点
 *   - 打 data-ai-feature 标记，供自动化断言关闭态零节点
 *
 * 用法：
 *   <AiFeatureGate domain="vision">
 *     <button>AI 识别</button>
 *   </AiFeatureGate>
 */
import { computed } from 'vue'
import { useAiCapabilities, type AiDomains } from '../composables/useAiCapabilities'

const props = withDefaults(defineProps<{
  /** 能力域；不传则要求任一 AI 能力可用 */
  domain?: keyof AiDomains
}>(), {
  domain: undefined
})

const { enabled, domainEnabled } = useAiCapabilities()

const visible = computed<boolean>(() => {
  if (props.domain) return domainEnabled(props.domain)
  return enabled.value
})
</script>

<template>
  <template v-if="visible">
    <div class="ai-feature" :data-ai-feature="domain ?? 'any'">
      <slot />
    </div>
  </template>
</template>

<style scoped>
.ai-feature {
  display: contents;
}
</style>
