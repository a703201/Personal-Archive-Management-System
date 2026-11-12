// ============================================================
// ams.core.media · OCR 三路路由与印刷体识别（纯仓颉实现）
//
// 【定位】
//   面向档案场景的进程内 OCR。5×7 印刷体字模负责「证件号 / 日期 /
//   编号」等**等宽印刷体数字与大写字母**：灰度化 → 自适应二值化 →
//   水平投影分行 → 垂直投影分字 → 归一化到 5×7 → 点阵汉明距离匹配。
//   另两路为 16×16 CJK 字典（CjkOcr）与手写风格数字字典（HandOcr），
//   由 recognizeAuto / recognizeAutoWithEngine 按置信度三路路由。
//
// 【内置三路 + 可选外部引擎】
//   默认仍是纯仓颉的三路字模（构建期生成位串，整数运算，可复现、
//   可单测、无网络调用），保持「一个进程、一个端口、零外部依赖」的
//   部署形态。另提供**可选**的外部 PP-OCRv5 引擎（见 ocr_ext.cj +
//   native/ocr_ext/ 的 C 桥接层）：仅当 AMS_OCR_ENGINE=external 且
//   初始化成功时启用，识别失败/未启用会自动回退到内置三路。外部引擎
//   以 .so 形式随镜像分发，无独立进程/端口/网络，部署形态不变。
//
// 【三路路由（recognizeAuto）】
//   printed = recognize(img)（5×7）；confidence(printed) >= 60 直接用；
//   否则尝试 CJK 字典（非空即用）；再否则尝试手写数字字典（非空即用）；
//   都为空则回退 printed。engine 字段如实标注实际采用的那一路。
//
// 【诚实的能力边界】
//   · 5×7 字模 + 16×16 CJK/手写点阵字典三路路由，字典仅覆盖 220 个
//     常用汉字与 10 个手写风格数字；
//   · 这些是印刷 / 手写风格字体点阵，不是训练式识别模型：真实草书 /
//     生僻字 / 复杂排版 / 强倾斜 / 多字体混排仍需外部模型；
//   · 输入格式分流（PNG / JPEG / PDF / BMP）由 MediaEngine.sniff 决定，
//     本识别器只接收已解码的 RasterImage；
//   · PDF 走 PdfText 的文本流抽取，不走本识别器；
//   · 真实扫描件若字体与内置字模差异较大，识别率会下降；
//   · 强需求已内置可选外部引擎（PP-OCRv5，默认关闭 + 自动回退），
//     详见 ocr_ext.cj 与 native/ocr_ext/。
//
// 【二值化取舍】
//   用「灰度极值中点」而非 Otsu：纯仓颉下 Otsu 的类间方差用 Int64
//   会溢出（大图 wB*wF*diff² 可超过 2^63），而极值中点对白底黑字
//   文档图同样稳定，且完全整数运算、无浮点依赖。
// ============================================================
package ams.core.media

import std.collection.*

public class MediaOcr {
    private static let ALPHABET: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-./:"
    private static let GLYPHS: Array<String> = [
        "01110100011001110101110011000101110",
        "00100011000010000100001000010001110",
        "01110100010000100010001000100011111",
        "11111000100010000010000011000101110",
        "00010001100101010010111110001000010",
        "11111100001111000001000011000101110",
        "00110010001000011110100011000101110",
        "11111000010001000100010000100001000",
        "01110100011000101110100011000101110",
        "01110100011000101111000010001001100",
        "01110100011000111111100011000110001",
        "11110100011000111110100011000111110",
        "01111100001000010000100001000001111",
        "11110100011000110001100011000111110",
        "11111100001000011110100001000011111",
        "11111100001000011110100001000010000",
        "01111100001000010111100011000101111",
        "10001100011000111111100011000110001",
        "01110001000010000100001000010001110",
        "00111000100001000010100101001001100",
        "10001100101010011000101001001010001",
        "10000100001000010000100001000011111",
        "10001110111010110101100011000110001",
        "10001110011010110011100011000110001",
        "01110100011000110001100011000101110",
        "11110100011000111110100001000010000",
        "01110100011000110001101011001001101",
        "11110100011000111110101001001010001",
        "01111100001000001110000010000111110",
        "11111001000010000100001000010000100",
        "10001100011000110001100011000101110",
        "10001100011000110001100010101000100",
        "10001100011000110101101011101110001",
        "10001100010101000100010101000110001",
        "10001100010101000100001000010000100",
        "11111000010001000100010001000011111",
        "00000000000000011111000000000000000",
        "00000000000000000000000000110001100",
        "00001000100001000100010000100010000",
        "00000011000110000000011000110000000"
    ]

    /** 单张图最多识别的字符数，防止超大图撑爆输出。 */
    private static let MAX_CHARS: Int64 = 512

    private static func indexOf(ch: String): Int64 {
        var i: Int64 = 0
        while (i < MediaOcr.ALPHABET.size) {
            if (MediaOcr.ALPHABET[i..(i + 1)] == ch) {
                return i
            }
            i = i + 1
        }
        return -1
    }

    /**
     * 字节 → 单字符 String（ASCII 大写化，避免依赖不确定的大小写 API）。
     *
     * 非 ASCII（如水印分隔符 U+00B7 `·`、中文）一律跳过：返回空串，
     * 由 render 的 `indexOf` 得到 -1 后跳过该字。若对 ≥0x80 的码点直接
     * `String.fromUtf8([单字节])` 会抛 `Invalid utf8 byte sequence`
     * （续字节不能单独成字），导致水印绘制整体失败（ocamlStatus=3）。
     */
    private static func upperByte(b: Int64): String {
        var v = b
        if (v < 0 || v > 127) {
            return ""
        }
        if (v >= 97 && v <= 122) {
            v = v - 32
        }
        let one = Array<Byte>(1, repeat: UInt8(v))
        return String.fromUtf8(one)
    }

    /**
     * 用内置字模把文本渲染成白底黑字图。
     * 既是单测夹具（渲染 → 编码 → 解码 → 识别闭环），也是水印绘制的基础。
     */
    public static func render(text: String, scale: Int64, pad: Int64): RasterImage {
        let idx = ArrayList<Int64>()
        var i: Int64 = 0
        while (i < text.size) {
            idx.add(MediaOcr.indexOf(MediaOcr.upperByte(Int64(text[i]))))
            i = i + 1
        }
        let cw = 5 * scale
        let gap = scale
        let w = pad * 2 + idx.size * (cw + gap)
        let h = pad * 2 + 7 * scale
        let img = RasterImage.white(w, h)
        var ci: Int64 = 0
        while (ci < idx.size) {
            let gi = idx[ci]
            if (gi >= 0) {
                let s = MediaOcr.GLYPHS[gi]
                var ty: Int64 = 0
                while (ty < 7) {
                    var tx: Int64 = 0
                    while (tx < 5) {
                        if (Int64(s[ty * 5 + tx]) == 49) {
                            var dy: Int64 = 0
                            while (dy < scale) {
                                var dx: Int64 = 0
                                while (dx < scale) {
                                    let x = pad + ci * (cw + gap) + tx * scale + dx
                                    let y = pad + ty * scale + dy
                                    let q = (y * w + x) * 3
                                    img.pixels[q] = 0u8
                                    img.pixels[q + 1] = 0u8
                                    img.pixels[q + 2] = 0u8
                                    dx = dx + 1
                                }
                                dy = dy + 1
                            }
                        }
                        tx = tx + 1
                    }
                    ty = ty + 1
                }
            }
            ci = ci + 1
        }
        return img
    }

    /** 灰度极值中点二值化：返回 1=墨、0=背景。 */
    public static func binarize(img: RasterImage): Array<Byte> {
        let n = img.width * img.height
        let gray = Array<Int64>(n, repeat: 0)
        var minV: Int64 = 255
        var maxV: Int64 = 0
        var i: Int64 = 0
        while (i < n) {
            let q = i * 3
            let v = (Int64(img.pixels[q]) * 299 + Int64(img.pixels[q + 1]) * 587 +
                Int64(img.pixels[q + 2]) * 114) / 1000
            gray[i] = v
            if (v < minV) { minV = v }
            if (v > maxV) { maxV = v }
            i = i + 1
        }
        let out = Array<Byte>(n, repeat: 0u8)
        // 几乎纯色的图没有可分离的文字层
        if (maxV - minV < 40) {
            return out
        }
        let thr = (minV + maxV) / 2
        i = 0
        while (i < n) {
            if (gray[i] <= thr) {
                out[i] = 1u8
            }
            i = i + 1
        }
        return out
    }

    /** 水平投影分行，返回扁平的 [y0,y1,y0,y1,...]。 */
    private static func lineRanges(bin: Array<Byte>, w: Int64, h: Int64): Array<Int64> {
        let out = ArrayList<Int64>()
        var start: Int64 = -1
        var y: Int64 = 0
        while (y < h) {
            var ink: Int64 = 0
            var x: Int64 = 0
            while (x < w) {
                ink = ink + Int64(bin[y * w + x])
                x = x + 1
            }
            if (ink > 0 && start < 0) {
                start = y
            } else if (ink == 0 && start >= 0) {
                if (y - start >= 3) {
                    out.add(start)
                    out.add(y)
                }
                start = -1
            }
            y = y + 1
        }
        if (start >= 0 && h - start >= 3) {
            out.add(start)
            out.add(h)
        }
        return out.toArray()
    }

    /** 垂直投影分字，返回扁平的 [x0,x1,x0,x1,...]。 */
    private static func charRanges(bin: Array<Byte>, w: Int64, y0: Int64, y1: Int64): Array<Int64> {
        let out = ArrayList<Int64>()
        var start: Int64 = -1
        var x: Int64 = 0
        while (x < w) {
            var ink: Int64 = 0
            var y = y0
            while (y < y1) {
                ink = ink + Int64(bin[y * w + x])
                y = y + 1
            }
            if (ink > 0 && start < 0) {
                start = x
            } else if (ink == 0 && start >= 0) {
                out.add(start)
                out.add(x)
                start = -1
            }
            x = x + 1
        }
        if (start >= 0) {
            out.add(start)
            out.add(w)
        }
        return out.toArray()
    }

    /** 字符区域最近邻采样到 5×7。 */
    private static func normalize(bin: Array<Byte>, w: Int64,
        x0: Int64, x1: Int64, y0: Int64, y1: Int64): Array<Byte> {
        let bits = Array<Byte>(35, repeat: 0u8)
        let cw = x1 - x0
        let ch = y1 - y0
        var ty: Int64 = 0
        while (ty < 7) {
            var sy = y0 + (ty * ch) / 7
            if (sy >= y1) { sy = y1 - 1 }
            var tx: Int64 = 0
            while (tx < 5) {
                var sx = x0 + (tx * cw) / 5
                if (sx >= x1) { sx = x1 - 1 }
                bits[ty * 5 + tx] = bin[sy * w + sx]
                tx = tx + 1
            }
            ty = ty + 1
        }
        return bits
    }

    /** 与内置字模做汉明距离匹配，距离 >10 视为不可识别。 */
    private static func matchGlyph(bits: Array<Byte>): String {
        var bestI: Int64 = -1
        var bestD: Int64 = 36
        var i: Int64 = 0
        while (i < MediaOcr.GLYPHS.size) {
            let s = MediaOcr.GLYPHS[i]
            var d: Int64 = 0
            var k: Int64 = 0
            while (k < 35) {
                let gv = if (Int64(s[k]) == 49) { 1 } else { 0 }
                if (Int64(bits[k]) != gv) {
                    d = d + 1
                }
                k = k + 1
            }
            if (d < bestD) {
                bestD = d
                bestI = i
            }
            i = i + 1
        }
        if (bestI < 0 || bestD > 10) {
            return "?"
        }
        return MediaOcr.ALPHABET[bestI..(bestI + 1)]
    }

    /** 识别整张图，多行以换行分隔。 */
    public static func recognize(img: RasterImage): String {
        let bin = MediaOcr.binarize(img)
        let lines = MediaOcr.lineRanges(bin, img.width, img.height)
        let sb = StringBuilder()
        var li: Int64 = 0
        var total: Int64 = 0
        while (li + 1 < lines.size) {
            let y0 = lines[li]
            let y1 = lines[li + 1]
            let chars = MediaOcr.charRanges(bin, img.width, y0, y1)
            if (li > 0) {
                sb.append("\n")
            }
            var ci: Int64 = 0
            while (ci + 1 < chars.size && total < MediaOcr.MAX_CHARS) {
                let x0 = chars[ci]
                let x1 = chars[ci + 1]
                if (x1 - x0 >= 2 && y1 - y0 >= 3) {
                    sb.append(MediaOcr.matchGlyph(MediaOcr.normalize(bin, img.width, x0, x1, y0, y1)))
                    total = total + 1
                }
                ci = ci + 2
            }
            li = li + 2
        }
        return sb.toString()
    }

    /**
     * 置信度：非 '?' 且非换行的字符数 × 100 / 全部非换行字符数。
     * 5×7 识别器把不可识别字输出为 '?'，据此衡量「像不像印刷体」。
     * 全空返回 0。
     */
    public static func confidence(text: String): Int64 {
        var total: Int64 = 0
        var good: Int64 = 0
        var i: Int64 = 0
        while (i < text.size) {
            let b = Int64(text[i])
            if (b != 10) {
                total = total + 1
                if (b != 63) {
                    good = good + 1
                }
            }
            i = i + 1
        }
        if (total == 0) {
            return 0
        }
        return good * 100 / total
    }

    /** 三路路由，返回识别文本（不携带引擎名）。 */
    public static func recognizeAuto(img: RasterImage): String {
        return MediaOcr.recognizeAutoWithEngine(img).text
    }

    /**
     * 内置三路路由（5×7 印刷体 → CJK 字典 → 手写数字），返回文本 + 引擎名。
     * 这是「无外部引擎」时的确定性行为，也是 external 引擎的回退目标。
     */
    private static func recognizeBuiltin(img: RasterImage): OcrOutcome {
        let r = OcrOutcome()
        let printed = MediaOcr.recognize(img)
        let c = MediaOcr.confidence(printed)
        if (c >= 60) {
            r.text = printed
            r.engine = "builtin-5x7"
            return r
        }
        let cjk = CjkOcr.recognize(img)
        if (cjk.size > 0) {
            r.text = cjk
            r.engine = "builtin-cjk"
            return r
        }
        let hand = HandOcr.recognize(img)
        if (hand.size > 0) {
            r.text = hand
            r.engine = "builtin-hand"
            return r
        }
        r.text = printed
        r.engine = "builtin-5x7"
        return r
    }

    /**
     * 三路路由 + 可选外部引擎。优先级：
     *   1) 外部 PP-OCRv5（仅当 AMS_OCR_ENGINE=external 且初始化成功，
     *      且实际识别出非空文本）；
     *   2) 内置三路（CJK / 手写 / 5×7）。
     * 任一环节失败 / 未启用都透明回退，调用方拿到的 contract 不变。
     */
    public static func recognizeAutoWithEngine(img: RasterImage): OcrOutcome {
        let ext = PpOcrV5.recognize(img)
        if (ext.size > 0) {
            let r = OcrOutcome()
            r.text = ext
            r.engine = "external-ppocrv5"
            return r
        }
        return MediaOcr.recognizeBuiltin(img)
    }

}

/** 三路路由结果：识别文本 + 实际采用的引擎名。 */
public class OcrOutcome {
    public var text: String
    public var engine: String

    public init() {
        this.text = ""
        this.engine = ""
    }
}
