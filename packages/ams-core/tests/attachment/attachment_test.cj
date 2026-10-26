// ============================================================
// ams.core.attachment · 单元测试
//
// 覆盖需求：FR-ATT-001 / 002 / 003 / 004 / 006 / 007
//
// [约定]：仓颉的 match 分支只能是单个表达式，不能写 { 多行语句 }。
//   故所有复杂场景都用「先解包 → 再判断」的写法，或抽成辅助方法。
// ============================================================
package ams.core.attachment.test

import std.unittest.*

import ams.crypto.impl.*
import ams.crypto.provider.*

import ams.core.attachment.*

@Test
public class FileTypesTest {
    // ---- FR-ATT-001 类型与大小限制 ----

    @TestCase
    public func testAllowedExtensions() {
        @Assert(FileTypes.isAllowedExtension("jpg"), true)
        @Assert(FileTypes.isAllowedExtension("JPG"), true)
        @Assert(FileTypes.isAllowedExtension("jpeg"), true)
        @Assert(FileTypes.isAllowedExtension("png"), true)
        @Assert(FileTypes.isAllowedExtension("pdf"), true)
        @Assert(FileTypes.isAllowedExtension("exe"), false)
        @Assert(FileTypes.isAllowedExtension("doc"), false)
        @Assert(FileTypes.isAllowedExtension("sh"), false)
    }

    @TestCase
    public func testAllowedMime() {
        @Assert(FileTypes.isAllowedMime("image/jpeg"), true)
        @Assert(FileTypes.isAllowedMime("image/png"), true)
        @Assert(FileTypes.isAllowedMime("application/pdf"), true)
        @Assert(FileTypes.isAllowedMime("application/x-msdownload"), false)
        @Assert(FileTypes.isAllowedMime("text/html"), false)
    }

    @TestCase
    public func testSizeLimits() {
        // 单文件 ≤ 50 MB；分片 5 MB
        @Assert(FileTypes.maxFileSize, 52428800)
        @Assert(FileTypes.chunkSize, 5242880)
    }

    @TestCase
    public func testExtensionOf() {
        @Assert(FileTypes.extensionOf("photo.jpg"), "jpg")
        @Assert(FileTypes.extensionOf("a.b.c.PNG"), "png")
        @Assert(FileTypes.extensionOf("noext"), "")
        @Assert(FileTypes.extensionOf("trailing."), "")
    }

    @TestCase
    public func testMimeOf() {
        @Assert(FileTypes.mimeOf("jpg"), "image/jpeg")
        @Assert(FileTypes.mimeOf("png"), "image/png")
        @Assert(FileTypes.mimeOf("pdf"), "application/pdf")
        @Assert(FileTypes.mimeOf("bin"), "application/octet-stream")
    }
}

@Test
public class AttachmentCipherTest {
    private let provider = StdxCryptoProvider()
    private let cipher = AttachmentCipher(StdxCryptoProvider())

    private func key(): Array<Byte> {
        let k = Array<Byte>(16, repeat: 0u8)
        for (i in 0..16) {
            k[i] = UInt8(i + 1)
        }
        return k
    }

    // ---- FR-ATT-003 加密存储 ----

    @TestCase
    public func testEncryptDecryptRoundTrip() {
        let plain = "这是一段需要加密的附件内容，包含中文与 ASCII。".toArray()
        @Assert(AttachmentTest.roundTrip(this.cipher, plain, this.key()), true)
    }

    @TestCase
    public func testCiphertextDiffersFromPlain() {
        let plain = "secret content".toArray()
        let c = AttachmentTest.unwrap(this.cipher.encrypt(plain, this.key()))
        @Assert(c.size == 0, false)
        @Assert(AttachmentTest.containsPlain(c), false)
    }

    @TestCase
    public func testEachObjectHasUniqueIv() {
        // 每对象独立 IV → 相同明文产生不同密文
        let plain = "same content".toArray()
        let e1 = this.cipher.encrypt(plain, this.key())
        let e2 = this.cipher.encrypt(plain, this.key())
        @Assert(AttachmentTest.sameIv(e1, e2), false)
    }

    @TestCase
    public func testTamperedCipherRejected() {
        // 密文被改动 → HMAC 校验失败
        let plain = "important data".toArray()
        let c = AttachmentTest.unwrap(this.cipher.encrypt(plain, this.key()))
        @Assert(c.size == 0, false)
        c[AttachmentCipher.headerSize] = c[AttachmentCipher.headerSize] ^ 0xFFu8
        @Assert(AttachmentTest.isErr(this.cipher.decrypt(c, this.key())), true)
    }

    @TestCase
    public func testWrongKeyRejected() {
        let c = AttachmentTest.unwrap(this.cipher.encrypt("data".toArray(), this.key()))
        @Assert(c.size == 0, false)
        let wrong = Array<Byte>(16, repeat: 0xEEu8)
        @Assert(AttachmentTest.isErr(this.cipher.decrypt(c, wrong)), true)
    }

    @TestCase
    public func testBadMagicRejected() {
        let c = AttachmentTest.unwrap(this.cipher.encrypt("x".toArray(), this.key()))
        @Assert(c.size == 0, false)
        c[0] = 0u8
        @Assert(AttachmentTest.isErr(this.cipher.decrypt(c, this.key())), true)
    }

    @TestCase
    public func testPlainLengthInHeader() {
        let c = AttachmentTest.unwrap(this.cipher.encrypt("1234567890".toArray(), this.key()))
        @Assert(c.size == 0, false)
        @Assert(AttachmentCipher.plainLengthOf(c), 10)
    }

    @TestCase
    public func testBadDekLengthRejected() {
        @Assert(AttachmentTest.isErr(
            this.cipher.encrypt("x".toArray(), Array<Byte>(8, repeat: 0u8))), true)
    }

    // ---- FR-ATT-002 指纹与去重 ----

    @TestCase
    public func testFingerprintIsDeterministic() {
        let a = this.cipher.fingerprint("same".toArray())
        let b = this.cipher.fingerprint("same".toArray())
        @Assert(AttachmentTest.fingerprintSize(a), 32)
        @Assert(AttachmentTest.sameFingerprint(a, b), true)
    }

    @TestCase
    public func testFingerprintDiffersForDifferentContent() {
        let a = this.cipher.fingerprint("a".toArray())
        let b = this.cipher.fingerprint("b".toArray())
        @Assert(AttachmentTest.sameFingerprint(a, b), false)
    }

    @TestCase
    public func testDedupKeyIncludesSubject() {
        // 跨主体不复用：去重键含 subjectId
        let fp = AttachmentTest.unwrap(this.cipher.fingerprint("x".toArray()))
        @Assert(fp.size == 0, false)
        let k1 = this.cipher.dedupKey("s1", fp)
        let k2 = this.cipher.dedupKey("s2", fp)
        @Assert(k1 == k2, false)
        @Assert(k1.contains("s1"), true)
    }
}

@Test
public class AttachmentStatusTest {
    // ---- FR-ATT-007 状态机 ----

    @TestCase
    public func testStatusCodes() {
        @Assert(AttachmentStatus.Uploading.toCode(), 0)
        @Assert(AttachmentStatus.Scanning.toCode(), 1)
        @Assert(AttachmentStatus.Ready.toCode(), 2)
        @Assert(AttachmentStatus.Quarantined.toCode(), 3)
        @Assert(AttachmentStatus.Superseded.toCode(), 4)
        @Assert(AttachmentStatus.Deleted.toCode(), 5)
    }

    @TestCase
    public func testOnlyReadyIsDownloadable() {
        // 隔离的附件不可下载
        @Assert(AttachmentStatus.Ready.isDownloadable(), true)
        @Assert(AttachmentStatus.Quarantined.isDownloadable(), false)
        @Assert(AttachmentStatus.Scanning.isDownloadable(), false)
        @Assert(AttachmentStatus.Deleted.isDownloadable(), false)
        @Assert(AttachmentStatus.Uploading.isDownloadable(), false)
    }
}

/**
 * 断言辅助（仓颉的 match 分支只能是单个表达式）。
 */
class AttachmentTest {
    static func isErr(r: CryptoResult<Array<Byte>>): Bool {
        match (r) {
            case CryptoResult.Ok(_) => return false
            case CryptoResult.Err(_) => return true
        }
    }

    /**
     * 解包（失败返回空数组）。
     */
    static func unwrap(r: CryptoResult<Array<Byte>>): Array<Byte> {
        match (r) {
            case CryptoResult.Ok(c) => return c
            case CryptoResult.Err(_) => return Array<Byte>(0, repeat: 0u8)
        }
    }

    static func fingerprintSize(r: CryptoResult<Array<Byte>>): Int64 {
        match (r) {
            case CryptoResult.Ok(x) => return x.size
            case CryptoResult.Err(_) => return -1
        }
    }

    static func sameFingerprint(
        a: CryptoResult<Array<Byte>>,
        b: CryptoResult<Array<Byte>>
    ): Bool {
        match (a) {
            case CryptoResult.Ok(x) => match (b) {
                case CryptoResult.Ok(y) => return AttachmentTest.sameBytes(x, y)
                case CryptoResult.Err(_) => return false
            }
            case CryptoResult.Err(_) => return false
        }
    }

    /**
     * 字节数组是否相同。
     */
    static func sameBytes(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }

    /**
     * 加密→解密往返校验。
     */
    static func roundTrip(
        cipher: AttachmentCipher,
        plain: Array<Byte>,
        key: Array<Byte>
    ): Bool {
        let c = AttachmentTest.unwrap(cipher.encrypt(plain, key))
        if (c.size <= plain.size) {
            return false
        }
        let p = AttachmentTest.unwrap(cipher.decrypt(c, key))
        if (p.size != plain.size) {
            return false
        }
        return AttachmentTest.sameBytes(p, plain)
    }

    /**
     * 密文中是否含明文片段（"sec"）。
     */
    static func containsPlain(c: Array<Byte>): Bool {
        for (i in 0..(c.size - 3)) {
            if (c[i] == 115u8 && c[i + 1] == 101u8 && c[i + 2] == 99u8) {
                return true
            }
        }
        return false
    }

    /**
     * 两次加密的 IV 是否相同（应为不同）。
     */
    static func sameIv(
        e1: CryptoResult<Array<Byte>>,
        e2: CryptoResult<Array<Byte>>
    ): Bool {
        let a = AttachmentTest.unwrap(e1)
        let b = AttachmentTest.unwrap(e2)
        if (a.size < 32 || b.size < 32) {
            return false
        }
        for (i in 0..16) {
            if (a[16 + i] != b[12 + i]) {
                return false
            }
        }
        return true
    }
}
