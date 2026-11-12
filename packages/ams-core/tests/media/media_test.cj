// ============================================================
// ams.core.media · 单元测试（纯仓颉 OCR / 图像引擎）
//
// 全部内存驱动，不依赖数据库 / 网络 / 外部进程 / Python。
// 闭环：用内置字模渲染 → 自写 PNG 编码 → 自写 PNG 解码 → 自研识别。
//
// 运行：bash scripts/test.sh ams-core
// ============================================================
package ams.core.media.test

import std.collection.*
import std.unittest.*
import std.env.*

import ams.core.media.*

@Test
public class PngCodecTest {
    @TestCase
    public func testCrc32KnownVector() {
        // CRC-32("123456789") = 0xCBF43926
        @Assert(PngCodec.crc32("123456789".toArray()), 0xCBF43926)
    }

    @TestCase
    public func testZlibStoredRoundTrip() {
        let raw = "ABC123-AMS-MEDIA".toArray()
        let z = PngCodec.zlibStored(raw)
        let back = PngCodec.inflateZlib(z, 65536)
        @Assert(back.size, raw.size)
        var same = true
        var i: Int64 = 0
        while (i < raw.size) {
            if (back[i] != raw[i]) {
                same = false
            }
            i = i + 1
        }
        @Assert(same, true)
    }

    @TestCase
    public func testPngRoundTrip() {
        let img = MediaOcr.render("ABC123", 3, 8)
        let png = PngCodec.encode(img)
        let back = PngCodec.decode(png)
        @Assert(back.width, img.width)
        @Assert(back.height, img.height)
        @Assert(back.pixels.size, img.pixels.size)
        var same = true
        var i: Int64 = 0
        while (i < img.pixels.size) {
            if (back.pixels[i] != img.pixels[i]) {
                same = false
            }
            i = i + 1
        }
        @Assert(same, true)
    }
}

@Test
public class MediaOcrTest {
    @TestCase
    public func testRenderThenRecognize() {
        let img = MediaOcr.render("ABC123", 3, 8)
        @Assert(MediaOcr.recognize(img), "ABC123")
    }

    @TestCase
    public func testRecognizeThroughPng() {
        let png = PngCodec.encode(MediaOcr.render("AMS42", 3, 8))
        @Assert(MediaOcr.recognize(PngCodec.decode(png)), "AMS42")
    }

    @TestCase
    public func testBlankImageHasNoText() {
        let img = RasterImage.white(60, 30)
        @Assert(MediaOcr.recognize(img), "")
    }
}

@Test
public class MediaEngineTest {
    @TestCase
    public func testSniff() {
        let png = PngCodec.encode(RasterImage.white(4, 4))
        @Assert(MediaEngine.sniff(png), "png")
        @Assert(MediaEngine.sniff("%PDF-1.4".toArray()), "pdf")
        @Assert(MediaEngine.sniff("nothing here".toArray()), "unknown")
    }

    @TestCase
    public func testThumbnailBounds() {
        let img = MediaOcr.render("ABC123", 3, 8)
        let small = MediaEngine.thumbnail(img, 32)
        @Assert(small.width <= 32 && small.height <= 32, true)
        @Assert(small.width > 0 && small.height > 0, true)
        let back = PngCodec.decode(PngCodec.encode(small))
        @Assert(back.width, small.width)
    }

    @TestCase
    public func testWatermarkChangesPixels() {
        let img = MediaOcr.render("ABC123", 3, 8)
        let wm = MediaEngine.burnWatermark(img, "TESTER 20261107 #A1B2C3")
        @Assert(wm.width, img.width)
        var changed = false
        var i: Int64 = 0
        while (i < img.pixels.size) {
            if (wm.pixels[i] != img.pixels[i]) {
                changed = true
            }
            i = i + 1
        }
        @Assert(changed, true)
        let back = PngCodec.decode(PngCodec.encode(wm))
        @Assert(back.width, wm.width)
    }

    @TestCase
    public func testProcessPng() {
        let png = PngCodec.encode(MediaOcr.render("AMS42", 3, 8))
        let r = MediaEngine.process(png, true, true, true, "viewer 2026-11-07")
        @Assert(r.ocrText, "AMS42")
        @Assert(r.ocrStatus, 2)
        @Assert(r.ocrEngine, "builtin-5x7")
        @Assert(r.thumbnail.size > 100, true)
        @Assert(r.watermarked.size > 100, true)
        @Assert(r.error, "")
    }

    @TestCase
    public func testProcessUnsupported() {
        let r = MediaEngine.process("random bytes".toArray(), true, true, true, "x")
        @Assert(r.ocrStatus, 3)
        @Assert(r.thumbnail.size, 0)
        @Assert(r.watermarked.size, 0)
    }

    @TestCase
    public func testPdfTextExtraction() {
        // 未压缩内容流：inflateZlib 失败后按原始字节解析，覆盖同一条抽取路径。
        let pdf = "%PDF-1.4\n1 0 obj\n<< >>\nstream\nBT (Hello AMS 123) Tj ET\nendstream\nendobj\n%%EOF\n".toArray()
        @Assert(PdfText.extract(pdf), "Hello AMS 123")
        let r = MediaEngine.process(pdf, true, true, true, "x")
        @Assert(r.ocrText, "Hello AMS 123")
        @Assert(r.ocrEngine, "pdf-text")
        @Assert(r.ocrStatus, 2)
    }
}

// ============================================================
// 外接 PP-OCRv5 引擎的「默认关闭 + 回退契约」测试。
//
// 设计要点（见 ocr_ext.cj / ocr.cj）：
//   · 外部引擎为**可选**分支，默认开关 AMS_OCR_ENGINE 为 "builtin"，
//     即不启用（无论 Linux/Windows）；
//   · 未启用时 PpOcrV5.available() 恒返回 false，recognize() 返回空串，
//     MediaOcr.recognizeAutoWithEngine 必须透明回退到内置三路
//     （CJK / 手写 / 5×7），绝不标 external-ppocrv5；
//   · 本测试在「默认开关」下运行（CI / test.sh 不设 AMS_OCR_ENGINE），
//     因此既是契约验证，也是「零回归」保证：接入外部引擎不得改变
//     默认行为（行为不变 = 内置三路 + 文本一致）。
// ============================================================
@Test
public class ExternalOcrFallbackTest {
    @TestCase
    public func testExternalEngineOffByDefault() {
        // 默认（未设 AMS_OCR_ENGINE）下，外部引擎必须不可用。
        @Assert(PpOcrV5.available(), false)
    }

    @TestCase
    public func testRecognizeFallsBackToBuiltin() {
        // 显式关闭外部引擎（容器镜像默认 AMS_OCR_ENGINE=external，
        // 单测不依赖运行环境，强制复位以保证契约确定）。
        setVariable("AMS_OCR_ENGINE", "builtin")
        // 与 MediaEngineTest.testProcessPng 同夹具：渲染 "AMS42"（5×7 印刷体）。
        let img = MediaOcr.render("AMS42", 3, 8)
        let r = MediaOcr.recognizeAutoWithEngine(img)
        // 文本必须与纯内置识别一致（未受外部引擎影响）。
        @Assert(r.text, "AMS42")
        // 实际采用的引擎必须是内置三路之一，绝不允许 external-ppocrv5。
        @Assert(r.engine, "builtin-5x7")
    }

    @TestCase
    public func testRecognizeNeverLabelsExternalWhenOff() {
        setVariable("AMS_OCR_ENGINE", "builtin")
        // 用一张空白图（内置三路同样返回空），确认回退路径在任何输入下
        // 都不会把 engine 标成 external-ppocrv5（即外部分支从未被触发）。
        let img = RasterImage.white(60, 30)
        let r = MediaOcr.recognizeAutoWithEngine(img)
        @Assert(r.engine == "external-ppocrv5", false)
        @Assert(r.text, "")
    }
}
