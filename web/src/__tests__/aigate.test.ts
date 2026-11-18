/**
 * AI 关闭态门控判定单测（docs/20 §6.9.4）。
 *
 * 验证三类关闭来源（用户 opt-out / 系统关闭 / 能力发现失败保守关闭）
 * 下任一能力域均不可用；开启态各域独立判定。
 * DOM 零节点由 AiFeatureGate 的 v-if 结构保证（data-ai-feature 标记可供 CDP 断言）。
 */
import { describe, it, expect } from 'vitest'
import {
  isAiEnabled,
  isDomainEnabled,
  type AiCapabilities,
} from '../composables/useAiCapabilities'

const on: AiCapabilities = {
  aiEnabled: true,
  optOut: false,
  onlineAllowed: false,
  domains: { vision: true, summary: true, query: true, advice: true },
}

const domains = ['vision', 'summary', 'query', 'advice'] as const

describe('AI 关闭态门控（P12 零痕迹）', () => {
  it('开启态：总开关放行，四域各自可用', () => {
    expect(isAiEnabled(on)).toBe(true)
    for (const d of domains) expect(isDomainEnabled(on, d)).toBe(true)
  })

  it('用户 opt-out：总开关与全部能力域均不可用', () => {
    const c: AiCapabilities = { ...on, optOut: true }
    expect(isAiEnabled(c)).toBe(false)
    for (const d of domains) expect(isDomainEnabled(c, d)).toBe(false)
  })

  it('系统总开关关闭：总开关与全部能力域均不可用', () => {
    const c: AiCapabilities = { ...on, aiEnabled: false }
    expect(isAiEnabled(c)).toBe(false)
    for (const d of domains) expect(isDomainEnabled(c, d)).toBe(false)
  })

  it('能力发现失败（默认空）：保守关闭，不误放行', () => {
    const c: AiCapabilities = {
      aiEnabled: false, optOut: false, onlineAllowed: false,
      domains: { vision: false, summary: false, query: false, advice: false },
    }
    for (const d of domains) expect(isDomainEnabled(c, d)).toBe(false)
  })

  it('分域开关独立：单域关闭不影响其它域', () => {
    const c: AiCapabilities = {
      ...on, domains: { ...on.domains, query: false },
    }
    expect(isAiEnabled(c)).toBe(true)
    expect(isDomainEnabled(c, 'query')).toBe(false)
    expect(isDomainEnabled(c, 'vision')).toBe(true)
  })

  it('opt-out 优先于分域开关：即使分域全开也不可用', () => {
    const c: AiCapabilities = { ...on, optOut: true, onlineAllowed: true }
    for (const d of domains) expect(isDomainEnabled(c, d)).toBe(false)
  })
})
