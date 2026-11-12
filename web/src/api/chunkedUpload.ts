/**
 * 分片上传 / 断点续传客户端（FR-ATT-001 补齐）。
 *
 * 与后端 `ChunkUploadStore` 的 5 个端点一一对应。小文件仍走原来的
 * 单次 raw-body 上传（零回归），只有超过 1 MiB 才启用分片。
 *
 * 断点续传：会话 ID 存 sessionStorage，键由 文件名 + 大小 + 修改时间
 * 组成。页面刷新 / 网络中断后重新选同一个文件，会先查已收分片并跳过，
 * 不会重头再传。会话是服务端单实例内存态（TTL 24h），服务端重启后
 * status 查询失败会自动开新会话重传。
 */
import { api, getToken, ApiError } from './client'
import { t } from '../i18n'

/** 超过 1 MiB 走分片；以下仍走单次上传，保持原有行为 */
export const CHUNK_THRESHOLD = 1024 * 1024

export interface ChunkedUploadMeta {
  itemId?: number
  subjectId?: number
  fileName: string
  title: string
  category?: number
  summary?: string
  keywords?: string
}

interface CreateResp {
  uploadId: string
  chunkSize: number
  totalChunks: number
  totalSize: number
}

interface StatusResp {
  uploadId: string
  chunkSize: number
  totalChunks: number
  totalSize: number
  received: number[]
}

export interface CompleteResp {
  id: number
  dedupHit: boolean
  status: number
  bytes: number
}

export function shouldUseChunked(file: File): boolean {
  return file.size > CHUNK_THRESHOLD
}

function resumeKey(file: File): string {
  return `ams.upload.${file.name}.${file.size}.${file.lastModified}`
}

async function readError(res: Response): Promise<string> {
  const j = (await res.json().catch(() => ({}))) as { message?: string }
  return j.message || t('api.chunkedUploadFailed', `上传失败（${res.status}）`, { status: res.status })
}

/**
 * 失败是否「可恢复」（保留会话供下次续传）。
 * 网络错误 / 超时 / 429 / 408 / 5xx 可恢复；其余 4xx（参数错、会话不存在、
 * 未登录、越权）重试也不会成功，应释放会话，避免残留到 24h TTL。
 */
function isRecoverable(e: unknown): boolean {
  if (e instanceof ApiError) {
    const s = e.status
    if (s === 0 || s === 408 || s === 429 || s >= 500) return true
    return false
  }
  return true // 未知错误保守当作可恢复，不误删会话
}

async function putChunk(uploadId: string, index: number, blob: Blob): Promise<void> {
  const res = await fetch(
    `/api/attachments/upload/sessions/${encodeURIComponent(uploadId)}/chunks/${index}`,
    {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/octet-stream',
        Authorization: `Bearer ${getToken()}`,
      },
      body: blob,
      credentials: 'same-origin',
    },
  )
  if (!res.ok) throw new ApiError(res.status, 'CHUNK_FAILED', await readError(res))
}

/**
 * 上传一个文件。返回正式附件的 id。
 * onProgress(done, total) 在每一片（含跳过的片）后回调。
 */
export async function uploadChunked(
  file: File,
  meta: ChunkedUploadMeta,
  onProgress?: (done: number, total: number) => void,
): Promise<CompleteResp> {
  const key = resumeKey(file)
  let uploadId = sessionStorage.getItem(key) || ''
  let info: CreateResp | StatusResp | null = null

  try {
    if (uploadId) {
      try {
        info = await api<StatusResp>(`/attachments/upload/sessions/${encodeURIComponent(uploadId)}`)
      } catch (e) {
        // 登录失效交由外层清理；其余（会话过期 / 服务端重启 / 网络抖动）重开会话
        if (e instanceof ApiError && e.status === 401) throw e
        sessionStorage.removeItem(key)
        uploadId = ''
        info = null
      }
    }

    if (!uploadId || !info) {
      const created = await api<CreateResp>('/attachments/upload/sessions', {
        method: 'POST',
        body: {
          fileName: meta.fileName,
          title: meta.title,
          subjectId: meta.subjectId ?? 0,
          itemId: meta.itemId ?? 0,
          category: meta.category ?? 10,
          totalSize: file.size,
          summary: meta.summary ?? '',
          keywords: meta.keywords ?? '',
        },
      })
      uploadId = created.uploadId
      info = created
      sessionStorage.setItem(key, uploadId)
    }

    const chunkSize = info.chunkSize
    const totalChunks = info.totalChunks
    const received = new Set('received' in info ? info.received : [])

    for (let i = 0; i < totalChunks; i++) {
      if (!received.has(i)) {
        const blob = file.slice(i * chunkSize, Math.min(file.size, (i + 1) * chunkSize))
        await putChunk(uploadId, i, blob)
      }
      onProgress?.(i + 1, totalChunks)
    }

    const done = await api<CompleteResp>(
      `/attachments/upload/sessions/${encodeURIComponent(uploadId)}/complete`,
      { method: 'POST', timeoutMs: 0 },
    )
    sessionStorage.removeItem(key)
    return done
  } catch (e) {
    // 不可恢复失败（4xx 参数/权限/会话不存在等）：主动释放服务端会话并清
    // sessionStorage，避免会话与本地 ID 残留到 24h TTL。可恢复失败保留会话
    // 与 uploadId，下次重选同一文件即可续传。
    if (!isRecoverable(e)) await cancelChunkedUpload(file)
    throw e
  }
}

/** 用户取消 / 上传失败时可选择主动释放服务端会话 */
export async function cancelChunkedUpload(file: File): Promise<void> {
  const key = resumeKey(file)
  const uploadId = sessionStorage.getItem(key)
  if (!uploadId) return
  try {
    await api(`/attachments/upload/sessions/${encodeURIComponent(uploadId)}`, { method: 'DELETE' })
  } catch {
    // 会话可能已过期，忽略
  }
  sessionStorage.removeItem(key)
}
