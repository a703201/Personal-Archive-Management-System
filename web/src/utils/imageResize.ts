/**
 * 图片上传前的自动缩放（AI 识别专用）。
 *
 * 背景：证书原图动辄 4000~7000px，base64 后 2MB+（触发 1MB 网关 413），
 * 且 CPU 模式下 3B 视觉模型处理超大图要数分钟。缩到长边 MAX_EDGE 后：
 *   - 请求体降到 ~200KB，不再 413
 *   - 视觉 token 大幅减少，推理时间从分钟级降到 ~1 分钟
 *
 * 不缩小小图（避免无谓重编码损失画质）；PDF 不处理（由后端明确拒绝）。
 */

const MAX_EDGE = 1600

/** 把图片文件缩到长边不超过 MAX_EDGE，返回 { base64（无 data URI 前缀）, width, height }。 */
export async function resizeImageForAi(file: File): Promise<{ data: string; width: number; height: number }> {
  const dataUrl = await readAsDataUrl(file)
  const img = await loadImage(dataUrl)

  const longest = Math.max(img.naturalWidth, img.naturalHeight)
  if (longest <= MAX_EDGE) {
    // 小图：直接返回原始 base64（去掉前缀）
    return {
      data: dataUrl.substring(dataUrl.indexOf(',') + 1),
      width: img.naturalWidth,
      height: img.naturalHeight,
    }
  }

  const scale = MAX_EDGE / longest
  const w = Math.max(1, Math.round(img.naturalWidth * scale))
  const h = Math.max(1, Math.round(img.naturalHeight * scale))
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    // canvas 不可用时退回原图（由后端/网关处理大小）
    return { data: dataUrl.substring(dataUrl.indexOf(',') + 1), width: img.naturalWidth, height: img.naturalHeight }
  }
  ctx.drawImage(img, 0, 0, w, h)
  const out = canvas.toDataURL('image/jpeg', 0.85)
  return { data: out.substring(out.indexOf(',') + 1), width: w, height: h }
}

function readAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result ?? ''))
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error('image_load_failed'))
    img.src = src
  })
}
