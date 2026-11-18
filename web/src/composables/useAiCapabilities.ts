/**
 * AI 能力发现与关闭态门控（docs/20 §6.9）。
 *
 * 唯一数据源：后端 GET /api/ai/capabilities。前端**不自行判断开关组合**，
 * 避免各页面口径漂移（与 useCatalog 文案唯一口径同理）。
 *
 * 关闭态（opt-out 或系统关闭）下：
 *   - enabled = false，各页面 AI 区域由 AiFeatureGate 整块移除（v-if，不置灰）
 *   - 不发任何 AI 请求（调用方应先查 enabled）
 *
 * 用户偏好持久化在**服务端** cfg_settings（OQ12 已定稿），不使用 localStorage。
 */
import { ref, computed } from 'vue'
import { api } from '../api/client'

export interface AiDomains {
  vision: boolean
  summary: boolean
  query: boolean
  advice: boolean
}

export interface AiCapabilities {
  aiEnabled: boolean
  optOut: boolean
  onlineAllowed: boolean
  domains: AiDomains
}

const EMPTY: AiCapabilities = {
  aiEnabled: false,
  optOut: false,
  onlineAllowed: false,
  domains: { vision: false, summary: false, query: false, advice: false }
}

// 模块级单例：所有页面共享同一份能力状态
const caps = ref<AiCapabilities>({ ...EMPTY })
const loaded = ref(false)

async function refresh(): Promise<void> {
  try {
    const data = await api<AiCapabilities>('/ai/capabilities')
    caps.value = {
      aiEnabled: !!data.aiEnabled,
      optOut: !!data.optOut,
      onlineAllowed: !!data.onlineAllowed,
      domains: {
        vision: !!(data.domains && data.domains.vision),
        summary: !!(data.domains && data.domains.summary),
        query: !!(data.domains && data.domains.query),
        advice: !!(data.domains && data.domains.advice)
      }
    }
  } catch {
    // 能力发现失败 → 保守关闭（失败关闭红线），不显示任何 AI 入口
    caps.value = { ...EMPTY }
  } finally {
    loaded.value = true
  }
}

async function setOptOut(optedOut: boolean): Promise<void> {
  await api('/me/ai-preference', {
    method: 'PUT',
    body: { optOut: optedOut }
  })
  await refresh()
}

/**
 * 关闭态判定的纯函数（供单测直接验证，不依赖 Vue 响应式 / DOM）。
 * 文档 §6.9：opt-out 或系统关闭 → 一律 false；能力发现失败（EMPTY）→ 保守 false。
 */
export function isAiEnabled(c: AiCapabilities): boolean {
  return c.aiEnabled && !c.optOut
}

export function isDomainEnabled(c: AiCapabilities, domain: keyof AiDomains): boolean {
  if (!isAiEnabled(c)) return false
  return c.domains[domain]
}

export function useAiCapabilities() {
  const enabled = computed<boolean>(() => isAiEnabled(caps.value))

  function domainEnabled(domain: keyof AiDomains): boolean {
    return isDomainEnabled(caps.value, domain)
  }

  return {
    caps,
    loaded,
    enabled,
    domainEnabled,
    refresh,
    setOptOut
  }
}
