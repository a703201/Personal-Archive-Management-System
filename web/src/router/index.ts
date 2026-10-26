import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import OverviewView from '../views/OverviewView.vue'
import ProfileView from '../views/ProfileView.vue'

const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/overview' },
  { path: '/overview', name: 'overview', component: OverviewView, meta: { title: '概览' } },
  { path: '/profile', name: 'profile', component: ProfileView, meta: { title: '个人主页' } },
  // 未登录/登录失效由 API 客户端抛 401，这里给一个明确的占位页，
  // 避免用户看到空白页面无从下手
  { path: '/login', name: 'login', component: OverviewView, meta: { title: '登录' } },
  { path: '/:pathMatch(.*)*', redirect: '/overview' },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

router.afterEach((to) => {
  const title = (to.meta.title as string | undefined) ?? ''
  document.title = title ? `${title} · AMS` : 'AMS · 个人档案管理系统'
})

export default router
