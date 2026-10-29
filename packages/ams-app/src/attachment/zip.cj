// ============================================================
// ams.app.attachment · 极简 ZIP 打包器（FR-ATT-010 批量下载）
//
// 为什么要自己写：
//   本机标准库只有 tar / zlib，**没有 zip**（stdx.compress 无 zip 包）。
//   批量下载若给 .tar.gz，Windows 用户双击打不开，体验断崖；
//   而 ZIP 的「store（不压缩）」子集格式极简，可以只用规范里
//   几十行就能写对，且能被 Python zipfile / 7-Zip / 资源管理器验证。
//   因此这里只实现 store 方法（不压缩）+ 可选的 ZipCrypto 传统加密，
//   不实现 deflate —— 需要压缩时由调用方决定是否另存为 tar.gz。
//
// 已实现范围（够用且可验证）：
//   · 本地文件头 / 中央目录 / EOCD，单盘、无注释、无扩展字段；
//   · CRC-32（逐位算法，不建表，几 MB 量级完全够）；
//   · ZipCrypto（PKWARE 传统加密）：12 字节随机头 + CRC 高字节校验，
//     Python zipfile 可直接用 pwd 解密验证 —— 这是本项目接受它的前提。
//
// ⚠️ ZipCrypto 抗已知明文攻击能力弱，只用于「防止随手打开」的场景；
//    真正的机密性依赖传输层与访问控制（本仓已做归属校验 + 下载审计）。
// ============================================================
package ams.app.attachment

import std.collection.*

import ams.crypto.provider.*
import ams.kernel.error.*
import ams.kernel.time.*

/**
 * 一个待打包条目。
 */
public class ZipItem {
    public let name: String
    public let data: Array<Byte>

    public init(name: String, data: Array<Byte>) {
        this.name = name
        this.data = data
    }
}

/**
 * ZIP 打包器。
 */
public class ZipBuilder {
    private let items: ArrayList<ZipItem>
    private let crypto: CryptoProvider

    public init(crypto: CryptoProvider) {
        this.items = ArrayList<ZipItem>()
        this.crypto = crypto
    }

    /** 追加一个条目（重名自动加序号后缀，避免解压时互相覆盖）。 */
    public func add(name: String, data: Array<Byte>): Unit {
        var n = name
        var i = 2
        while (this.hasName(n)) {
            n = ZipBuilder.rename(name, i)
            i = i + 1
        }
        this.items.add(ZipItem(n, data))
    }

    /** 条目数 */
    public func size(): Int64 {
        return this.items.size
    }

    /**
     * 打包。
     *
     * @param password 非空则用 ZipCrypto 加密每个条目
     * @return ZIP 字节
     */
    public func build(password: String): Array<Byte> {
        let out = ArrayList<Byte>()
        let (dosTime, dosDate) = ZipBuilder.dosNow()
        // 中央目录先收集，最后统一写出
        let centrals = ArrayList<Array<Byte>>()
        for (it in this.items.iterator()) {
            let offset = out.size
            let crc = ZipBuilder.crc32(it.data)
            let encrypted = !password.isEmpty()
            var payload = it.data
            if (encrypted) {
                payload = this.encryptEntry(it.data, crc, password)
            }
            // ---- 本地文件头 ----
            ZipBuilder.putU32(out, 0x04034b50)
            ZipBuilder.putU16(out, 20)                       // version needed
            ZipBuilder.putU16(out, ZipBuilder.flagsOf(encrypted))    // flags（含 UTF-8 名标记）
            ZipBuilder.putU16(out, 0)                        // method: store
            ZipBuilder.putU16(out, dosTime)
            ZipBuilder.putU16(out, dosDate)
            ZipBuilder.putU32(out, crc)
            ZipBuilder.putU32(out, payload.size)             // compressed size
            ZipBuilder.putU32(out, it.data.size)             // uncompressed size
            let nameBytes = it.name.toArray()
            ZipBuilder.putU16(out, nameBytes.size)
            ZipBuilder.putU16(out, 0)                        // extra len
            ZipBuilder.appendBytes(out, nameBytes)
            ZipBuilder.appendBytes(out, payload)

            // ---- 中央目录项 ----
            let cd = ArrayList<Byte>()
            ZipBuilder.putU32(cd, 0x02014b50)
            ZipBuilder.putU16(cd, 20)                        // version made by
            ZipBuilder.putU16(cd, 20)                        // version needed
            ZipBuilder.putU16(cd, ZipBuilder.flagsOf(encrypted))
            ZipBuilder.putU16(cd, 0)
            ZipBuilder.putU16(cd, dosTime)
            ZipBuilder.putU16(cd, dosDate)
            ZipBuilder.putU32(cd, crc)
            ZipBuilder.putU32(cd, payload.size)
            ZipBuilder.putU32(cd, it.data.size)
            ZipBuilder.putU16(cd, nameBytes.size)
            ZipBuilder.putU16(cd, 0)                         // extra
            ZipBuilder.putU16(cd, 0)                         // comment
            ZipBuilder.putU16(cd, 0)                         // disk start
            ZipBuilder.putU16(cd, 0)                         // internal attr
            ZipBuilder.putU32(cd, 0)                         // external attr
            ZipBuilder.putU32(cd, offset)
            ZipBuilder.appendBytes(cd, nameBytes)
            centrals.add(cd.toArray())
        }
        let cdOffset = out.size
        var cdSize: Int64 = 0
        for (cd in centrals.iterator()) {
            ZipBuilder.appendBytes(out, cd)
            cdSize = cdSize + cd.size
        }
        // ---- EOCD ----
        ZipBuilder.putU32(out, 0x06054b50)
        ZipBuilder.putU16(out, 0)
        ZipBuilder.putU16(out, 0)
        ZipBuilder.putU16(out, this.items.size)
        ZipBuilder.putU16(out, this.items.size)
        ZipBuilder.putU32(out, cdSize)
        ZipBuilder.putU32(out, cdOffset)
        ZipBuilder.putU16(out, 0)
        return out.toArray()
    }

    // ---- 内部 ----

    private func hasName(name: String): Bool {
        for (it in this.items.iterator()) {
            if (it.name == name) {
                return true
            }
        }
        return false
    }

    private static func rename(name: String, seq: Int64): String {
        let dot = ZipBuilder.lastDot(name)
        if (dot <= 0) {
            return "${name}(${seq})"
        }
        return name[0..dot] + "(${seq})" + name[dot..]
    }

    private static func lastDot(name: String): Int64 {
        let bytes = name.toArray()
        var i = bytes.size - 1
        while (i >= 0) {
            if (bytes[i] == 46) {
                return i
            }
            i = i - 1
        }
        return -1
    }

    /**
     * ZipCrypto 加密：12 字节头（11 随机 + CRC 高字节）+ 逐字节加密。
     */
    private func encryptEntry(plain: Array<Byte>, crc: Int64, password: String): Array<Byte> {
        let keys = ZipCryptoKeys(password)
        let head = match (this.crypto.randomBytes(11)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "随机数生成失败")
        }
        let out = ArrayList<Byte>()
        for (b in head) {
            let c = keys.encrypt(Int64(b))
            out.add(UInt8(c))
        }
        let check = keys.encrypt((crc >> 24) & 0xFF)
        out.add(UInt8(check))
        for (b in plain) {
            let c = keys.encrypt(Int64(b))
            out.add(UInt8(c))
        }
        return out.toArray()
    }

    /**
     * CRC-32（IEEE 802.3，逐位实现，不建表）。
     */
    public static func crc32(data: Array<Byte>): Int64 {
        var crc: Int64 = 0xFFFFFFFF
        for (b in data) {
            crc = crc ^ Int64(b)
            var i = 0
            while (i < 8) {
                if ((crc & 1) == 1) {
                    // Int64 里保持非负：先右移再异或，最后统一取低 32 位
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

    /**
     * 当前时间 → DOS 日期/时间（ZIP 规范：1980 起算，秒按 2 秒精度）。
     */
    private static func dosNow(): (Int64, Int64) {
        let iso = Times.toIso8601(Times.nowMillis())
        if (iso.size < 19) {
            return (0, (1 << 5) | 1)
        }
        let year = ZipBuilder.num(iso[0..4])
        let month = ZipBuilder.num(iso[5..7])
        let day = ZipBuilder.num(iso[8..10])
        let hour = ZipBuilder.num(iso[11..13])
        let minute = ZipBuilder.num(iso[14..16])
        let second = ZipBuilder.num(iso[17..19])
        var y = year
        if (y < 1980) {
            y = 1980
        }
        let date = ((y - 1980) << 9) | (month << 5) | day
        let time = (hour << 11) | (minute << 5) | (second / 2)
        return (time, date)
    }

    /** ASCII 数字串 → 整数（非法字符按 0 处理）。 */
    private static func num(s: String): Int64 {
        var v: Int64 = 0
        for (b in s.toArray()) {
            if (b >= 48 && b <= 57) {
                v = v * 10 + Int64(b) - 48
            }
        }
        return v
    }

    /**
     * 通用标志位。
     *
     * bit 0  = 加密（ZipCrypto）
     * bit 11 = 文件名按 UTF-8 编码 —— **必须置位**，否则 unzip / Python
     *          zipfile 会按 cp437 解码，中文文件名全部变乱码（实测踩到）。
     */
    private static func flagsOf(encrypted: Bool): Int64 {
        var f: Int64 = 0x0800
        if (encrypted) {
            f = f | 0x0001
        }
        return f
    }

    private static func putU16(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 0xFF))
        out.add(UInt8((v >> 8) & 0xFF))
    }

    private static func putU32(out: ArrayList<Byte>, v: Int64): Unit {
        out.add(UInt8(v & 0xFF))
        out.add(UInt8((v >> 8) & 0xFF))
        out.add(UInt8((v >> 16) & 0xFF))
        out.add(UInt8((v >> 24) & 0xFF))
    }

    private static func appendBytes(out: ArrayList<Byte>, b: Array<Byte>): Unit {
        for (x in b) {
            out.add(x)
        }
    }
}

/**
 * ZipCrypto 密钥流（PKWARE 传统加密）。
 *
 * 算法见 APPNOTE 6.1 的 "Traditional PKWARE Encryption"：
 * 三个 32 位密钥用 CRC32 与一个魔数乘法滚动，逐字节与明文异或。
 */
public class ZipCryptoKeys {
    private var k0: Int64
    private var k1: Int64
    private var k2: Int64

    public init(password: String) {
        this.k0 = 0x12345678
        this.k1 = 0x23456789
        this.k2 = 0x34567890
        for (b in password.toArray()) {
            this.update(Int64(b))
        }
    }

    /** 加密一个明文字节，返回密文字节（0..255）。 */
    public func encrypt(plain: Int64): Int64 {
        let c = plain ^ this.streamByte()
        this.update(plain)
        return c & 0xFF
    }

    /** 解密一个密文字节（与 encrypt 对称，另行构造实例使用）。 */
    public func decrypt(cipher: Int64): Int64 {
        let p = cipher ^ this.streamByte()
        this.update(p)
        return p & 0xFF
    }

    private func streamByte(): Int64 {
        let temp = (this.k2 | 2) & 0xFFFF
        return ((temp * (temp ^ 1)) >> 8) & 0xFF
    }

    private func update(b: Int64): Unit {
        this.k0 = ZipCryptoKeys.crcByte(this.k0, b)
        this.k1 = ((this.k1 + (this.k0 & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        this.k2 = ZipCryptoKeys.crcByte(this.k2, (this.k1 >> 24) & 0xFF)
    }

    /** CRC32 单字节滚动（与 ZipBuilder.crc32 同一多项式，但不取反）。 */
    private static func crcByte(crcIn: Int64, b: Int64): Int64 {
        var crc = (crcIn ^ b) & 0xFFFFFFFF
        var i = 0
        while (i < 8) {
            if ((crc & 1) == 1) {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc = crc >> 1
            }
            crc = crc & 0xFFFFFFFF
            i = i + 1
        }
        return crc
    }
}
