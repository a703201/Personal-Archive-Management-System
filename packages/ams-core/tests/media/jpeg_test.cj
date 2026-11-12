// ============================================================
// ams.core.media · JPEG 解码单元测试（baseline + 渐进式）
//
// 夹具是**可控的最小合法 JPEG**（8×8 灰度、自定义 Huffman 表、
// DC 差值 0 + EOB），不依赖任何图像库或外部文件：
//   SOI / DQT(全 16) / SOF0(1 组件 8x8) / DHT(DC: 2bit cat0, AC: 4bit EOB)
//   / SOS / entropy(0x03) / EOI
// 所有 DCT 系数为零 ⇒ IDCT 后应为平坦的 128 灰。
//
// 渐进式夹具（Windows GDI+ 实测可解码）均为 SOF2、量化表全 16、
// 1 个灰度组件、8×8、自定义 Huffman 表（DC 与 AC 各 1 个长度 1 的码：
// DC 符号 0、AC 符号 0x00=EOB），熵数据字节 0x7F（bit 0 + 填充 1）。
// DC/AC 系数全 0 ⇒ 反量化 + IDCT 后为平坦 128 灰（允许 126..130）。
//   PROG_DC      : DC 首次扫描（Ss=0,Se=0,Ah=0,Al=0），1 scan
//   PROG_DC_AC   : DC 首次扫描 + 全 AC 首次扫描（Ss=1,Se=63），2 scan
//   PROG_SA      : 逐次逼近 DC(Al=1) → DC 细化(Ah=1,Al=0) → AC 扫描，3 scan
// ============================================================
package ams.core.media.test

import std.collection.*
import std.unittest.*

import ams.core.media.*

@Test
public class JpegCodecTest {
    private static let JPEG_8X8: String =
        "FFD8FFDB004300101010101010101010101010101010101010101010101010101010101010101010" +
        "10101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC0000B080008000801011100" +
        "FFC40014000001000000000000000000000000000000" +
        "FFC40014100000000100000000000000000000000000" +
        "FFDA0008010100003F0003FFD9"

    // 夹具 A：DC-only 渐进扫描，1 个 scan
    private static let PROG_DC: String =
        "FFD8" +
        "FFDB00430010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC2000B080008000801011100" +
        "FFC40014000100000000000000000000000000000000" +
        "FFC40014100100000000000000000000000000000000" +
        "FFDA00080101000000007F" +
        "FFD9"

    // 夹具 B：DC 扫描 + 全 AC 扫描，2 个 scan
    private static let PROG_DC_AC: String =
        "FFD8" +
        "FFDB00430010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC2000B080008000801011100" +
        "FFC40014000100000000000000000000000000000000" +
        "FFC40014100100000000000000000000000000000000" +
        "FFDA00080101000000007F" +
        "FFDA0008010100013F007F" +
        "FFD9"

    // 夹具 C：逐次逼近（DC Al=1 → DC refine Ah=1,Al=0 → AC 扫描），3 个 scan
    private static let PROG_SA: String =
        "FFD8" +
        "FFDB00430010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC2000B080008000801011100" +
        "FFC40014000100000000000000000000000000000000" +
        "FFC40014100100000000000000000000000000000000" +
        "FFDA00080101000000017F" +
        "FFDA00080101000000107F" +
        "FFDA0008010100013F007F" +
        "FFD9"

    // 把夹具 A 的 SOF2(FFC2) 换成算术编码 SOF9(FFC9) 的伪 JPEG，用于拒绝性测试
    private static let JPEG_ARITH_SOF9: String =
        "FFD8" +
        "FFDB00430010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC9000B080008000801011100" +
        "FFC40014000100000000000000000000000000000000" +
        "FFC40014100100000000000000000000000000000000" +
        "FFDA00080101000000007F" +
        "FFD9"

    private static func hexVal(b: Int64): Int64 {
        if (b >= 48 && b <= 57) { return b - 48 }
        if (b >= 65 && b <= 70) { return b - 55 }
        return 0
    }

    private static func hexBytes(s: String): Array<Byte> {
        let out = ArrayList<Byte>()
        var i: Int64 = 0
        while (i + 1 < s.size) {
            let hi = JpegCodecTest.hexVal(Int64(s[i]))
            let lo = JpegCodecTest.hexVal(Int64(s[i + 1]))
            out.add(UInt8(hi * 16 + lo))
            i = i + 2
        }
        return out.toArray()
    }

    /** 全像素是否落在 126..130（平坦 128 灰，允许 ±2 抖动）。 */
    private static func isFlatGray(img: RasterImage): Bool {
        var flat = true
        var i: Int64 = 0
        while (i < img.pixels.size) {
            if (Int64(img.pixels[i]) < 126 || Int64(img.pixels[i]) > 130) {
                flat = false
            }
            i = i + 1
        }
        return flat
    }

    /** 期望 decode 抛 AppError；被静默接受则返回 false。 */
    private static func isRejected(data: Array<Byte>): Bool {
        var rejected = false
        try {
            let img = JpegCodec.decode(data)
            let w = img.width
            if (w > 0) {
                rejected = false
            }
        } catch (e: Exception) {
            rejected = true
        }
        return rejected
    }

    @TestCase
    public func testMinimalJpegDecode() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.JPEG_8X8)
        @Assert(MediaEngine.sniff(raw), "jpeg")
        let img = JpegCodec.decode(raw)
        @Assert(img.width, 8)
        @Assert(img.height, 8)
        @Assert(img.pixels.size, 192)
        var flat = true
        var i: Int64 = 0
        while (i < img.pixels.size) {
            if (Int64(img.pixels[i]) < 126 || Int64(img.pixels[i]) > 130) {
                flat = false
            }
            i = i + 1
        }
        @Assert(flat, true)
    }

    @TestCase
    public func testJpegPixelRoundTripThroughPng() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.JPEG_8X8)
        let jpeg = JpegCodec.decode(raw)
        let png = PngCodec.encode(jpeg)
        let back = PngCodec.decode(png)
        @Assert(back.width, 8)
        @Assert(back.height, 8)
        @Assert(back.pixels.size, jpeg.pixels.size)
        var same = true
        var i: Int64 = 0
        while (i < jpeg.pixels.size) {
            if (back.pixels[i] != jpeg.pixels[i]) {
                same = false
            }
            i = i + 1
        }
        @Assert(same, true)
    }

    @TestCase
    public func testProgressiveDcOnly() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.PROG_DC)
        let img = JpegCodec.decode(raw)
        @Assert(img.width, 8)
        @Assert(img.height, 8)
        @Assert(img.pixels.size, 192)
        @Assert(JpegCodecTest.isFlatGray(img), true)
    }

    @TestCase
    public func testProgressiveDcAc() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.PROG_DC_AC)
        let img = JpegCodec.decode(raw)
        @Assert(img.width, 8)
        @Assert(img.height, 8)
        @Assert(img.pixels.size, 192)
        @Assert(JpegCodecTest.isFlatGray(img), true)
    }

    @TestCase
    public func testProgressiveSuccessiveApprox() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.PROG_SA)
        let img = JpegCodec.decode(raw)
        @Assert(img.width, 8)
        @Assert(img.height, 8)
        @Assert(img.pixels.size, 192)
        @Assert(JpegCodecTest.isFlatGray(img), true)
    }

    @TestCase
    public func testProgressiveThroughPng() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.PROG_SA)
        let jpeg = JpegCodec.decode(raw)
        let png = PngCodec.encode(jpeg)
        let back = PngCodec.decode(png)
        @Assert(back.width, 8)
        @Assert(back.height, 8)
        @Assert(back.pixels.size, jpeg.pixels.size)
        var same = true
        var i: Int64 = 0
        while (i < jpeg.pixels.size) {
            if (back.pixels[i] != jpeg.pixels[i]) {
                same = false
            }
            i = i + 1
        }
        @Assert(same, true)
    }

    @TestCase
    public func testSniffProgressive() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.PROG_DC)
        @Assert(MediaEngine.sniff(raw), "jpeg")
    }

    @TestCase
    public func testRejectArithmeticCoding() {
        let raw = JpegCodecTest.hexBytes(JpegCodecTest.JPEG_ARITH_SOF9)
        @Assert(JpegCodecTest.isRejected(raw), true)
    }
}
