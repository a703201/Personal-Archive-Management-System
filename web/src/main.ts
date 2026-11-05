import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './styles/theme.css'
import './styles/motion.css'
import { vReveal } from './composables/useReveal'

createApp(App)
  .use(router)
  .directive('reveal', vReveal)
  .mount('#app')
