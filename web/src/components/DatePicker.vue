<script setup lang="ts">
/**
 * 自研日期选择器（替换原生 <input type="date">）
 *
 * 为什么不用原生：
 *   原生 `<input type="date">` 的日历面板由**浏览器**渲染（不在本项目 DOM 内），
 *   年份列表的滚动手感、动效、圆角都无法用 CSS/JS 调教 —— 用户反馈「阻力强、
 *   偏慢」的正是那一块。自研后滚动/动画/键盘可达性全部可控。
 *
 * 交互（对齐 iOS 日历）：day → 点头部的「2026年10月」→ year 列表 → 选年
 *   → month 网格 → 选月 → 回到 day 网格。
 *
 * 手感要点（apple-design）：
 *   ① 年份列表是本项目自己的滚动容器：`overscroll-behavior: contain` 防止
 *      滚动穿透，行样式极轻（无重边框/阴影），`will-change` 只给正在动的面板；
 *   ② 面板从触发点出现（transform-origin 跟随触发器），进出用同一条路径；
 *   ③ 只动 transform/opacity，prefers-reduced-motion 下降级为纯淡入。
 */
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { locale, t } from '../i18n'

/**
 * 月份 / 星期名按当前 locale 取（Intl），天然支持 zh-CN / en / fr，
 * 不再为每种语言硬编码数组；非中文下表头/月份网格改用「October 2026 / octobre 2026」语序。
 */
const MONTH_LONG = (i: number) =>
  new Intl.DateTimeFormat(locale.value, { month: 'long' }).format(new Date(2000, i, 1))
const MONTH_SHORT = (i: number) =>
  new Intl.DateTimeFormat(locale.value, { month: 'short' }).format(new Date(2000, i, 1))
// 2000-01-02 是周日（getDay()===0），故 2+i 对齐：0=Sun … 6=Sat
const WEEKDAY_SHORT = (i: number) =>
  new Intl.DateTimeFormat(locale.value, { weekday: 'short' }).format(new Date(2000, 0, 2 + i))
const isZh = computed(() => locale.value === 'zh-CN')

/**
 * 关闭默认属性继承：把 class / title / id 等透传到**真正的触发按钮**上。
 * 否则 `class="field-control"` 会落在包裹层，与触发器自带的边框叠成双边框。
 */
defineOptions({ inheritAttrs: false })

const props = withDefaults(
  defineProps<{
    /** yyyy-mm-dd，空串表示未选 */
    modelValue?: string
    placeholder?: string
    disabled?: boolean
    /** 可选的最早/最晚日期（yyyy-mm-dd） */
    min?: string
    max?: string
    id?: string
  }>(),
  {
    modelValue: '',
    placeholder: '',
    disabled: false,
    min: '',
    max: '',
    id: '',
  },
)

const emit = defineEmits<{
  (e: 'update:modelValue', v: string): void
  (e: 'change', v: string): void
}>()

/** 星期表头同样按 locale 走（非中文用 Intl 缩写，排版宽度稳定） */
const weekdays = computed(() =>
  isZh.value ? ['日', '一', '二', '三', '四', '五', '六'] : Array.from({ length: 7 }, (_, i) => WEEKDAY_SHORT(i)),
)

/** 年份可选范围：以当前年为中心，前后各 100 年 */
const YEAR_FROM = new Date().getFullYear() - 100
const YEAR_TO = new Date().getFullYear() + 100

const open = ref(false)
/** 'day' 日历 | 'month' 月份网格 | 'year' 年份列表 */
const view = ref<'day' | 'month' | 'year'>('day')
const rootEl = ref<HTMLElement | null>(null)
const triggerEl = ref<HTMLElement | null>(null)
const yearListEl = ref<HTMLElement | null>(null)

/** 当前查看的年月（与已选日期解耦：未选时默认今天所在月） */
function parseInitial(): { y: number; m: number } {
  const d = props.modelValue ? new Date(`${props.modelValue}T00:00:00`) : new Date()
  const ok = !Number.isNaN(d.getTime())
  return { y: ok ? d.getFullYear() : new Date().getFullYear(), m: ok ? d.getMonth() : new Date().getMonth() }
}
const initial = parseInitial()
const cursorYear = ref(initial.y)
const cursorMonth = ref(initial.m) // 0-11

const selected = computed(() => props.modelValue || '')

const displayText = computed(() => {
  if (!selected.value) return ''
  return selected.value
})

const headerText = computed(() => {
  if (view.value === 'year') return t('dp.titleYear', '选择年份')
  if (isZh.value) {
    return view.value === 'month'
      ? `${cursorYear.value}年`
      : `${cursorYear.value}年${cursorMonth.value + 1}月`
  }
  // 非中文：月份名在前（October 2026 / octobre 2026），避免把中文语序硬翻过去
  return view.value === 'month'
    ? String(cursorYear.value)
    : `${MONTH_LONG(cursorMonth.value)} ${cursorYear.value}`
})

/** 日历格子：前补空格 + 当月天数 */
const dayCells = computed<(number | null)[]>(() => {
  const first = new Date(cursorYear.value, cursorMonth.value, 1)
  const lead = first.getDay()
  const days = new Date(cursorYear.value, cursorMonth.value + 1, 0).getDate()
  const cells: (number | null)[] = Array.from({ length: lead }, () => null)
  for (let d = 1; d <= days; d++) cells.push(d)
  return cells
})

const years = computed(() => Array.from({ length: YEAR_TO - YEAR_FROM + 1 }, (_, i) => YEAR_FROM + i))

const monthNames = computed(() =>
  isZh.value
    ? Array.from({ length: 12 }, (_, i) => `${i + 1}月`)
    : Array.from({ length: 12 }, (_, i) => MONTH_SHORT(i)),
)

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

function toValue(y: number, m: number, d: number): string {
  return `${y}-${pad(m + 1)}-${pad(d)}`
}

function withinRange(v: string): boolean {
  if (props.min && v < props.min) return false
  if (props.max && v > props.max) return false
  return true
}

function isSelectedDay(d: number): boolean {
  return selected.value === toValue(cursorYear.value, cursorMonth.value, d)
}

const todayStr = (() => {
  const n = new Date()
  return toValue(n.getFullYear(), n.getMonth(), n.getDate())
})()

function pickDay(d: number): void {
  const v = toValue(cursorYear.value, cursorMonth.value, d)
  if (!withinRange(v)) return
  emit('update:modelValue', v)
  emit('change', v)
  close()
}

function pickMonth(m: number): void {
  cursorMonth.value = m
  view.value = 'day'
}

function pickYear(y: number): void {
  cursorYear.value = y
  view.value = 'month'
}

function shiftMonth(delta: number): void {
  let y = cursorYear.value
  let m = cursorMonth.value + delta
  if (m < 0) {
    m = 11
    y -= 1
  } else if (m > 11) {
    m = 0
    y += 1
  }
  cursorYear.value = y
  cursorMonth.value = m
}

function openPanel(): void {
  if (props.disabled) return
  const p = parseInitial()
  cursorYear.value = p.y
  cursorMonth.value = p.m
  view.value = 'day'
  open.value = true
  document.addEventListener('pointerdown', onDocPointerDown, true)
  document.addEventListener('keydown', onKeydown)
}

function close(): void {
  open.value = false
  document.removeEventListener('pointerdown', onDocPointerDown, true)
  document.removeEventListener('keydown', onKeydown)
  triggerEl.value?.focus?.()
}

function onDocPointerDown(e: PointerEvent): void {
  if (!rootEl.value?.contains(e.target as Node)) close()
}

function onKeydown(e: KeyboardEvent): void {
  if (e.key === 'Escape') {
    e.stopPropagation()
    close()
  }
}

/** 切到年份列表时，把当前年滚到可视区（不抢焦点，避免打断手势） */
watch(
  () => view.value,
  async (v) => {
    if (v !== 'year') return
    await nextTick()
    const el = yearListEl.value
    if (!el) return
    const idx = cursorYear.value - YEAR_FROM
    const rowH = 40
    el.scrollTop = Math.max(0, idx * rowH - el.clientHeight / 2 + rowH / 2)
  },
)

function clear(): void {
  emit('update:modelValue', '')
  emit('change', '')
  close()
}

function pickToday(): void {
  const n = new Date()
  const v = toValue(n.getFullYear(), n.getMonth(), n.getDate())
  if (!withinRange(v)) return
  emit('update:modelValue', v)
  emit('change', v)
  close()
}

onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', onDocPointerDown, true)
  document.removeEventListener('keydown', onKeydown)
})
</script>

<template>
  <div ref="rootEl" class="dp" :class="{ 'dp--disabled': disabled }">
    <button
      ref="triggerEl"
      v-bind="$attrs"
      type="button"
      class="dp__trigger"
      :disabled="disabled"
      :aria-expanded="open"
      aria-haspopup="dialog"
      @click="open ? close() : openPanel()"
    >
      <span :class="['dp__value', { 'dp__value--empty': !displayText }]">
        {{ displayText || placeholder || t('dp.placeholder', '选择日期') }}
      </span>
      <span class="dp__caret" aria-hidden="true">▾</span>
    </button>

    <Transition name="dp-pop">
      <div v-if="open" class="dp__panel" role="dialog" ::aria-label="t('dp.dialog', '选择日期')">
        <div class="dp__head">
          <button
            v-if="view === 'day'"
            type="button"
            class="dp__nav"
            ::aria-label="t('dp.prevMonth', '上一月')"
            @click="shiftMonth(-1)"
          >
            ‹
          </button>
          <button
            v-else-if="view === 'month'"
            type="button"
            class="dp__nav"
            ::aria-label="t('dp.prevYear', '上一年')"
            @click="cursorYear = cursorYear - 1"
          >
            ‹
          </button>
          <span v-else class="dp__nav" />

          <button type="button" class="dp__title" @click="view = 'year'">
            {{ headerText }}
          </button>

          <button
            v-if="view === 'day'"
            type="button"
            class="dp__nav"
            ::aria-label="t('dp.nextMonth', '下一月')"
            @click="shiftMonth(1)"
          >
            ›
          </button>
          <button
            v-else-if="view === 'month'"
            type="button"
            class="dp__nav"
            ::aria-label="t('dp.nextYear', '下一年')"
            @click="cursorYear = cursorYear + 1"
          >
            ›
          </button>
          <span v-else class="dp__nav" />
        </div>

        <!-- 年份列表：本项目自己的滚动容器（手感可控） -->
        <div v-if="view === 'year'" ref="yearListEl" class="dp__years">
          <button
            v-for="y in years"
            :key="y"
            type="button"
            class="dp__year"
            :class="{ 'dp__year--on': y === cursorYear }"
            @click="pickYear(y)"
          >
            {{ y }}
          </button>
        </div>

        <!-- 月份网格 -->
        <div v-else-if="view === 'month'" class="dp__months">
          <button
            v-for="(m, i) in monthNames"
            :key="m"
            type="button"
            class="dp__month"
            :class="{ 'dp__month--on': i === cursorMonth }"
            @click="pickMonth(i)"
          >
            {{ m }}
          </button>
        </div>

        <!-- 日历 -->
        <div v-else class="dp__cal">
          <div class="dp__weekdays">
            <span v-for="w in weekdays" :key="w" class="dp__weekday">{{ w }}</span>
          </div>
          <div class="dp__days">
            <template v-for="(d, i) in dayCells" :key="i">
              <span v-if="d === null" class="dp__day dp__day--blank" />
              <button
                v-else
                type="button"
                class="dp__day"
                :class="{
                  'dp__day--on': isSelectedDay(d),
                  'dp__day--today':
                    toValue(cursorYear, cursorMonth, d) === todayStr && !isSelectedDay(d),
                }"
                @click="pickDay(d)"
              >
                {{ d }}
              </button>
            </template>
          </div>
        </div>

        <div class="dp__foot">
          <button type="button" class="dp__btn" @click="pickToday">{{ t('dp.today', '今天') }}</button>
          <button type="button" class="dp__btn" @click="clear">{{ t('dp.clear', '清除') }}</button>
        </div>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.dp { position: relative; display: inline-block; width: 100%; }
.dp--disabled { opacity: 0.6; }
.dp__trigger {
  width: 100%; display: flex; align-items: center; justify-content: space-between;
  gap: var(--sp-2, 8px);
  padding: var(--sp-3, 12px);
  font: inherit; font-size: var(--font-size-md, 15px);
  color: var(--text-primary, #1f2937);
  background: var(--bg-surface, #fff);
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--g3-sm, 12px);
  cursor: pointer;
  transition: border-color var(--spring-fast,150ms) var(--ease-out-soft,ease),
    box-shadow var(--spring-fast,150ms) var(--ease-out-soft,ease);
}
.dp__trigger:hover:not(:disabled) { border-color: var(--accent, #2563eb); }
.dp__trigger:disabled { cursor: not-allowed; }
.dp__value--empty { color: var(--text-muted, #9ca3af); }
.dp__caret { color: var(--text-muted, #9ca3af); font-size: 12px; }
.dp__panel {
  position: absolute; z-index: 60; top: calc(100% + 6px); left: 0; width: 260px;
  padding: var(--sp-2, 8px);
  background: var(--bg-surface, #fff);
  border: 1px solid var(--border-subtle, #e5e7eb);
  border-radius: var(--g3-md, 18px);
  box-shadow: 0 12px 32px rgba(0,0,0,0.12);
  transform-origin: top left;
}
.dp__head { display:flex; align-items:center; justify-content:space-between; gap:var(--sp-1,4px); margin-bottom:var(--sp-2,8px); }
.dp__nav { width:28px; height:28px; display:inline-flex; align-items:center; justify-content:center; border:none; background:transparent; border-radius:var(--g3-xs,8px); color:var(--text-secondary,#4b5563); font-size:16px; cursor:pointer; }
.dp__title { flex:1; border:none; background:transparent; font-size:14px; font-weight:600; color:var(--text-primary,#1f2937); cursor:pointer; padding:4px; border-radius:var(--g3-xs,8px); }
.dp__years { height:220px; overflow-y:auto; overscroll-behavior:contain; -webkit-overflow-scrolling:touch; scrollbar-width:thin; border-radius:var(--g3-xs,8px); }
.dp__year { display:block; width:100%; height:40px; border:none; background:transparent; color:var(--text-primary,#1f2937); font-size:14px; border-radius:var(--g3-xs,8px); cursor:pointer; }
.dp__year--on { background:var(--accent,#2563eb); color:#fff; font-weight:600; }
.dp__months { display:grid; grid-template-columns:repeat(3,1fr); gap:var(--sp-1,4px); }
.dp__month { height:40px; border:none; background:transparent; border-radius:var(--g3-xs,8px); color:var(--text-primary,#1f2937); font-size:14px; cursor:pointer; }
.dp__month--on { background:var(--accent,#2563eb); color:#fff; font-weight:600; }
.dp__weekdays, .dp__days { display:grid; grid-template-columns:repeat(7,1fr); gap:2px; }
.dp__weekday { text-align:center; font-size:12px; color:var(--text-muted,#9ca3af); padding:4px 0; }
.dp__day { height:32px; display:inline-flex; align-items:center; justify-content:center; border:none; background:transparent; border-radius:var(--g3-xs,8px); font-size:13px; color:var(--text-primary,#1f2937); cursor:pointer; font-variant-numeric:tabular-nums; }
.dp__day--blank { cursor:default; }
.dp__day--today { outline:1px solid var(--accent,#2563eb); }
.dp__day--on { background:var(--accent,#2563eb); color:#fff; font-weight:600; }
.dp__foot { display:flex; justify-content:space-between; gap:var(--sp-2,8px); margin-top:var(--sp-2,8px); padding-top:var(--sp-2,8px); border-top:1px solid var(--border-subtle,#e5e7eb); }
.dp__btn { border:none; background:transparent; color:var(--accent,#2563eb); font-size:13px; cursor:pointer; padding:4px 8px; border-radius:var(--g3-xs,8px); }
.dp-pop-enter-active { transition: opacity var(--spring-fast,150ms) var(--ease-out-soft,ease), transform var(--spring-mid,200ms) var(--ease-apple,cubic-bezier(0.32,0.72,0,1)); }
.dp-pop-leave-active { transition: opacity var(--spring-fast,150ms) ease-in, transform var(--spring-fast,150ms) ease-in; }
.dp-pop-enter-from, .dp-pop-leave-to { opacity:0; transform:scale(0.96) translateY(-4px); }
@media (prefers-reduced-motion: reduce) {
  .dp-pop-enter-active, .dp-pop-leave-active { transition: opacity var(--spring-fast,150ms) ease; }
  .dp-pop-enter-from, .dp-pop-leave-to { transform:none; }
}
</style>

