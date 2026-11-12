import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

// i18n 模块在加载时就会访问 localStorage / document，且 watch() 回调在
// setLocale 后会再次访问两者。node 环境默认没有这些全局，故：
//   · 用 vi.stubGlobal 提供最小 stub；
//   · 用动态 import，确保 stub 生效后才求值模块；
//   · beforeEach 再 stub 一次，兼容 Vitest 在用例间恢复全局的行为。
// 另一个代理正在改 i18n，但承诺保持 t(key, fallback) 两参数兼容，
// 本文件只使用该形式，不依赖新加的可选参数。
type I18nModule = typeof import('../i18n')
let mod!: I18nModule

function applyStubs(): void {
  const store = new Map<string, string>()
  vi.stubGlobal('localStorage', {
    getItem: (k: string): string | null => store.get(k) ?? null,
    setItem: (k: string, v: string): void => {
      store.set(k, v)
    },
    removeItem: (k: string): void => {
      store.delete(k)
    },
    clear: (): void => {
      store.clear()
    },
  })
  // Vue runtime-dom 加载时会调用 document.createElement('template')；
  // i18n 初始化会调用 document.documentElement.setAttribute('lang', ...)。
  vi.stubGlobal('document', {
    documentElement: { setAttribute: (): void => {} },
    createElement: (): { innerHTML: string } => ({ innerHTML: '' }),
  })
  // navigator 由 Node 22 自带（language 为 zh-CN），无需 stub。
}

beforeAll(async () => {
  applyStubs()
  mod = await import('../i18n')
})

beforeEach(() => {
  applyStubs()
})

describe('i18n · t(key, fallback)', () => {
  it('查表命中目录中的词条', () => {
    mod.setLocale('zh-CN')
    const key = 'common.query'
    expect(mod.t(key, 'FALLBACK')).toBe(mod.catalogs['zh-CN'][key])
  })

  it('缺键回退到 fallback', () => {
    expect(mod.t('__vitest_missing_key__', '回退文案')).toBe('回退文案')
  })

  it('空串词条回退到 fallback', () => {
    mod.setLocale('en')
    mod.catalogs['en']['__vitest_empty__'] = ''
    expect(mod.t('__vitest_empty__', '空值回退')).toBe('空值回退')
  })

  it('含 ${ 的词条回退到 fallback', () => {
    mod.setLocale('en')
    mod.catalogs['en']['__vitest_tpl__'] = '共 ${count} 条'
    expect(mod.t('__vitest_tpl__', '已处理')).toBe('已处理')
  })

  it('setLocale 切换语言后取值变化', () => {
    mod.setLocale('zh-CN')
    const zh = mod.t('app.name', 'X')
    mod.setLocale('en')
    const en = mod.t('app.name', 'X')
    expect(mod.locale.value).toBe('en')
    expect(en).not.toBe(zh)
  })
})
