<script setup lang="ts">
/**
 * AppSheet —— 通用浮层（Modal / Sheet）。
 *
 * Apple 质感要点（见 apple-design 技能 + docs §9.8）：
 *   - 材质：不透明实底 + 更强阴影承载层级。**不用 backdrop-filter**：
 *     它会把面板抬进合成层，层内表单小字失去 ClearType 而发虚/锯齿，
 *     且长表单滚动时逐帧重算模糊造成卡顿。
 *   - 圆角：统一 G3 scale（--g3-lg）
 *     注：Web 无标准 corner-style 属性，圆角实为圆弧（G1 连续）；
 *     真正的连续曲率需 SVG mask 等方案，属「美观 vs 性能」权衡，暂不全局启用。
 *   - 进场：从 0.96 缩放 + 淡入（临界阻尼、无过冲，等效 damping 1.0 / response 0.25）
 *   - 遮罩：--material-scrim，背后内容后退变暗
 *   - 焦点：打开时焦点移入、Tab 循环、Esc 关闭、关闭后焦点还原
 *   - 无障碍：role="dialog" aria-modal，body 滚动锁定
 */
import { ref, watch, onBeforeUnmount, nextTick } from 'vue'
import { t } from '../i18n'

const props = withDefaults(
  defineProps<{
    modelValue: boolean
    title?: string
    size?: 'sm' | 'md' | 'lg'
    dismissible?: boolean
  }>(),
  { size: 'md', dismissible: true },
)

const emit = defineEmits<{
  (e: 'update:modelValue', v: boolean): void
  (e: 'close'): void
}>()

const root = ref<HTMLElement | null>(null)
const panel = ref<HTMLElement | null>(null)
let lastFocused: HTMLElement | null = null

function close(): void {
  if (!props.dismissible) return
  emit('update:modelValue', false)
  emit('close')
}

function onKeydown(e: KeyboardEvent): void {
  if (e.key === 'Escape') {
    e.stopPropagation()
    close()
    return
  }
  if (e.key !== 'Tab' || !panel.value) return
  const focusables = panel.value.querySelectorAll<HTMLElement>(
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
  )
  if (focusables.length === 0) return
  const first = focusables[0]
  const last = focusables[focusables.length - 1]
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  }
}

function lockScroll(lock: boolean): void {
  document.body.style.overflow = lock ? 'hidden' : ''
}

watch(
  () => props.modelValue,
  async (open) => {
    if (open) {
      lastFocused = document.activeElement as HTMLElement
      lockScroll(true)
      await nextTick()
      document.addEventListener('keydown', onKeydown, true)
      // 焦点移入面板首个可聚焦元素
      const target = panel.value?.querySelector<HTMLElement>('[autofocus]') ??
        panel.value?.querySelector<HTMLElement>('input, button, [tabindex]')
      target?.focus()
    } else {
      document.removeEventListener('keydown', onKeydown, true)
      lockScroll(false)
      lastFocused?.focus?.()
      lastFocused = null
    }
  },
)

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown, true)
  lockScroll(false)
})
</script>

<template>
  <Teleport to="body">
    <Transition name="sheet">
      <div
        v-if="modelValue"
        ref="root"
        class="sheet-root"
        :class="{ 'sheet-root--sm': size === 'sm', 'sheet-root--lg': size === 'lg' }"
      >
        <div class="sheet-scrim" @click="dismissible && close()" />
        <div
          ref="panel"
          class="sheet-panel"
          role="dialog"
          aria-modal="true"
          :aria-label="title"
        >
          <header v-if="title || $slots.header" class="sheet-head">
            <slot name="header">
              <h2 class="sheet-title">{{ title }}</h2>
            </slot>
            <button
              v-if="dismissible"
              class="sheet-close"
              type="button"
              :aria-label="t('AppSheet.6c14bd', '关闭')"
              @click="close"
            >
              ✕
            </button>
          </header>

          <div class="sheet-body">
            <slot />
          </div>

          <footer v-if="$slots.footer" class="sheet-foot">
            <slot name="footer" />
          </footer>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.sheet-root {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--sp-4);
}

.sheet-scrim {
  position: absolute;
  inset: 0;
  background: var(--material-scrim);
  /* 不在遮罩上做 blur：它是覆盖全屏的固定层，内部滚动时 Chrome 会连带
     重算背景模糊，是长表单「滑动卡、钝」的主要来源之一。 */
}

.sheet-panel {
  position: relative;
  width: 100%;
  max-width: 520px;
  max-height: 86vh;
  display: flex;
  flex-direction: column;
  /* 面板内是高频滚动的长表单：用不透明实底替代 backdrop-filter。
     Apple 的 modal 材质本就该比顶栏更「实」，且能避免每帧重算模糊。 */
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  box-shadow: var(--shadow-pop);
  overflow: hidden;
  color: var(--text-primary);
}
.sheet-root--sm .sheet-panel { max-width: 380px; }
.sheet-root--lg .sheet-panel { max-width: 760px; }

.sheet-head {
  flex: none;
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-4) var(--sp-5);
  border-bottom: 1px solid var(--border-subtle);
  background: var(--bg-surface);
}
.sheet-title {
  margin: 0;
  font-size: var(--font-size-lg);
  font-weight: 600;
  flex: 1;
}
.sheet-close {
  border: none;
  background: var(--bg-hover);
  color: var(--text-secondary);
  width: 32px;
  height: 32px;
  border-radius: var(--g3-pill);
  font-size: 14px;
  line-height: 1;
  transition: background-color var(--spring-fast) ease-out, transform 100ms ease-out;
}
.sheet-close:hover { background: var(--border-strong); }
.sheet-close:active { transform: scale(0.92); }

.sheet-body {
  /* ⚠️ flex 列布局里子项默认 min-height:auto，不会收缩；缺 flex/min-height:0
     时内容会把 panel 撑过 max-height，底部 footer 被 overflow:hidden 裁掉
     （表现为「保存按钮只露一半」），且滚动落不到这个容器上。 */
  flex: 1 1 auto;
  min-height: 0;
  padding: var(--sp-5);
  overflow-y: auto;
  overscroll-behavior: contain;
  -webkit-overflow-scrolling: touch;
  /* ⚠️ 这里刻意不加 transform:translateZ(0)。滚动流畅已由
     「去掉 backdrop-filter + 头尾固定 + content-visibility」保证；
     把滚动容器抬进合成层会让其中所有表单文字失去 ClearType、
     改用灰度抗锯齿（小字明显发虚/锯齿），代价大于收益。 */
}

.sheet-foot {
  flex: none;
  display: flex;
  justify-content: flex-end;
  gap: var(--sp-3);
  padding: var(--sp-4) var(--sp-5);
  border-top: 1px solid var(--hairline);
  background: var(--bg-surface);
}

/* ---- 进场 / 退场（G3 连续 + 临界阻尼，无过冲）---- */
.sheet-enter-active,
.sheet-leave-active {
  transition: opacity var(--spring-mid) var(--ease-apple);
}
.sheet-enter-active .sheet-panel {
  transition: transform var(--spring-mid) var(--ease-apple),
    opacity var(--spring-mid) var(--ease-apple);
}
.sheet-leave-active .sheet-panel {
  transition: transform var(--spring-mid) var(--ease-apple),
    opacity var(--spring-mid) var(--ease-apple);
}
.sheet-enter-from,
.sheet-leave-to {
  opacity: 0;
}
.sheet-enter-from .sheet-panel {
  transform: scale(0.96) translateY(10px);
  opacity: 0;
}
.sheet-leave-to .sheet-panel {
  transform: scale(0.98) translateY(8px);
  opacity: 0;
}

@media (prefers-reduced-motion: reduce) {
  .sheet-enter-active,
  .sheet-leave-active,
  .sheet-enter-active .sheet-panel,
  .sheet-leave-active .sheet-panel {
    transition: opacity 200ms ease;
  }
  .sheet-enter-from .sheet-panel,
  .sheet-leave-to .sheet-panel {
    transform: none;
  }
}
</style>
