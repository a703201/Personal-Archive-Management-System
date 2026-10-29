// ============================================================
// ams.app.importer · ZIP 读取器（FR-IMP-002 批量导入附件）
//
// 【为什么要自己写】
//   stdx 只有 tar / zlib，**没有 zip**。附件批量导入的输入约定就是 ZIP
//   （用户从资源管理器/7-Zip 直接打出来的包），换 tar 等于让用户先装工具。
//   故这里按 APPNOTE 6.3 实现读取子集。
//
// 【已实现范围】
//   · 中央目录驱动的枚举（EOCD → central directory → local header）；
//   · 压缩方法 store(0) 与 deflate(8)：deflate 走 stdx.compress.zlib 的
//     `WrapType.DeflateFormat`。**已实测该取值对应裸 deflate（RFC 1951）**，
//     正是 ZIP 条目所用的形式；zlib 包裹（RFC 1950）与 gzip 均不能解；
//   · 每个条目解压后做 CRC-32 校验（复用 ZipBuilder.crc32，与打包侧同一实现）；
//   · 文件名编码：先按严格 UTF-8 校验，失败则回落 GBK 表（见 gbk.cj）。
//     中文 Windows 的「压缩(zipped)文件夹」用 GBK 且不置 bit 11，
//     不照顾这条路径等于对最常见的输入直接报错。
//
// 【明确不支持（按条目给出原因，不静默跳过）】
//   · ZIP64（>4GB 或 >65535 条目）；
//   · 加密条目（ZipCrypto / AES）；
//   · 其它压缩方法（bzip2 / lzma / deflate64 / zstd）。
//
// 【安全约束】导入的是**外部输入**，按不可信数据处理：
//   · 路径穿越：拒绝 ".."、绝对路径、盘符、"\\\\" 段；
//   · zip bomb：条目数上限、单条目解压上限、整包解压总量上限，
//     且解压时**边读边计数**，超限立即中断而不是解完再判断；
//   · CRC 不符视为损坏，不落库。
// ============================================================
package ams.app.importer

import std.collection.*
import std.io.*
import stdx.compress.zlib.*

import ams.app.attachment.*
import ams.kernel.error.*

// ---- 常量 ----

/** 中央目录项签名 */
const CD_SIG: Int64 = 0x02014b50
/** 本地文件头签名 */
const LOCAL_SIG: Int64 = 0x04034b50
/** 中央目录结束标记 */
const EOCD_SIG: Int64 = 0x06054b50

/** 单包条目数上限（含目录条目） */
public const IMPORT_MAX_ENTRIES: Int64 = 2000

/**
 * 一个 ZIP 条目（目录项也包含在内，由 isDir 区分）。
 */
public class ZipEntry {
    /** 规范化后的相对路径（正斜杠，无前导 "./" 与 "/"） */
    public let path: String
    /** 压缩方法：0=store，8=deflate */
    public let method: Int64
    /** 通用标志位 */
    public let flags: Int64
    /** 中央目录记录的 CRC-32 */
    public let crcExpected: Int64
    /** 压缩后大小 */
    public let compressedSize: Int64
    /** 解压后大小（中央目录声明值，仅作参考与上限） */
    public let uncompressedSize: Int64
    /** 本地头偏移 */
    public let localOffset: Int64
    /** 是否目录条目 */
    public let isDir: Bool
    /**
     * 该条目能否处理。空串 = 可以；非空 = 不可处理的原因
     * （加密 / ZIP64 / 不支持的压缩方法 / 非法路径 / 编码无法识别）。
     */
    public let issue: String

    init(
        path: String, method: Int64, flags: Int64, crcExpected: Int64,
        compressedSize: Int64, uncompressedSize: Int64, localOffset: Int64,
        isDir: Bool, issue: String
    ) {
        this.path = path
        this.method = method
        this.flags = flags
        this.crcExpected = crcExpected
        this.compressedSize = compressedSize
        this.uncompressedSize = uncompressedSize
        this.localOffset = localOffset
        this.isDir = isDir
        this.issue = issue
    }
}

/**
 * ZIP 归档（只读）。
 */
public class ZipArchive {
    private let data: Array<Byte>
    private let items: ArrayList<ZipEntry>

    private init(data: Array<Byte>, items: ArrayList<ZipEntry>) {
        this.data = data
        this.items = items
    }

    /** 全部条目（含目录与不可处理项） */
    public func entries(): ArrayList<ZipEntry> {
        return this.items
    }

    /**
     * 解析 ZIP。
     *
     * @throws AppError(ValidationFailed) 不是合法 ZIP / 中央目录损坏
     */
    public static func open(data: Array<Byte>): ZipArchive {
        if (data.size < 22) {
            throw AppError(AppErrorKind.ValidationFailed, "不是有效的 ZIP 文件（长度不足）")
        }
        let eocd = ZipArchive.findEocd(data)
        if (eocd < 0) {
            throw AppError(AppErrorKind.ValidationFailed,
                           "不是有效的 ZIP 文件（找不到中央目录结束标记）")
        }
        let count = ZipArchive.u16(data, eocd + 10)
        let cdOffset = ZipArchive.u32(data, eocd + 16)
        if (count < 0 || cdOffset < 0) {
            throw AppError(AppErrorKind.ValidationFailed, "ZIP 中央目录损坏")
        }
        if (count > IMPORT_MAX_ENTRIES) {
            throw AppError(AppErrorKind.PayloadTooLarge,
                           "ZIP 条目数 ${count} 超过上限 ${IMPORT_MAX_ENTRIES}")
        }
        // 空档案（只有 EOCD）没有中央目录，不能拿 cdOffset 去验签名
        if (count > 0 && ZipArchive.u32(data, cdOffset) != CD_SIG) {
            throw AppError(AppErrorKind.ValidationFailed, "ZIP 中央目录签名不符")
        }
        let items = ArrayList<ZipEntry>()
        var p = cdOffset
        var k: Int64 = 0
        while (k < count) {
            if (ZipArchive.u32(data, p) != CD_SIG) {
                break
            }
            let flags = ZipArchive.u16(data, p + 8)
            let method = ZipArchive.u16(data, p + 10)
            let crc = ZipArchive.u32(data, p + 16)
            let csz = ZipArchive.u32(data, p + 20)
            let usz = ZipArchive.u32(data, p + 24)
            let nlen = ZipArchive.u16(data, p + 28)
            let elen = ZipArchive.u16(data, p + 30)
            let clen = ZipArchive.u16(data, p + 32)
            let lho = ZipArchive.u32(data, p + 42)
            if (flags < 0 || method < 0 || crc < 0 || csz < 0 || usz < 0 ||
                nlen < 0 || elen < 0 || clen < 0 || lho < 0) {
                throw AppError(AppErrorKind.ValidationFailed, "ZIP 中央目录字段越界")
            }
            let nameAt = p + 46
            if (nameAt + nlen > data.size) {
                throw AppError(AppErrorKind.ValidationFailed, "ZIP 中央目录字段越界")
            }
            let nameBytes = data[nameAt..(nameAt + nlen)]
            let (rawName, nameIssue) = ZipArchive.decodeName(nameBytes)
            let isDir = rawName.endsWith("/") || rawName.endsWith("\\")
            let (path, pathIssue) = if (isDir) {
                (rawName, "")
            } else {
                ZipArchive.normalize(rawName)
            }
            // 逐级判定不可处理原因（按优先级：编码 → 路径 → 加密 → ZIP64 → 方法）
            var issue = ""
            if (!nameIssue.isEmpty()) {
                issue = nameIssue
            } else if (!pathIssue.isEmpty()) {
                issue = pathIssue
            } else if ((flags & 0x0001) != 0) {
                issue = "条目已加密（不支持 ZipCrypto/AES）"
            } else if (csz >= 0xFFFFFFFF || usz >= 0xFFFFFFFF || lho >= 0xFFFFFFFF) {
                issue = "ZIP64 条目不支持"
            } else if (method != 0 && method != 8) {
                issue = "压缩方法 ${method} 不支持（仅 store/deflate）"
            }
            items.add(ZipEntry(path, method, flags, crc, csz, usz, lho, isDir, issue))
            p = nameAt + nlen + elen + clen
            k = k + 1
        }
        return ZipArchive(data, items)
    }

    /**
     * 取一个条目的明文内容（解压 + CRC 校验）。
     *
     * @throws AppError 条目不可处理 / 数据损坏 / 超过上限
     */
    public func read(entry: ZipEntry, maxBytes: Int64): Array<Byte> {
        if (!entry.issue.isEmpty()) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：${entry.issue}")
        }
        if (entry.isDir) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：目录条目无内容")
        }
        if (entry.uncompressedSize > maxBytes) {
            throw AppError(AppErrorKind.PayloadTooLarge,
                           "${entry.path}：解压后 ${entry.uncompressedSize} 字节，超过单文件上限 ${maxBytes}")
        }
        let lho = entry.localOffset
        if (ZipArchive.u32(this.data, lho) != LOCAL_SIG) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：本地文件头损坏")
        }
        let nlen = ZipArchive.u16(this.data, lho + 26)
        let elen = ZipArchive.u16(this.data, lho + 28)
        if (nlen < 0 || elen < 0) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：本地文件头损坏")
        }
        let start = lho + 30 + nlen + elen
        let end = start + entry.compressedSize
        if (start < 0 || end > this.data.size) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：压缩数据越界")
        }
        let raw = this.data[start..end]
        let plain = if (entry.method == 0) {
            raw
        } else {
            ZipArchive.inflate(raw, entry.path, maxBytes)
        }
        if (plain.size > maxBytes) {
            throw AppError(AppErrorKind.PayloadTooLarge,
                           "${entry.path}：解压后超过单文件上限 ${maxBytes}")
        }
        let actual = ZipBuilder.crc32(plain) & 0xFFFFFFFF
        if (actual != (entry.crcExpected & 0xFFFFFFFF)) {
            throw AppError(AppErrorKind.ValidationFailed, "${entry.path}：CRC 校验失败（文件损坏）")
        }
        return plain
    }

    // ---- 内部 ----

    /**
     * 裸 deflate 解压。
     *
     * 边读边计数：ZIP 是外部输入，一个 40KB 的 deflate 流可以膨胀到几十 MB，
     * 必须先设上限再解，而不是解完再判断。
     */
    private static func inflate(comp: Array<Byte>, name: String, maxBytes: Int64): Array<Byte> {
        let src = ByteBuffer(comp)
        let out = ArrayList<Byte>()
        var over = false
        let dis = DecompressInputStream(src, wrap: WrapType.DeflateFormat, bufLen: 32768)
        try {
            let buf = Array<Byte>(32768, repeat: 0u8)
            while (true) {
                let n = dis.read(buf)
                if (n <= 0) {
                    break
                }
                if (out.size + n > maxBytes) {
                    over = true
                    break
                }
                for (i in 0..n) {
                    out.add(buf[i])
                }
            }
        } catch (e: Exception) {
            throw AppError(AppErrorKind.ValidationFailed, "${name}：解压失败（数据损坏）")
        } finally {
            try {
                dis.close()
            } catch (e: Exception) {
                // 关闭失败不影响已解出的数据
            }
        }
        if (over) {
            throw AppError(AppErrorKind.PayloadTooLarge, "${name}：解压后超过单文件上限")
        }
        return out.toArray()
    }

    /** 从尾部向前找 EOCD（末 64KB + 22 字节范围内）。 */
    private static func findEocd(data: Array<Byte>): Int64 {
        var i = data.size - 22
        var floor = data.size - (65535 + 22)
        if (floor < 0) {
            floor = 0
        }
        while (i >= floor) {
            if (ZipArchive.u32(data, i) == EOCD_SIG) {
                return i
            }
            i = i - 1
        }
        return -1
    }

    /** 小端 u16；越界返回 -1。 */
    private static func u16(b: Array<Byte>, at: Int64): Int64 {
        if (at < 0 || at + 2 > b.size) {
            return -1
        }
        return Int64(b[at]) + Int64(b[at + 1]) * 256
    }

    /** 小端 u32；越界返回 -1。 */
    private static func u32(b: Array<Byte>, at: Int64): Int64 {
        if (at < 0 || at + 4 > b.size) {
            return -1
        }
        return Int64(b[at]) + Int64(b[at + 1]) * 256 +
               Int64(b[at + 2]) * 65536 + Int64(b[at + 3]) * 16777216
    }

    /**
     * 严格 UTF-8 校验。
     *
     * 不用「String.fromUtf8 抛不抛异常」来判断：那段行为在 SDK 版本间
     * 不稳定（本项目已因类似假设踩过坑），显式校验每个字节序列才可靠。
     */
    public static func isValidUtf8(b: Array<Byte>): Bool {
        var i = 0
        let n = b.size
        while (i < n) {
            let c = Int64(b[i])
            if (c < 0x80) {
                i = i + 1
                continue
            }
            var need = 0
            var cp: Int64 = 0
            if (c >= 0xC2 && c <= 0xDF) {
                need = 1
                cp = c & 0x1F
            } else if (c >= 0xE0 && c <= 0xEF) {
                need = 2
                cp = c & 0x0F
            } else if (c >= 0xF0 && c <= 0xF4) {
                need = 3
                cp = c & 0x07
            } else {
                return false
            }
            if (i + need >= n) {
                return false
            }
            var k = 1
            while (k <= need) {
                let cc = Int64(b[i + k])
                if ((cc & 0xC0) != 0x80) {
                    return false
                }
                cp = (cp * 64) + (cc & 0x3F)
                k = k + 1
            }
            if (need == 2 && cp < 0x800) {
                return false
            }
            if (need == 3 && cp < 0x10000) {
                return false
            }
            if (cp >= 0xD800 && cp <= 0xDFFF) {
                return false
            }
            if (cp > 0x10FFFF) {
                return false
            }
            i = i + need + 1
        }
        return true
    }

    /**
     * 文件名解码：UTF-8 与 GBK 双解 + 可读性打分。
     *
     * 【为什么不能只看 bit 11】
     *   ZIP 规范说置位即 UTF-8，但现实里两头都有偏差：
     *   中文 Windows 的「压缩文件夹」写 GBK 且**不置位**；
     *   部分打包工具写 UTF-8 却**忘记置位**。
     *
     * 【为什么不能只按「先试 UTF-8」】
     *   GBK 双字节序列有相当比例**恰好也是合法 UTF-8**
     *   （如 C4 E3 = GBK「你」，按 UTF-8 是 U+0123）。
     *   只按能不能解出来判断，会把这些名字解成怪字符。
     *
     * 【做法】两种都解一遍，按「字符是否像文件名」打分：
     *   期望字符集 = ASCII + CJK 汉字 + CJK 标点 + 全角 + 通用标点；
     *   落在拉丁扩展 / 希伯来 / 阿拉伯 / 组合符等区间的判为可疑。
     *   GBK 误判成 UTF-8 会落到希伯来等区间（低分），
     *   UTF-8 误判成 GBK 会落到汉字区间（同为高分），此时**并列取 UTF-8**
     *   —— 跨平台工具写 UTF-8 是主流，并列时偏向它更安全。
     */
    private static func decodeName(bytes: Array<Byte>): (String, String) {
        if (bytes.size == 0) {
            return ("", "条目名为空")
        }
        let utf8Ok = ZipArchive.isValidUtf8(bytes)
        let gbk = Gbk.decode(bytes, 0, bytes.size)
        if (utf8Ok) {
            let s = String.fromUtf8(bytes)
            if (ZipArchive.isAscii(bytes)) {
                return (s, "")
            }
            match (gbk) {
                case Some(g) =>
                    if (ZipArchive.plausibility(g) > ZipArchive.plausibility(s)) {
                        return (g, "")
                    }
                case None => ()
            }
            return (s, "")
        }
        match (gbk) {
            case Some(g) => return (g, "")
            case None => return ("", "文件名编码无法识别（既不是 UTF-8 也不是 GBK）")
        }
    }

    /** 全部字节是否 ASCII */
    private static func isAscii(b: Array<Byte>): Bool {
        for (x in b) {
            if (x >= 0x80) {
                return false
            }
        }
        return true
    }

    /**
     * 「像文件名」的程度（0..100）。
     *
     * 分母是该串的码点数，分子是落在常见字符集内的码点数。
     */
    static func plausibility(s: String): Int64 {
        var good: Int64 = 0
        var total: Int64 = 0
        for (r in s.runes()) {
            total = total + 1
            let c = UInt32(r)
            let ok = (c >= 0x20 && c < 0x7F) ||            // ASCII 可见
                     (c >= 0x4E00 && c <= 0x9FFF) ||       // CJK 统一汉字
                     (c >= 0x3400 && c <= 0x4DBF) ||       // CJK 扩展 A
                     (c >= 0x3000 && c <= 0x303F) ||       // CJK 标点
                     (c >= 0xFF00 && c <= 0xFFEF) ||       // 全角
                     (c >= 0x2000 && c <= 0x206F)          // 通用标点
            if (ok) {
                good = good + 1
            }
        }
        if (total == 0) {
            return 0
        }
        return good * 100 / total
    }

    /**
     * 路径规范化 + 安全校验。
     *
     * 有问题时**仍然返回路径**（不是空串）：预览里要让用户看见究竟是
     * 哪一条被拒了，返回空串等于把线索抹掉。该行只会被标记为 skip，
     * 不会被拿去读文件，故露出原始路径没有风险。
     *
     * @return (用于展示的路径, 问题描述)；问题描述非空即不可处理
     */
    private static func normalize(raw: String): (String, String) {
        var s = raw.replace("\\", "/")
        while (s.startsWith("./")) {
            s = s[2..]
        }
        while (s.startsWith("/")) {
            s = s[1..]
        }
        if (s.isEmpty()) {
            return ("", "条目名为空")
        }
        if (s.toArray().size > 400) {
            return (s, "路径超过 400 字节")
        }
        let parts = s.split("/")
        var depth = 0
        for (seg in parts) {
            if (seg.isEmpty()) {
                continue
            }
            if (seg == ".") {
                continue
            }
            if (seg == "..") {
                return (s, "路径包含上级引用（..），已拒绝")
            }
            if (seg.contains(":")) {
                return (s, "路径包含盘符或冒号，已拒绝")
            }
            depth = depth + 1
        }
        if (depth == 0) {
            return ("", "条目名为空")
        }
        return (s, "")
    }
}

