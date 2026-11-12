// ============================================================
// ams.core.media · PNG 编解码（纯仓颉实现）
//
// 【为什么要自己写】
//   SDK 没有图像编解码库。但附件域需要的只是「把 PNG 变成 RGB 像素」
//   与「把 RGB 像素写回 PNG」——PNG 本身是 zlib + 几种行过滤器，
//   而本项目自研的 ZIP 读取器已经验证了 stdx.compress.zlib 的
//   DecompressInputStream（裸 deflate / WrapType.DeflateFormat）。
//
// 【关键技巧】
//   ① 解码：PNG 的 IDAT 是 zlib 包裹（RFC 1950）= 2 字节头 + 裸
//      deflate + 4 字节 Adler-32。剥掉头尾即可喂给已验证的裸 deflate
//      解压器，无需猜测 WrapType 的其它取值。
//   ② 编码：不实现 deflate 压缩算法，改用 RFC 1951 的 **stored 块**
//      （BTYPE=00）构造合法 zlib 流。产物较大但完全合规、零依赖，
//      对缩略图 / 水印图足够。
//   ③ CRC-32 / Adler-32 逐位实现，不依赖任何压缩库。
//
// 【支持范围】8-bit 非隔行 PNG，color type 0/2/3/4/6；
//   不支持 16-bit、隔行、JPEG、PDF 栅格化（由 MediaEngine 分流）。
// ============================================================
package ams.core.media

import std.collection.*
import std.io.*
import stdx.compress.zlib.*

import ams.kernel.error.*

/**
 * 栅格图像：RGB 三通道，行优先，pixels.size = width * height * 3。
 */
public class RasterImage {
    public let width: Int64
    public let height: Int64
    public let pixels: Array<Byte>

    public init(width: Int64, height: Int64, pixels: Array<Byte>) {
        this.width = width
        this.height = height
        this.pixels = pixels
    }

    /** 白底空图（供自测与合成用）。 */
    public static func white(width: Int64, height: Int64): RasterImage {
        return RasterImage(width, height, Array<Byte>(width * height * 3, repeat: 255u8))
    }
}

public class PngCodec {
    private static let TAG_IHDR: Int64 = 0x49484452
    private static let TAG_PLTE: Int64 = 0x504C5445
    private static let TAG_IDAT: Int64 = 0x49444154
    private static let TAG_IEND: Int64 = 0x49454E44

    /** 单张图片解压上限：防止 zip-bomb 式的超大 IDAT。 */
    private static let MAX_RAW_BYTES: Int64 = 64 * 1024 * 1024

    /** 读大端 32 位无符号整数（用乘法避免位移歧义）。 */
    private static func u32(data: Array<Byte>, off: Int64): Int64 {
        return Int64(data[off]) * 16777216 + Int64(data[off + 1]) * 65536 +
            Int64(data[off + 2]) * 256 + Int64(data[off + 3])
    }

    private static func putU32(buf: Array<Byte>, off: Int64, v: Int64): Unit {
        buf[off] = UInt8((v / 16777216) & 255)
        buf[off + 1] = UInt8((v / 65536) & 255)
        buf[off + 2] = UInt8((v / 256) & 255)
        buf[off + 3] = UInt8(v & 255)
    }

    /** CRC-32（IEEE 802.3，逐位实现）。 */
    public static func crc32(data: Array<Byte>): Int64 {
        var crc: Int64 = 0xFFFFFFFF
        for (b in data) {
            crc = crc ^ Int64(b)
            var i: Int64 = 0
            while (i < 8) {
                if ((crc & 1) == 1) {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc = crc >> 1
                }
                crc = crc & 0xFFFFFFFF
                i = i + 1
            }
        }
        return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
    }

    /** Adler-32（zlib 尾校验）。 */
    public static func adler32(data: Array<Byte>): Int64 {
        var a: Int64 = 1
        var b: Int64 = 0
        for (x in data) {
            a = (a + Int64(x)) % 65521
            b = (b + a) % 65521
        }
        return b * 65536 + a
    }

    /**
     * 解 zlib 包裹的数据：剥 2 字节头（FDICT 时 6 字节）与 4 字节 Adler-32，
     * 剩下就是裸 deflate，交给 ZIP 读取器已验证的解压器。
     */
    public static func inflateZlib(data: Array<Byte>, maxBytes: Int64): Array<Byte> {
        if (data.size < 7) {
            throw AppError(AppErrorKind.ValidationFailed, "zlib 数据过短")
        }
        var head: Int64 = 2
        if ((Int64(data[1]) & 0x20) != 0) {
            head = 6
        }
        let end = data.size - 4
        if (end <= head) {
            throw AppError(AppErrorKind.ValidationFailed, "zlib 数据长度不合法")
        }
        let raw = Array<Byte>(end - head, repeat: 0u8)
        var i: Int64 = head
        while (i < end) {
            raw[i - head] = data[i]
            i = i + 1
        }
        let out = ArrayList<Byte>()
        let dis = DecompressInputStream(ByteBuffer(raw), wrap: WrapType.DeflateFormat, bufLen: 32768)
        try {
            let buf = Array<Byte>(32768, repeat: 0u8)
            while (true) {
                let n = dis.read(buf)
                if (n <= 0) {
                    break
                }
                if (out.size + n > maxBytes) {
                    throw AppError(AppErrorKind.PayloadTooLarge, "解压后超过上限")
                }
                for (k in 0..n) {
                    out.add(buf[k])
                }
            }
        } catch (e: Exception) {
            throw AppError(AppErrorKind.ValidationFailed, "zlib 解压失败（数据损坏）")
        } finally {
            try {
                dis.close()
            } catch (e: Exception) {
                // 关闭失败不影响已解出的数据
            }
        }
        return out.toArray()
    }

    /**
     * 构造 zlib 流：CMF/FLG + 若干 stored deflate 块 + Adler-32。
     * 不做压缩，但生成的是完全合法的 zlib 数据流。
     */
    public static func zlibStored(data: Array<Byte>): Array<Byte> {
        let out = ArrayList<Byte>()
        out.add(UInt8(0x78))
        out.add(UInt8(0x01))
        let n = data.size
        if (n == 0) {
            out.add(UInt8(1))
            out.add(UInt8(0))
            out.add(UInt8(0))
            out.add(UInt8(255))
            out.add(UInt8(255))
        } else {
            var pos: Int64 = 0
            while (pos < n) {
                var len = n - pos
                if (len > 65535) {
                    len = 65535
                }
                let last = if (pos + len >= n) { 1 } else { 0 }
                out.add(UInt8(last))
                out.add(UInt8(len & 255))
                out.add(UInt8((len / 256) & 255))
                let nlen = 65535 - len
                out.add(UInt8(nlen & 255))
                out.add(UInt8((nlen / 256) & 255))
                var k: Int64 = 0
                while (k < len) {
                    out.add(data[pos + k])
                    k = k + 1
                }
                pos = pos + len
            }
        }
        let ad = PngCodec.adler32(data)
        out.add(UInt8((ad / 16777216) & 255))
        out.add(UInt8((ad / 65536) & 255))
        out.add(UInt8((ad / 256) & 255))
        out.add(UInt8(ad & 255))
        return out.toArray()
    }

    private static func paeth(a: Int64, b: Int64, c: Int64): Int64 {
        let p = a + b - c
        let pa = if (p >= a) { p - a } else { a - p }
        let pb = if (p >= b) { p - b } else { b - p }
        let pc = if (p >= c) { p - c } else { c - p }
        if (pa <= pb && pa <= pc) {
            return a
        }
        if (pb <= pc) {
            return b
        }
        return c
    }

    /** PNG 解码 → RGB。 */
    public static func decode(data: Array<Byte>): RasterImage {
        if (data.size < 33 || Int64(data[0]) != 0x89 || Int64(data[1]) != 0x50 ||
            Int64(data[2]) != 0x4E || Int64(data[3]) != 0x47) {
            throw AppError(AppErrorKind.ValidationFailed, "不是 PNG 文件")
        }
        var pos: Int64 = 8
        var w: Int64 = 0
        var h: Int64 = 0
        var depth: Int64 = 0
        var ctype: Int64 = 0
        var interlace: Int64 = 0
        let palette = ArrayList<Byte>()
        let idat = ArrayList<Byte>()
        while (pos + 12 <= data.size) {
            let len = PngCodec.u32(data, pos)
            if (len < 0 || pos + 12 + len > data.size) {
                break
            }
            let tag = PngCodec.u32(data, pos + 4)
            let body = pos + 8
            if (tag == PngCodec.TAG_IHDR && len >= 13) {
                w = PngCodec.u32(data, body)
                h = PngCodec.u32(data, body + 4)
                depth = Int64(data[body + 8])
                ctype = Int64(data[body + 9])
                interlace = Int64(data[body + 12])
            } else if (tag == PngCodec.TAG_PLTE) {
                for (k in 0..len) {
                    palette.add(data[body + k])
                }
            } else if (tag == PngCodec.TAG_IDAT) {
                for (k in 0..len) {
                    idat.add(data[body + k])
                }
            } else if (tag == PngCodec.TAG_IEND) {
                break
            }
            pos = pos + 12 + len
        }
        if (w <= 0 || h <= 0 || w > 8192 || h > 8192) {
            throw AppError(AppErrorKind.ValidationFailed, "PNG 尺寸不合法")
        }
        if (depth != 8 || interlace != 0 || (ctype != 0 && ctype != 2 &&
            ctype != 3 && ctype != 4 && ctype != 6)) {
            throw AppError(AppErrorKind.ValidationFailed, "不支持的 PNG 变体（需 8-bit 非隔行）")
        }
        let bpp = if (ctype == 0) { 1 } else {
            if (ctype == 2) { 3 } else {
                if (ctype == 3) { 1 } else {
                    if (ctype == 4) { 2 } else { 4 }
                }
            }
        }
        let stride = w * bpp
        let cap = h * (stride + 1) + 1024
        let limit = if (cap > PngCodec.MAX_RAW_BYTES) { PngCodec.MAX_RAW_BYTES } else { cap }
        let raw = PngCodec.inflateZlib(idat.toArray(), limit)
        if (raw.size < h * (stride + 1)) {
            throw AppError(AppErrorKind.ValidationFailed, "PNG 扫描线数据不足")
        }
        let px = Array<Byte>(w * h * 3, repeat: 0u8)
        let prev = Array<Byte>(stride, repeat: 0u8)
        var p: Int64 = 0
        var y: Int64 = 0
        while (y < h) {
            let ft = Int64(raw[p])
            p = p + 1
            let line = Array<Byte>(stride, repeat: 0u8)
            for (k in 0..stride) {
                line[k] = raw[p + k]
            }
            p = p + stride
            var i: Int64 = 0
            while (i < stride) {
                let a = if (i >= bpp) { Int64(line[i - bpp]) } else { 0 }
                let b = Int64(prev[i])
                let c = if (i >= bpp) { Int64(prev[i - bpp]) } else { 0 }
                var v = Int64(line[i])
                if (ft == 1) {
                    v = v + a
                } else if (ft == 2) {
                    v = v + b
                } else if (ft == 3) {
                    v = v + (a + b) / 2
                } else if (ft == 4) {
                    v = v + PngCodec.paeth(a, b, c)
                } else if (ft != 0) {
                    throw AppError(AppErrorKind.ValidationFailed, "未知的 PNG 行过滤器")
                }
                line[i] = UInt8(v & 255)
                i = i + 1
            }
            var x: Int64 = 0
            while (x < w) {
                let o = x * bpp
                var r: Int64 = 0
                var g: Int64 = 0
                var bl: Int64 = 0
                if (ctype == 0) {
                    r = Int64(line[o])
                    g = r
                    bl = r
                } else if (ctype == 2) {
                    r = Int64(line[o])
                    g = Int64(line[o + 1])
                    bl = Int64(line[o + 2])
                } else if (ctype == 3) {
                    let idx = Int64(line[o]) * 3
                    if (idx + 2 >= palette.size) {
                        throw AppError(AppErrorKind.ValidationFailed, "PNG 调色板索引越界")
                    }
                    r = Int64(palette[idx])
                    g = Int64(palette[idx + 1])
                    bl = Int64(palette[idx + 2])
                } else if (ctype == 4) {
                    let v = Int64(line[o])
                    let al = Int64(line[o + 1])
                    let mixed = (v * al + 255 * (255 - al)) / 255
                    r = mixed
                    g = mixed
                    bl = mixed
                } else {
                    let al = Int64(line[o + 3])
                    r = (Int64(line[o]) * al + 255 * (255 - al)) / 255
                    g = (Int64(line[o + 1]) * al + 255 * (255 - al)) / 255
                    bl = (Int64(line[o + 2]) * al + 255 * (255 - al)) / 255
                }
                let q = (y * w + x) * 3
                px[q] = UInt8(r)
                px[q + 1] = UInt8(g)
                px[q + 2] = UInt8(bl)
                x = x + 1
            }
            for (k in 0..stride) {
                prev[k] = line[k]
            }
            y = y + 1
        }
        return RasterImage(w, h, px)
    }

    /** RGB → PNG（8-bit truecolor，stored deflate）。 */
    public static func encode(img: RasterImage): Array<Byte> {
        let stride = img.width * 3
        let raw = Array<Byte>(img.height * (stride + 1), repeat: 0u8)
        var p: Int64 = 0
        var y: Int64 = 0
        while (y < img.height) {
            raw[p] = 0u8
            p = p + 1
            var k: Int64 = 0
            while (k < stride) {
                raw[p + k] = img.pixels[y * stride + k]
                k = k + 1
            }
            p = p + stride
            y = y + 1
        }
        let out = ArrayList<Byte>()
        out.add(UInt8(0x89))
        out.add(UInt8(0x50))
        out.add(UInt8(0x4E))
        out.add(UInt8(0x47))
        out.add(UInt8(0x0D))
        out.add(UInt8(0x0A))
        out.add(UInt8(0x1A))
        out.add(UInt8(0x0A))
        let ihdr = Array<Byte>(13, repeat: 0u8)
        PngCodec.putU32(ihdr, 0, img.width)
        PngCodec.putU32(ihdr, 4, img.height)
        ihdr[8] = 8u8
        ihdr[9] = 2u8
        PngCodec.appendChunk(out, "IHDR".toArray(), ihdr)
        PngCodec.appendChunk(out, "IDAT".toArray(), PngCodec.zlibStored(raw))
        PngCodec.appendChunk(out, "IEND".toArray(), Array<Byte>(0, repeat: 0u8))
        return out.toArray()
    }

    private static func appendChunk(out: ArrayList<Byte>, tag: Array<Byte>, data: Array<Byte>): Unit {
        let len = data.size
        out.add(UInt8((len / 16777216) & 255))
        out.add(UInt8((len / 65536) & 255))
        out.add(UInt8((len / 256) & 255))
        out.add(UInt8(len & 255))
        for (b in tag) {
            out.add(b)
        }
        for (b in data) {
            out.add(b)
        }
        let check = ArrayList<Byte>()
        for (b in tag) {
            check.add(b)
        }
        for (b in data) {
            check.add(b)
        }
        let crc = PngCodec.crc32(check.toArray())
        out.add(UInt8((crc / 16777216) & 255))
        out.add(UInt8((crc / 65536) & 255))
        out.add(UInt8((crc / 256) & 255))
        out.add(UInt8(crc & 255))
    }
}
