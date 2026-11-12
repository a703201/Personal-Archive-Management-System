// ============================================================
// ams.core.media · CJK / 手写点阵识别单元测试
//
// 全部内存驱动，夹具来自只读的 glyphdata.cj（构建期生成的跨字体
// 位串），不依赖数据库 / 网络 / 外部进程 / Python / 字体 / GDI。
// 覆盖：GlyphBits 位运算、CJK 夹具、手写夹具、三路路由回归、
//       confidence、空白图、字典内自洽。
// ============================================================
package ams.core.media.test

import std.collection.*
import std.unittest.*

import ams.core.media.*

@Test
public class CjkHandOcrTest {
    @TestCase
    public func testDecodeHexLength() {
        // CJK_BITS[0] 是 64 个 hex 字符 → 256 bit
        let bits = GlyphBits.decodeHex(GlyphData.CJK_BITS[0])
        @Assert(bits.size, 256)
        // 首 hex 字符 '1' = 0001 → 前 3 bit 为 0，第 4 bit 为 1（MSB 先）
        @Assert(Int64(bits[0]), 0)
        @Assert(Int64(bits[1]), 0)
        @Assert(Int64(bits[2]), 0)
        @Assert(Int64(bits[3]), 1)
    }

    @TestCase
    public func testAlignTranslation() {
        let f = Array<Byte>(256, repeat: 0u8)
        f[5 * 16 + 7] = 1u8
        f[9 * 16 + 3] = 1u8
        // minX=3, minY=5 → 两点平移到 (4,0) 与 (0,4)
        let a = GlyphBits.align(f)
        @Assert(Int64(a[0 * 16 + 4]), 1)
        @Assert(Int64(a[4 * 16 + 0]), 1)
        @Assert(Int64(a[5 * 16 + 7]), 0)
        // 全空数组对齐后仍全 0
        let empty = GlyphBits.align(Array<Byte>(256, repeat: 0u8))
        @Assert(Int64(empty[0]), 0)
    }

    @TestCase
    public func testShiftDistanceSelfZero() {
        let a = GlyphBits.align(GlyphBits.decodeHex(GlyphData.CJK_BITS[0]))
        @Assert(GlyphBits.shiftDistance(a, a), 0)
    }

    @TestCase
    public func testCjkFixture() {
        let img = GlyphBits.fromHexRaster(
            GlyphData.TEST_CJK_W, GlyphData.TEST_CJK_H, GlyphData.TEST_CJK_BITS)
        @Assert(CjkOcr.recognize(img), GlyphData.TEST_CJK_EXPECT)
    }

    @TestCase
    public func testHandFixture() {
        let img = GlyphBits.fromHexRaster(
            GlyphData.TEST_HAND_W, GlyphData.TEST_HAND_H, GlyphData.TEST_HAND_BITS)
        @Assert(HandOcr.recognize(img), GlyphData.TEST_HAND_EXPECT)
    }

    @TestCase
    public func testAutoWithEngineRegression() {
        let img = MediaOcr.render("ABC123", 3, 8)
        let r = MediaOcr.recognizeAutoWithEngine(img)
        @Assert(r.text, "ABC123")
        @Assert(r.engine, "builtin-5x7")
        @Assert(MediaOcr.recognizeAuto(img), "ABC123")
        // 保持 recognize() 本身行为一字不变
        @Assert(MediaOcr.recognize(img), "ABC123")
    }

    @TestCase
    public func testRecognizeAutoCjk() {
        let img = GlyphBits.fromHexRaster(
            GlyphData.TEST_CJK_W, GlyphData.TEST_CJK_H, GlyphData.TEST_CJK_BITS)
        @Assert(MediaOcr.recognizeAuto(img), GlyphData.TEST_CJK_EXPECT)
        let r = MediaOcr.recognizeAutoWithEngine(img)
        @Assert(r.engine, "builtin-cjk")
    }

    @TestCase
    public func testConfidence() {
        @Assert(MediaOcr.confidence("ABC123"), 100)
        @Assert(MediaOcr.confidence("????"), 0)
        @Assert(MediaOcr.confidence(""), 0)
    }

    @TestCase
    public func testBlankImage() {
        let img = RasterImage.white(60, 30)
        @Assert(CjkOcr.recognize(img), "")
        @Assert(HandOcr.recognize(img), "")
    }

    @TestCase
    public func testProtoSelfConsistency() {
        // 原型自身对齐后与原型表匹配：最佳距离为 0，且命中同一字符
        let protos = GlyphBits.alignProtos(GlyphData.CJK_BITS)
        let a = GlyphBits.align(GlyphBits.decodeHex(GlyphData.CJK_BITS[0]))
        let r = GlyphBits.bestMatch(a, protos)
        @Assert(r[1], 0)
        @Assert(r[0] / GlyphData.CJK_PROTOS, 0)
    }
}
