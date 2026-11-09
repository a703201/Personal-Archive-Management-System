import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { watch } from 'vue'
import { api, getToken } from '../api/client'
import { t, locale } from '../i18n'

declare module 'vue-router' {
  interface RouteMeta {
    /** 公开页面（无需登录），如登录页 */
    public?: boolean
    /** 管理类页面（需管理权限，前端仅作分组展示） */
    admin?: boolean
    /** 文档标题；用函数以便切换语言时重新求值 */
    title?: string | (() => string)
  }
}

// 路由级代码分割：每个视图独立成 chunk，首屏只加载当前页，降低初始 JS 体积。
const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/overview' },
  { path: '/overview', name: 'overview', component: () => import('../views/OverviewView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.overview', '概览') } },
  { path: '/notifications', name: 'notifications', component: () => import('../views/NotificationView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.notifications', '通知') } },
  { path: '/archive', name: 'archive', component: () => import('../views/ArchiveView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.archive', '档案') } },
  { path: '/templates', name: 'templates', component: () => import('../views/TemplateView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.templates', '条目模板') } },
  { path: '/family', name: 'family', component: () => import('../views/FamilyView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.family', '家庭协作') } },
  { path: '/tags', name: 'tags', component: () => import('../views/TagView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.tags', '标签管理') } },
  { path: '/import', name: 'import', component: () => import('../views/ImportView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.import', '批量导入') } },
  { path: '/profile', name: 'profile', component: () => import('../views/ProfileView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.profile', '个人主页') } },
  { path: '/users', name: 'users', component: () => import('../views/UsersView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.users', '用户管理'), admin: true } },
  { path: '/roles', name: 'roles', component: () => import('../views/RolesView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.roles', '角色与权限'), admin: true } },
  { path: '/audit', name: 'audit', component: () => import('../views/AuditView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.audit', '审计日志'), admin: true } },
  { path: '/system', name: 'system', component: () => import('../views/SystemView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.system', '系统运维'), admin: true } },
  { path: '/about', name: 'about', component: () => import('../views/AboutView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.about', '关于') } },
  { path: '/login', name: 'login', component: () => import('../views/LoginView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.login', '登录'), public: true } },
  { path: '/register', name: 'register', component: () => import('../views/RegisterView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.register', '注册'), public: true } },
  {
    path: '/forgot',
    name: 'forgot',
    component: () => import('../views/ForgotPasswordView.vue').catch(() => import('../views/LoadFailedView.vue')),
    meta: { title: () => t('route.forgot', '找回口令'), public: true },
  },
  // 共享页：接收方无需账号，token 本身就是凭据（FR-ACL-012）
  // ⚠️ 必须排在通配兜底之前，否则会被 redirect 到 /overview
  { path: '/share/:token', name: 'share', component: () => import('../views/ShareView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.share', '共享档案'), public: true } },
  // 家庭邀请落地页：未登录也要能打开（先核对组名与邀请人，再要求登录）
  { path: '/invite/:token', name: 'invite', component: () => import('../views/InviteView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.invite', '家庭邀请'), public: true } },
  // 首次部署初始化向导：公开，但后端完成初始化后接口会拒绝，守卫也会挡回登录页
  { path: '/setup', name: 'setup', component: () => import('../views/SetupView.vue').catch(() => import('../views/LoadFailedView.vue')), meta: { title: () => t('route.setup', '首次部署'), public: true } },
  {
    path: '/:pathMatch(.*)*',
    name: 'not-found',
    component: () => import('../views/NotFoundView.vue').catch(() => import('../views/LoadFailedView.vue')),
    meta: { title: () => t('route.notFound', '页面不存在'), public: true },
  },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

/**
 * 首次部署状态：模块级缓存，避免每次导航都打 /setup/status。
 * 后端为旧版本（无该接口）时按「已初始化」处理 —— 行为与改造前完全一致。
 * 向导完成后用整页跳转清缓存，无需额外导出重置函数。
 */
let setupChecked = false
let setupRequired = false
let setupPending: Promise<boolean> | null = null

function checkSetup(): Promise<boolean> {
  if (setupChecked) return Promise.resolve(setupRequired)
  if (setupPending) return setupPending
  setupPending = api<{ initialized: boolean }>('/setup/status', { auth: false })
    .then((s) => { setupRequired = !s.initialized; return setupRequired })
    .catch(() => { setupRequired = false; return false })
    .finally(() => { setupChecked = true; setupPending = null })
  return setupPending
}

// 未登录且访问非公开页面 → 跳登录，并带上原目标用于登录后回跳；
// 尚未初始化时优先引导到向导，避免在无账号状态下空转。
router.beforeEach(async (to) => {
  const needSetup = await checkSetup()
  if (to.path === '/setup') {
    return needSetup ? true : { name: 'login' }
  }
  if (to.meta.public) {
    if (needSetup && (to.path === '/login' || to.path === '/register' || to.path === '/forgot')) {
      return { path: '/setup' }
    }
    return true
  }
  if (!getToken()) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  if (needSetup) return { path: '/setup' }
  return true
})

function syncTitle(): void {
  const raw = router.currentRoute.value.meta.title
  const title = typeof raw === 'function' ? raw() : (typeof raw === 'string' ? raw : '')
  document.title = title ? `${title} · AMS` : 'AMS · 个人档案管理系统'
}

router.afterEach(syncTitle)

// 切换语言后同步刷新当前标签标题，无需重新导航
watch(locale, syncTitle)

export default router
