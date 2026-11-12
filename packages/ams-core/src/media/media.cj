// ============================================================
// ams.core.media · 媒体能力门面（纯仓颉，进程内同步）
//
// 这是「OCR / 缩略图 / 像素水印」转正后的**主实现入口**：
//   · 不依赖 Python、不依赖外部进程、不监听端口；
//   · 由 AttachmentService 在进程内直接调用，结果落库 / 落文件存储；
//   · 保持「一个进程、一个端口」的既定部署形态。
//
// 支持矩阵（如实标注）：
//   PNG / BMP / JPEG (baseline + 渐进式)  解码 / OCR / 缩略图 / 像素水印  ✅
//   文本型 PDF            内容流 Tj/TJ 文本抽取                        ✅
//   图像型扫描 PDF        XObject / 内联图像流抽取 → 三路 OCR            ✅
//   CJK 印刷体            220 常用汉字 × 8 字体原型（构建期生成点阵）    ✅ 字典内字符
//   手写风格数字          10 个数字 × 9 原型（手写风格字体 + 形变）      ✅ 近似手写
//   BMP RLE/16-bit/OS2、算术编码 JPEG、12·16-bit、CMYK、加密 PDF        ❌
//   真实草书 / 生僻字 / 强倾斜 / 复杂排版 / 图像型 PDF 的 CJK 高精度识别  ❌（需外部模型）
//
// OCR 路由：MediaOcr.recognizeAutoWithEngine 依次尝试「5×7 印刷体字模 →
//   16×16 CJK 点阵字典 → 16×16 手写风格数字字典」，返回实际命中的引擎名。
//   点阵字典由 scripts/gen-media-glyphs.py 构建期生成，运行时不依赖字体/GDI/Python。
//
// 隐私：调用方必须先确认「OCR 显式同意」开关，本层不做隐私判断。
// ============================================================
package ams.core.media

import std.collection.*

/** 一次媒体处理的结果；数组为空表示该能力不可用。 */
public class MediaResult {
    public var ocrText: String
    /** 0 待处理 / 2 完成 / 3 失败或不支持 */
    public var ocrStatus: Int64
    public var ocrEngine: String
    public var thumbnail: Array<Byte>
    public var watermarked: Array<Byte>
    public var error: String

    public init() {
        this.ocrText = ""
        this.ocrStatus = 0
        this.ocrEngine = ""
        this.thumbnail = Array<Byte>(0, repeat: 0u8)
        this.watermarked = Array<Byte>(0, repeat: 0u8)
        this.error = ""
    }
}

public class MediaEngine {
    /** 按魔数判断输入类型。 */
    public static func sniff(data: Array<Byte>): String {
        if (data.size >= 8 && Int64(data[0]) == 0x89 && Int64(data[1]) == 0x50 &&
            Int64(data[2]) == 0x4E && Int64(data[3]) == 0x47) {
            return "png"
        }
        if (data.size >= 4 && Int64(data[0]) == 0x25 && Int64(data[1]) == 0x50 &&
            Int64(data[2]) == 0x44 && Int64(data[3]) == 0x46) {
            return "pdf"
        }
        if (data.size >= 2 && Int64(data[0]) == 0x42 && Int64(data[1]) == 0x4D) {
            return "bmp"
        }
        if (data.size >= 2 && Int64(data[0]) == 0xFF && Int64(data[1]) == 0xD8) {
            return "jpeg"
        }
        return "unknown"
    }

    /** 等比缩放（最近邻，保持整数像素）。 */
    public static func thumbnail(img: RasterImage, maxSide: Int64): RasterImage {
        if (img.width <= 0 || img.height <= 0 || maxSide <= 0) {
            return img
        }
        // 用整数运算避免浮点：newW = w * maxSide / max(w,h)
        let long = if (img.width > img.height) { img.width } else { img.height }
        var nw = (img.width * maxSide) / long
        var nh = (img.height * maxSide) / long
        if (nw < 1) { nw = 1 }
        if (nh < 1) { nh = 1 }
        if (nw >= img.width && nh >= img.height) {
            return img
        }
        let out = RasterImage(nw, nh, Array<Byte>(nw * nh * 3, repeat: 0u8))
        var y: Int64 = 0
        while (y < nh) {
            let sy = (y * img.height) / nh
            var x: Int64 = 0
            while (x < nw) {
                let sx = (x * img.width) / nw
                let s = (sy * img.width + sx) * 3
                let q = (y * nw + x) * 3
                out.pixels[q] = img.pixels[s]
                out.pixels[q + 1] = img.pixels[s + 1]
                out.pixels[q + 2] = img.pixels[s + 2]
                x = x + 1
            }
            y = y + 1
        }
        return out
    }

    /**
     * 把水印文字烧进像素：用内置字模渲染一张文字图，斜向平铺，
     * 以 42% 中灰混合。与原「前端 CSS 叠加」相比，这一步真正改了字节。
     */
    public static func burnWatermark(img: RasterImage, text: String): RasterImage {
        var label = text
        if (label.size > 80) {
            label = label[0..80]
        }
        if (label.size == 0) {
            label = "AMS"
        }
        let stamp = MediaOcr.render(label, 2, 0)
        if (stamp.width <= 0 || stamp.height <= 0) {
            return img
        }
        let out = RasterImage(img.width, img.height,
            Array<Byte>(img.pixels.size, repeat: 0u8))
        for (k in 0..img.pixels.size) {
            out.pixels[k] = img.pixels[k]
        }
        let stepX = stamp.width + 40
        let stepY = stamp.height + 34
        var y: Int64 = 8
        var row: Int64 = 0
        while (y < img.height) {
            var x: Int64 = -((row * 37) % stepX)
            while (x < img.width) {
                var sy: Int64 = 0
                while (sy < stamp.height) {
                    var sx: Int64 = 0
                    while (sx < stamp.width) {
                        let s = (sy * stamp.width + sx) * 3
                        if (Int64(stamp.pixels[s]) < 128) {
                            let dx = x + sx
                            let dy = y + sy
                            if (dx >= 0 && dx < img.width && dy >= 0 && dy < img.height) {
                                let q = (dy * img.width + dx) * 3
                                var c: Int64 = 0
                                while (c < 3) {
                                    let old = Int64(out.pixels[q + c])
                                    out.pixels[q + c] = UInt8((old * 58 + 128 * 42) / 100)
                                    c = c + 1
                                }
                            }
                        }
                        sx = sx + 1
                    }
                    sy = sy + 1
                }
                x = x + stepX
            }
            y = y + stepY
            row = row + 1
        }
        return out
    }

    /**
     * 进程内处理附件明文字节。
     * 任一能力失败不影响其它能力；不支持的格式通过 ocrStatus=3 明确告知调用方。
     */
    public static func process(data: Array<Byte>, wantOcr: Bool, wantThumb: Bool,
        wantWatermark: Bool, watermarkText: String): MediaResult {
        let r = MediaResult()
        let fmt = MediaEngine.sniff(data)
        if (fmt == "pdf") {
            let text = PdfText.extract(data)
            if (text.size > 0) {
                r.ocrText = text
                r.ocrEngine = "pdf-text"
                r.ocrStatus = 2
                return r
            }
            // 文本流为空 = 图像型扫描件：抽取 XObject / 内联图像流后逐张做三路 OCR。
            // PdfImage.extract 保证逐图失败只跳过、不中断；这里再包一层兜底。
            try {
                let images = PdfImage.extract(data)
                let sb = StringBuilder()
                var hasText = false
                var engine = ""
                var i: Int64 = 0
                while (i < images.size) {
                    let outcome = MediaOcr.recognizeAutoWithEngine(images[i])
                    if (outcome.text.size > 0) {
                        if (hasText) { sb.append("\n") }
                        sb.append(outcome.text)
                        hasText = true
                        if (engine.isEmpty()) { engine = outcome.engine }
                    }
                    i = i + 1
                }
                r.ocrText = sb.toString()
                r.ocrEngine = if (engine.isEmpty()) { "pdf-image" } else { "pdf-image+" + engine }
                r.ocrStatus = if (r.ocrText.size > 0) { 2 } else { 3 }
                if (r.ocrText.size == 0) {
                    r.error = "PDF 无可抽取文本流，图像流也未识别出文本（复杂扫描件需外部 OCR 模型）"
                }
            } catch (err: Exception) {
                r.ocrStatus = 3
                r.error = "PDF 图像流抽取失败：" + err.toString()
            }
            return r
        }
        if (fmt != "png" && fmt != "jpeg" && fmt != "bmp") {
            r.ocrStatus = 3
            r.error = "unsupported format: " + fmt
            return r
        }
        try {
            var img = RasterImage.white(1, 1)
            if (fmt == "jpeg") {
                img = JpegCodec.decode(data)
            } else if (fmt == "bmp") {
                img = BmpCodec.decode(data)
            } else {
                img = PngCodec.decode(data)
            }
            if (wantOcr) {
                // 三路路由：印刷体 5×7 → CJK 点阵 → 手写风格数字。
                // 印刷体命中时 engine 仍为 builtin-5x7，保持既有契约不变。
                let outcome = MediaOcr.recognizeAutoWithEngine(img)
                r.ocrText = outcome.text
                r.ocrEngine = outcome.engine
                r.ocrStatus = if (outcome.text.size > 0) { 2 } else { 3 }
            }
            if (wantThumb) {
                r.thumbnail = PngCodec.encode(MediaEngine.thumbnail(img, 256))
            }
            if (wantWatermark) {
                r.watermarked = PngCodec.encode(MediaEngine.burnWatermark(img, watermarkText))
            }
        } catch (err: Exception) {
            r.ocrStatus = 3
            r.error = err.toString()
        }
        return r
    }
}
