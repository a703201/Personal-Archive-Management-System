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
import { ref, computed, onMounted } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'
import GlobalSearch from './components/GlobalSearch.vue'
import ToastHost from './components/ToastHost.vue'
import { useTheme } from './composables/useTheme'
import { api, getToken } from './api/client'

const route = useRoute()
const { resolved, mode, setMode, toggle } = useTheme()

/**
 * 管理类导航按真实权限逐模块显隐（后端仍是权威校验，前端仅决定入口）。
 * 注意：org_admin 未必含 audit:read，故不能用一个总开关。
 */
const canUsers = ref(false)
const canRoles = ref(false)
const canAudit = ref(false)
const hasAdmin = computed(() => canUsers.value || canRoles.value || canAudit.value)

onMounted(async () => {
  if (!getToken()) return
  try {
    const me = await api<{ perms: string[] }>('/me')
    const p = me.perms ?? []
    canUsers.value = p.includes('user:read:any') || p.includes('user:manage')
    canRoles.value = p.includes('acl:manage')
    canAudit.value = p.includes('audit:read')
  } catch {
    canUsers.value = false
    canRoles.value = false
    canAudit.value = false
  }
})
</script>

<template>
  <div v-if="!route.meta.public" class="app-shell">
    <!-- 侧栏：desktop 及以上显示 -->
    <aside class="sidebar">
      <div class="brand">AMS</div>
      <nav class="nav">
        <p class="nav__group">个人</p>
        <RouterLink class="nav__item" to="/archive">档案</RouterLink>
        <RouterLink class="nav__item" to="/overview">概览</RouterLink>
        <RouterLink class="nav__item" to="/profile">个人主页</RouterLink>
        <template v-if="hasAdmin">
          <p class="nav__group">管理</p>
          <RouterLink v-if="canUsers" class="nav__item" to="/users">用户管理</RouterLink>
          <RouterLink v-if="canRoles" class="nav__item" to="/roles">角色与权限</RouterLink>
          <RouterLink v-if="canAudit" class="nav__item" to="/audit">审计日志</RouterLink>
        </template>
      </nav>
    </aside>

    <div class="app-body">
      <header class="topbar">
        <!-- 移动端顶部导航 -->
        <nav class="nav nav--inline">
          <RouterLink class="nav__item" to="/archive">档案</RouterLink>
          <RouterLink class="nav__item" to="/overview">概览</RouterLink>
          <RouterLink class="nav__item" to="/profile">个人主页</RouterLink>
          <RouterLink v-if="canUsers" class="nav__item" to="/users">用户</RouterLink>
          <RouterLink v-if="canRoles" class="nav__item" to="/roles">角色</RouterLink>
          <RouterLink v-if="canAudit" class="nav__item" to="/audit">审计</RouterLink>
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
  <div v-else class="login-only">
    <RouterView />
  </div>
  <ToastHost />
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
  /* Apple 材质：半透明玻璃层 + 模糊，承载层级（见 apple-design §12） */
  background: var(--material-toolbar);
  backdrop-filter: blur(var(--material-blur)) saturate(180%);
  -webkit-backdrop-filter: blur(var(--material-blur)) saturate(180%);
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
  padding: 0 var(--sp-2);
}
.nav--inline {
  flex-direction: row;
  gap: var(--sp-3);
  padding: 0;
}

/* 分组标题：小字号 + 略正字距（apple-design §15：小字不收紧） */
.nav__group {
  margin: var(--sp-3) var(--sp-3) var(--sp-1);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--text-muted);
}
.nav--inline .nav__group {
  display: none;
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
    width: 220px;
    background: var(--material-sidebar);
    backdrop-filter: blur(var(--material-blur)) saturate(180%);
    -webkit-backdrop-filter: blur(var(--material-blur)) saturate(180%);
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
