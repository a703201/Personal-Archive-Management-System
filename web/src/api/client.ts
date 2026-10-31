/**
 * 后端 API 客户端。
 *
 * 约定：
 *   ① 一律走同源 /api（dev 由 vite proxy 转发，生产由网关处理），
 *      不在前端拼后端绝对地址 —— 避免硬编码环境、也便于统一鉴权。
 *   ② 访问令牌只存 sessionStorage：关闭标签页即失效，
 *      降低 XSS 场景下的持久化泄漏面（刷新令牌由后端 HttpOnly 侧管理）。
 *   ③ 统一处理 401（跳登录）与非 2xx（抛 ApiError）。
 */

const TOKEN_KEY = 'ams.accessToken'

export function getToken(): string {
  return sessionStorage.getItem(TOKEN_KEY) ?? ''
}

export function setToken(token: string): void {
  sessionStorage.setItem(TOKEN_KEY, token)
}

export function clearToken(): void {
  sessionStorage.removeItem(TOKEN_KEY)
}

export class ApiError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
  }
}

/** 后端统一响应信封 */
interface Envelope<T> {
  code: string
  message: string
  data: T
  requestId?: string
}

/** 默认请求超时（ms）。口令校验类接口可自行放宽（见 LoginView）。 */
const DEFAULT_TIMEOUT_MS = 15000

export interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE'
  body?: unknown
  /** 是否附带令牌（登录接口不需要） */
  auth?: boolean
  signal?: AbortSignal
  /**
   * 超时毫秒数，默认 15s；传 0 表示不设限。
   *
   * 为什么必须有：没有超时的话，一旦请求挂起（网络抖断 / 后端卡死），
   * 上层会永远停在「登录中…」这类 loading 态 —— 用户既看不到错误，
   * 也无法重试，看起来就像「卡死了」。
   */
  timeoutMs?: number
}

export async function api<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const { method = 'GET', body, auth = true, signal, timeoutMs = DEFAULT_TIMEOUT_MS } = opts

  const headers: Record<string, string> = {
    Accept: 'application/json',
  }
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json'
  }
  const token = getToken()
  if (auth && token) {
    headers.Authorization = `Bearer ${token}`
  }

  const ctrl = new AbortController()
  let timedOut = false
  const timer =
    timeoutMs > 0
      ? setTimeout(() => {
          timedOut = true
          ctrl.abort()
        }, timeoutMs)
      : null
  // 调用方传入的 signal 优先：取消意图要能穿透到 fetch
  const forwardAbort = () => ctrl.abort()
  signal?.addEventListener('abort', forwardAbort)

  let res: Response
  try {
    res = await fetch(`/api${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: signal ?? ctrl.signal,
      credentials: 'same-origin',
    })
  } catch (e) {
    // 网络层失败靠 catch 区分：超时 / 调用方取消 / 真正的网络错误
    if (timedOut) {
      throw new ApiError(0, 'TIMEOUT', '请求超时，请检查网络后重试')
    }
    if ((e as Error)?.name === 'AbortError') {
      throw e // 调用方主动取消，原样透出
    }
    throw new ApiError(0, 'NETWORK', '网络连接失败，请稍后重试')
  } finally {
    if (timer) clearTimeout(timer)
    signal?.removeEventListener('abort', forwardAbort)
  }

  const text = await res.text()
  let payload: Envelope<T> | undefined
  try {
    payload = text ? (JSON.parse(text) as Envelope<T>) : undefined
  } catch {
    throw new ApiError(res.status, 'BAD_RESPONSE', '响应不是合法 JSON')
  }

  if (!res.ok) {
    // 401 有两种截然不同的语义，不能一律说成「登录已失效」：
    //   ① 带令牌的请求被拒 → 会话过期/失效，清令牌并提示重新登录；
    //   ② 登录这类「刻意不带令牌」的请求被拒 → 就是凭据错误，
    //      必须透传服务端文案（「用户名或口令错误」），
    //      否则用户会看到莫名其妙的「登录已失效」。
    if (res.status === 401 && auth) {
      clearToken()
      // 交给上层路由决定跳转，这里只抛出，避免与 vue-router 强耦合
      throw new ApiError(401, 'UNAUTHORIZED', '登录已失效，请重新登录')
    }
    throw new ApiError(res.status, payload?.code ?? 'ERROR', payload?.message ?? res.statusText)
  }

  if (!payload) {
    throw new ApiError(res.status, 'EMPTY', '空响应')
  }
  return payload.data
}

/**
 * 发送原始字节体（ZIP / CSV 等二进制或大文本）。
 *
 * 与 api() 分开的原因：
 *   ① 不能设 Content-Type: application/json，也不能 JSON.stringify；
 *   ② 上传 ZIP 时请求体可达数十 MB，复用 api() 会把整个 body 塞进
 *      JSON 字符串（膨胀并改变字节内容）。
 */
export async function apiBinary<T>(
  path: string,
  body: BodyInit,
  contentType: string,
  method: 'POST' = 'POST',
): Promise<T> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Content-Type': contentType,
  }
  const token = getToken()
  if (token) headers.Authorization = `Bearer ${token}`

  const res = await fetch(`/api${path}`, {
    method,
    headers,
    body,
    credentials: 'same-origin',
  })
  if (res.status === 401) {
    clearToken()
    throw new ApiError(401, 'UNAUTHORIZED', '登录已失效，请重新登录')
  }
  const text = await res.text()
  let payload: Envelope<T> | undefined
  try {
    payload = text ? (JSON.parse(text) as Envelope<T>) : undefined
  } catch {
    throw new ApiError(res.status, 'BAD_RESPONSE', '响应不是合法 JSON')
  }
  if (!res.ok) {
    throw new ApiError(res.status, payload?.code ?? 'ERROR', payload?.message ?? res.statusText)
  }
  if (!payload) {
    throw new ApiError(res.status, 'EMPTY', '空响应')
  }
  return payload.data
}

/** 下载（带鉴权头的 GET → Blob），用于任务错误报告 / 导出产物。 */
export async function apiBlob(path: string): Promise<Blob> {
  const headers: Record<string, string> = {}
  const token = getToken()
  if (token) headers.Authorization = `Bearer ${token}`
  const res = await fetch(`/api${path}`, { headers, credentials: 'same-origin' })
  if (res.status === 401) {
    clearToken()
    throw new ApiError(401, 'UNAUTHORIZED', '登录已失效，请重新登录')
  }
  if (!res.ok) {
    // 错误响应是 JSON 信封，这里取出 message 便于提示
    const t = await res.text()
    let msg = res.statusText
    try {
      const j = JSON.parse(t) as Envelope<unknown>
      msg = j.message || msg
    } catch {
      /* 忽略 */
    }
    throw new ApiError(res.status, 'ERROR', msg)
  }
  return res.blob()
}
