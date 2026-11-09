// ============================================================
// ams.core.media · 图像型扫描 PDF 的图像流抽取（纯仓颉实现）
//
// 【定位】
//   文本型 PDF（电子证照 / 回执）由 PdfText.extract 处理；扫描件把整页
//   当作一张或多张位图塞进内容流，PdfText 只能拿到空串。PdfImage.extract
//   负责把这些图像流解成 RasterImage，供上层逐张跑 OCR。
//
// 【做法：字节级扫描，不是完整 PDF 解释器】
//   纯仓颉进程内、只做字节级解析、不是完整 PDF 解释器：
//     · 不建对象图 / 不读 xref / 不解析间接引用链；
//     · 全文件找 "/Subtype /Image"，向前找最近的 "<<"，向后找 "stream"；
//     · 在这段字典里按名取值（/Width /Height /BitsPerComponent /
//       /ColorSpace /Filter /Length，以及 /DecodeParms 里的 /Predictor）；
//     · stream 关键字后按 /Length 取字节，交给 JpegCodec / inflateZlib；
//     · 另扫 "BI ... ID <二进制> EI" 内联图像（缩写键 /W /H /BPC /CS /F）。
//   任一张图解析/解码失败都 try/catch 后跳过，整体绝不抛异常；
//   返回所有成功解码的图像（可能为空数组）。不写文件、不调外部进程。
//
// 【支持的滤镜 / 色彩空间矩阵】
//   /Filter      DCTDecode(/DCT)        → JpegCodec.decode
//                FlateDecode(/Fl)       → inflateZlib + 原始样本
//                （缺失 / 无滤镜）       → 原始样本
//                ASCIIHex/A85/LZW/RL/CCF/JPX/JBIG2/未知 → 跳过该图
//   /ColorSpace  DeviceGray(/G)         → 1 字节/像素（灰值复制到 RGB）
//                DeviceRGB(/RGB)        → 3 字节/像素
//                DeviceCMYK/Indexed/ICCBased/数组形式 → 跳过该图
//   /Predictor   1（无）/ 2（TIFF 横向差分）→ 支持；其余(10~15 PNG)跳过该图
//   仅支持 BitsPerComponent = 8；PDF 图像行自上而下，与 RasterImage 一致。
//
// 【诚实边界（明确不支持）】
//   加密 PDF、对象流 /ObjStm、XRef 流、CMYK、JPEG2000、CCITT、JBIG2、
//   图像掩码 /ImageMask、1/2/4/16-bit 样本、多滤镜数组、调色板/索引色；
//   渐进式 JPEG 由 JpegCodec 决定。遇到这些只跳过对应图像，不中断整体。
// ============================================================
package ams.core.media

import std.collection.*

public class PdfImage {
    // 色彩空间编码直接用「每像素字节数」，方便算样本长度与预测步长：
    // 0 = 跳过，1 = DeviceGray，3 = DeviceRGB。
    private static let CS_SKIP: Int64 = 0
    private static let CS_GRAY: Int64 = 1
    private static let CS_RGB: Int64 = 3

    // 滤镜编码。
    private static let F_SKIP: Int64 = -1
    private static let F_NONE: Int64 = 0
    private static let F_DCT: Int64 = 1
    private static let F_FLATE: Int64 = 2

    // 单图维度上限（防 zip-bomb 式超大 /Width /Height 触发巨量分配）。
    private static let MAX_PIXELS: Int64 = 8 * 1024 * 1024
    private static let MAX_SIDE: Int64 = 8192

    /** 字节 → 是否 ASCII 空白（PDF white-space：NUL/TAB/LF/FF/CR/SP）。 */
    private static func isWhite(b: Byte): Bool {
        return b == 0u8 || b == 9u8 || b == 10u8 || b == 12u8 || b == 13u8 || b == 32u8
    }

    /** 字节 → 是否 PDF 分隔符 ()<>[]{}/% 。 */
    private static func isDelim(b: Byte): Bool {
        return b == 40u8 || b == 41u8 || b == 60u8 || b == 62u8 ||
            b == 91u8 || b == 93u8 || b == 123u8 || b == 125u8 ||
            b == 47u8 || b == 37u8
    }

    private static func isWhiteOrDelim(b: Byte): Bool {
        return PdfImage.isWhite(b) || PdfImage.isDelim(b)
    }

    private static func isDigit(b: Byte): Bool {
        return b >= 48u8 && b <= 57u8
    }

    /** 跳过空白与 % 行注释（只在读 token 时用，绝不越过 end）。 */
    private static func skipWhite(data: Array<Byte>, i0: Int64, end: Int64): Int64 {
        var i = i0
        while (i < end) {
            let b = data[i]
            if (PdfImage.isWhite(b)) {
                i = i + 1
                continue
            }
            if (b == 37u8) {
                i = i + 1
                while (i < end && data[i] != 10u8 && data[i] != 13u8) {
                    i = i + 1
                }
                continue
            }
            break
        }
        return i
    }

    /** data[i..j) 是否等于 ASCII 串 lit。 */
    private static func bytesEqual(data: Array<Byte>, i: Int64, j: Int64, lit: String): Bool {
        let lb = lit.toArray()
        if (j - i != lb.size) {
            return false
        }
        var k: Int64 = 0
        while (k < lb.size) {
            if (data[i + k] != lb[k]) {
                return false
            }
            k = k + 1
        }
        return true
    }

    /** 拷贝子区间，返回独立可变数组（避免依赖区间切片的返回类型）。 */
    private static func slice(data: Array<Byte>, from: Int64, to: Int64): Array<Byte> {
        if (to <= from) {
            return Array<Byte>(0, repeat: 0u8)
        }
        let out = Array<Byte>(to - from, repeat: 0u8)
        var k: Int64 = 0
        while (k < to - from) {
            out[k] = data[from + k]
            k = k + 1
        }
        return out
    }

    /** 在 [start,end) 找 "/key"，返回「值起始下标」；带 token 边界，找不到 -1。 */
    private static func findKey(data: Array<Byte>, start: Int64, end: Int64, key: String): Int64 {
        let kb = key.toArray()
        var i = start
        while (i + 1 + kb.size <= end) {
            if (data[i] == 47u8 && PdfImage.bytesEqual(data, i + 1, i + 1 + kb.size, key)) {
                let after = i + 1 + kb.size
                if (after >= end || PdfImage.isWhiteOrDelim(data[after])) {
                    return after
                }
            }
            i = i + 1
        }
        return -1
    }

    /** 读 /Name 名字段：假定 data[i]=='/'，返回 (nameStart, nameEnd)。 */
    private static func readNameRange(data: Array<Byte>, i: Int64, end: Int64): (Int64, Int64) {
        var j = i + 1
        while (j < end && !PdfImage.isWhiteOrDelim(data[j])) {
            j = j + 1
        }
        return (i + 1, j)
    }

    /** 读十进制整数（可带 +/-），返回 (值, 结束下标, 是否成功)。 */
    private static func readInt(data: Array<Byte>, i0: Int64, end: Int64): (Int64, Int64, Bool) {
        var i = PdfImage.skipWhite(data, i0, end)
        var sign: Int64 = 1
        if (i < end && data[i] == 45u8) {
            sign = -1
            i = i + 1
        } else if (i < end && data[i] == 43u8) {
            i = i + 1
        }
        if (i >= end || !PdfImage.isDigit(data[i])) {
            return (0, i, false)
        }
        var v: Int64 = 0
        while (i < end && PdfImage.isDigit(data[i])) {
            v = v * 10 + (Int64(data[i]) - 48)
            i = i + 1
        }
        return (sign * v, i, true)
    }

    private static func nameIs(data: Array<Byte>, s: Int64, e: Int64, lit: String): Bool {
        return PdfImage.bytesEqual(data, s, e, lit)
    }

    /** 读 /Width 等整数键，缺键或非法值给 default。 */
    private static func readKeyInt(data: Array<Byte>, start: Int64, end: Int64,
        key: String, def: Int64): Int64 {
        let vpos = PdfImage.findKey(data, start, end, key)
        if (vpos < 0) {
            return def
        }
        let (v, _, ok) = PdfImage.readInt(data, vpos, end)
        if (!ok) {
            return def
        }
        return v
    }

    /** 读 /Length：直接数值返回之；间接引用(N G R)或缺键返回 -1（改由 endstream 取长度）。 */
    private static func readKeyLength(data: Array<Byte>, start: Int64, end: Int64): Int64 {
        let vpos = PdfImage.findKey(data, start, end, "Length")
        if (vpos < 0) {
            return -1
        }
        let (v, after, ok) = PdfImage.readInt(data, vpos, end)
        if (!ok) {
            return -1
        }
        let j = PdfImage.skipWhite(data, after, end)
        // 数字后又跟数字或 'R' ⇒ 形如 "12 0 R" 的间接引用，长度不可信。
        if (j < end && (PdfImage.isDigit(data[j]) || data[j] == 82u8)) {
            return -1
        }
        return v
    }

    /** 把 /ColorSpace 的值归类为 CS_*；数组 / 未知名 → CS_SKIP。 */
    private static func classifyColorSpace(data: Array<Byte>, i0: Int64, end: Int64): Int64 {
        let i = PdfImage.skipWhite(data, i0, end)
        if (i >= end) {
            return PdfImage.CS_SKIP
        }
        if (data[i] == 91u8) {   // '[' 数组（Indexed/ICCBased 等）
            return PdfImage.CS_SKIP
        }
        if (data[i] == 47u8) {   // '/'
            let (s, e) = PdfImage.readNameRange(data, i, end)
            if (PdfImage.nameIs(data, s, e, "DeviceGray") || PdfImage.nameIs(data, s, e, "G")) {
                return PdfImage.CS_GRAY
            }
            if (PdfImage.nameIs(data, s, e, "DeviceRGB") || PdfImage.nameIs(data, s, e, "RGB")) {
                return PdfImage.CS_RGB
            }
        }
        return PdfImage.CS_SKIP
    }

    private static func classifyFilterName(data: Array<Byte>, s: Int64, e: Int64): Int64 {
        if (PdfImage.nameIs(data, s, e, "DCTDecode") || PdfImage.nameIs(data, s, e, "DCT")) {
            return PdfImage.F_DCT
        }
        if (PdfImage.nameIs(data, s, e, "FlateDecode") || PdfImage.nameIs(data, s, e, "Fl")) {
            return PdfImage.F_FLATE
        }
        // 其余（AHx/A85/LZW/RL/CCF/JPX/JBIG2/未知）一律跳过该图。
        return PdfImage.F_SKIP
    }

    /** 读 /Filter：单名或单滤镜数组 [ /Xxx ]；多滤镜 / 未知 → F_SKIP。 */
    private static func classifyFilter(data: Array<Byte>, i0: Int64, end: Int64): Int64 {
        let i = PdfImage.skipWhite(data, i0, end)
        if (i >= end) {
            return PdfImage.F_SKIP
        }
        if (data[i] == 91u8) {   // '[' 只支持单滤镜数组
            var j = i + 1
            var count: Int64 = 0
            var fs: Int64 = 0
            var fe: Int64 = 0
            while (j < end && data[j] != 93u8) {   // 直到 ']'
                j = PdfImage.skipWhite(data, j, end)
                if (j < end && data[j] == 47u8) {
                    let (s, e) = PdfImage.readNameRange(data, j, end)
                    if (count == 0) {
                        fs = s
                        fe = e
                    }
                    count = count + 1
                    j = e
                } else {
                    j = j + 1
                }
            }
            if (count == 1) {
                return PdfImage.classifyFilterName(data, fs, fe)
            }
            return PdfImage.F_SKIP
        }
        if (data[i] == 47u8) {
            let (s, e) = PdfImage.readNameRange(data, i, end)
            return PdfImage.classifyFilterName(data, s, e)
        }
        return PdfImage.F_SKIP
    }

    /** 读 DecodeParms 里的 /Predictor /Columns /Colors（缺则 -1，由调用方用图像默认值）。 */
    private static func readPredictor(data: Array<Byte>, start: Int64,
        end: Int64): (Int64, Int64, Int64) {
        var pred: Int64 = 1
        var columns: Int64 = -1
        var colors: Int64 = -1
        let pp = PdfImage.findKey(data, start, end, "Predictor")
        if (pp >= 0) {
            let (v, _, ok) = PdfImage.readInt(data, pp, end)
            if (ok) {
                pred = v
            }
        }
        let cp = PdfImage.findKey(data, start, end, "Columns")
        if (cp >= 0) {
            let (v, _, ok) = PdfImage.readInt(data, cp, end)
            if (ok) {
                columns = v
            }
        }
        let clp = PdfImage.findKey(data, start, end, "Colors")
        if (clp >= 0) {
            let (v, _, ok) = PdfImage.readInt(data, clp, end)
            if (ok) {
                colors = v
            }
        }
        return (pred, columns, colors)
    }

    /** 从 from 找 "/Subtype /Image"，返回 "/Subtype" 下标；找不到 -1。 */
    private static func findSubtypeImage(data: Array<Byte>, from: Int64): Int64 {
        let pat = "/Subtype".toArray()
        var i = from
        while (i + pat.size <= data.size) {
            var ok = true
            var k: Int64 = 0
            while (k < pat.size) {
                if (data[i + k] != pat[k]) {
                    ok = false
                    break
                }
                k = k + 1
            }
            if (ok) {
                let after = i + pat.size
                if (after < data.size && PdfImage.isWhiteOrDelim(data[after])) {
                    let q = PdfImage.skipWhite(data, after, data.size)
                    if (q < data.size && data[q] == 47u8) {
                        let (s, e) = PdfImage.readNameRange(data, q, data.size)
                        if (PdfImage.bytesEqual(data, s, e, "Image")) {
                            return i
                        }
                    }
                }
            }
            i = i + 1
        }
        return -1
    }

    /** 从 p 向前（更早字节）找最近的 "<<"。 */
    private static func findDictStart(data: Array<Byte>, p: Int64): Int64 {
        var i = p
        while (i >= 0) {
            if (i + 1 < data.size && data[i] == 60u8 && data[i + 1] == 60u8) {
                return i
            }
            i = i - 1
        }
        return -1
    }

    /** 找真正的 stream 关键字（排除 endstream 里的 stream），要求后紧跟 EOL。 */
    private static func findStreamKeyword(data: Array<Byte>, from: Int64): Int64 {
        let pat = "stream".toArray()
        var i = from
        while (i + pat.size <= data.size) {
            if (PdfImage.bytesEqual(data, i, i + pat.size, "stream")) {
                let prevOK = (i == 0) || PdfImage.isWhiteOrDelim(data[i - 1])
                var nextOK = false
                let nx = i + pat.size
                if (nx < data.size) {
                    let b = data[nx]
                    if (b == 10u8 || b == 13u8) {
                        nextOK = true
                    }
                }
                if (prevOK && nextOK) {
                    return i
                }
            }
            i = i + 1
        }
        return -1
    }

    /** 从 from 找 endstream（带前后边界），找不到 -1。 */
    private static func findEndstream(data: Array<Byte>, from: Int64): Int64 {
        let pat = "endstream".toArray()
        var i = from
        while (i + pat.size <= data.size) {
            var ok = true
            var k: Int64 = 0
            while (k < pat.size) {
                if (data[i + k] != pat[k]) {
                    ok = false
                    break
                }
                k = k + 1
            }
            if (ok) {
                let prevOK = (i == 0) || PdfImage.isWhiteOrDelim(data[i - 1])
                let nx = i + pat.size
                let nextOK = (nx >= data.size) || PdfImage.isWhiteOrDelim(data[nx])
                if (prevOK && nextOK) {
                    return i
                }
            }
            i = i + 1
        }
        return -1
    }

    /** 找 2 字母内联关键字 BI / ID / EI（带前后边界）。 */
    private static func findInlineToken(data: Array<Byte>, from: Int64, tok: String): Int64 {
        let tb = tok.toArray()
        var i = from
        while (i + tb.size <= data.size) {
            var ok = true
            var k: Int64 = 0
            while (k < tb.size) {
                if (data[i + k] != tb[k]) {
                    ok = false
                    break
                }
                k = k + 1
            }
            if (ok) {
                let prevOK = (i == 0) || PdfImage.isWhiteOrDelim(data[i - 1])
                let nx = i + tb.size
                let nextOK = (nx >= data.size) || PdfImage.isWhiteOrDelim(data[nx])
                if (prevOK && nextOK) {
                    return i
                }
            }
            i = i + 1
        }
        return -1
    }

    /** stream 关键字后跳过一个 EOL（CRLF 或 LF 或 CR）。 */
    private static func streamDataStart(data: Array<Byte>, sp: Int64): Int64 {
        var ds = sp + 6
        if (ds < data.size && data[ds] == 13u8) {
            ds = ds + 1
            if (ds < data.size && data[ds] == 10u8) {
                ds = ds + 1
            }
        } else if (ds < data.size && data[ds] == 10u8) {
            ds = ds + 1
        }
        return ds
    }

    /** 取流字节：(字节, 建议 resume, 是否成功)。 */
    private static func getStream(data: Array<Byte>, dictStart: Int64, dictEnd: Int64,
        sp: Int64): (Array<Byte>, Int64, Bool) {
        let empty = Array<Byte>(0, repeat: 0u8)
        let streamStart = PdfImage.streamDataStart(data, sp)
        let length = PdfImage.readKeyLength(data, dictStart, dictEnd)
        if (length >= 0 && streamStart + length <= data.size) {
            let se = streamStart + length
            return (PdfImage.slice(data, streamStart, se), se, true)
        }
        // /Length 为间接引用或缺省：退化为找 endstream 并去掉紧邻其前的换行。
        let es = PdfImage.findEndstream(data, streamStart)
        if (es < 0) {
            return (empty, sp + 6, false)
        }
        var e = es
        while (e > streamStart && (data[e - 1] == 10u8 || data[e - 1] == 13u8)) {
            e = e - 1
        }
        return (PdfImage.slice(data, streamStart, e), es + 9, true)
    }

    /** TIFF Predictor 2 横向差分还原（就地累加，步长 = 颜色分量数）。 */
    private static func applyPredictor(raw: Array<Byte>, w: Int64, h: Int64,
        bpp: Int64, pred: Int64, columns: Int64, colors: Int64): Array<Byte> {
        if (pred <= 1) {
            return raw
        }
        var cols = columns
        if (cols <= 0) {
            cols = w
        }
        var ncol = colors
        if (ncol <= 0) {
            ncol = bpp
        }
        let rowLen = cols * ncol
        if (rowLen <= 0) {
            return raw
        }
        var row: Int64 = 0
        while (row < h) {
            let base = row * rowLen
            if (base + rowLen > raw.size) {
                break
            }
            var p = ncol
            while (p < rowLen) {
                let v = Int64(raw[base + p]) + Int64(raw[base + p - ncol])
                raw[base + p] = UInt8(v & 255)
                p = p + 1
            }
            row = row + 1
        }
        return raw
    }

    /** 原始样本 → RGB 栅格（行自上而下，与 PDF 图像 / RasterImage 一致）。 */
    private static func samplesToRaster(raw: Array<Byte>, w: Int64, h: Int64,
        bpp: Int64): RasterImage {
        let px = Array<Byte>(w * h * 3, repeat: 0u8)
        var idx: Int64 = 0
        while (idx < w * h) {
            let q = idx * 3
            if (bpp == 1) {
                let g = raw[idx]
                px[q] = g
                px[q + 1] = g
                px[q + 2] = g
            } else {
                px[q] = raw[idx * 3]
                px[q + 1] = raw[idx * 3 + 1]
                px[q + 2] = raw[idx * 3 + 2]
            }
            idx = idx + 1
        }
        return RasterImage(w, h, px)
    }

    /**
     * 处理一个 XObject 图像：成功则加入 result，失败/不支持则静默跳过。
     * 返回主循环应继续扫描的位置（保证 > p，且尽量越过二进制流）。
     */
    private static func decodeXObject(data: Array<Byte>, p: Int64,
        result: ArrayList<RasterImage>): Int64 {
        var resume = p + 8
        try {
            let dictStart = PdfImage.findDictStart(data, p)
            if (dictStart < 0) {
                return resume
            }
            let sp = PdfImage.findStreamKeyword(data, p)
            if (sp < 0) {
                return resume
            }
            resume = sp + 6
            let dictEnd = sp

            let w = PdfImage.readKeyInt(data, dictStart, dictEnd, "Width", -1)
            let h = PdfImage.readKeyInt(data, dictStart, dictEnd, "Height", -1)
            if (w <= 0 || h <= 0 || w > PdfImage.MAX_SIDE || h > PdfImage.MAX_SIDE ||
                w * h > PdfImage.MAX_PIXELS) {
                return resume
            }
            let bpc = PdfImage.readKeyInt(data, dictStart, dictEnd, "BitsPerComponent", 8)
            if (bpc != 8) {
                return resume
            }
            let csPos = PdfImage.findKey(data, dictStart, dictEnd, "ColorSpace")
            var bpp: Int64 = PdfImage.CS_GRAY   // 缺省按灰度
            if (csPos >= 0) {
                bpp = PdfImage.classifyColorSpace(data, csPos, dictEnd)
            }
            if (bpp == PdfImage.CS_SKIP) {
                return resume
            }
            let fPos = PdfImage.findKey(data, dictStart, dictEnd, "Filter")
            var filter: Int64 = PdfImage.F_NONE   // 无 /Filter ⇒ 原始样本
            if (fPos >= 0) {
                filter = PdfImage.classifyFilter(data, fPos, dictEnd)
            }
            if (filter == PdfImage.F_SKIP) {
                return resume
            }
            var pred: Int64 = 1
            var columns: Int64 = -1
            var colors: Int64 = -1
            if (filter == PdfImage.F_FLATE) {
                let (pr, co, cl) = PdfImage.readPredictor(data, dictStart, dictEnd)
                pred = pr
                columns = co
                colors = cl
                if (pred != 1 && pred != 2) {
                    return resume
                }
            }

            let (stream, streamResume, ok) = PdfImage.getStream(data, dictStart, dictEnd, sp)
            if (!ok) {
                return resume
            }
            if (streamResume > resume) {
                resume = streamResume
            }

            if (filter == PdfImage.F_DCT) {
                result.add(JpegCodec.decode(stream))
            } else {
                var raw = stream
                if (filter == PdfImage.F_FLATE) {
                    raw = PngCodec.inflateZlib(stream, w * h * 4 + 1024)
                    raw = PdfImage.applyPredictor(raw, w, h, bpp, pred, columns, colors)
                }
                if (raw.size < w * h * bpp) {
                    return resume
                }
                result.add(PdfImage.samplesToRaster(raw, w, h, bpp))
            }
        } catch (err: Exception) {
            // 单张图解析/解码失败：跳过，继续其它图，绝不中断整体。
        }
        return resume
    }

    /** 处理一个内联图像 BI ... ID <二进制> EI（缩写键 /W /H /BPC /CS /F /DP /IM）。 */
    private static func decodeInline(data: Array<Byte>, b: Int64,
        result: ArrayList<RasterImage>): Int64 {
        var resume = b + 2
        try {
            let ip = PdfImage.findInlineToken(data, b + 2, "ID")
            if (ip < 0 || ip - b > 2048) {
                return resume
            }
            resume = ip + 2
            let ds = b + 2
            let de = ip
            let w = PdfImage.readKeyInt(data, ds, de, "W", -1)
            let h = PdfImage.readKeyInt(data, ds, de, "H", -1)
            if (w <= 0 || h <= 0 || w > PdfImage.MAX_SIDE || h > PdfImage.MAX_SIDE ||
                w * h > PdfImage.MAX_PIXELS) {
                return resume
            }
            let bpc = PdfImage.readKeyInt(data, ds, de, "BPC", 8)
            if (bpc != 8) {
                return resume
            }
            if (PdfImage.findKey(data, ds, de, "IM") >= 0) {
                return resume   // /ImageMask 不支持
            }
            let csPos = PdfImage.findKey(data, ds, de, "CS")
            var bpp: Int64 = PdfImage.CS_GRAY
            if (csPos >= 0) {
                bpp = PdfImage.classifyColorSpace(data, csPos, de)
            }
            if (bpp == PdfImage.CS_SKIP) {
                return resume
            }
            let fPos = PdfImage.findKey(data, ds, de, "F")
            var filter: Int64 = PdfImage.F_NONE
            if (fPos >= 0) {
                filter = PdfImage.classifyFilter(data, fPos, de)
            }
            if (filter == PdfImage.F_SKIP) {
                return resume
            }

            // ID 后恰好一个空白字节（或 CRLF），其后即二进制数据。
            var dataStart = ip + 2
            if (dataStart < data.size && data[dataStart] == 13u8 &&
                dataStart + 1 < data.size && data[dataStart + 1] == 10u8) {
                dataStart = dataStart + 2
            } else if (dataStart < data.size && PdfImage.isWhite(data[dataStart])) {
                dataStart = dataStart + 1
            }
            let ep = PdfImage.findInlineToken(data, dataStart, "EI")
            if (ep < 0) {
                return resume   // 找不到 EI 不越界，直接跳过
            }
            resume = ep + 2
            var e = ep
            while (e > dataStart && PdfImage.isWhite(data[e - 1])) {
                e = e - 1
            }
            let stream = PdfImage.slice(data, dataStart, e)

            if (filter == PdfImage.F_DCT) {
                result.add(JpegCodec.decode(stream))
            } else {
                var raw = stream
                if (filter == PdfImage.F_FLATE) {
                    let (pr, co, cl) = PdfImage.readPredictor(data, ds, de)
                    if (pr != 1 && pr != 2) {
                        return resume
                    }
                    raw = PngCodec.inflateZlib(stream, w * h * 4 + 1024)
                    raw = PdfImage.applyPredictor(raw, w, h, bpp, pr, co, cl)
                }
                if (raw.size < w * h * bpp) {
                    return resume
                }
                result.add(PdfImage.samplesToRaster(raw, w, h, bpp))
            }
        } catch (err: Exception) {
            // 内联图像解析/解码失败：跳过。
        }
        return resume
    }

    /**
     * 主入口：抽取所有成功解码的图像。
     * 任一张图失败只跳过该图，整体绝不抛异常；可能返回空数组。
     */
    public static func extract(data: Array<Byte>): Array<RasterImage> {
        let result = ArrayList<RasterImage>()
        if (data.size < 4) {
            return result.toArray()
        }
        // 第一遍：XObject 图像（/Subtype /Image）。
        var cursor: Int64 = 0
        var guardCount: Int64 = 0
        while (guardCount < 512) {
            let p = PdfImage.findSubtypeImage(data, cursor)
            if (p < 0) {
                break
            }
            let next = PdfImage.decodeXObject(data, p, result)
            cursor = if (next > p) { next } else { p + 8 }
            guardCount = guardCount + 1
        }
        // 第二遍：内联图像 BI ... ID ... EI。
        cursor = 0
        guardCount = 0
        while (guardCount < 512) {
            let b = PdfImage.findInlineToken(data, cursor, "BI")
            if (b < 0) {
                break
            }
            let next = PdfImage.decodeInline(data, b, result)
            cursor = if (next > b) { next } else { b + 2 }
            guardCount = guardCount + 1
        }
        return result.toArray()
    }
}
