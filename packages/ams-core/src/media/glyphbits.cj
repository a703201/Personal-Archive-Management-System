// ============================================================
// ams.core.media · CJK / 手写点阵识别共享位运算工具
//
// 【职责】
//   把 glyphdata.cj 里的 16×16 hex 点阵字典解码成二值数组，并提供
//   墨迹包围盒对齐、位移容差汉明距离、水平投影分行、列投影分字
//   （含断笔合并）、box → 16×16 零画布等纯整数运算工具。
//   CjkOcr / HandOcr 共用，运行时不依赖字体 / GDI / Python / 外部进程。
//
// 【数据约定】（与 scripts/gen-media-glyphs.py 的 to_hex 一致）
//   1 个 hex 字符 = 4 像素，MSB 先；整幅字模是行优先的连续位流。
//   16×16 字模 = 64 hex = 256 bit = flat[y * 16 + x]。
//   ink(=1) 表示墨迹，0 表示背景。
// ============================================================
package ams.core.media

import std.collection.*

public class GlyphBits {
    /** 单个 hex 字符 → 数值，兼容大写 A-F 与小写 a-f；非法字符按 0。 */
    private static func hexVal(b: Int64): Int64 {
        if (b >= 48 && b <= 57) {
            return b - 48
        }
        if (b >= 65 && b <= 70) {
            return b - 55
        }
        if (b >= 97 && b <= 102) {
            return b - 87
        }
        return 0
    }

    /** 每个 hex 字符展开成 4 个 bit（MSB 先），返回 s.size * 4 长度的 0/1 数组。 */
    public static func decodeHex(s: String): Array<Byte> {
        let out = Array<Byte>(s.size * 4, repeat: 0u8)
        var i: Int64 = 0
        while (i < s.size) {
            let v = GlyphBits.hexVal(Int64(s[i]))
            let q = i * 4
            out[q] = UInt8((v >> 3) & 1)
            out[q + 1] = UInt8((v >> 2) & 1)
            out[q + 2] = UInt8((v >> 1) & 1)
            out[q + 3] = UInt8(v & 1)
            i = i + 1
        }
        return out
    }

    /** 墨迹包围盒对齐：把所有 ink 平移到原点，超界丢弃；全空返回全 0。 */
    public static func align(flat: Array<Byte>): Array<Byte> {
        let out = Array<Byte>(256, repeat: 0u8)
        var minX: Int64 = 16
        var minY: Int64 = 16
        var y: Int64 = 0
        while (y < 16) {
            var x: Int64 = 0
            while (x < 16) {
                if (Int64(flat[y * 16 + x]) == 1) {
                    if (x < minX) {
                        minX = x
                    }
                    if (y < minY) {
                        minY = y
                    }
                }
                x = x + 1
            }
            y = y + 1
        }
        if (minX == 16) {
            return out
        }
        y = 0
        while (y < 16) {
            var x: Int64 = 0
            while (x < 16) {
                if (Int64(flat[y * 16 + x]) == 1) {
                    let nx = x - minX
                    let ny = y - minY
                    if (nx >= 0 && nx < 16 && ny >= 0 && ny < 16) {
                        out[ny * 16 + nx] = 1u8
                    }
                }
                x = x + 1
            }
            y = y + 1
        }
        return out
    }

    /**
     * 位移容差汉明距离：对 dy,dx ∈ {-1,0,1} 共 9 种位移，逐像素比较
     * a[y,x] 与 b[y+dy,x+dx]（b 越界视为 0），取最小不等数。
     */
    public static func shiftDistance(a: Array<Byte>, b: Array<Byte>): Int64 {
        return GlyphBits.shiftDistanceFlat(a, b, 0)
    }

    /** 内部核心：把 b 视作 flat[off .. off+256) 的 16×16 窗口，避免重复拷贝。 */
    private static func shiftDistanceFlat(a: Array<Byte>, flat: Array<Byte>, off: Int64): Int64 {
        var best: Int64 = 1000000
        var dy: Int64 = -1
        while (dy <= 1) {
            var dx: Int64 = -1
            while (dx <= 1) {
                var d: Int64 = 0
                var y: Int64 = 0
                while (y < 16) {
                    var x: Int64 = 0
                    while (x < 16) {
                        let av = Int64(a[y * 16 + x])
                        let by = y + dy
                        let bx = x + dx
                        var bv: Int64 = 0
                        if (by >= 0 && by < 16 && bx >= 0 && bx < 16) {
                            bv = Int64(flat[off + by * 16 + bx])
                        }
                        if (av != bv) {
                            d = d + 1
                        }
                        x = x + 1
                    }
                    y = y + 1
                }
                if (d < best) {
                    best = d
                }
                dx = dx + 1
            }
            dy = dy + 1
        }
        return best
    }

    /** 把 TEST_* 位串还原成白底黑字 RGB 图：bit=1 → 黑(0)，bit=0 → 白(255)。 */
    public static func fromHexRaster(w: Int64, h: Int64, hex: String): RasterImage {
        let img = RasterImage.white(w, h)
        let bits = GlyphBits.decodeHex(hex)
        var y: Int64 = 0
        while (y < h) {
            var x: Int64 = 0
            while (x < w) {
                let idx = y * w + x
                if (idx < bits.size && Int64(bits[idx]) == 1) {
                    let q = idx * 3
                    img.pixels[q] = 0u8
                    img.pixels[q + 1] = 0u8
                    img.pixels[q + 2] = 0u8
                }
                x = x + 1
            }
            y = y + 1
        }
        return img
    }

    /**
     * 原型表一次性对齐缓存：返回扁平 Array<Byte>，长度 = bits.size * 256，
     * 第 p 个原型的对齐数组位于 [p*256, p*256+256)。
     * 扁平布局规避仓颉嵌套数组类型的构造歧义，也避免逐 box 重复解码 hex。
     */
    public static func alignProtos(bits: Array<String>): Array<Byte> {
        let out = Array<Byte>(bits.size * 256, repeat: 0u8)
        var p: Int64 = 0
        while (p < bits.size) {
            let a = GlyphBits.align(GlyphBits.decodeHex(bits[p]))
            let off = p * 256
            var k: Int64 = 0
            while (k < 256) {
                out[off + k] = a[k]
                k = k + 1
            }
            p = p + 1
        }
        return out
    }

    /** 水平投影分行，返回扁平 [y0,y1,...]（与 MediaOcr.lineRanges 同思路）。 */
    public static func lineRanges(bin: Array<Byte>, w: Int64, h: Int64): Array<Int64> {
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

    /**
     * 垂直投影分字 + 断笔合并，返回扁平 [x0,x1,...]。
     * 合并条件：相邻 box 间隙 <= 3 且合并后宽度 <= 20（汉字内部常有断笔）。
     */
    public static func boxes(bin: Array<Byte>, w: Int64, y0: Int64, y1: Int64): Array<Int64> {
        let raw = ArrayList<Int64>()
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
                raw.add(start)
                raw.add(x)
                start = -1
            }
            x = x + 1
        }
        if (start >= 0) {
            raw.add(start)
            raw.add(w)
        }
        let out = ArrayList<Int64>()
        var have = false
        var curX0: Int64 = 0
        var curX1: Int64 = 0
        var i: Int64 = 0
        while (i + 1 < raw.size) {
            let bx0 = raw[i]
            let bx1 = raw[i + 1]
            if (have) {
                if (bx0 - curX1 <= 3 && bx1 - curX0 <= 20) {
                    curX1 = bx1
                } else {
                    out.add(curX0)
                    out.add(curX1)
                    curX0 = bx0
                    curX1 = bx1
                }
            } else {
                curX0 = bx0
                curX1 = bx1
                have = true
            }
            i = i + 2
        }
        if (have) {
            out.add(curX0)
            out.add(curX1)
        }
        return out.toArray()
    }

    /**
     * box → 16×16 零画布（不拉伸）：box 内像素按相对坐标 (x-x0, y-y0) 放入，
     * 只取前 16 列 / 16 行，超出的丢弃。返回 1=ink 的扁平数组。
     */
    public static func glyphFlat(bin: Array<Byte>, w: Int64,
        x0: Int64, x1: Int64, y0: Int64, y1: Int64): Array<Byte> {
        let out = Array<Byte>(256, repeat: 0u8)
        var y = y0
        while (y < y1) {
            let ty = y - y0
            if (ty >= 0 && ty < 16) {
                var x = x0
                while (x < x1) {
                    let tx = x - x0
                    if (tx >= 0 && tx < 16) {
                        if (Int64(bin[y * w + x]) == 1) {
                            out[ty * 16 + tx] = 1u8
                        }
                    }
                    x = x + 1
                }
            }
            y = y + 1
        }
        return out
    }

    /**
     * 与扁平原型表逐条求 shiftDistance，返回 [bestProtoIdx, bestDistance]。
     * bestProtoIdx / PROTOS 即字符下标；调用方按阈值决定是否接受。
     */
    public static func bestMatch(a: Array<Byte>, flat: Array<Byte>): Array<Int64> {
        let n = flat.size / 256
        var bestI: Int64 = -1
        var bestD: Int64 = 1000000
        var p: Int64 = 0
        while (p < n) {
            let d = GlyphBits.shiftDistanceFlat(a, flat, p * 256)
            if (d < bestD) {
                bestD = d
                bestI = p
            }
            p = p + 1
        }
        let res = Array<Int64>(2, repeat: 0)
        res[0] = bestI
        res[1] = bestD
        return res
    }
}
