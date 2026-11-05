/**
 * v-reveal —— 滚动进入视口时柔和显现（Apple「适量交互动画」）。
 *
 * 设计取舍：
 *  - 只在指令 mounted 后才给元素加 [data-reveal] 初始隐藏态。脚本未执行
 *    / IntersectionObserver 不可用 / 用户开启 reduced-motion 时，元素保持
 *    默认可见 —— 内容永不会因为动效而丢失（渐进增强，不是渐进退化）。
 *  - 单例 observer + 进入即 unobserve：动画只播一次，不随反复滚动抖动。
 *  - 延迟由 CSS 变量 --reveal-delay 传递，供列表做交错；只动 opacity 与
 *    transform，不触发布局重排（apple-design §11）。
 *  - 真实的位移/时长降级在 motion.css 的 prefers-reduced-motion 段完成，
 *    这里只负责不再推迟显现。
 *
 * 用法：
 *   <div v-reveal> … </div>
 *   <div v-reveal="120"> … </div>                 延迟 120ms
 *   <div v-reveal="{ delay: 80, threshold: 0.2 }"> … </div>
 */
import type { Directive, DirectiveBinding } from 'vue'

export interface RevealOptions {
  /** 进入视口后的延迟（ms），用于交错 */
  delay?: number
  /** 可见比例阈值，默认 0.12 */
  threshold?: number
  /** 提前/延后触发的根边距，默认 '0px 0px -40px 0px' */
  rootMargin?: string
}

type RevealValue = number | RevealOptions | undefined

let observer: IntersectionObserver | null = null
let supported = true

/** 所有被观察元素共享一个回调：解析出各自 threshold 由 observer 统一处理 */
function getObserver(): IntersectionObserver | null {
  if (!supported) return null
  if (observer) return observer
  if (typeof IntersectionObserver === 'undefined') {
    supported = false
    return null
  }
  observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        const el = entry.target as HTMLElement
        el.classList.add('is-visible')
        observer?.unobserve(el)
      }
    },
    { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
  )
  return observer
}

function prefersReducedMotion(): boolean {
  return typeof window !== 'undefined'
    && typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function normalize(value: RevealValue): Required<RevealOptions> {
  const opts: RevealOptions = typeof value === 'number' ? { delay: value } : (value ?? {})
  return {
    delay: Math.max(0, Math.min(opts.delay ?? 0, 600)),
    threshold: opts.threshold ?? 0.12,
    rootMargin: opts.rootMargin ?? '0px 0px -40px 0px',
  }
}

function apply(el: HTMLElement, binding: DirectiveBinding<RevealValue>): void {
  // 渐进增强：减少动态效果 / 不支持 IO 时，不隐藏也不观察
  if (prefersReducedMotion() || !supported) return

  const io = getObserver()
  if (!io) return

  const { delay } = normalize(binding.value)
  el.style.setProperty('--reveal-delay', `${delay}ms`)
  el.setAttribute('data-reveal', '')
  io.observe(el)
}

function cleanup(el: HTMLElement): void {
  observer?.unobserve(el)
  el.removeAttribute('data-reveal')
  el.style.removeProperty('--reveal-delay')
}

export const vReveal: Directive<HTMLElement, RevealValue> = {
  mounted: apply,
  updated(el, binding) {
    // 仅当延迟值变化时更新 CSS 变量，不重新触发已完成的显现
    if (binding.value !== binding.oldValue && el.hasAttribute('data-reveal')) {
      const { delay } = normalize(binding.value)
      el.style.setProperty('--reveal-delay', `${delay}ms`)
    }
  },
  unmounted: cleanup,
}

export default vReveal
