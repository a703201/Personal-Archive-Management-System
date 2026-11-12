// ============================================================
// ams.core.media · BMP 解码（纯仓颉、零外部依赖、进程内）
//
// 【定位】
//   附件域只需要「把 BMP 变成 RGB 像素」。本解码器完全用仓颉标准库
//   逐字节解析，不调用任何图像库、不启外部进程、不监听端口，
//   由 AttachmentService / MediaEngine 在进程内直接调用，结果仍是
//   行优先、每像素 3 字节的 RasterImage。
//
// 【支持的格式矩阵（如实标注）】
//   信息头     BITMAPINFOHEADER（40 字节）                 ✅
//   压缩       BI_RGB（compression = 0）                   ✅
//   位深       24-bit BGR / 32-bit BGRA（忽略 alpha）      ✅
//              8-bit 调色板索引 / 1-bit 双色索引           ✅
//   行序       height > 0 自下而上 / height < 0 自上而下   ✅
//   行对齐     ((width*bpp+31)/32)*4，跳过 row padding      ✅
//
// 【明确不支持（一律抛 AppError，绝不静默返回空白图）】
//   · RLE4 / RLE8 / BI_BITFIELDS / BI_ALPHABITFIELDS / JPEG / PNG 等压缩
//   · OS/2 BITMAPCOREHEADER（12 字节信息头）及其它非 40 字节信息头
//   · 16-bit / 4-bit / 2-bit 等其它位深
//   · 带 alpha 合成：32-bit 直接丢弃 alpha，不做半透明混合
//   · 宽高 ≤0 或 >8192、像素数据不足、调色板越界
//
// 【小端】所有多字节整数按小端读取；用逐字节乘加（v = v*256 + byte）
//   组装，避免 32 位位移与有符号溢出踩坑；有符号宽高单独换算。
// ============================================================
package ams.core.media

import std.collection.*

import ams.kernel.error.*

public class BmpCodec {
    private static let INFO_HEADER_SIZE: Int64 = 40
    private static let HEADER_SIZE: Int64 = 54
    private static let MAX_SIDE: Int64 = 8192

    /** 小端读 2 字节无符号整数（逐字节累加）。 */
    private static func leU16(data: Array<Byte>, off: Int64): Int64 {
        return Int64(data[off]) + Int64(data[off + 1]) * 256
    }

    /**
     * 小端读 4 字节无符号整数：从最高位字节往下 v = v*256 + byte，
     * 结果恒为非负 Int64（0 .. 4294967295），不做位移。
     */
    private static func leU32(data: Array<Byte>, off: Int64): Int64 {
        var v: Int64 = 0
        var k: Int64 = 3
        while (k >= 0) {
            v = v * 256 + Int64(data[off + k])
            k = k - 1
        }
        return v
    }

    /** 小端读 4 字节有符号整数（宽 / 高；height 可为负表示自上而下）。 */
    private static func leI32(data: Array<Byte>, off: Int64): Int64 {
        let u = BmpCodec.leU32(data, off)
        if (u >= 2147483648) {
            return u - 4294967296
        }
        return u
    }

    /**
     * BMP → RGB。pixels 行优先、每像素 3 字节；返回图高度恒为正。
     * 任何不支持 / 损坏的输入都抛 AppError(ValidationFailed)。
     */
    public static func decode(data: Array<Byte>): RasterImage {
        // ---- BITMAPFILEHEADER（14 字节）----
        //  0..1  'B''M'      2..5  bfSize（不少编码器填不准，仅解析不据此拒绝）
        //  6..9  bfReserved  10..13 bfOffBits（像素数据起点，权威）
        // ---- BITMAPINFOHEADER（40 字节）----
        // 14..17 biSize       18..21 biWidth       22..25 biHeight
        // 26..27 biPlanes     28..29 biBitCount    30..33 biCompression
        // 34..37 biSizeImage  38..41 biXPelsPerMeter 42..45 biYPelsPerMeter
        // 46..49 biClrUsed    50..53 biClrImportant
        if (data.size < BmpCodec.HEADER_SIZE) {
            throw AppError(AppErrorKind.ValidationFailed,
                "BMP 数据过短（不足 54 字节文件头+信息头）")
        }
        if (Int64(data[0]) != 0x42 || Int64(data[1]) != 0x4D) {
            throw AppError(AppErrorKind.ValidationFailed, "BMP 魔数不是 BM")
        }
        let bfOffBits = BmpCodec.leU32(data, 10)
        let biSize = BmpCodec.leU32(data, 14)
        let w = BmpCodec.leI32(data, 18)
        let h = BmpCodec.leI32(data, 22)
        let planes = BmpCodec.leU16(data, 26)
        let bpp = BmpCodec.leU16(data, 28)
        let compression = BmpCodec.leU32(data, 30)
        let clrUsed = BmpCodec.leU32(data, 46)

        if (biSize != BmpCodec.INFO_HEADER_SIZE) {
            throw AppError(AppErrorKind.ValidationFailed,
                "BMP 仅支持 40 字节 BITMAPINFOHEADER（拒绝 OS/2 BITMAPCOREHEADER 等变体）")
        }
        if (planes != 1) {
            throw AppError(AppErrorKind.ValidationFailed, "BMP biPlanes 必须为 1")
        }
        if (compression != 0) {
            throw AppError(AppErrorKind.ValidationFailed,
                "BMP 不支持压缩（仅 BI_RGB；RLE4/RLE8/BI_BITFIELDS 等一律拒绝）")
        }
        if (bpp != 1 && bpp != 8 && bpp != 24 && bpp != 32) {
            throw AppError(AppErrorKind.ValidationFailed,
                "BMP 不支持的位深（仅 1/8/24/32，拒绝 16-bit 等）")
        }
        let absH = if (h < 0) { -h } else { h }
        if (w <= 0 || w > BmpCodec.MAX_SIDE || absH <= 0 || absH > BmpCodec.MAX_SIDE) {
            throw AppError(AppErrorKind.ValidationFailed, "BMP 宽高不合法（需 1..8192）")
        }
        if (bfOffBits < BmpCodec.HEADER_SIZE || bfOffBits > data.size) {
            throw AppError(AppErrorKind.ValidationFailed, "BMP 像素数据偏移不合法")
        }

        // 每行按 DWORD（4 字节）对齐，跳过 padding。
        let stride = ((w * bpp + 31) / 32) * 4
        if (bfOffBits + absH * stride > data.size) {
            throw AppError(AppErrorKind.ValidationFailed, "BMP 像素数据不足")
        }

        // 调色板：紧随信息头之后（54 起），每项 B,G,R,0 四字节。
        // biClrUsed 为 0 时按 2^bpp 取默认项数；调色板必须落在 bfOffBits 之前。
        let paletteStart = BmpCodec.HEADER_SIZE
        var numColors: Int64 = 0
        if (bpp == 8 || bpp == 1) {
            numColors = if (clrUsed > 0) { clrUsed } else {
                if (bpp == 8) { 256 } else { 2 }
            }
            let paletteBytes = numColors * 4
            if (paletteStart + paletteBytes > bfOffBits) {
                throw AppError(AppErrorKind.ValidationFailed, "BMP 调色板越界")
            }
        }

        let topDown = h < 0
        let px = Array<Byte>(w * absH * 3, repeat: 0u8)
        var y: Int64 = 0
        while (y < absH) {
            // height > 0 自下而上：文件首行是图像最底行；height < 0 自上而下。
            let srcRow = if (topDown) { y } else { (absH - 1 - y) }
            let lineStart = bfOffBits + srcRow * stride
            var x: Int64 = 0
            while (x < w) {
                var r: Int64 = 0
                var g: Int64 = 0
                var bl: Int64 = 0
                if (bpp == 24 || bpp == 32) {
                    let step: Int64 = if (bpp == 24) { 3 } else { 4 }
                    let o = lineStart + x * step
                    bl = Int64(data[o])
                    g = Int64(data[o + 1])
                    r = Int64(data[o + 2])
                    // bpp == 32 时 o+3 是 alpha，直接忽略，不做合成
                } else {
                    var idx: Int64 = 0
                    if (bpp == 8) {
                        idx = Int64(data[lineStart + x])
                    } else {
                        // 1-bit：每字节 MSB 在前，x 对应第 (7 - x%8) 位。
                        // 用乘 2 求权值取位，避免位移。
                        let srcByte = Int64(data[lineStart + x / 8])
                        let bitPos = 7 - (x % 8)
                        var divisor: Int64 = 1
                        var t: Int64 = 0
                        while (t < bitPos) {
                            divisor = divisor * 2
                            t = t + 1
                        }
                        idx = (srcByte / divisor) % 2
                    }
                    if (idx >= numColors) {
                        throw AppError(AppErrorKind.ValidationFailed, "BMP 调色板索引越界")
                    }
                    let o = paletteStart + idx * 4
                    bl = Int64(data[o])
                    g = Int64(data[o + 1])
                    r = Int64(data[o + 2])
                }
                let q = (y * w + x) * 3
                px[q] = UInt8(r)
                px[q + 1] = UInt8(g)
                px[q + 2] = UInt8(bl)
                x = x + 1
            }
            y = y + 1
        }
        return RasterImage(w, absH, px)
    }
}
