/**
 * 轻量 Toast 反馈（docs §9.7）。
 *
 * - 位置：底部（移动）/ 右上角（桌面）
 * - 材质：--material-sheet + --shadow-pop
 * - 进场：从边缘滑入 + 淡入（弹簧 damping 1.0 / response 0.3，无过冲）
 * - 时长：成功 3s，错误 5s（错误需手动关闭时传 duration:0）
 * - 堆叠：最多 3 条，超出替换最旧
 * - 可操作：支持「撤销」按钮（如删除后撤销）
 */
import { reactive } from 'vue'

export type ToastType = 'success' | 'error' | 'warning' | 'info'

export interface ToastItem {
  id: number
  type: ToastType
  message: string
  actionLabel?: string
  onAction?: () => void
  duration: number
}

const state = reactive<{ items: ToastItem[] }>({ items: [] })
const timers: Record<number, number> = {}
let seq = 1

export function useToast() {
  function remove(id: number): void {
    const i = state.items.findIndex((t) => t.id === id)
    if (i >= 0) state.items.splice(i, 1)
    if (timers[id]) {
      clearTimeout(timers[id])
      delete timers[id]
    }
  }

  function push(opts: {
    type?: ToastType
    message: string
    duration?: number
    actionLabel?: string
    onAction?: () => void
  }): number {
    const id = seq++
    const duration =
      opts.duration ?? (opts.type === 'error' ? 5000 : 3000)
    state.items.push({
      id,
      type: opts.type ?? 'info',
      message: opts.message,
      duration,
      actionLabel: opts.actionLabel,
      onAction: opts.onAction,
    })
    // 最多 3 条，超出替换最旧
    while (state.items.length > 3) {
      const old = state.items.shift()
      if (old && timers[old.id]) {
        clearTimeout(timers[old.id])
        delete timers[old.id]
      }
    }
    if (duration > 0) {
      timers[id] = window.setTimeout(() => remove(id), duration)
    }
    return id
  }

  const success = (m: string, d?: number) => push({ type: 'success', message: m, duration: d })
  const error = (m: string, d?: number) => push({ type: 'error', message: m, duration: d })
  const warning = (m: string, d?: number) => push({ type: 'warning', message: m, duration: d })
  const info = (m: string, d?: number) => push({ type: 'info', message: m, duration: d })

  return { items: state.items, push, success, error, warning, info, remove }
}
