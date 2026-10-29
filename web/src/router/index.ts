import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import OverviewView from '../views/OverviewView.vue'
import ArchiveView from '../views/ArchiveView.vue'
import ImportView from '../views/ImportView.vue'
import ProfileView from '../views/ProfileView.vue'
import LoginView from '../views/LoginView.vue'
import RegisterView from '../views/RegisterView.vue'
import ForgotPasswordView from '../views/ForgotPasswordView.vue'
import UsersView from '../views/UsersView.vue'
import RolesView from '../views/RolesView.vue'
import AuditView from '../views/AuditView.vue'
import SystemView from '../views/SystemView.vue'
import NotificationView from '../views/NotificationView.vue'
import TagView from '../views/TagView.vue'
import TemplateView from '../views/TemplateView.vue'
import ShareView from '../views/ShareView.vue'
import FamilyView from '../views/FamilyView.vue'
import InviteView from '../views/InviteView.vue'
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
  { path: '/notifications', name: 'notifications', component: NotificationView, meta: { title: '通知' } },
  { path: '/archive', name: 'archive', component: ArchiveView, meta: { title: '档案' } },
  { path: '/templates', name: 'templates', component: TemplateView, meta: { title: '条目模板' } },
  { path: '/family', name: 'family', component: FamilyView, meta: { title: '家庭协作' } },
  { path: '/tags', name: 'tags', component: TagView, meta: { title: '标签管理' } },
  { path: '/import', name: 'import', component: ImportView, meta: { title: '批量导入' } },
  { path: '/profile', name: 'profile', component: ProfileView, meta: { title: '个人主页' } },
  { path: '/users', name: 'users', component: UsersView, meta: { title: '用户管理', admin: true } },
  { path: '/roles', name: 'roles', component: RolesView, meta: { title: '角色与权限', admin: true } },
  { path: '/audit', name: 'audit', component: AuditView, meta: { title: '审计日志', admin: true } },
  { path: '/system', name: 'system', component: SystemView, meta: { title: '系统运维', admin: true } },
  { path: '/login', name: 'login', component: LoginView, meta: { title: '登录', public: true } },
  { path: '/register', name: 'register', component: RegisterView, meta: { title: '注册', public: true } },
  {
    path: '/forgot',
    name: 'forgot',
    component: ForgotPasswordView,
    meta: { title: '找回口令', public: true },
  },
  // 共享页：接收方无需账号，token 本身就是凭据（FR-ACL-012）
  // ⚠️ 必须排在通配兜底之前，否则会被 redirect 到 /overview
  { path: '/share/:token', name: 'share', component: ShareView, meta: { title: '共享档案', public: true } },
  // 家庭邀请落地页：未登录也要能打开（先核对组名与邀请人，再要求登录）
  { path: '/invite/:token', name: 'invite', component: InviteView, meta: { title: '家庭邀请', public: true } },
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
