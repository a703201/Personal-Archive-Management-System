// ============================================================
// ams.core.media · BMP 解码单元测试（纯仓颉字节数组字面量夹具）
//
// 全部夹具都是**内存里现拼的最小合法 BMP**，不依赖任何图像库或外部文件：
//   BITMAPFILEHEADER(14) + BITMAPINFOHEADER(40) + 可选调色板 + 像素行
// 多字节字段用 putLE16/putLE32 小端写入；调色板 / 像素数据用字节数组
// 字面量给出，行 padding 与自下而上 / 自上而下都手工算好。
//
// 运行：bash scripts/test.sh ams-core
// ============================================================
package ams.core.media.test

import std.collection.*
import std.unittest.*

import ams.core.media.*

@Test
public class BmpCodecTest {
    /** 空调色板（24/32-bit 真彩用）。 */
    private static let NO_PALETTE: Array<Byte> = Array<Byte>(0, repeat: 0u8)

    /** 小端写 2 字节。 */
    private static func putLE16(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 255))
        out.add(UInt8((v / 256) & 255))
    }

    /** 小端写 4 字节。 */
    private static func putLE32(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 255))
        out.add(UInt8((v / 256) & 255))
        out.add(UInt8((v / 65536) & 255))
        out.add(UInt8((v / 16777216) & 255))
    }

    /**
     * 拼一张最小 BMP。h 为有符号高度（负值 → 0xFFFF.... 补码写入）；
     * pixelData 是已含行 padding 的原始像素字节，按文件行顺序排列。
     */
    private static func buildBmp(w: Int64, h: Int64, bpp: Int64,
        compression: Int64, palette: Array<Byte>, pixelData: Array<Byte>): Array<Byte> {
        let out = ArrayList<Byte>()
        // ---- BITMAPFILEHEADER ----
        out.add(0x42u8)                       // 'B'
        out.add(0x4Du8)                       // 'M'
        let pixelOffset = 54 + palette.size
        let fileSize = pixelOffset + pixelData.size
        BmpCodecTest.putLE32(out, fileSize)
        BmpCodecTest.putLE32(out, 0)          // bfReserved
        BmpCodecTest.putLE32(out, pixelOffset)
        // ---- BITMAPINFOHEADER ----
        BmpCodecTest.putLE32(out, 40)         // biSize
        BmpCodecTest.putLE32(out, w)          // biWidth
        var hu = h
        if (hu < 0) {
            hu = hu + 4294967296              // 负高度写成 32 位补码
        }
        BmpCodecTest.putLE32(out, hu)         // biHeight
        BmpCodecTest.putLE16(out, 1)          // biPlanes
        BmpCodecTest.putLE16(out, bpp)        // biBitCount
        BmpCodecTest.putLE32(out, compression)
        BmpCodecTest.putLE32(out, pixelData.size)
        BmpCodecTest.putLE32(out, 0)          // biXPelsPerMeter
        BmpCodecTest.putLE32(out, 0)          // biYPelsPerMeter
        BmpCodecTest.putLE32(out, palette.size / 4)  // biClrUsed
        BmpCodecTest.putLE32(out, 0)          // biClrImportant
        for (b in palette) {
            out.add(b)
        }
        for (b in pixelData) {
            out.add(b)
        }
        return out.toArray()
    }

    /** 取 img 在 (x,y) 的第 c 个通道（0=R,1=G,2=B）。 */
    private static func px(img: RasterImage, x: Int64, y: Int64, c: Int64): Int64 {
        return Int64(img.pixels[(y * img.width + x) * 3 + c])
    }

    /**
     * 期望 decode 抛 AppError：捕获到异常返回 true；若非法输入被错误地
     * 静默接受（未抛异常）则返回 false，交由 @Assert 判定该用例失败。
     * 项目内暂无 expectThrows 宏，故用「捕获到异常则置标志」的写法。
     */
    private static func isRejected(data: Array<Byte>): Bool {
        var rejected = false
        try {
            let img = BmpCodec.decode(data)
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
    public func test24BitBottomUp() {
        // 每行 2*3=6 字节，按 DWORD 对齐补到 8；BGR 顺序。
        // height>0 ⇒ 文件首行是图像「底行」，需翻转。
        let pixelData: Array<Byte> = [
            90u8, 80u8, 70u8, 120u8, 110u8, 100u8, 0u8, 0u8,
            30u8, 20u8, 10u8, 60u8, 50u8, 40u8, 0u8, 0u8
        ]
        let bmp = BmpCodecTest.buildBmp(2, 2, 24, 0, BmpCodecTest.NO_PALETTE, pixelData)
        @Assert(MediaEngine.sniff(bmp), "bmp")
        let img = BmpCodec.decode(bmp)
        @Assert(img.width, 2)
        @Assert(img.height, 2)
        @Assert(img.pixels.size, 12)
        // 顶行（来自文件第二行）：(10,20,30) 与 (40,50,60)
        @Assert(BmpCodecTest.px(img, 0, 0, 0), 10)
        @Assert(BmpCodecTest.px(img, 0, 0, 1), 20)
        @Assert(BmpCodecTest.px(img, 0, 0, 2), 30)
        @Assert(BmpCodecTest.px(img, 1, 0, 0), 40)
        @Assert(BmpCodecTest.px(img, 1, 0, 1), 50)
        @Assert(BmpCodecTest.px(img, 1, 0, 2), 60)
        // 底行（来自文件第一行）：(70,80,90) 与 (100,110,120)
        @Assert(BmpCodecTest.px(img, 0, 1, 0), 70)
        @Assert(BmpCodecTest.px(img, 0, 1, 1), 80)
        @Assert(BmpCodecTest.px(img, 0, 1, 2), 90)
        @Assert(BmpCodecTest.px(img, 1, 1, 0), 100)
        @Assert(BmpCodecTest.px(img, 1, 1, 1), 110)
        @Assert(BmpCodecTest.px(img, 1, 1, 2), 120)
    }

    @TestCase
    public func test8BitPalette() {
        // 4 项调色板，每项 B,G,R,0：0=黑 1=蓝 2=绿 3=红
        let palette: Array<Byte> = [
            0u8, 0u8, 0u8, 0u8,
            255u8, 0u8, 0u8, 0u8,
            0u8, 255u8, 0u8, 0u8,
            0u8, 0u8, 255u8, 0u8
        ]
        // 每行 2 个索引 + 2 字节 padding；文件首行是图像底行。
        let pixelData: Array<Byte> = [
            3u8, 2u8, 0u8, 0u8,
            0u8, 1u8, 0u8, 0u8
        ]
        let bmp = BmpCodecTest.buildBmp(2, 2, 8, 0, palette, pixelData)
        let img = BmpCodec.decode(bmp)
        @Assert(img.width, 2)
        @Assert(img.height, 2)
        // 顶行：idx0=黑(0,0,0)，idx1=蓝(0,0,255)
        @Assert(BmpCodecTest.px(img, 0, 0, 0), 0)
        @Assert(BmpCodecTest.px(img, 0, 0, 1), 0)
        @Assert(BmpCodecTest.px(img, 0, 0, 2), 0)
        @Assert(BmpCodecTest.px(img, 1, 0, 0), 0)
        @Assert(BmpCodecTest.px(img, 1, 0, 1), 0)
        @Assert(BmpCodecTest.px(img, 1, 0, 2), 255)
        // 底行：idx3=红(255,0,0)，idx2=绿(0,255,0)
        @Assert(BmpCodecTest.px(img, 0, 1, 0), 255)
        @Assert(BmpCodecTest.px(img, 0, 1, 1), 0)
        @Assert(BmpCodecTest.px(img, 0, 1, 2), 0)
        @Assert(BmpCodecTest.px(img, 1, 1, 0), 0)
        @Assert(BmpCodecTest.px(img, 1, 1, 1), 255)
        @Assert(BmpCodecTest.px(img, 1, 1, 2), 0)
    }

    @TestCase
    public func test1BitMonochrome() {
        // 2 项调色板：idx0=黑，idx1=白
        let palette: Array<Byte> = [
            0u8, 0u8, 0u8, 0u8,
            255u8, 255u8, 255u8, 0u8
        ]
        // 每行 1 字节（MSB 在前）+ 3 字节 padding。
        // 0x80 = 10...... → 左白右黑；0x40 = 01...... → 左黑右白
        let pixelData: Array<Byte> = [
            0x80u8, 0u8, 0u8, 0u8,
            0x40u8, 0u8, 0u8, 0u8
        ]
        let bmp = BmpCodecTest.buildBmp(2, 2, 1, 0, palette, pixelData)
        let img = BmpCodec.decode(bmp)
        @Assert(img.width, 2)
        @Assert(img.height, 2)
        // 顶行（文件第二行 0x40）：左黑、右白
        @Assert(BmpCodecTest.px(img, 0, 0, 0), 0)
        @Assert(BmpCodecTest.px(img, 0, 0, 1), 0)
        @Assert(BmpCodecTest.px(img, 0, 0, 2), 0)
        @Assert(BmpCodecTest.px(img, 1, 0, 0), 255)
        @Assert(BmpCodecTest.px(img, 1, 0, 1), 255)
        @Assert(BmpCodecTest.px(img, 1, 0, 2), 255)
        // 底行（文件第一行 0x80）：左白、右黑
        @Assert(BmpCodecTest.px(img, 0, 1, 0), 255)
        @Assert(BmpCodecTest.px(img, 0, 1, 1), 255)
        @Assert(BmpCodecTest.px(img, 1, 1, 0), 0)
    }

    @TestCase
    public func testTopDownNegativeHeight() {
        // height = -2 ⇒ 自上而下，文件首行即图像首行，不做行翻转。
        let pixelData: Array<Byte> = [
            1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 0u8, 0u8,
            7u8, 8u8, 9u8, 10u8, 11u8, 12u8, 0u8, 0u8
        ]
        let bmp = BmpCodecTest.buildBmp(2, -2, 24, 0, BmpCodecTest.NO_PALETTE, pixelData)
        let img = BmpCodec.decode(bmp)
        @Assert(img.width, 2)
        @Assert(img.height, 2)
        // 第一行：BGR(1,2,3)→RGB(3,2,1)、BGR(4,5,6)→RGB(6,5,4)
        @Assert(BmpCodecTest.px(img, 0, 0, 0), 3)
        @Assert(BmpCodecTest.px(img, 0, 0, 1), 2)
        @Assert(BmpCodecTest.px(img, 0, 0, 2), 1)
        @Assert(BmpCodecTest.px(img, 1, 0, 0), 6)
        @Assert(BmpCodecTest.px(img, 1, 0, 1), 5)
        @Assert(BmpCodecTest.px(img, 1, 0, 2), 4)
        // 第二行：BGR(7,8,9)→RGB(9,8,7)
        @Assert(BmpCodecTest.px(img, 0, 1, 0), 9)
        @Assert(BmpCodecTest.px(img, 0, 1, 1), 8)
        @Assert(BmpCodecTest.px(img, 0, 1, 2), 7)
    }

    @TestCase
    public func test32BitBgraIgnoresAlpha() {
        // 每行 2*4=8 字节正好对齐；A 取 0 / 128，应被忽略而非参与合成。
        let pixelData: Array<Byte> = [
            10u8, 20u8, 30u8, 0u8,
            40u8, 50u8, 60u8, 128u8
        ]
        let bmp = BmpCodecTest.buildBmp(2, 1, 32, 0, BmpCodecTest.NO_PALETTE, pixelData)
        let img = BmpCodec.decode(bmp)
        @Assert(img.width, 2)
        @Assert(img.height, 1)
        @Assert(img.pixels.size, 6)
        @Assert(BmpCodecTest.px(img, 0, 0, 0), 30)
        @Assert(BmpCodecTest.px(img, 0, 0, 1), 20)
        @Assert(BmpCodecTest.px(img, 0, 0, 2), 10)
        @Assert(BmpCodecTest.px(img, 1, 0, 0), 60)
        @Assert(BmpCodecTest.px(img, 1, 0, 1), 50)
        @Assert(BmpCodecTest.px(img, 1, 0, 2), 40)
    }

    @TestCase
    public func testBadMagicRejected() {
        let pixelData: Array<Byte> = [
            30u8, 20u8, 10u8, 60u8, 50u8, 40u8, 0u8, 0u8,
            90u8, 80u8, 70u8, 120u8, 110u8, 100u8, 0u8, 0u8
        ]
        let data = BmpCodecTest.buildBmp(2, 2, 24, 0, BmpCodecTest.NO_PALETTE, pixelData)
        // 反例：合法 BMP 不应被拒绝，证明 isRejected 判定有效。
        @Assert(BmpCodecTest.isRejected(data), false)
        // 改成非 "BM" 魔数 "XX"。
        data[0] = 0x58u8
        data[1] = 0x58u8
        @Assert(BmpCodecTest.isRejected(data), true)
    }

    @TestCase
    public func testRleCompressionRejected() {
        let palette: Array<Byte> = [
            0u8, 0u8, 0u8, 0u8,
            255u8, 255u8, 255u8, 0u8
        ]
        let pixelData: Array<Byte> = [
            0u8, 1u8, 0u8, 0u8,
            1u8, 0u8, 0u8, 0u8
        ]
        // compression = 1（BI_RLE8）与 2（BI_RLE4）都必须明确拒绝。
        let rle8 = BmpCodecTest.buildBmp(2, 2, 8, 1, palette, pixelData)
        @Assert(BmpCodecTest.isRejected(rle8), true)
        let rle4 = BmpCodecTest.buildBmp(2, 2, 8, 2, palette, pixelData)
        @Assert(BmpCodecTest.isRejected(rle4), true)
        // BI_BITFIELDS = 3 同样拒绝。
        let bitfields = BmpCodecTest.buildBmp(2, 2, 8, 3, palette, pixelData)
        @Assert(BmpCodecTest.isRejected(bitfields), true)
    }

    @TestCase
    public func testUnsupportedBppRejected() {
        let pixelData: Array<Byte> = [
            0u8, 0u8, 0u8, 0u8,
            0u8, 0u8, 0u8, 0u8
        ]
        // 16-bit 不在支持矩阵内，必须拒绝（不静默返回空白图）。
        let data = BmpCodecTest.buildBmp(2, 2, 16, 0, BmpCodecTest.NO_PALETTE, pixelData)
        @Assert(BmpCodecTest.isRejected(data), true)
    }

    @TestCase
    public func testTruncatedDataRejected() {
        let pixelData: Array<Byte> = [
            30u8, 20u8, 10u8, 60u8, 50u8, 40u8, 0u8, 0u8,
            90u8, 80u8, 70u8, 120u8, 110u8, 100u8, 0u8, 0u8
        ]
        let full = BmpCodecTest.buildBmp(2, 2, 24, 0, BmpCodecTest.NO_PALETTE, pixelData)
        // 砍掉末尾 4 字节像素数据（70 → 66），像素数据不足应抛异常。
        let cut = full[0..66]
        @Assert(BmpCodecTest.isRejected(cut), true)
    }
}
