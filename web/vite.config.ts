import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 后端开发端口（ams-server 默认 8080，见 ServerConfig）
const API_TARGET = process.env.AMS_API_TARGET ?? 'http://127.0.0.1:8080'

export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    // 监听所有网卡：便于手机/平板在局域网内访问做响应式验收，也避免仅绑 IPv6 时 127.0.0.1 无法访问
    host: true,
    proxy: {
      // 前端只写同源 /api。开发期由本 dev server 代理到 ams-server；
      // 生产期由 ams-server 自己在同一端口托管 web/dist，无需任何代理配置。
      '/api': {
        target: API_TARGET,
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
})
