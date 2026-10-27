import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import OverviewView from '../views/OverviewView.vue'
import ArchiveView from '../views/ArchiveView.vue'
import ProfileView from '../views/ProfileView.vue'
import LoginView from '../views/LoginView.vue'
import RegisterView from '../views/RegisterView.vue'
import UsersView from '../views/UsersView.vue'
import RolesView from '../views/RolesView.vue'
import AuditView from '../views/AuditView.vue'
import { getToken } from '../api/client'

declare module 'vue-router' {
  interface RouteMeta {
    /** 公开页面（无需登录），如登录页 */
    public?: boolean
    /** 管理类页面（需管理权限，前端仅作分组展示） */
    admin?: boolean
  }
}

const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/overview' },
  { path: '/overview', name: 'overview', component: OverviewView, meta: { title: '概览' } },
  { path: '/archive', name: 'archive', component: ArchiveView, meta: { title: '档案' } },
  { path: '/profile', name: 'profile', component: ProfileView, meta: { title: '个人主页' } },
  { path: '/users', name: 'users', component: UsersView, meta: { title: '用户管理', admin: true } },
  { path: '/roles', name: 'roles', component: RolesView, meta: { title: '角色与权限', admin: true } },
  { path: '/audit', name: 'audit', component: AuditView, meta: { title: '审计日志', admin: true } },
  { path: '/login', name: 'login', component: LoginView, meta: { title: '登录', public: true } },
  { path: '/register', name: 'register', component: RegisterView, meta: { title: '注册', public: true } },
  { path: '/:pathMatch(.*)*', redirect: '/overview' },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

// 未登录且访问非公开页面 → 跳登录，并带上原目标用于登录后回跳
router.beforeEach((to) => {
  const token = getToken()
  if (!to.meta.public && !token) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }
  return true
})

router.afterEach((to) => {
  const title = (to.meta.title as string | undefined) ?? ''
  document.title = title ? `${title} · AMS` : 'AMS · 个人档案管理系统'
})

export default router
