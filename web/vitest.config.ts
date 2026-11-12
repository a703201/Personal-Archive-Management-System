import { defineConfig } from 'vitest/config'

// 前端单测最小配置：纯逻辑测试，不需要 DOM / 浏览器环境。
// 被测模块若访问 localStorage / document / sessionStorage，由各测试文件
// 用 vi.stubGlobal 提供最小 stub，故这里保持 environment: 'node'。
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/__tests__/**/*.test.ts'],
    // Windows 上多个 worker 并发写 Vite SSR 转换缓存（同一临时文件）会偶发
    // EPERM；测试文件本就很小，关掉文件级并行换取稳定可复现的结果。
    fileParallelism: false,
  },
})
