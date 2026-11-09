import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError, clearToken, getToken, setToken } from '../api/client'

type FetchImpl = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

/** 安装一个受控的 fetch stub（node 环境下 sessionStorage 也需 stub）。 */
function installFetch(impl: FetchImpl): void {
  vi.stubGlobal('fetch', vi.fn(impl))
}

/** 构造带 JSON 信封的 Response。 */
function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    statusText: status === 200 ? 'OK' : 'Error',
  })
}

beforeAll(() => {
  const store = new Map<string, string>()
  vi.stubGlobal('sessionStorage', {
    getItem: (k: string): string | null => store.get(k) ?? null,
    setItem: (k: string, v: string): void => {
      store.set(k, v)
    },
    removeItem: (k: string): void => {
      store.delete(k)
    },
    clear: (): void => {
      store.clear()
    },
  })
})

beforeEach(() => {
  clearToken()
})

describe('client · 令牌存取', () => {
  it('getToken / setToken / clearToken', () => {
    expect(getToken()).toBe('')
    setToken('tok-abc')
    expect(getToken()).toBe('tok-abc')
    clearToken()
    expect(getToken()).toBe('')
  })
})

describe('client · ApiError', () => {
  it('携带 status / code / message 且是 Error 子类', () => {
    const e = new ApiError(403, 'FORBIDDEN', '无权限')
    expect(e).toBeInstanceOf(Error)
    expect(e).toBeInstanceOf(ApiError)
    expect(e.name).toBe('ApiError')
    expect(e.status).toBe(403)
    expect(e.code).toBe('FORBIDDEN')
    expect(e.message).toBe('无权限')
  })
})

describe('client · api() 行为', () => {
  it('2xx 返回 data 并附带 Authorization 头', async () => {
    setToken('tok-2')
    let sentAuth = ''
    installFetch(async (_input, init) => {
      sentAuth = new Headers(init?.headers).get('Authorization') ?? ''
      return jsonResponse(200, { code: 'OK', message: '', data: { id: 7 } })
    })
    const data = await api<{ id: number }>('/items/7')
    expect(data).toEqual({ id: 7 })
    expect(sentAuth).toBe('Bearer tok-2')
  })

  it('401 且带令牌时清令牌并抛 UNAUTHORIZED', async () => {
    setToken('tok-1')
    installFetch(async () =>
      jsonResponse(401, { code: 'UNAUTHORIZED', message: '过期', data: null }),
    )
    await expect(api('/me')).rejects.toMatchObject({ status: 401, code: 'UNAUTHORIZED' })
    expect(getToken()).toBe('')
  })

  it('非 2xx 抛 ApiError 并透传 code / message', async () => {
    installFetch(async () =>
      jsonResponse(400, { code: 'VALIDATION_FAILED', message: '参数错误', data: null }),
    )
    let caught: unknown
    try {
      await api('/items')
    } catch (e) {
      caught = e
    }
    expect(caught).toBeInstanceOf(ApiError)
    const err = caught as ApiError
    expect(err.status).toBe(400)
    expect(err.code).toBe('VALIDATION_FAILED')
    expect(err.message).toBe('参数错误')
  })

  it('网络错误映射为 ApiError(NETWORK)', async () => {
    installFetch(async () => {
      throw new TypeError('fetch failed')
    })
    await expect(api('/x')).rejects.toMatchObject({ status: 0, code: 'NETWORK' })
  })

  it('超时映射为 ApiError(TIMEOUT)', async () => {
    installFetch(
      (_input, init) =>
        new Promise<Response>((_resolve, reject) => {
          // 真实定时器到点后 api() 会 ctrl.abort()，此处随 signal 一起 reject
          init?.signal?.addEventListener('abort', () => {
            reject(new Error('aborted'))
          })
        }),
    )
    await expect(api('/slow', { timeoutMs: 20 })).rejects.toMatchObject({
      status: 0,
      code: 'TIMEOUT',
    })
  })
})
