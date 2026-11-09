// ============================================================
// ams.core.media · JPEG 解码（纯仓颉实现：baseline + progressive）
//
// 【为什么自己写】
//   附件类型约定包含 jpg/png/pdf，而 SDK 没有图像库。PNG 已由 png.cj
//   解决，这里补上 JPEG：全部在 ams-server 进程内完成，不引入外部
//   引擎 / 独立容器 / 网络调用，保持「一个进程、一个端口」。
//   定点 IDCT、纯仓颉进程内、零外部依赖。
//
// 【实现范围】
//   · SOI / APPn(跳过) / DQT / SOF0·SOF1·SOF2 / DHT / DRI(拒绝) / SOS / EOI
//   · Baseline / extended sequential：单 scan，逐 MCU 解码
//   · 渐进式 JPEG（SOF2）：全图 Int64[64] 系数缓冲 + 多 scan 累加写同一份
//       - 光谱选择（Ss/Se 频段划分）
//       - 逐次逼近（Ah/Al 点位变换，DC/AC refinement 位）
//       - AC EOB run（EOBn 跨 block 跳过）与 ZRL
//       - DC 首次扫描 / DC 细化扫描、AC 首次扫描 / AC 细化扫描
//     全部 scan 结束后统一反量化 → IDCT → 上采样 → YCbCr→RGB
//   · Huffman 解码（DC/AC，表由 DHT 段构建，不硬编码标准表）
//   · 反量化、zigzag 还原、**定点分离式 2D IDCT**（预计算余弦矩阵，
//     完全整数运算，不依赖 Math.cos / Float64 API）
//   · YCbCr → RGB、4:4:4 / 4:2:2 / 4:2:0 与任意 H/V 采样
//   · 8-bit 量化表、8-bit 精度
//
// 【明确不支持（抛 AppError(ValidationFailed)，不静默降级成空白图）】
//   算术编码（SOF9/10/11/13/14/15 与 DAC）、12/16-bit 精度、
//   restart interval(DRI)、16-bit 量化表、CMYK/YCCK 四色、
//   无损 JPEG(SOF3)、差分/层次 JPEG(SOF5/6/7)、
//   渐进式 AC 交错扫描(Ns>1)、跨 scan 重定义量化表。
//
// 【定点 IDCT】
//   M1[t][v] = 0.5 * C(v) * cos((2t+1)vπ/16)，C(0)=1/√2；
//   IDCT_M[t][v] = round(512 * M1) = round(256*C(v)*cos(...))。
//   两级 1D 变换各除以 512，避免浮点与溢出（Int64 足够）。
//
// 【数值约定】
//   系数与中间量一律 Int64；2^Al 用乘法范式 pow2（不用 << 以免 32 位
//   有符号溢出）；多字节组装用 v = v * 256 + byte 范式。
// ============================================================
package ams.core.media

import std.collection.*

import ams.kernel.error.*

/** 熵编码位流（已去掉 0xFF00 填充与 restart marker 的纯字节流）。 */
private class BitStream {
    let data: Array<Byte>
    var pos: Int64 = 0
    var buf: Int64 = 0
    var cnt: Int64 = 0

    public init(data: Array<Byte>) {
        this.data = data
    }

    public func readBit(): Int64 {
        if (this.cnt == 0) {
            this.buf = if (this.pos < this.data.size) { Int64(this.data[this.pos]) } else { 0 }
            this.pos = this.pos + 1
            this.cnt = 8
        }
        this.cnt = this.cnt - 1
        return (this.buf >> this.cnt) & 1
    }

    public func readBits(n: Int64): Int64 {
        var v: Int64 = 0
        var k: Int64 = 0
        while (k < n) {
            v = v * 2 + this.readBit()
            k = k + 1
        }
        return v
    }
}

/** 一个渐进式 scan 的描述：组件表引用在解析 SOS 时快照，避免跨 scan 的 DHT 覆盖。 */
private class ScanInfo {
    public let ns: Int64
    public let compIdx: Array<Int64>
    public let dcRefs: Array<HashMap<Int64, Int64>>
    public let acRefs: Array<HashMap<Int64, Int64>>
    public let ss: Int64
    public let se: Int64
    public let ah: Int64
    public let al: Int64
    public let entropy: Array<Byte>

    public init(ns: Int64, compIdx: Array<Int64>, dcRefs: Array<HashMap<Int64, Int64>>,
        acRefs: Array<HashMap<Int64, Int64>>, ss: Int64, se: Int64, ah: Int64, al: Int64,
        entropy: Array<Byte>) {
        this.ns = ns
        this.compIdx = compIdx
        this.dcRefs = dcRefs
        this.acRefs = acRefs
        this.ss = ss
        this.se = se
        this.ah = ah
        this.al = al
        this.entropy = entropy
    }
}

/** 渐进式解码的全图状态：每个组件按 MCU 网格分配系数缓冲与采样平面。 */
private class ProgressiveState {
    public let width: Int64
    public let height: Int64
    public let compCount: Int64
    public let hMax: Int64
    public let vMax: Int64
    public let mcusX: Int64
    public let mcusY: Int64
    public let compH: Array<Int64>
    public let compV: Array<Int64>
    public let compQ: Array<Int64>
    public let quant: ArrayList<Array<Int64>>
    public let coefBufs: ArrayList<Array<Int64>>
    public let blocksX: Array<Int64>
    public let blocksY: Array<Int64>
    public let strides: Array<Int64>
    public let planes: ArrayList<Array<Int64>>

    public init(width: Int64, height: Int64, compCount: Int64, hMax: Int64, vMax: Int64,
        compH: Array<Int64>, compV: Array<Int64>, compQ: Array<Int64>,
        quant: ArrayList<Array<Int64>>) {
        this.width = width
        this.height = height
        this.compCount = compCount
        this.hMax = hMax
        this.vMax = vMax
        this.compH = compH
        this.compV = compV
        this.compQ = compQ
        this.quant = quant
        this.mcusX = (width + 8 * hMax - 1) / (8 * hMax)
        this.mcusY = (height + 8 * vMax - 1) / (8 * vMax)
        this.blocksX = Array<Int64>(4, repeat: 0)
        this.blocksY = Array<Int64>(4, repeat: 0)
        this.strides = Array<Int64>(4, repeat: 0)
        this.coefBufs = ArrayList<Array<Int64>>()
        this.planes = ArrayList<Array<Int64>>()
        var c: Int64 = 0
        while (c < compCount) {
            this.blocksX[c] = this.mcusX * compH[c]
            this.blocksY[c] = this.mcusY * compV[c]
            let n = this.blocksX[c] * this.blocksY[c]
            this.coefBufs.add(Array<Int64>(n * 64, repeat: 0))
            this.strides[c] = this.blocksX[c] * 8
            let rows = this.blocksY[c] * 8
            this.planes.add(Array<Int64>(this.strides[c] * rows, repeat: 128))
            c = c + 1
        }
    }
}

public class JpegCodec {
    private static let ZIGZAG: Array<Int64> = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
    ]

    private static let IDCT_M: Array<Int64> = [
        181, 251, 237, 213, 181, 142, 98, 50,
        181, 213, 98, -50, -181, -251, -237, -142,
        181, 142, -98, -251, -181, 50, 237, 213,
        181, 50, -237, -142, 181, 213, -98, -251,
        181, -50, -237, 142, 181, -213, -98, 251,
        181, -142, -98, 251, -181, -50, 237, -213,
        181, -213, 98, 50, -181, 251, -237, 142,
        181, -251, 237, -213, 181, -142, 98, -50
    ]

    private static func u16(data: Array<Byte>, off: Int64): Int64 {
        return Int64(data[off]) * 256 + Int64(data[off + 1])
    }

    /** 2^n（Int64 乘法范式，不使用 << 以免 32 位有符号溢出）。 */
    private static func pow2(n: Int64): Int64 {
        var v: Int64 = 1
        var k: Int64 = 0
        while (k < n) {
            v = v * 2
            k = k + 1
        }
        return v
    }

    /** 由 DHT 的 bits/vals 构建 (len,code) → symbol 查表。 */
    private static func buildHuff(bits: Array<Int64>, vals: Array<Int64>): HashMap<Int64, Int64> {
        let map = HashMap<Int64, Int64>()
        var code: Int64 = 0
        var k: Int64 = 0
        var len: Int64 = 1
        while (len <= 16) {
            var j: Int64 = 0
            while (j < bits[len - 1]) {
                map[len * 65536 + code] = vals[k]
                code = code + 1
                k = k + 1
                j = j + 1
            }
            code = code * 2
            len = len + 1
        }
        return map
    }

    private static func huffDecode(bs: BitStream, table: HashMap<Int64, Int64>): Int64 {
        var code: Int64 = 0
        var len: Int64 = 1
        while (len <= 16) {
            code = code * 2 + bs.readBit()
            let hit = table.get(len * 65536 + code)
            match (hit) {
                case Some(v) => return v
                case None => ()
            }
            len = len + 1
        }
        throw AppError(AppErrorKind.ValidationFailed, "JPEG Huffman 码非法")
    }

    /** JPEG 的差分值符号扩展。 */
    private static func extendBits(v: Int64, n: Int64): Int64 {
        if (n == 0) {
            return 0
        }
        let half = 1 << (n - 1)
        if (v < half) {
            return v - half * 2 + 1
        }
        return v
    }

    /** 定点分离式 2D IDCT，输出 64 个 0..255 的采样值。 */
    private static func idct(coef: Array<Int64>): Array<Int64> {
        let tmp = Array<Int64>(64, repeat: 0)
        var v: Int64 = 0
        while (v < 8) {
            var x: Int64 = 0
            while (x < 8) {
                var s: Int64 = 0
                var u: Int64 = 0
                while (u < 8) {
                    s = s + coef[v * 8 + u] * JpegCodec.IDCT_M[x * 8 + u]
                    u = u + 1
                }
                tmp[v * 8 + x] = s / 512
                x = x + 1
            }
            v = v + 1
        }
        let out = Array<Int64>(64, repeat: 0)
        var y: Int64 = 0
        while (y < 8) {
            var x: Int64 = 0
            while (x < 8) {
                var s: Int64 = 0
                var t: Int64 = 0
                while (t < 8) {
                    s = s + tmp[t * 8 + x] * JpegCodec.IDCT_M[y * 8 + t]
                    t = t + 1
                }
                var p = s / 512 + 128
                if (p < 0) { p = 0 }
                if (p > 255) { p = 255 }
                out[y * 8 + x] = p
                x = x + 1
            }
            y = y + 1
        }
        return out
    }

    /** 解一个 8×8 块，返回像素值与更新后的 DC 预测值。 */
    private static func decodeBlock(bs: BitStream, dcTable: HashMap<Int64, Int64>,
        acTable: HashMap<Int64, Int64>, q: Array<Int64>, dcPred: Int64): (Array<Int64>, Int64) {
        let coef = Array<Int64>(64, repeat: 0)
        let t = JpegCodec.huffDecode(bs, dcTable)
        let diff = JpegCodec.extendBits(bs.readBits(t), t)
        let newDc = dcPred + diff
        coef[0] = newDc * q[0]
        var k: Int64 = 1
        while (k < 64) {
            let rs = JpegCodec.huffDecode(bs, acTable)
            let run = rs / 16
            let size = rs % 16
            if (size == 0) {
                if (run == 15) {
                    k = k + 16
                    continue
                }
                break
            }
            k = k + run
            if (k >= 64) {
                break
            }
            let val = JpegCodec.extendBits(bs.readBits(size), size)
            coef[JpegCodec.ZIGZAG[k]] = val * q[k]
            k = k + 1
        }
        return (JpegCodec.idct(coef), newDc)
    }

    private static func clamp(v: Int64): Int64 {
        if (v < 0) { return 0 }
        if (v > 255) { return 255 }
        return v
    }

    /**
     * 从 start 起收集熵数据：去 0xFF00 填充、跳 restart marker，遇真实 marker 停止。
     * 返回 (纯字节流, 下一个 marker 的 0xFF 下标)；无后续 marker 时为 data.size。
     */
    private static func extractEntropy(data: Array<Byte>, start: Int64): (Array<Byte>, Int64) {
        let out = ArrayList<Byte>()
        var i = start
        var nextPos = data.size
        while (i < data.size) {
            let b = Int64(data[i])
            if (b == 0xFF) {
                if (i + 1 >= data.size) {
                    nextPos = data.size
                    break
                }
                let n = Int64(data[i + 1])
                if (n == 0) {
                    out.add(UInt8(255))
                    i = i + 2
                    continue
                }
                if (n >= 0xD0 && n <= 0xD7) {
                    i = i + 2
                    continue
                }
                nextPos = i
                break
            }
            out.add(data[i])
            i = i + 1
        }
        return (out.toArray(), nextPos)
    }

    /** 解一个渐进式 scan：所有 block 累加写同一份全图系数缓冲。 */
    private static func decodeProgressiveScan(st: ProgressiveState, scan: ScanInfo): Unit {
        if (scan.ss < 0 || scan.ss > scan.se || scan.se > 63) {
            throw AppError(AppErrorKind.ValidationFailed, "渐进式扫描光谱范围(Ss/Se)不合法")
        }
        if (scan.ss >= 1 && scan.ns > 1) {
            throw AppError(AppErrorKind.ValidationFailed, "渐进式 AC 扫描不支持交错(Ns>1)")
        }
        if (scan.ss == 0 && scan.se != 0) {
            throw AppError(AppErrorKind.ValidationFailed, "渐进式 DC 扫描必须 Ss=Se=0")
        }
        let bs = BitStream(scan.entropy)
        // 点位变换比例 2^Al；细化扫描的修正量亦为 ±2^Al
        let p2al = JpegCodec.pow2(scan.al)
        // 建立本 scan 的 block 访问序列：(组件下标, scan 内序号, block 下标)
        let blkCi = ArrayList<Int64>()
        let blkSi = ArrayList<Int64>()
        let blkIdx = ArrayList<Int64>()
        if (scan.ns == 1) {
            let ci = scan.compIdx[0]
            var by: Int64 = 0
            while (by < st.blocksY[ci]) {
                var bx: Int64 = 0
                while (bx < st.blocksX[ci]) {
                    blkCi.add(ci)
                    blkSi.add(0)
                    blkIdx.add(by * st.blocksX[ci] + bx)
                    bx = bx + 1
                }
                by = by + 1
            }
        } else {
            var my: Int64 = 0
            while (my < st.mcusY) {
                var mx: Int64 = 0
                while (mx < st.mcusX) {
                    var si: Int64 = 0
                    while (si < scan.ns) {
                        let ci = scan.compIdx[si]
                        var by: Int64 = 0
                        while (by < st.compV[ci]) {
                            var bx: Int64 = 0
                            while (bx < st.compH[ci]) {
                                let idx = (my * st.compV[ci] + by) * st.blocksX[ci] + (mx * st.compH[ci] + bx)
                                blkCi.add(ci)
                                blkSi.add(si)
                                blkIdx.add(idx)
                                bx = bx + 1
                            }
                            by = by + 1
                        }
                        si = si + 1
                    }
                    mx = mx + 1
                }
                my = my + 1
            }
        }
        let dcFirst = scan.ss == 0 && scan.se == 0 && scan.ah == 0
        let dcRefine = scan.ss == 0 && scan.se == 0 && scan.ah > 0
        let acFirst = scan.ss >= 1 && scan.ah == 0
        // DC 预测器按组件独立，每个 scan 从 0 开始
        let dcPred = Array<Int64>(4, repeat: 0)
        var eobRun: Int64 = 0
        var b: Int64 = 0
        while (b < blkCi.size) {
            let ci = blkCi[b]
            let si = blkSi[b]
            let base = blkIdx[b] * 64
            let buf = st.coefBufs[ci]
            if (dcFirst) {
                // DC 首次扫描：Huffman 解差值分类 + 附加位。
                // 编码器先做点位变换再差分，故预测器为「变换域」累计值，
                // coef[0] += dcPred * 2^Al（等价于 diff << Al 的逐块累加）。
                let t = JpegCodec.huffDecode(bs, scan.dcRefs[si])
                let diff = JpegCodec.extendBits(bs.readBits(t), t)
                dcPred[ci] = dcPred[ci] + diff
                buf[base] = buf[base] + dcPred[ci] * p2al
            } else if (dcRefine) {
                // DC 细化扫描：每 block 读 1 个原始位（不经 Huffman），为 1 时按符号修正
                if (bs.readBit() == 1) {
                    if (buf[base] >= 0) {
                        buf[base] = buf[base] + p2al
                    } else {
                        buf[base] = buf[base] - p2al
                    }
                }
            } else if (acFirst) {
                // AC 首次扫描：EOBn / ZRL / (run,size)，非零系数值 ×2^Al
                if (eobRun > 0) {
                    eobRun = eobRun - 1
                } else {
                    var k = scan.ss
                    while (k <= scan.se) {
                        let rs = JpegCodec.huffDecode(bs, scan.acRefs[si])
                        let run = rs / 16
                        let size = rs % 16
                        if (size == 0) {
                            if (run == 15) {
                                k = k + 16
                                continue
                            }
                            eobRun = JpegCodec.pow2(run) + bs.readBits(run) - 1
                            break
                        }
                        k = k + run
                        if (k > scan.se) {
                            break
                        }
                        let val = JpegCodec.extendBits(bs.readBits(size), size)
                        let dest = base + JpegCodec.ZIGZAG[k]
                        buf[dest] = buf[dest] + val * p2al
                        k = k + 1
                    }
                }
            } else {
                // AC 细化扫描：新非零系数 ±2^Al，已有非零系数读 refinement 位
                if (eobRun > 0) {
                    eobRun = eobRun - 1
                } else {
                    var k = scan.ss
                    while (k <= scan.se) {
                        let rs = JpegCodec.huffDecode(bs, scan.acRefs[si])
                        let run = rs / 16
                        let size = rs % 16
                        var newVal: Int64 = 0
                        if (size != 0) {
                            if (bs.readBit() == 1) {
                                newVal = p2al
                            } else {
                                newVal = -p2al
                            }
                        } else {
                            if (run != 15) {
                                eobRun = JpegCodec.pow2(run) + bs.readBits(run) - 1
                                break
                            }
                        }
                        var r = run
                        while (k <= scan.se) {
                            let dest = base + JpegCodec.ZIGZAG[k]
                            let cur = buf[dest]
                            if (cur != 0) {
                                if (bs.readBit() == 1) {
                                    if ((cur & p2al) == 0) {
                                        if (cur >= 0) {
                                            buf[dest] = cur + p2al
                                        } else {
                                            buf[dest] = cur - p2al
                                        }
                                    }
                                }
                                k = k + 1
                            } else {
                                if (r == 0) {
                                    if (newVal != 0) {
                                        buf[dest] = newVal
                                    }
                                    k = k + 1
                                    break
                                }
                                r = r - 1
                                k = k + 1
                            }
                        }
                    }
                }
            }
            b = b + 1
        }
    }

    /** 全部 scan 结束后：统一反量化 → IDCT → 上采样 → YCbCr→RGB。 */
    private static func renderProgressive(st: ProgressiveState): RasterImage {
        var my: Int64 = 0
        while (my < st.mcusY) {
            var mx: Int64 = 0
            while (mx < st.mcusX) {
                var ci: Int64 = 0
                while (ci < st.compCount) {
                    let q = st.quant[st.compQ[ci]]
                    let buf = st.coefBufs[ci]
                    var by: Int64 = 0
                    while (by < st.compV[ci]) {
                        var bx: Int64 = 0
                        while (bx < st.compH[ci]) {
                            let blockIdx = (my * st.compV[ci] + by) * st.blocksX[ci] + (mx * st.compH[ci] + bx)
                            let base = blockIdx * 64
                            let deq = Array<Int64>(64, repeat: 0)
                            var k: Int64 = 0
                            while (k < 64) {
                                let nat = JpegCodec.ZIGZAG[k]
                                deq[nat] = buf[base + nat] * q[k]
                                k = k + 1
                            }
                            let block = JpegCodec.idct(deq)
                            let baseX = (mx * st.compH[ci] + bx) * 8
                            let baseY = (my * st.compV[ci] + by) * 8
                            var yy: Int64 = 0
                            while (yy < 8) {
                                var xx: Int64 = 0
                                while (xx < 8) {
                                    let idx = (baseY + yy) * st.strides[ci] + baseX + xx
                                    if (idx >= 0 && idx < st.planes[ci].size) {
                                        st.planes[ci][idx] = block[yy * 8 + xx]
                                    }
                                    xx = xx + 1
                                }
                                yy = yy + 1
                            }
                            bx = bx + 1
                        }
                        by = by + 1
                    }
                    ci = ci + 1
                }
                mx = mx + 1
            }
            my = my + 1
        }
        // 采样到全分辨率并转 RGB
        let rgb = Array<Byte>(st.width * st.height * 3, repeat: 0u8)
        var py: Int64 = 0
        while (py < st.height) {
            var px: Int64 = 0
            while (px < st.width) {
                var yy: Int64 = 128
                var cb: Int64 = 128
                var cr: Int64 = 128
                var k: Int64 = 0
                while (k < st.compCount) {
                    let sx = (px * st.compH[k]) / st.hMax
                    let sy = (py * st.compV[k]) / st.vMax
                    let idx = sy * st.strides[k] + sx
                    var val: Int64 = 128
                    if (idx >= 0 && idx < st.planes[k].size) {
                        val = st.planes[k][idx]
                    }
                    if (k == 0) {
                        yy = val
                    } else if (k == 1) {
                        cb = val
                    } else if (k == 2) {
                        cr = val
                    }
                    k = k + 1
                }
                let cbm = cb - 128
                let crm = cr - 128
                let r = JpegCodec.clamp(yy + (1402 * crm) / 1024)
                let g = JpegCodec.clamp(yy - (344 * cbm + 714 * crm) / 1024)
                let b = JpegCodec.clamp(yy + (1772 * cbm) / 1024)
                let o = (py * st.width + px) * 3
                rgb[o] = UInt8(r)
                rgb[o + 1] = UInt8(g)
                rgb[o + 2] = UInt8(b)
                px = px + 1
            }
            py = py + 1
        }
        return RasterImage(st.width, st.height, rgb)
    }

    /** Baseline / progressive JPEG → RGB。 */
    public static func decode(data: Array<Byte>): RasterImage {
        if (data.size < 4 || Int64(data[0]) != 0xFF || Int64(data[1]) != 0xD8) {
            throw AppError(AppErrorKind.ValidationFailed, "不是 JPEG 文件")
        }
        // 量化表 / Huffman 表：各 4 个槽
        let quant = ArrayList<Array<Int64>>()
        let dcTables = ArrayList<HashMap<Int64, Int64>>()
        let acTables = ArrayList<HashMap<Int64, Int64>>()
        var slot: Int64 = 0
        while (slot < 4) {
            quant.add(Array<Int64>(64, repeat: 16))
            dcTables.add(HashMap<Int64, Int64>())
            acTables.add(HashMap<Int64, Int64>())
            slot = slot + 1
        }
        let compId = Array<Int64>(4, repeat: 0)
        let compH = Array<Int64>(4, repeat: 1)
        let compV = Array<Int64>(4, repeat: 1)
        let compQ = Array<Int64>(4, repeat: 0)
        let compTd = Array<Int64>(4, repeat: 0)
        let compTa = Array<Int64>(4, repeat: 0)
        var width: Int64 = 0
        var height: Int64 = 0
        var compCount: Int64 = 0
        var hMax: Int64 = 1
        var vMax: Int64 = 1
        var sosEnd: Int64 = -1
        var progressive = false
        var entropy: Array<Byte> = Array<Byte>(0, repeat: 0u8)
        let scans = ArrayList<ScanInfo>()
        var pos: Int64 = 2
        while (pos + 1 < data.size) {
            if (Int64(data[pos]) != 0xFF) {
                pos = pos + 1
                continue
            }
            while (pos < data.size && Int64(data[pos]) == 0xFF) {
                pos = pos + 1
            }
            if (pos >= data.size) {
                break
            }
            let marker = Int64(data[pos])
            pos = pos + 1
            if (marker == 0xD9) {
                break
            }
            if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
                continue
            }
            if (pos + 2 > data.size) {
                break
            }
            let segLen = JpegCodec.u16(data, pos)
            let segStart = pos + 2
            let segEnd = segStart + segLen - 2
            if (segEnd > data.size || segLen < 2) {
                throw AppError(AppErrorKind.ValidationFailed, "JPEG 段长度不合法")
            }
            if (marker == 0xDB) {
                var p = segStart
                while (p < segEnd) {
                    let spec = Int64(data[p])
                    p = p + 1
                    if ((spec >> 4) != 0) {
                        throw AppError(AppErrorKind.ValidationFailed, "不支持 16-bit JPEG 量化表")
                    }
                    let tid = spec & 15
                    let q = Array<Int64>(64, repeat: 16)
                    var k: Int64 = 0
                    while (k < 64) {
                        q[k] = Int64(data[p + k])
                        k = k + 1
                    }
                    p = p + 64
                    quant[tid] = q
                }
            } else if (marker == 0xC4) {
                var p = segStart
                while (p < segEnd) {
                    let spec = Int64(data[p])
                    p = p + 1
                    let tc = spec >> 4
                    let th = spec & 15
                    let bits = Array<Int64>(16, repeat: 0)
                    var total: Int64 = 0
                    var k: Int64 = 0
                    while (k < 16) {
                        bits[k] = Int64(data[p + k])
                        total = total + bits[k]
                        k = k + 1
                    }
                    p = p + 16
                    let vals = Array<Int64>(total, repeat: 0)
                    k = 0
                    while (k < total) {
                        vals[k] = Int64(data[p + k])
                        k = k + 1
                    }
                    p = p + total
                    if (tc == 0) {
                        dcTables[th] = JpegCodec.buildHuff(bits, vals)
                    } else {
                        acTables[th] = JpegCodec.buildHuff(bits, vals)
                    }
                }
            } else if (marker == 0xC3) {
                throw AppError(AppErrorKind.ValidationFailed, "不支持无损 JPEG(SOF3)")
            } else if (marker == 0xC9 || marker == 0xCA || marker == 0xCB ||
                marker == 0xCD || marker == 0xCE || marker == 0xCF) {
                throw AppError(AppErrorKind.ValidationFailed, "不支持算术编码 JPEG(SOF9/10/11/13/14/15)")
            } else if (marker == 0xC5 || marker == 0xC6 || marker == 0xC7) {
                throw AppError(AppErrorKind.ValidationFailed, "不支持差分/层次 JPEG(SOF5/6/7)")
            } else if (marker == 0xCC) {
                throw AppError(AppErrorKind.ValidationFailed, "不支持算术编码条件表(DAC)")
            } else if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
                if (marker == 0xC2) {
                    progressive = true
                }
                let precision = Int64(data[segStart])
                if (precision != 8) {
                    throw AppError(AppErrorKind.ValidationFailed, "只支持 8-bit JPEG")
                }
                height = JpegCodec.u16(data, segStart + 1)
                width = JpegCodec.u16(data, segStart + 3)
                compCount = Int64(data[segStart + 5])
                if (compCount == 4) {
                    throw AppError(AppErrorKind.ValidationFailed, "不支持 CMYK/YCCK 四色 JPEG")
                }
                if (compCount < 1 || compCount > 4) {
                    throw AppError(AppErrorKind.ValidationFailed, "JPEG 组件数不合法")
                }
                var c: Int64 = 0
                while (c < compCount) {
                    let o = segStart + 6 + c * 3
                    compId[c] = Int64(data[o])
                    compH[c] = Int64(data[o + 1]) >> 4
                    compV[c] = Int64(data[o + 1]) & 15
                    compQ[c] = Int64(data[o + 2])
                    if (compH[c] < 1 || compV[c] < 1 || compH[c] > 4 || compV[c] > 4) {
                        throw AppError(AppErrorKind.ValidationFailed, "JPEG 采样因子不合法")
                    }
                    if (compH[c] > hMax) { hMax = compH[c] }
                    if (compV[c] > vMax) { vMax = compV[c] }
                    c = c + 1
                }
            } else if (marker == 0xDD) {
                throw AppError(AppErrorKind.ValidationFailed, "不支持带 restart interval 的 JPEG")
            } else if (marker == 0xDA) {
                let ns = Int64(data[segStart])
                if (ns < 1 || ns > 4) {
                    throw AppError(AppErrorKind.ValidationFailed, "JPEG 扫描组件数不合法")
                }
                let scanComp = Array<Int64>(ns, repeat: 0)
                let dcRefs = ArrayList<HashMap<Int64, Int64>>()
                let acRefs = ArrayList<HashMap<Int64, Int64>>()
                var c: Int64 = 0
                while (c < ns) {
                    let o = segStart + 1 + c * 2
                    let cs = Int64(data[o])
                    let tables = Int64(data[o + 1])
                    let td = tables / 16
                    let ta = tables % 16
                    var found = false
                    var k: Int64 = 0
                    while (k < compCount) {
                        if (compId[k] == cs) {
                            scanComp[c] = k
                            compTd[k] = td
                            compTa[k] = ta
                            found = true
                        }
                        k = k + 1
                    }
                    if (!found) {
                        throw AppError(AppErrorKind.ValidationFailed, "JPEG 扫描引用了未定义的组件")
                    }
                    dcRefs.add(dcTables[td])
                    acRefs.add(acTables[ta])
                    c = c + 1
                }
                let ph = segStart + 1 + ns * 2
                let ss = Int64(data[ph])
                let se = Int64(data[ph + 1])
                let ahl = Int64(data[ph + 2])
                let ah = ahl / 16
                let al = ahl % 16
                sosEnd = segEnd
                let (ent, nextPos) = JpegCodec.extractEntropy(data, segEnd)
                entropy = ent
                if (progressive) {
                    scans.add(ScanInfo(ns, scanComp, dcRefs.toArray(), acRefs.toArray(),
                        ss, se, ah, al, ent))
                    pos = nextPos
                    continue
                }
                break
            }
            pos = segEnd
        }
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || sosEnd < 0) {
            throw AppError(AppErrorKind.ValidationFailed, "JPEG 缺少 SOF/SOS 或尺寸不合法")
        }
        if (progressive) {
            if (scans.size == 0) {
                throw AppError(AppErrorKind.ValidationFailed, "渐进式 JPEG 缺少 scan")
            }
            let st = ProgressiveState(width, height, compCount, hMax, vMax,
                compH, compV, compQ, quant)
            var s: Int64 = 0
            while (s < scans.size) {
                JpegCodec.decodeProgressiveScan(st, scans[s])
                s = s + 1
            }
            return JpegCodec.renderProgressive(st)
        }
        // ---- baseline 路径：与旧实现逐字节一致 ----
        let bs = BitStream(entropy)
        let mcuW = 8 * hMax
        let mcuH = 8 * vMax
        let mcusX = (width + mcuW - 1) / mcuW
        let mcusY = (height + mcuH - 1) / mcuH
        let planes = ArrayList<Array<Int64>>()
        let strides = Array<Int64>(4, repeat: 0)
        var c: Int64 = 0
        while (c < compCount) {
            strides[c] = mcusX * 8 * compH[c]
            let rows = mcusY * 8 * compV[c]
            planes.add(Array<Int64>(strides[c] * rows, repeat: 128))
            c = c + 1
        }
        let dcPred = Array<Int64>(4, repeat: 0)
        var my: Int64 = 0
        while (my < mcusY) {
            var mx: Int64 = 0
            while (mx < mcusX) {
                var ci: Int64 = 0
                while (ci < compCount) {
                    let q = quant[compQ[ci]]
                    let dt = dcTables[compTd[ci]]
                    let at = acTables[compTa[ci]]
                    var by: Int64 = 0
                    while (by < compV[ci]) {
                        var bx: Int64 = 0
                        while (bx < compH[ci]) {
                            let (block, newDc) = JpegCodec.decodeBlock(bs, dt, at, q, dcPred[ci])
                            dcPred[ci] = newDc
                            let baseX = (mx * compH[ci] + bx) * 8
                            let baseY = (my * compV[ci] + by) * 8
                            var yy: Int64 = 0
                            while (yy < 8) {
                                var xx: Int64 = 0
                                while (xx < 8) {
                                    let idx = (baseY + yy) * strides[ci] + baseX + xx
                                    if (idx >= 0 && idx < planes[ci].size) {
                                        planes[ci][idx] = block[yy * 8 + xx]
                                    }
                                    xx = xx + 1
                                }
                                yy = yy + 1
                            }
                            bx = bx + 1
                        }
                        by = by + 1
                    }
                    ci = ci + 1
                }
                mx = mx + 1
            }
            my = my + 1
        }
        // 采样到全分辨率并转 RGB
        let rgb = Array<Byte>(width * height * 3, repeat: 0u8)
        var py: Int64 = 0
        while (py < height) {
            var px: Int64 = 0
            while (px < width) {
                var yy: Int64 = 128
                var cb: Int64 = 128
                var cr: Int64 = 128
                var k: Int64 = 0
                while (k < compCount) {
                    let sx = (px * compH[k]) / hMax
                    let sy = (py * compV[k]) / vMax
                    let idx = sy * strides[k] + sx
                    var val: Int64 = 128
                    if (idx >= 0 && idx < planes[k].size) {
                        val = planes[k][idx]
                    }
                    if (k == 0) {
                        yy = val
                    } else if (k == 1) {
                        cb = val
                    } else if (k == 2) {
                        cr = val
                    }
                    k = k + 1
                }
                let cbm = cb - 128
                let crm = cr - 128
                let r = JpegCodec.clamp(yy + (1402 * crm) / 1024)
                let g = JpegCodec.clamp(yy - (344 * cbm + 714 * crm) / 1024)
                let b = JpegCodec.clamp(yy + (1772 * cbm) / 1024)
                let o = (py * width + px) * 3
                rgb[o] = UInt8(r)
                rgb[o + 1] = UInt8(g)
                rgb[o + 2] = UInt8(b)
                px = px + 1
            }
            py = py + 1
        }
        return RasterImage(width, height, rgb)
    }
}
