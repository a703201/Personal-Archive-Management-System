import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './styles/theme.css'
import './styles/motion.css'
import { vReveal } from './composables/useReveal'
import { useToast } from './composables/useToast'
import { t } from './i18n'

const app = createApp(App)

// 渲染期异常的全局兜底：此前组件抛错会直接白屏且无任何提示。
// 这里统一给出可见反馈并留一条控制台痕迹，便于排障。
app.config.errorHandler = (err, _instance, info) => {
  console.error('[AMS] render error:', info, err)
  useToast().error(t('main.renderError', '页面出现异常，请刷新后重试'))
}

// 未被 catch 的 Promise 拒绝（含 chunk 加载之外的异步失败）。
window.addEventListener('unhandledrejection', (event) => {
  console.error('[AMS] unhandled rejection:', event.reason)
  useToast().error(t('main.unhandledError', '操作未完成，请稍后重试'))
})

app
  .use(router)
  .directive('reveal', vReveal)
  .mount('#app')
