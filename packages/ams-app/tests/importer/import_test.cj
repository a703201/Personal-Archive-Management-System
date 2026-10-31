// ============================================================
// ams.app.importer · 单元测试（FR-IMP-002 ZIP 读取与映射规则）
//
// [夹具来源] 本文件里的裸 deflate 字节由 **Python zlib** 独立产出
//   （zlib.compressobj(9, DEFLATED, -15)），不是用本仓的压缩代码生成的。
//   这样验证的是「我们的读取器能解外部实现的输出」，
//   而不是「自己的写入和读取互相自洽」——后者对不上真实 ZIP 也没意义。
//
// [为什么测试里自带 ZIP 打包器]
//   要验证的是**解析器对畸形/恶意输入的反应**：CRC 错、加密标志、
//   不支持的压缩方法、路径穿越、ZIP64。本仓的 ZipBuilder 只会产出
//   合规包，造不出这些样本，故测试里另写一个可指定各字段的迷你打包器。
// ============================================================
package ams.app.importer.test

import std.collection.*
import std.unittest.*

import ams.app.attachment.*
import ams.app.importer.*
import ams.crypto.impl.*

// ------------------------------------------------------------
// 夹具
// ------------------------------------------------------------

/**
 * 独立实现产出的裸 deflate 字节。
 */
class Fx {
    /** 明文 40 字节（"AMS 附件导入 · deflate 校验样本" 的 UTF-8） */
    static let SAMPLE_PLAIN_LEN: Int64 = 40
    /** 上述明文的裸 deflate（45 字节） */
    static let Z_SAMPLE: Array<Byte> = [
        1, 40, 0, 215, 255, 65, 77, 83, 32, 233, 153, 132, 228, 187, 182, 229, 175, 188,
        229, 133, 165, 32, 194, 183, 32, 100, 101, 102, 108, 97, 116, 101, 32, 230, 160,
        161, 233, 170, 140, 230, 160, 183, 230, 156, 172
    ]
    /** 明文 100000 字节（"0123456789abcdef" 重复 6250 次） */
    static let BIG_PLAIN_LEN: Int64 = 100000
    /** 上述明文的裸 deflate（229 字节，用于触发多次 read） */
    static let Z_BIG: Array<Byte> = [
        237, 199, 201, 1, 192, 16, 0, 0, 176, 149, 148, 186, 198, 65, 217, 127, 132, 174,
        225, 145, 252, 18, 158, 152, 222, 92, 106, 235, 99, 174, 111, 159, 224, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 238,
        238, 238, 238, 238, 238, 238, 238, 238, 238, 238, 215, 252, 7,
    ]
    /** "证件照片" 的 GBK 字节 */
    static let GBK_NAME: Array<Byte> = [214, 164, 188, 254, 213, 213, 198, 172]
    /** "证件照片" 的 UTF-8 字节 */
    static let UTF8_NAME: Array<Byte> = [
        232, 175, 129, 228, 187, 182, 231, 133, 167, 231, 137, 135
    ]
}

/**
 * 可指定任意字段的迷你 ZIP 打包器（仅测试用）。
 */
class ZipMaker {
    private let local = ArrayList<Byte>()
    private let central = ArrayList<Byte>()
    private var count: Int64 = 0

    /**
     * 追加一个条目。
     *
     * @param payload 实际写入的字节（method=8 时应为裸 deflate）
     * @param plain   用于计算 CRC 的原始内容
     * @param crc     非负则强制使用该值（构造 CRC 错误样本）
     */
    func add(
        name: Array<Byte>, payload: Array<Byte>, plain: Array<Byte>,
        method: Int64, flags: Int64, crc!: Int64 = -1
    ): ZipMaker {
        let realCrc = if (crc >= 0) { crc } else { ZipBuilder.crc32(plain) & 0xFFFFFFFF }
        let off = this.local.size
        ZipMaker.u32(this.local, 0x04034b50)
        ZipMaker.u16(this.local, 20)
        ZipMaker.u16(this.local, flags)
        ZipMaker.u16(this.local, method)
        ZipMaker.u16(this.local, 0)
        ZipMaker.u16(this.local, 0)
        ZipMaker.u32(this.local, realCrc)
        ZipMaker.u32(this.local, payload.size)
        ZipMaker.u32(this.local, plain.size)
        ZipMaker.u16(this.local, name.size)
        ZipMaker.u16(this.local, 0)
        ZipMaker.raw(this.local, name)
        ZipMaker.raw(this.local, payload)

        ZipMaker.u32(this.central, 0x02014b50)
        ZipMaker.u16(this.central, 20)
        ZipMaker.u16(this.central, 20)
        ZipMaker.u16(this.central, flags)
        ZipMaker.u16(this.central, method)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u32(this.central, realCrc)
        ZipMaker.u32(this.central, payload.size)
        ZipMaker.u32(this.central, plain.size)
        ZipMaker.u16(this.central, name.size)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u16(this.central, 0)
        ZipMaker.u32(this.central, 0)
        ZipMaker.u32(this.central, off)
        ZipMaker.raw(this.central, name)
        this.count = this.count + 1
        return this
    }

    /** 中央目录里声明的解压大小（用于伪造 ZIP64 标记） */
    func build(): Array<Byte> {
        let out = ArrayList<Byte>()
        ZipMaker.raw(out, this.local.toArray())
        let cdOff = out.size
        ZipMaker.raw(out, this.central.toArray())
        ZipMaker.u32(out, 0x06054b50)
        ZipMaker.u16(out, 0)
        ZipMaker.u16(out, 0)
        ZipMaker.u16(out, this.count)
        ZipMaker.u16(out, this.count)
        ZipMaker.u32(out, this.central.size)
        ZipMaker.u32(out, cdOff)
        ZipMaker.u16(out, 0)
        return out.toArray()
    }

    static func u16(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 0xFF))
        out.add(UInt8((v >> 8) & 0xFF))
    }

    static func u32(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 0xFF))
        out.add(UInt8((v >> 8) & 0xFF))
        out.add(UInt8((v >> 16) & 0xFF))
        out.add(UInt8((v >> 24) & 0xFF))
    }

    static func raw(out: ArrayList<Byte>, b: Array<Byte>): Unit {
        for (x in b) {
            out.add(x)
        }
    }
}

/** 执行并返回异常消息（无异常返回空串） */
func caught(body: () -> Unit): String {
    try {
        body()
        return ""
    } catch (e: Exception) {
        return e.message
    }
}

// ------------------------------------------------------------
// ZIP 解析
// ------------------------------------------------------------

@Test
public class ZipReaderTest {
    /** store（不压缩）条目：与自研 ZipBuilder 的输出互通 */
    @TestCase
    public func testStoreEntryFromOwnBuilder() {
        let b = ZipBuilder(StdxCryptoProvider())
        b.add("证件/正面.png", [1u8, 2u8, 3u8, 4u8])
        let zip = ZipArchive.open(b.build(""))
        let list = zip.entries()
        @Assert(list.size, 1)
        @Assert(list[0].path, "证件/正面.png")
        @Assert(list[0].method, 0)
        @Assert(list[0].issue, "")
        let plain = zip.read(list[0], 1024)
        @Assert(plain.size, 4)
        @Assert(plain[0], 1u8)
    }

    /** deflate 条目：解 Python zlib 产出的裸 deflate */
    @TestCase
    public func testDeflateEntry() {
        let realPlain = "AMS 附件导入 · deflate 校验样本".toArray()
        @Assert(realPlain.size, Fx.SAMPLE_PLAIN_LEN)
        let zip = ZipArchive.open(
            ZipMaker().add("a/x.png".toArray(), Fx.Z_SAMPLE, realPlain, 8, 0x0800).build()
        )
        let e = zip.entries()[0]
        @Assert(e.method, 8)
        @Assert(e.compressedSize, 45)
        @Assert(e.uncompressedSize, 40)
        let plain = zip.read(e, 1024)
        @Assert(plain.size, 40)
        @Assert(String.fromUtf8(plain), "AMS 附件导入 · deflate 校验样本")
    }

    /** 解压 100000 字节：跨越多个 32KB 缓冲块 */
    @TestCase
    public func testDeflateLargeEntry() {
        // 明文是 "0123456789abcdef" 重复 6250 次
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < 6250) {
            sb.append("0123456789abcdef")
            i = i + 1
        }
        let realPlain = sb.toString().toArray()
        @Assert(realPlain.size, Fx.BIG_PLAIN_LEN)
        let zip = ZipArchive.open(
            ZipMaker().add("b/y.pdf".toArray(), Fx.Z_BIG, realPlain, 8, 0x0800).build()
        )
        let e = zip.entries()[0]
        let plain = zip.read(e, Fx.BIG_PLAIN_LEN)
        @Assert(plain.size, Fx.BIG_PLAIN_LEN)
        @Assert(String.fromUtf8(plain[0..16]), "0123456789abcdef")
    }

    /** CRC 不符必须拒绝（不静默接受损坏文件） */
    @TestCase
    public func testCrcMismatchRejected() {
        let name = "证件/坏.png".toArray()
        let plain = [1u8, 2u8, 3u8]
        let zip = ZipArchive.open(
            ZipMaker().add(name, plain, plain, 0, 0x0800, crc: 12345).build()
        )
        let e = zip.entries()[0]
        @Assert(caught({ => zip.read(e, 1024) }).contains("CRC"), true)
    }

    /** 超出单文件上限必须拒绝（zip bomb 防护） */
    @TestCase
    public func testReadBeyondLimitRejected() {
        let zip = ZipArchive.open(
            ZipMaker().add("b/y.pdf".toArray(), Fx.Z_BIG, Array<Byte>(Fx.BIG_PLAIN_LEN, repeat: 48u8), 8, 0x0800).build()
        )
        let e = zip.entries()[0]
        @Assert(caught({ => zip.read(e, 1000) }).contains("上限"), true)
    }

    /** GBK 文件名（中文 Windows 压缩文件夹场景，无 bit 11） */
    @TestCase
    public func testGbkNameDecoded() {
        let name = ArrayList<Byte>()
        for (b in Fx.GBK_NAME) {
            name.add(b)
        }
        name.add(47u8)   // '/'
        for (b in "a.png".toArray()) {
            name.add(b)
        }
        let plain = [9u8, 9u8]
        let zip = ZipArchive.open(
            ZipMaker().add(name.toArray(), plain, plain, 0, 0x0000).build()
        )
        let e = zip.entries()[0]
        @Assert(e.issue, "")
        @Assert(e.path, "证件照片/a.png")
    }

    /** UTF-8 文件名但不置 bit 11：按内容判定，不能依赖标志位 */
    @TestCase
    public func testUtf8NameWithoutFlag() {
        let name = ArrayList<Byte>()
        for (b in Fx.UTF8_NAME) {
            name.add(b)
        }
        name.add(47u8)
        for (b in "b.jpg".toArray()) {
            name.add(b)
        }
        let plain = [7u8]
        let zip = ZipArchive.open(
            ZipMaker().add(name.toArray(), plain, plain, 0, 0x0000).build()
        )
        @Assert(zip.entries()[0].path, "证件照片/b.jpg")
    }

    /** 路径穿越必须拒绝，且要能看见是哪一条 */
    @TestCase
    public func testPathTraversalRejected() {
        let plain = [1u8]
        let zip = ZipArchive.open(
            ZipMaker().add("../../etc/passwd".toArray(), plain, plain, 0, 0x0800).build()
        )
        let e = zip.entries()[0]
        @Assert(e.issue.contains("上级引用"), true)
        // 路径仍要返回，便于预览里定位
        @Assert(e.path.contains("passwd"), true)
        @Assert(caught({ => zip.read(e, 1024) }).isEmpty(), false)
    }

    /** 盘符 / 绝对路径必须拒绝 */
    @TestCase
    public func testAbsolutePathRejected() {
        let plain = [1u8]
        let zip = ZipArchive.open(
            ZipMaker()
                .add("C:/Windows/x.png".toArray(), plain, plain, 0, 0x0800)
                .add("/etc/root.png".toArray(), plain, plain, 0, 0x0800)
                .build()
        )
        let list = zip.entries()
        @Assert(list[0].issue.contains("冒号"), true)
        // "/etc/root.png" 去掉前导斜杠后是合法相对路径，应可处理
        @Assert(list[1].issue, "")
        @Assert(list[1].path, "etc/root.png")
    }

    /** 反斜杠分隔要归一化为正斜杠 */
    @TestCase
    public func testBackslashNormalized() {
        let plain = [1u8]
        let zip = ZipArchive.open(
            ZipMaker().add("证件\\照片\\a.png".toArray(), plain, plain, 0, 0x0800).build()
        )
        @Assert(zip.entries()[0].path, "证件/照片/a.png")
    }

    /** 加密条目：标记为不可处理而不是解出错数据 */
    @TestCase
    public func testEncryptedEntryFlagged() {
        let plain = [1u8, 2u8]
        let zip = ZipArchive.open(
            ZipMaker().add("a.png".toArray(), plain, plain, 0, 0x0801).build()
        )
        let e = zip.entries()[0]
        @Assert(e.issue.contains("加密"), true)
    }

    /** 不支持的压缩方法（bzip2=12）要明确报错 */
    @TestCase
    public func testUnsupportedMethodFlagged() {
        let plain = [1u8, 2u8]
        let zip = ZipArchive.open(
            ZipMaker().add("a.png".toArray(), plain, plain, 12, 0x0800).build()
        )
        @Assert(zip.entries()[0].issue.contains("压缩方法"), true)
    }

    /** 目录条目不算错误，但不可读取 */
    @TestCase
    public func testDirEntry() {
        let zip = ZipArchive.open(
            ZipMaker().add("证件/".toArray(), Array<Byte>(), Array<Byte>(), 0, 0x0800).build()
        )
        let e = zip.entries()[0]
        @Assert(e.isDir, true)
        @Assert(caught({ => zip.read(e, 1024) }).contains("目录"), true)
    }

    /** 非 ZIP 输入 */
    @TestCase
    public func testNotZipRejected() {
        @Assert(caught({ => ZipArchive.open("hello world, not a zip".toArray()) }).contains("ZIP"), true)
        @Assert(caught({ => ZipArchive.open(Array<Byte>()) }).contains("ZIP"), true)
    }

    /** 空档案：解析成功、条目为空（由调用方判断「没有可导入的文件」） */
    @TestCase
    public func testEmptyZip() {
        let maker = ZipMaker()
        let zip = ZipArchive.open(maker.build())
        @Assert(zip.entries().size, 0)
    }

    /**
     * 60 条目的多条目包（对应现场反馈「60 个条目解析失败」）。
     *
     * 解析器对条目数没有特殊分支，但「条目一多就失败」的现场反馈最终
     * 往往落在**请求体**而不是解析器上。这条用例把解析侧的基线钉住：
     * 60 个条目必须全部枚举、顺序不能串、每条内容与路径一一对应。
     * 若哪天分块读 / 切片语义出问题（长度对、内容错），这里会立刻失败。
     */
    @TestCase
    public func testSixtyEntries() {
        let maker = ZipMaker()
        var i: Int64 = 0
        while (i < 60) {
            maker.add("目录${i}/文件${i}.png".toArray(), [UInt8(i)], [UInt8(i)], 0, 0x0800)
            i = i + 1
        }
        let zip = ZipArchive.open(maker.build())
        let list = zip.entries()
        @Assert(list.size, 60)
        @Assert(list[0].path, "目录0/文件0.png")
        @Assert(list[59].path, "目录59/文件59.png")
        @Assert(list[42].issue, "")
        var k: Int64 = 0
        while (k < 60) {
            let plain = zip.read(list[k], 1024)
            @Assert(plain.size, 1)
            @Assert(plain[0], UInt8(k))
            @Assert(AttachmentImportService.firstSegment(list[k].path), "目录${k}")
            k = k + 1
        }
    }

    /** 条目数上限 */
    @TestCase
    public func testEntryCountCap() {
        let maker = ZipMaker()
        var i: Int64 = 0
        while (i < 2001) {
            maker.add("d/f${i}.png".toArray(), [1u8], [1u8], 0, 0x0800)
            i = i + 1
        }
        // 2001 > 2000 上限：open 直接抛
        @Assert(caught({ => ZipArchive.open(maker.build()) }).contains("上限"), true)
        @Assert(IMPORT_MAX_ENTRIES, 2000)
    }
}

// ------------------------------------------------------------
// 纯函数
// ------------------------------------------------------------

@Test
public class ZipRuleTest {
    @TestCase
    public func testBaseName() {
        @Assert(AttachmentImportService.baseName("证件/照片/正面.png"), "正面.png")
        @Assert(AttachmentImportService.baseName("a.png"), "a.png")
        @Assert(AttachmentImportService.baseName("证件/"), "")
    }

    @TestCase
    public func testFirstSegment() {
        @Assert(AttachmentImportService.firstSegment("证件/照片/正面.png"), "证件")
        @Assert(AttachmentImportService.firstSegment("a.png"), "")
        @Assert(AttachmentImportService.firstSegment("证件/"), "证件")
    }

    @TestCase
    public func testUtf8Validator() {
        @Assert(ZipArchive.isValidUtf8("abc".toArray()), true)
        @Assert(ZipArchive.isValidUtf8("证件照片".toArray()), true)
        @Assert(ZipArchive.isValidUtf8(Fx.GBK_NAME), false)          // GBK 不是 UTF-8
        @Assert(ZipArchive.isValidUtf8([0xC0u8, 0x80u8]), false)     // 过长编码
        @Assert(ZipArchive.isValidUtf8([0xE4u8, 0xB8u8]), false)     // 截断
        @Assert(ZipArchive.isValidUtf8([0xEDu8, 0xA0u8, 0x80u8]), false)  // 代理区
    }

    @TestCase
    public func testCsvCellEscapesQuotes() {
        @Assert(AttachmentImportService.csvCell("a\"b"), "a\"\"b")
        @Assert(AttachmentImportService.csvCell("普通"), "普通")
    }
}
