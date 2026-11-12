<script setup lang="ts">
/**
 * 应用外壳。
 *
 * 布局遵循 FR-UX-003 四档断点（见 styles/theme.css）：
 *   mobile  竖排，导航在顶部
 *   tablet  竖排，内容限宽
 *   desktop 横排，左侧固定侧栏
 *   wide    横排，内容限宽居中
 *
 * 顶栏常驻全局搜索入口与主题开关（FR-UX-005 / FR-UX-002）。
 */
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { t } from './i18n'
import { RouterLink, RouterView, useRoute } from 'vue-router'
// 顶栏滚动状态：内容滚动后才浮现极淡的分界线（Apple 用边缘效果替代硬边框）。
// 高刷屏下 scroll 事件可达 120~144 次/秒，用 rAF 合并到每帧一次，且只在
// 布尔值真正翻转时才写 ref（避免无意义的响应式触发）。
const mainEl = ref<HTMLElement | null>(null)
const scrolled = ref(false)
let scrollRaf = 0
function onMainScroll(): void {
  if (scrollRaf) return
  scrollRaf = window.requestAnimationFrame(() => {
    scrollRaf = 0
    const next = (mainEl.value?.scrollTop ?? 0) > 4
    if (next !== scrolled.value) scrolled.value = next
  })
}
onBeforeUnmount(() => {
  if (scrollRaf) window.cancelAnimationFrame(scrollRaf)
})
import GlobalSearch from './components/GlobalSearch.vue'
import ToastHost from './components/ToastHost.vue'
import Onboarding from './components/Onboarding.vue'
import { useTheme } from './composables/useTheme'
import { api, getToken } from './api/client'
import { locale, setLocale, supported } from './i18n'

const route = useRoute()
const { resolved, mode, setMode, toggle } = useTheme()

/** 顶栏通知铃铛的未读数量（个人名下，权限 notify:read:own） */
const unread = ref(0)
async function loadUnread(): Promise<void> {
  try {
    const r = await api<{ count: number }>('/notifications/unread')
    unread.value = Number(r.count ?? 0)
  } catch {
    unread.value = 0
  }
}

/**
 * 管理类导航按真实权限逐模块显隐（后端仍是权威校验，前端仅决定入口）。
 * 注意：org_admin 未必含 audit:read，故不能用一个总开关。
 */
const canUsers = ref(false)
const canRoles = ref(false)
const canAudit = ref(false)
const canSystem = ref(false)
const hasAdmin = computed(
  () => canUsers.value || canRoles.value || canAudit.value || canSystem.value,
)

onMounted(async () => {
  if (!getToken()) return
  try {
    const me = await api<{ perms: string[] }>('/me')
    const p = me.perms ?? []
    loadUnread()
    canUsers.value = p.includes('user:read:any') || p.includes('user:manage')
    canRoles.value = p.includes('acl:manage')
    canAudit.value = p.includes('audit:read')
    canSystem.value = p.includes('system:admin')
  } catch {
    canUsers.value = false
    canRoles.value = false
    canAudit.value = false
    canSystem.value = false
  }
})
</script>

<template>
  <div v-if="!route.meta.public" class="app-shell">
    <a class="skip-link" href="#main-content">{{ t('App.01f027', '跳到主内容') }}</a>
    <!-- 侧栏：desktop 及以上显示 -->
      <aside class="sidebar">
      <div class="brand">
        <span class="brand__mark">A</span>
        <span class="brand__name">AMS</span>
      </div>
        <nav class="nav">
          <p class="nav__group">{{ t('App.2d7c0c', '个人') }}</p>
          <RouterLink class="nav__item" to="/archive">{{ t('App.3ca928', '档案') }}</RouterLink>
          <RouterLink class="nav__item" to="/overview">{{ t('App.506042', '概览') }}</RouterLink>
          <RouterLink class="nav__item" to="/notifications">
            {{ t('App.notificationsNav', '通知') }}
            <span v-if="unread > 0" class="nav__badge">{{ unread > 99 ? '99+' : unread }}</span>
          </RouterLink>
          <RouterLink class="nav__item" to="/import">{{ t('App.14b196', '批量导入') }}</RouterLink>
          <RouterLink class="nav__item" to="/templates">{{ t('App.dad23e', '条目模板') }}</RouterLink>
          <RouterLink class="nav__item" to="/family">{{ t('App.e686bb', '家庭协作') }}</RouterLink>
          <RouterLink class="nav__item" to="/tags">{{ t('App.4e02a9', '标签管理') }}</RouterLink>
          <RouterLink class="nav__item" to="/profile">{{ t('App.d04c1f', '个人主页') }}</RouterLink>
        <template v-if="hasAdmin">
          <p class="nav__group">{{ t('App.4989b5', '管理') }}</p>
          <RouterLink v-if="canUsers" class="nav__item" to="/users">{{ t('App.baf847', '用户管理') }}</RouterLink>
          <RouterLink v-if="canRoles" class="nav__item" to="/roles">{{ t('App.0c1a09', '角色与权限') }}</RouterLink>
          <RouterLink v-if="canAudit" class="nav__item" to="/audit">{{ t('App.7666cd', '审计日志') }}</RouterLink>
          <RouterLink v-if="canSystem" class="nav__item" to="/system">{{ t('App.08f206', '系统运维') }}</RouterLink>
        </template>
      </nav>
      <!-- 关于：固定在侧栏底部，任何权限都能查看 -->
      <div class="nav__footer">
        <p class="nav__group">{{ t('App.aboutGroup', '其他') }}</p>
        <RouterLink class="nav__item" to="/about">{{ t('App.about', '关于') }}</RouterLink>
      </div>
    </aside>

    <div class="app-body">
      <header class="topbar" :class="{ 'is-scrolled': scrolled }">
        <!-- 移动端顶部导航 -->
        <nav class="nav nav--inline">
          <RouterLink class="nav__item" to="/archive">{{ t('App.3ca928', '档案') }}</RouterLink>
          <RouterLink class="nav__item" to="/overview">{{ t('App.506042', '概览') }}</RouterLink>
          <RouterLink class="nav__item" to="/notifications">
            {{ t('App.notificationsNav', '通知') }}
            <span v-if="unread > 0" class="nav__badge">{{ unread > 99 ? '99+' : unread }}</span>
          </RouterLink>
          <RouterLink class="nav__item" to="/import">{{ t('App.60e2bc', '导入') }}</RouterLink>
          <RouterLink class="nav__item" to="/templates">{{ t('App.06d0f3', '模板') }}</RouterLink>
          <RouterLink class="nav__item" to="/family">{{ t('App.7cc8d6', '家庭') }}</RouterLink>
          <RouterLink class="nav__item" to="/tags">{{ t('App.tagsShort', '标签') }}</RouterLink>
          <RouterLink class="nav__item" to="/profile">{{ t('App.d04c1f', '个人主页') }}</RouterLink>
          <RouterLink v-if="canUsers" class="nav__item" to="/users">{{ t('App.9ba763', '用户') }}</RouterLink>
          <RouterLink v-if="canRoles" class="nav__item" to="/roles">{{ t('App.6b2669', '角色') }}</RouterLink>
          <RouterLink v-if="canAudit" class="nav__item" to="/audit">{{ t('App.3a96c5', '审计') }}</RouterLink>
          <RouterLink v-if="canSystem" class="nav__item" to="/system">{{ t('App.1a1f6d', '系统') }}</RouterLink>
          <RouterLink class="nav__item" to="/about">{{ t('App.about', '关于') }}</RouterLink>
        </nav>

        <div class="topbar__right">
          <RouterLink
            to="/notifications"
            class="bell"
            :aria-label="t('App.e1bb0c', `通知（${unread} 条未读）`, { count: unread })"
          >
            <svg class="bell__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9" />
              <path d="M13.7 21a2 2 0 0 1-3.4 0" />
            </svg>
            <span v-if="unread > 0" class="bell__badge">{{ unread > 99 ? '99+' : unread }}</span>
          </RouterLink>
          <GlobalSearch />
          <button
            class="theme-btn"
            type="button"
            :aria-label="resolved === 'dark' ? t('App.themeToLight', '切换到浅色') : t('App.themeToDark', '切换到深色')"
            @click="toggle"
          >
            <svg v-if="resolved === 'dark'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true">
              <circle cx="12" cy="12" r="4" />
              <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
            </svg>
            <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z" />
            </svg>
          </button>
          <select
            class="theme-select"
            :value="mode"
            :aria-label="t('App.c6e31a', '主题模式')"
            @change="setMode(($event.target as HTMLSelectElement).value as 'light' | 'dark' | 'system')"
          >
            <option value="light">{{ t('App.80ec9e', '浅色') }}</option>
            <option value="dark">{{ t('App.30b2c9', '深色') }}</option>
            <option value="system">{{ t('App.f4bbd9', '跟随系统') }}</option>
          </select>
          <select
            class="theme-select"
            :value="locale"
            :aria-label="t('App.cd99b2', '语言')"
            @change="setLocale(($event.target as HTMLSelectElement).value as 'zh-CN' | 'en' | 'fr')"
          >
            <option v-for="l in supported" :key="l" :value="l">{{ l === 'zh-CN' ? t('App.xa7bac2', '中文') : l === 'en' ? 'English' : 'Français' }}</option>
          </select>
        </div>
      </header>

      <main
        id="main-content"
        ref="mainEl"
        tabindex="-1"
        class="app-main"
        @scroll.passive="onMainScroll"
      >
        <RouterView v-slot="{ Component, route: currentRoute }">
          <Transition name="route" mode="out-in">
            <component :is="Component" :key="currentRoute.path" />
          </Transition>
        </RouterView>
      </main>
    </div>
  </div>
  <div v-else class="login-only">
    <RouterView v-slot="{ Component, route: currentRoute }">
      <Transition name="auth-fade" mode="out-in">
        <component :is="Component" :key="currentRoute.path" />
      </Transition>
    </RouterView>
  </div>
  <ToastHost />
  <Onboarding />
</template>

<style scoped>
.app-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
}

.sidebar {
  display: none;
}

.topbar {
  position: relative;
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-5);
  /* 顶栏用不透明实底：backdrop-filter 会把它抬进合成层，
     层内小字（导航、搜索框、下拉）会失去 ClearType 而发虚。
     层级改由实底色 + 滚动后浮现的极淡边缘线表达（见 motion.css ::after）。 */
  background: var(--bg-surface);
  flex-wrap: wrap;
}

.topbar__right {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  margin-left: auto;
}

.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: var(--sp-6) var(--sp-5) var(--sp-6);
}
.brand__mark {
  width: 30px;
  height: 30px;
  flex: none;
  border-radius: 9px;
  background: var(--text-primary);
  color: var(--bg-surface);
  display: grid;
  place-items: center;
  font-weight: 700;
  font-size: 15px;
  letter-spacing: -0.02em;
  box-shadow: none;
}
.brand__name {
  font-weight: 700;
  font-size: var(--font-size-lg);
  letter-spacing: -0.022em;
  color: var(--text-primary);
}

.nav {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 0 var(--sp-2);
}
.nav--inline {
  flex-direction: row;
  flex-wrap: wrap;
  gap: var(--sp-2) var(--sp-3);
  padding: 0;
}

/* 分组标题：小字号 + 略正字距（apple-design §15：小字不收紧） */
.nav__group {
  margin: var(--sp-3) var(--sp-3) var(--sp-1);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--text-muted);
}
.nav--inline .nav__group {
  display: none;
}
/* 侧栏底部：关于入口推到底部，与上方导航保持同一视觉语言 */
.nav__footer {
  margin-top: auto;
  padding-bottom: var(--sp-3);
}

.nav__item {
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--g3-sm);
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  /* Apple 字重阶梯只用 400 / 600 / 700，不用 500 */
  font-weight: 400;
  transition: background-color var(--spring-fast) var(--ease-out-soft),
    color var(--spring-fast) var(--ease-out-soft);
}
.nav__item:hover {
  background: var(--bg-hover);
}

/* 导航未读徽标 */
.nav__badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  height: 18px;
  padding: 0 5px;
  margin-left: var(--sp-1);
  font-size: 12px;
  font-weight: 600;
  line-height: 1;
  color: #fff;
  background: var(--danger);
  border-radius: var(--g3-pill);
}

/* 顶栏通知铃铛 */
.bell {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 38px;
  height: 38px;
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  border-radius: var(--g3-pill);
  cursor: pointer;
  color: var(--text-secondary);
}
.bell:hover {
  background: var(--bg-hover);
}
/* 单色线性图标（SF Symbols 风格），替代彩色 emoji */
.bell__icon {
  width: 18px;
  height: 18px;
  display: block;
}
.bell__badge {
  position: absolute;
  top: -6px;
  right: -6px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  height: 18px;
  padding: 0 5px;
  font-size: 12px;
  font-weight: 600;
  line-height: 1;
  color: #fff;
  background: var(--danger);
  border: 2px solid var(--bg-surface);
  border-radius: var(--g3-pill);
}
.nav__item.router-link-active {
  background: var(--bg-selected);
  color: var(--accent);
  font-weight: 600;
}

.theme-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 38px;
  height: 38px;
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  color: var(--text-primary);
  border-radius: var(--g3-pill);
  cursor: pointer;
}
.theme-btn:hover {
  background: var(--bg-hover);
}
.theme-btn svg {
  width: 18px;
  height: 18px;
  display: block;
}

.theme-select {
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  color: var(--text-primary);
  border-radius: var(--g3-sm);
  padding: var(--sp-2);
  font-size: var(--font-size-sm);
}

/* desktop：显示侧栏、隐藏顶部内联导航 */
@media (min-width: 1024px) {
  .sidebar {
    display: flex;
    flex-direction: column;
    width: 240px;
    /* 实底侧栏：同上，避免整列导航文字被抬进合成层后走灰度抗锯齿 */
    background: var(--bg-surface);
    border-right: 1px solid var(--hairline);
    flex-shrink: 0;
  }
  .nav--inline {
    display: none;
  }
}

/* 移动端：隐藏主题下拉（保留一键切换，节省横向空间） */
@media (max-width: 639px) {
  .theme-select {
    display: none;
  }
  .topbar {
    padding: var(--sp-2) var(--sp-3);
  }
}
</style>
