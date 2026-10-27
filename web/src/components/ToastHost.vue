<script setup lang="ts">
/**
 * Toast 宿主（docs §9.7）。
 * 全局只挂一次：在 App.vue 中 <ToastHost />。
 */
import { useToast } from '../composables/useToast'

const { items, remove } = useToast()

const ICONS: Record<string, string> = {
  success: '✓',
  error: '!',
  warning: '⚠',
  info: 'i',
}
</script>

<template>
  <Teleport to="body">
    <div class="toast-host" aria-live="polite">
      <TransitionGroup name="toast">
        <div
          v-for="t in items"
          :key="t.id"
          class="toast"
          :class="`toast--${t.type}`"
          role="status"
        >
          <span class="toast__icon" aria-hidden="true">{{ ICONS[t.type] }}</span>
          <span class="toast__msg">{{ t.message }}</span>
          <button
            v-if="t.actionLabel"
            class="toast__action"
            type="button"
            @click="t.onAction?.(); remove(t.id)"
          >
            {{ t.actionLabel }}
          </button>
          <button
            v-if="t.duration === 0 || t.type === 'error'"
            class="toast__close"
            type="button"
            aria-label="关闭提示"
            @click="remove(t.id)"
          >
            ✕
          </button>
        </div>
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<style scoped>
.toast-host {
  position: fixed;
  z-index: 1200;
  left: 50%;
  transform: translateX(-50%);
  bottom: var(--sp-4);
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
  width: calc(100% - 32px);
  max-width: 420px;
  pointer-events: none;
}

.toast {
  pointer-events: auto;
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
  background: var(--material-sheet);
  backdrop-filter: blur(var(--material-blur)) saturate(180%);
  -webkit-backdrop-filter: blur(var(--material-blur)) saturate(180%);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-md);
  box-shadow: var(--shadow-pop);
  color: var(--text-primary);
  font-size: var(--font-size-sm);
  corner-style: continuous;
}

.toast__icon {
  flex-shrink: 0;
  width: 22px;
  height: 22px;
  border-radius: var(--g3-pill);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 700;
  color: #fff;
}
.toast--success .toast__icon { background: var(--success); }
.toast--error .toast__icon { background: var(--danger); }
.toast--warning .toast__icon { background: var(--warning); }
.toast--info .toast__icon { background: var(--accent); }

.toast__msg { flex: 1; }

.toast__action {
  border: none;
  background: transparent;
  color: var(--accent);
  font-weight: 600;
  padding: var(--sp-1) var(--sp-2);
  border-radius: var(--radius-sm);
}
.toast__action:hover { background: var(--bg-hover); }

.toast__close {
  border: none;
  background: transparent;
  color: var(--text-muted);
  font-size: 13px;
  padding: var(--sp-1);
  border-radius: var(--radius-sm);
}
.toast__close:hover { background: var(--bg-hover); }

/* 进场：从底部滑入 + 淡入（临界阻尼，无过冲） */
.toast-enter-active,
.toast-leave-active {
  transition: transform var(--spring-mid) var(--ease-apple),
    opacity var(--spring-mid) var(--ease-apple);
}
.toast-enter-from,
.toast-leave-to {
  opacity: 0;
  transform: translateY(16px);
}
.toast-leave-active {
  position: absolute;
  width: 100%;
}

/* 桌面：右上角，从顶部滑入 */
@media (min-width: 1024px) {
  .toast-host {
    left: auto;
    right: var(--sp-4);
    transform: none;
    bottom: auto;
    top: var(--sp-4);
    align-items: flex-end;
  }
  .toast-enter-from,
  .toast-leave-to {
    transform: translateY(-16px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .toast-enter-active,
  .toast-leave-active {
    transition: opacity 200ms ease;
  }
  .toast-enter-from,
  .toast-leave-to {
    transform: none;
  }
}
</style>
