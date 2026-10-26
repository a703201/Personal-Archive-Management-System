/**
 * 主题（FR-UX-002 深浅色主题）。
 *
 * 取值：'light' | 'dark' | 'system'
 *   - system：跟随 prefers-color-scheme，随系统切换实时变化
 *   - 显式选择后写入 localStorage
 *
 * 说明：偏好本应持久化到后端 cfg_settings（后端已提供该表），
 * 但当前后端尚无「用户偏好」读写接口，故先落 localStorage；
 * 待接口就绪后把 persist() 换成一次 PUT 即可，组件代码无需改动。
 */
import { ref, computed, watch } from 'vue'

export type ThemeMode = 'light' | 'dark' | 'system'
export type ResolvedTheme = 'light' | 'dark'

const STORAGE_KEY = 'ams.theme'

const mode = ref<ThemeMode>(readMode())
const systemDark = ref<boolean>(matchMedia('(prefers-color-scheme: dark)').matches)

function readMode(): ThemeMode {
  const v = localStorage.getItem(STORAGE_KEY)
  if (v === 'light' || v === 'dark' || v === 'system') return v
  return 'system'
}

/** 实际生效的明暗（system 会解析成具体值） */
const resolved = computed<ResolvedTheme>(() => {
  if (mode.value === 'system') return systemDark.value ? 'dark' : 'light'
  return mode.value
})

function apply(): void {
  document.documentElement.setAttribute('data-theme', resolved.value)
}

export function useTheme() {
  function setMode(next: ThemeMode): void {
    mode.value = next
    localStorage.setItem(STORAGE_KEY, next)
  }

  function toggle(): void {
    setMode(resolved.value === 'dark' ? 'light' : 'dark')
  }

  return { mode, resolved, setMode, toggle }
}

// 监听系统与模式变化，实时反映到 <html data-theme>
watch([resolved], apply, { immediate: true })

const mq = matchMedia('(prefers-color-scheme: dark)')
mq.addEventListener('change', (e) => {
  systemDark.value = e.matches
})
