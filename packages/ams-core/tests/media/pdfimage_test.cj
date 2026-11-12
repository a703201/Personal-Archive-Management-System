// ============================================================
// ams.core.media · 图像型扫描 PDF 图像流抽取单元测试
//
// 严格模仿 jpeg_test.cj / bmp_test.cj：@Test 类 + @TestCase + @Assert，
// 所有夹具都是仓颉字节数组现拼的最小 PDF，不依赖任何外部文件 / 进程。
//   · 灰度样本与 RGB 样本用可控字节（不含 endstream / EI 字面量）；
//   · FlateDecode 流用 PngCodec.zlibStored 现生成合法 zlib 数据；
//   · DCTDecode 用 jpeg_test.cj 那份最小合法 JPEG 的 hex 常量。
// 覆盖：无滤镜灰度 / Flate 灰度 / DCT / RGB / Predictor2 / 文本 PDF /
//       损坏图 / 未知色彩空间 / 混合跳过继续 / 内联图像。
// ============================================================
package ams.core.media.test

import std.collection.*
import std.unittest.*

import ams.core.media.*

@Test
public class PdfImageTest {
    /** 8×8 灰度最小合法 JPEG（与 jpeg_test.cj 一致，DC=0 + EOB ⇒ 平坦 128 灰）。 */
    private static let JPEG_8X8: String =
        "FFD8FFDB004300101010101010101010101010101010101010101010101010101010101010101010" +
        "10101010101010101010101010101010101010101010101010101010101010101010" +
        "FFC0000B080008000801011100" +
        "FFC40014000001000000000000000000000000000000" +
        "FFC40014100000000100000000000000000000000000" +
        "FFDA0008010100003F0003FFD9"

    private static func appendStr(out: ArrayList<Byte>, s: String): Unit {
        for (b in s.toArray()) {
            out.add(b)
        }
    }

    private static func appendBytes(out: ArrayList<Byte>, bs: Array<Byte>): Unit {
        for (b in bs) {
            out.add(b)
        }
    }

    /**
     * 拼一个单 XObject 图像对象：/Length 自动取 streamData.size，
     * 形如 `<< ... >>\nstream\n<data>\nendstream`。extraKeys 自行带前导空格。
     */
    private static func buildXObjectPdf(w: Int64, h: Int64, extraKeys: String,
        streamData: Array<Byte>): Array<Byte> {
        let out = ArrayList<Byte>()
        PdfImageTest.appendStr(out, "%PDF-1.4\n1 0 obj\n<< /Type /XObject /Subtype /Image /Width ")
        PdfImageTest.appendStr(out, w.toString())
        PdfImageTest.appendStr(out, " /Height ")
        PdfImageTest.appendStr(out, h.toString())
        PdfImageTest.appendStr(out, extraKeys)
        PdfImageTest.appendStr(out, " /Length ")
        PdfImageTest.appendStr(out, streamData.size.toString())
        PdfImageTest.appendStr(out, " >>\nstream\n")
        PdfImageTest.appendBytes(out, streamData)
        PdfImageTest.appendStr(out, "\nendstream\nendobj\n%%EOF\n")
        return out.toArray()
    }

    /** 取 img 在 (x,y) 的第 c 个通道（0=R,1=G,2=B）。 */
    private static func px(img: RasterImage, x: Int64, y: Int64, c: Int64): Int64 {
        return Int64(img.pixels[(y * img.width + x) * 3 + c])
    }

    private static func hexVal(b: Int64): Int64 {
        if (b >= 48 && b <= 57) { return b - 48 }
        if (b >= 65 && b <= 70) { return b - 55 }
        return 0
    }

    private static func hexBytes(s: String): Array<Byte> {
        let out = ArrayList<Byte>()
        var i: Int64 = 0
        while (i + 1 < s.size) {
            let hi = PdfImageTest.hexVal(Int64(s[i]))
            let lo = PdfImageTest.hexVal(Int64(s[i + 1]))
            out.add(UInt8(hi * 16 + lo))
            i = i + 2
        }
        return out.toArray()
    }

    @TestCase
    public func testRawDeviceGray2x2() {
        // 2×2 灰度原始样本：行自上而下，灰值复制到 R/G/B。
        let streamData: Array<Byte> = [0u8, 128u8, 255u8, 64u8]
        let pdf = PdfImageTest.buildXObjectPdf(2, 2,
            " /ColorSpace /DeviceGray /BitsPerComponent 8", streamData)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(imgs[0].pixels.size, 12)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 0)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 1), 0)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 2), 0)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 128)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 1), 128)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 2), 128)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 255)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 1), 255)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 2), 255)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 0), 64)
    }

    @TestCase
    public func testFlateDeviceGray2x2() {
        // 用 zlibStored 现生成合法 zlib 流，解压后应得到 [10,20,30,40]。
        let raw: Array<Byte> = [10u8, 20u8, 30u8, 40u8]
        let z = PngCodec.zlibStored(raw)
        let pdf = PdfImageTest.buildXObjectPdf(2, 2,
            " /ColorSpace /DeviceGray /Filter /FlateDecode /BitsPerComponent 8", z)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 10)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 20)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 30)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 0), 40)
    }

    @TestCase
    public func testDctDecode8x8() {
        let jpeg = PdfImageTest.hexBytes(PdfImageTest.JPEG_8X8)
        let pdf = PdfImageTest.buildXObjectPdf(8, 8,
            " /ColorSpace /DeviceGray /Filter /DCTDecode", jpeg)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 8)
        @Assert(imgs[0].height, 8)
        @Assert(imgs[0].pixels.size, 192)
        var flat = true
        var i: Int64 = 0
        while (i < imgs[0].pixels.size) {
            let v = Int64(imgs[0].pixels[i])
            if (v < 126 || v > 130) {
                flat = false
            }
            i = i + 1
        }
        @Assert(flat, true)
    }

    @TestCase
    public func testDeviceRgbRaw2x2() {
        // 2×2 RGB = 12 字节，验证 bpp=3 的样本→像素映射。
        let streamData: Array<Byte> = [
            1u8, 2u8, 3u8, 4u8, 5u8, 6u8,
            7u8, 8u8, 9u8, 10u8, 11u8, 12u8
        ]
        let pdf = PdfImageTest.buildXObjectPdf(2, 2, " /ColorSpace /DeviceRGB", streamData)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(imgs[0].pixels.size, 12)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 1)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 1), 2)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 2), 3)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 4)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 7)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 2), 12)
    }

    @TestCase
    public func testPredictor2TiffHorizontal() {
        // 期望样本 [10,20,30,40]；TIFF Predictor 2 存为横向差分 [10,10,30,10]。
        // 每行 2 字节、2 行，步长 Colors=1、Columns=2；解压后累加还原。
        let predicted: Array<Byte> = [10u8, 10u8, 30u8, 10u8]
        let z = PngCodec.zlibStored(predicted)
        let pdf = PdfImageTest.buildXObjectPdf(2, 2,
            " /ColorSpace /DeviceGray /Filter /FlateDecode" +
            " /DecodeParms << /Predictor 2 /Colors 1 /Columns 2 >>", z)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 10)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 20)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 30)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 0), 40)
    }

    @TestCase
    public func testTextPdfReturnsNoImages() {
        // 纯文本型 PDF（无图像字典 / 无内联图像）→ 0 张。
        let pdf = "%PDF-1.4\n1 0 obj\n<< >>\nstream\n" +
            "BT (Hello AMS 123) Tj ET\nendstream\nendobj\n%%EOF\n"
        let imgs = PdfImage.extract(pdf.toArray())
        @Assert(imgs.size, 0)
    }

    @TestCase
    public func testTruncatedStreamSkipped() {
        // 2×2 灰度需要 4 字节，只给 2 字节 → 不抛异常、跳过该图、返回 0 张。
        let short: Array<Byte> = [9u8, 90u8]
        let pdf = PdfImageTest.buildXObjectPdf(2, 2,
            " /ColorSpace /DeviceGray /BitsPerComponent 8", short)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 0)
    }

    @TestCase
    public func testUnknownColorSpaceSkipped() {
        // /DeviceCMYK 不在支持矩阵 → 跳过该图、返回 0 张、不抛异常。
        let streamData: Array<Byte> = [
            0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8
        ]
        let pdf = PdfImageTest.buildXObjectPdf(2, 2,
            " /ColorSpace /DeviceCMYK /BitsPerComponent 8", streamData)
        let imgs = PdfImage.extract(pdf)
        @Assert(imgs.size, 0)
    }

    @TestCase
    public func testMixedValidAndBrokenContinues() {
        // 一张损坏图 + 一张合法图：损坏的必须被跳过，合法的仍要返回。
        let out = ArrayList<Byte>()
        PdfImageTest.appendStr(out, "%PDF-1.4\n")
        PdfImageTest.appendStr(out, "1 0 obj\n<< /Type /XObject /Subtype /Image" +
            " /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8" +
            " /Length 2 >>\nstream\n")
        out.add(50u8)
        out.add(60u8)
        PdfImageTest.appendStr(out, "\nendstream\nendobj\n")
        PdfImageTest.appendStr(out, "2 0 obj\n<< /Type /XObject /Subtype /Image" +
            " /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8" +
            " /Length 4 >>\nstream\n")
        out.add(9u8)
        out.add(90u8)
        out.add(180u8)
        out.add(250u8)
        PdfImageTest.appendStr(out, "\nendstream\nendobj\n%%EOF\n")
        let imgs = PdfImage.extract(out.toArray())
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 9)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 90)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 180)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 0), 250)
    }

    @TestCase
    public func testInlineImage() {
        // BI ... ID <二进制> EI，缩写键 /W /H /CS /BPC；无滤镜灰度。
        // 数据字节 100/120/140/160 不含 EI / 空白，避免与 EI 边界冲突。
        let out = ArrayList<Byte>()
        PdfImageTest.appendStr(out, "%PDF-1.4\nq 2 0 0 2 0 0 cm\n")
        PdfImageTest.appendStr(out, "BI\n/W 2\n/H 2\n/CS /G\n/BPC 8\nID\n")
        out.add(100u8)
        out.add(120u8)
        out.add(140u8)
        out.add(160u8)
        PdfImageTest.appendStr(out, "\nEI\nQ\n%%EOF\n")
        let imgs = PdfImage.extract(out.toArray())
        @Assert(imgs.size, 1)
        @Assert(imgs[0].width, 2)
        @Assert(imgs[0].height, 2)
        @Assert(PdfImageTest.px(imgs[0], 0, 0, 0), 100)
        @Assert(PdfImageTest.px(imgs[0], 1, 0, 0), 120)
        @Assert(PdfImageTest.px(imgs[0], 0, 1, 0), 140)
        @Assert(PdfImageTest.px(imgs[0], 1, 1, 0), 160)
    }
}
