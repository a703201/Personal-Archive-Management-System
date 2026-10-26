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
import { RouterLink, RouterView } from 'vue-router'
import GlobalSearch from './components/GlobalSearch.vue'
import { useTheme } from './composables/useTheme'

const { resolved, mode, setMode, toggle } = useTheme()
</script>

<template>
  <div class="app-shell">
    <!-- 侧栏：desktop 及以上显示 -->
    <aside class="sidebar">
      <div class="brand">AMS</div>
      <nav class="nav">
        <RouterLink class="nav__item" to="/overview">概览</RouterLink>
        <RouterLink class="nav__item" to="/profile">个人主页</RouterLink>
      </nav>
    </aside>

    <div class="app-body">
      <header class="topbar">
        <!-- 移动端顶部导航 -->
        <nav class="nav nav--inline">
          <RouterLink class="nav__item" to="/overview">概览</RouterLink>
          <RouterLink class="nav__item" to="/profile">个人主页</RouterLink>
        </nav>

        <div class="topbar__right">
          <GlobalSearch />
          <button
            class="theme-btn"
            type="button"
            :aria-label="resolved === 'dark' ? '切换到浅色' : '切换到深色'"
            @click="toggle"
          >
            {{ resolved === 'dark' ? '☀' : '☾' }}
          </button>
          <select
            class="theme-select"
            :value="mode"
            aria-label="主题模式"
            @change="setMode(($event.target as HTMLSelectElement).value as 'light' | 'dark' | 'system')"
          >
            <option value="light">浅色</option>
            <option value="dark">深色</option>
            <option value="system">跟随系统</option>
          </select>
        </div>
      </header>

      <main class="app-main">
        <RouterView />
      </main>
    </div>
  </div>
</template>

<style scoped>
.app-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.sidebar {
  display: none;
}

.topbar {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border-subtle);
  position: sticky;
  top: 0;
  z-index: 10;
  flex-wrap: wrap;
}

.topbar__right {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  margin-left: auto;
}

.brand {
  font-weight: 700;
  font-size: var(--font-size-lg);
  padding: var(--sp-4);
  color: var(--accent);
}

.nav {
  display: flex;
  flex-direction: column;
  gap: var(--sp-1);
}
.nav--inline {
  flex-direction: row;
  gap: var(--sp-3);
}

.nav__item {
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--radius-sm);
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
}
.nav__item:hover {
  background: var(--bg-hover);
}
.nav__item.router-link-active {
  background: var(--bg-selected);
  color: var(--accent);
  font-weight: 600;
}

.theme-btn {
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  color: var(--text-primary);
  border-radius: var(--radius-md);
  padding: var(--sp-2) var(--sp-3);
  cursor: pointer;
}
.theme-btn:hover {
  background: var(--bg-hover);
}

.theme-select {
  border: 1px solid var(--border-subtle);
  background: var(--bg-surface);
  color: var(--text-primary);
  border-radius: var(--radius-md);
  padding: var(--sp-2);
  font-size: var(--font-size-sm);
}

/* desktop：显示侧栏、隐藏顶部内联导航 */
@media (min-width: 1024px) {
  .sidebar {
    display: flex;
    flex-direction: column;
    width: 200px;
    background: var(--bg-surface);
    border-right: 1px solid var(--border-subtle);
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
