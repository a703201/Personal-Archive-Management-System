// ============================================================
// ams.core.media · PDF 文本流抽取（纯仓颉实现）
//
// 【定位】
//   档案里的「扫描件 PDF」有相当一部分其实是文本型 PDF（电子证照、
//   电子回执、银行流水）。这类文件无需 OCR，直接解出内容流里的
//   Tj / TJ 字面字符串即可拿到可检索文本。
//
// 【做法】
//   ① 逐字节找 `stream` / `endstream`；
//   ② 尝试 PngCodec.inflateZlib（FlateDecode），失败则按未压缩处理；
//   ③ 扫描 PDF 字面字符串 `(...)`，处理 \n \r \t \ooo 与 \( \) 转义；
//   ④ 只保留 ASCII 可见字符并折叠空白，避免非法 UTF-8 片段。
//
// 【边界】
//   不做 CMAP / ToUnicode 映射、不做字体解码、不支持图像型扫描 PDF，
//   因此中文 PDF 与纯图片 PDF 抽不出文本 —— 这部分如实返回空串，
//   由上层把 ocrStatus 置为「失败 / 需外部引擎」。
// ============================================================
package ams.core.media

import std.collection.*

public class PdfText {
    private static let MAX_STREAM_BYTES: Int64 = 8 * 1024 * 1024

    /** 从 from 起找 pattern，返回起始下标；找不到返回 -1。 */
    private static func find(data: Array<Byte>, pattern: Array<Byte>, from: Int64): Int64 {
        var i = from
        while (i + pattern.size <= data.size) {
            var ok = true
            var k: Int64 = 0
            while (k < pattern.size) {
                if (data[i + k] != pattern[k]) {
                    ok = false
                    break
                }
                k = k + 1
            }
            if (ok) {
                return i
            }
            i = i + 1
        }
        return -1
    }

    /** 折叠空白并只保留 ASCII 可见字符。 */
    private static func normalize(s: String): String {
        let sb = StringBuilder()
        var pendingSpace = false
        var started = false
        var i: Int64 = 0
        while (i < s.size) {
            let b = Int64(s[i])
            let space = (b == 32 || b == 10 || b == 13 || b == 9)
            if (space) {
                pendingSpace = started
            } else if (b >= 32 && b < 127) {
                if (pendingSpace) {
                    sb.append(" ")
                    pendingSpace = false
                }
                sb.append(s[i..(i + 1)])
                started = true
            }
            i = i + 1
        }
        return sb.toString()
    }

    /** 抽取所有内容流里的字面字符串。 */
    public static func extract(data: Array<Byte>): String {
        let streamTag = "stream".toArray()
        let endTag = "endstream".toArray()
        let sb = StringBuilder()
        var cursor: Int64 = 0
        var guardCount: Int64 = 0
        while (guardCount < 512) {
            let s = PdfText.find(data, streamTag, cursor)
            if (s < 0) {
                break
            }
            var bodyStart = s + streamTag.size
            // 跳过 CRLF / LF
            if (bodyStart < data.size && Int64(data[bodyStart]) == 13) {
                bodyStart = bodyStart + 1
            }
            if (bodyStart < data.size && Int64(data[bodyStart]) == 10) {
                bodyStart = bodyStart + 1
            }
            let e = PdfText.find(data, endTag, bodyStart)
            if (e < 0) {
                break
            }
            var bodyEnd = e
            while (bodyEnd > bodyStart && (Int64(data[bodyEnd - 1]) == 10 ||
                Int64(data[bodyEnd - 1]) == 13)) {
                bodyEnd = bodyEnd - 1
            }
            if (bodyEnd > bodyStart) {
                let raw = Array<Byte>(bodyEnd - bodyStart, repeat: 0u8)
                var k: Int64 = 0
                while (k < bodyEnd - bodyStart) {
                    raw[k] = data[bodyStart + k]
                    k = k + 1
                }
                var stream = raw
                try {
                    stream = PngCodec.inflateZlib(raw, PdfText.MAX_STREAM_BYTES)
                } catch (err: Exception) {
                    stream = raw
                }
                sb.append(PdfText.literals(stream))
                sb.append(" ")
            }
            cursor = e + endTag.size
            guardCount = guardCount + 1
        }
        return PdfText.normalize(sb.toString())
    }

    /** 解析 `( ... ) Tj` 与 `[ ... ] TJ` 里的字面字符串。 */
    private static func literals(stream: Array<Byte>): String {
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < stream.size) {
            if (Int64(stream[i]) != 40) {
                i = i + 1
                continue
            }
            i = i + 1
            let bytes = ArrayList<Byte>()
            while (i < stream.size) {
                let b = Int64(stream[i])
                if (b == 92 && i + 1 < stream.size) {
                    let n = Int64(stream[i + 1])
                    if (n == 110) {
                        bytes.add(UInt8(32))
                        i = i + 2
                        continue
                    }
                    if (n == 114 || n == 116) {
                        bytes.add(UInt8(32))
                        i = i + 2
                        continue
                    }
                    if (n >= 48 && n <= 55) {
                        var v: Int64 = 0
                        var k: Int64 = 0
                        while (k < 3 && i + 1 + k < stream.size) {
                            let d = Int64(stream[i + 1 + k])
                            if (d < 48 || d > 55) {
                                break
                            }
                            v = v * 8 + (d - 48)
                            k = k + 1
                        }
                        bytes.add(UInt8(v & 255))
                        i = i + 1 + k
                        continue
                    }
                    bytes.add(UInt8(n))
                    i = i + 2
                    continue
                }
                if (b == 41) {
                    i = i + 1
                    break
                }
                bytes.add(stream[i])
                i = i + 1
            }
            if (bytes.size > 0) {
                // 非 ASCII / 非法 UTF-8 片段（中文 PDF 走 CMAP，本实现不支持）
                // 直接丢弃该段，不让解码异常中断整份文件的抽取。
                var s = ""
                try {
                    s = PdfText.normalize(String.fromUtf8(bytes.toArray()))
                } catch (err: Exception) {
                    s = ""
                }
                sb.append(s)
                sb.append(" ")
            }
        }
        return sb.toString()
    }
}
