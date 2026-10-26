import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 后端开发端口（ams-server 默认 8080，见 ServerConfig）
const API_TARGET = process.env.AMS_API_TARGET ?? 'http://127.0.0.1:8080'

export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      // 前端只认同源 /api，跨域由 dev server 代理，生产由网关/Nginx 处理
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
