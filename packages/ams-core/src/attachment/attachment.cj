// ============================================================
// ams.core.attachment · 附件领域模型与加密存储
//
// 需求：
//   FR-ATT-001 附件上传（单文件 ≤ 50 MB；类型限 jpg/png/pdf；分片上传 5 MB/片）
//   FR-ATT-002 SM3 指纹与去重（同主体内相同指纹复用物理文件；跨主体默认不复用）
//   FR-ATT-003 附件加密存储（每对象独立 IV；密文头含 算法/IV/版本/原始长度）
//   FR-ATT-004 版本管理（默认最新版本为当前版本）
//   FR-ATT-005 预览与下载（下载权限与预览权限分离）
//   FR-ATT-006 附件元数据（文件名/扩展名/MIME/大小/指纹/宽高/页数/状态）
//   FR-ATT-007 病毒/内容扫描（uploading → scanning → ready / quarantined）
//
// [加密格式]（因 stdx 的 SM4-GCM 不可用，改 SM4-CBC + HMAC-SM3）
//   密文布局：
//     magic(4) | alg(1) | ver(1) | reserved(2) | origLen(8) | iv(16)
//     | ciphertext(n) | hmac(32)
//   HMAC-SM3 覆盖 magic..ciphertext（Encrypt-then-MAC）。
//   每个对象独立 IV（随机 16 字节），故相同明文产生不同密文。
//
// [状态机]（PRD §6.2.3）
//   uploading → scanning → ready → deleted
//                    → quarantined（管理员可放行 → ready 或 → deleted）
//   superseded：非当前版本（可回滚为当前版本）
// ============================================================
package ams.core.attachment

import stdx.encoding.hex.*

import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 附件状态。
 */
public enum AttachmentStatus {
    | Uploading    // 0 上传中
    | Scanning     // 1 扫描中
    | Ready        // 2 可用
    | Quarantined  // 3 隔离
    | Superseded   // 4 非当前版本
    | Deleted      // 5 已删除

    public func toCode(): Int64 {
        match (this) {
            case AttachmentStatus.Uploading => return 0
            case AttachmentStatus.Scanning => return 1
            case AttachmentStatus.Ready => return 2
            case AttachmentStatus.Quarantined => return 3
            case AttachmentStatus.Superseded => return 4
            case AttachmentStatus.Deleted => return 5
        }
    }

    public static func fromCode(code: Int64): AttachmentStatus {
        if (code == 1) { return AttachmentStatus.Scanning }
        if (code == 3) { return AttachmentStatus.Quarantined }
        if (code == 4) { return AttachmentStatus.Superseded }
        if (code == 5) { return AttachmentStatus.Deleted }
        return AttachmentStatus.Ready
    }

    /**
     * 是否可下载（隔离与删除状态不可下载）。
     */
    public func isDownloadable(): Bool {
        match (this) {
            case AttachmentStatus.Ready => return true
            case _ => return false
        }
    }
}

/**
 * 文件类型限制（FR-ATT-001：类型限 jpg/png/pdf）。
 */
public class FileTypes {
    /** 单文件大小上限（50 MB） */
    public static let maxFileSize: Int64 = 50 * 1024 * 1024
    /** 分片大小（5 MB） */
    public static let chunkSize: Int64 = 5 * 1024 * 1024

    /**
     * 允许的扩展名。
     */
    public static let allowedExtensions: Array<String> = ["jpg", "jpeg", "png", "pdf"]

    /**
     * 允许的 MIME 类型。
     */
    public static let allowedMimeTypes: Array<String> = [
        "image/jpeg", "image/png", "application/pdf"
    ]

    /**
     * 扩展名是否允许。
     */
    public static func isAllowedExtension(ext: String): Bool {
        let lower = ext.toAsciiLower()
        for (a in FileTypes.allowedExtensions) {
            if (a == lower) {
                return true
            }
        }
        return false
    }

    /**
     * MIME 是否允许。
     */
    public static func isAllowedMime(mime: String): Bool {
        for (a in FileTypes.allowedMimeTypes) {
            if (a == mime) {
                return true
            }
        }
        return false
    }

    /**
     * 从文件名提取扩展名（小写，不含点）。
     */
    public static func extensionOf(fileName: String): String {
        var dot = -1
        for (i in 0..fileName.size) {
            if (fileName[i] == 46u8) {   // '.'
                dot = i
            }
        }
        if (dot < 0 || dot >= fileName.size - 1) {
            return ""
        }
        return fileName[(dot + 1)..fileName.size].toAsciiLower()
    }

    /**
     * 根据扩展名推断 MIME。
     */
    public static func mimeOf(ext: String): String {
        match (ext.toAsciiLower()) {
            case "jpg" => return "image/jpeg"
            case "jpeg" => return "image/jpeg"
            case "png" => return "image/png"
            case "pdf" => return "application/pdf"
            case _ => return "application/octet-stream"
        }
    }
}

/**
 * 附件逻辑对象（对应 arc_attachments 表）。
 */
public class Attachment {
    public let id: String
    public let subjectId: String
    /** 所属条目（空 = 主体级独立附件） */
    public let itemId: String
    public let category: Int64
    public var title: String
    /** 当前版本 ID */
    public var currentVersionId: String
    public var versionCount: Int64
    /** 存储对象键（明文路径不含敏感文件名） */
    public var storageKey: String
    /** 使用的 DEK 版本 */
    public var keyVersion: Int64
    public var fileSize: Int64
    public var fileExt: String
    public var mimeType: String
    public var width: Int64
    public var height: Int64
    public var pageCount: Int64
    /** SM3 指纹（明文内容的摘要） */
    public var sm3Fingerprint: Array<Byte>
    /** 去重键 = subjectId + sm3 */
    public var dedupKey: String
    public var status: AttachmentStatus
    public var downloadCount: Int64
    public var watermarkEnabled: Bool

    public init(
        id: String,
        subjectId: String,
        itemId: String,
        category: Int64,
        title: String,
        currentVersionId: String,
        versionCount: Int64,
        storageKey: String,
        keyVersion: Int64,
        fileSize: Int64,
        fileExt: String,
        mimeType: String,
        width: Int64,
        height: Int64,
        pageCount: Int64,
        sm3Fingerprint: Array<Byte>,
        dedupKey: String,
        status: AttachmentStatus,
        downloadCount: Int64,
        watermarkEnabled: Bool
    ) {
        this.id = id
        this.subjectId = subjectId
        this.itemId = itemId
        this.category = category
        this.title = title
        this.currentVersionId = currentVersionId
        this.versionCount = versionCount
        this.storageKey = storageKey
        this.keyVersion = keyVersion
        this.fileSize = fileSize
        this.fileExt = fileExt
        this.mimeType = mimeType
        this.width = width
        this.height = height
        this.pageCount = pageCount
        this.sm3Fingerprint = sm3Fingerprint
        this.dedupKey = dedupKey
        this.status = status
        this.downloadCount = downloadCount
        this.watermarkEnabled = watermarkEnabled
    }
}

/**
 * 附件版本（对应 arc_attachment_versions 表）。
 */
public class AttachmentVersion {
    public let id: String
    public let attachmentId: String
    public let versionNo: Int64
    public let storageKey: String
    public let fileSize: Int64
    public let fileExt: String
    public let mimeType: String
    /** 该版本的 SM3 指纹 */
    public let sm3Fingerprint: Array<Byte>
    /** 是否当前版本 */
    public var isCurrent: Bool
    public var status: AttachmentStatus
    public let changeNote: String
    public let uploadedBy: String
    public let uploadedAt: Int64

    public init(
        id: String,
        attachmentId: String,
        versionNo: Int64,
        storageKey: String,
        fileSize: Int64,
        fileExt: String,
        mimeType: String,
        sm3Fingerprint: Array<Byte>,
        isCurrent: Bool,
        status: AttachmentStatus,
        changeNote: String,
        uploadedBy: String,
        uploadedAt: Int64
    ) {
        this.id = id
        this.attachmentId = attachmentId
        this.versionNo = versionNo
        this.storageKey = storageKey
        this.fileSize = fileSize
        this.fileExt = fileExt
        this.mimeType = mimeType
        this.sm3Fingerprint = sm3Fingerprint
        this.isCurrent = isCurrent
        this.status = status
        this.changeNote = changeNote
        this.uploadedBy = uploadedBy
        this.uploadedAt = uploadedAt
    }
}

/**
 * 附件加密存储。
 *
 * 因 stdx 的 SM4-GCM 在 1.0.5.1 / 1.2.0.1 上均不可用（实测 "create tag error"），
 * 改用 SM4-CBC + HMAC-SM3（Encrypt-then-MAC）。
 */
public class AttachmentCipher {
    /** 魔数 "AMSC" */
    public static let magic: Int64 = 0x414D5343
    /** 算法标识：1 = SM4-CBC + HMAC-SM3 */
    public static let algSm4CbcHmac: Int64 = 1
    /** 格式版本 */
    public static let formatVersion: Int64 = 1
    /**
     * 头部长度：magic(4) + alg(1) + ver(1) + reserved(2) + origLen(8) + iv(16) = 32
     * 布局：magic[0..4) alg[4] ver[5] reserved[6..8) origLen[8..16) iv[16..32)
     */
    public static let headerSize: Int64 = 32
    /** 尾部 HMAC 长度 */
    public static let macSize: Int64 = 32

    private let provider: CryptoProvider

    public init(provider: CryptoProvider) {
        this.provider = provider
    }

    /**
     * 计算明文的 SM3 指纹（FR-ATT-002）。
     *
     * 注意：生产环境应**流式**计算（不整文件读入内存），
     * 此处对已加载到内存的内容计算。
     */
    public func fingerprint(plain: Array<Byte>): CryptoResult<Array<Byte>> {
        return this.provider.digest(plain, DigestAlgorithm.Sm3)
    }

    /**
     * 去重键 = subjectId + ":" + sm3 十六进制。
     *
     * 同主体内相同指纹复用物理文件；跨主体默认不复用
     * （因去重键含 subjectId，跨主体自然不复用）。
     */
    public func dedupKey(subjectId: String, fingerprint: Array<Byte>): String {
        return "${subjectId}:${toHexString(fingerprint)}"
    }

    /**
     * 加密内容。
     *
     * @param plain 明文
     * @param dek 数据密钥（16 字节）
     * @return 密文（含头部与 HMAC）
     */
    public func encrypt(plain: Array<Byte>, dek: Array<Byte>): CryptoResult<Array<Byte>> {
        if (dek.size != 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "DEK 长度必须为 16 字节"))
        }
        // 每对象独立 IV（随机 16 字节）
        let iv = match (this.provider.randomBytes(16)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let ct = match (this.provider.encrypt(dek, iv, plain, CipherMode.Cbc)) {
            case CryptoResult.Ok(c) => c
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        // 组装头部
        var out = Array<Byte>(AttachmentCipher.headerSize + ct.size, repeat: 0u8)
        AttachmentCipher.writeInt32(out, 0, AttachmentCipher.magic)
        AttachmentCipher.writeByte(out, 4, AttachmentCipher.algSm4CbcHmac)
        AttachmentCipher.writeByte(out, 5, AttachmentCipher.formatVersion)
        AttachmentCipher.writeByte(out, 6, 0)
        AttachmentCipher.writeByte(out, 7, 0)
        AttachmentCipher.writeInt64(out, 8, plain.size)
        // 布局：magic(4) alg(1) ver(1) reserved(2) | origLen(8) | iv(16) | ciphertext | hmac
        //         0         4     5     6-7          8-15      16-31
        for (i in 0..16) {
            out[16 + i] = iv[i]
        }
        for (i in 0..ct.size) {
            out[AttachmentCipher.headerSize + i] = ct[i]
        }
        // HMAC 覆盖 magic..ciphertext
        let macInput = Array<Byte>(AttachmentCipher.headerSize + ct.size, repeat: 0u8)
        for (i in 0..macInput.size) {
            macInput[i] = out[i]
        }
        let mac = match (this.provider.hmac(dek, macInput, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(m) => m
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        var full = Array<Byte>(out.size + mac.size, repeat: 0u8)
        for (i in 0..out.size) {
            full[i] = out[i]
        }
        for (i in 0..mac.size) {
            full[out.size + i] = mac[i]
        }
        return CryptoResult.Ok(full)
    }

    /**
     * 解密内容（先验 HMAC 再解密，Encrypt-then-MAC）。
     */
    public func decrypt(cipher: Array<Byte>, dek: Array<Byte>): CryptoResult<Array<Byte>> {
        if (dek.size != 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "DEK 长度必须为 16 字节"))
        }
        if (cipher.size < AttachmentCipher.headerSize + AttachmentCipher.macSize) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "密文长度不足"))
        }
        // 校验魔数与版本
        if (AttachmentCipher.readInt32(cipher, 0) != AttachmentCipher.magic) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "密文魔数不正确"))
        }
        if (AttachmentCipher.readByte(cipher, 5) != AttachmentCipher.formatVersion) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "密文版本不支持"))
        }
        let origLen = AttachmentCipher.readInt64(cipher, 8)
        let iv = Array<Byte>(16, repeat: 0u8)
        for (i in 0..16) {
            iv[i] = cipher[16 + i]
        }
        let ctLen = cipher.size - AttachmentCipher.headerSize - AttachmentCipher.macSize
        let ct = Array<Byte>(ctLen, repeat: 0u8)
        for (i in 0..ctLen) {
            ct[i] = cipher[AttachmentCipher.headerSize + i]
        }
        // 验 HMAC
        let macInput = Array<Byte>(AttachmentCipher.headerSize + ctLen, repeat: 0u8)
        for (i in 0..macInput.size) {
            macInput[i] = cipher[i]
        }
        let expect = match (this.provider.hmac(dek, macInput, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(m) => m
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let actual = Array<Byte>(AttachmentCipher.macSize, repeat: 0u8)
        for (i in 0..AttachmentCipher.macSize) {
            actual[i] = cipher[AttachmentCipher.headerSize + ctLen + i]
        }
        if (!this.provider.constantTimeEquals(expect, actual)) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "密文完整性校验失败"))
        }
        // 解密
        let plain = match (this.provider.decrypt(dek, iv, ct, CipherMode.Cbc)) {
            case CryptoResult.Ok(p) => p
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        if (plain.size != origLen) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "明文长度与头部记录不符"))
        }
        return CryptoResult.Ok(plain)
    }

    /**
     * 从密文读出原始长度（用于流式场景预分配）。
     */
    public static func plainLengthOf(cipher: Array<Byte>): Int64 {
        if (cipher.size < AttachmentCipher.headerSize) {
            return -1
        }
        return AttachmentCipher.readInt64(cipher, 8)
    }

    // ---- 字节读写工具（大端）----

    private static func writeInt32(buf: Array<Byte>, offset: Int64, v: Int64): Unit {
        buf[offset] = UInt8((v >> 24) & 0xFF)
        buf[offset + 1] = UInt8((v >> 16) & 0xFF)
        buf[offset + 2] = UInt8((v >> 8) & 0xFF)
        buf[offset + 3] = UInt8(v & 0xFF)
    }

    private static func readInt32(buf: Array<Byte>, offset: Int64): Int64 {
        return (Int64(buf[offset]) << 24) | (Int64(buf[offset + 1]) << 16) |
               (Int64(buf[offset + 2]) << 8) | Int64(buf[offset + 3])
    }

    private static func writeInt64(buf: Array<Byte>, offset: Int64, v: Int64): Unit {
        buf[offset] = UInt8((v >> 56) & 0xFF)
        buf[offset + 1] = UInt8((v >> 48) & 0xFF)
        buf[offset + 2] = UInt8((v >> 40) & 0xFF)
        buf[offset + 3] = UInt8((v >> 32) & 0xFF)
        buf[offset + 4] = UInt8((v >> 24) & 0xFF)
        buf[offset + 5] = UInt8((v >> 16) & 0xFF)
        buf[offset + 6] = UInt8((v >> 8) & 0xFF)
        buf[offset + 7] = UInt8(v & 0xFF)
    }

    private static func readInt64(buf: Array<Byte>, offset: Int64): Int64 {
        var v: Int64 = 0
        for (i in 0..8) {
            v = (v << 8) | Int64(buf[offset + i])
        }
        return v
    }

    private static func writeByte(buf: Array<Byte>, offset: Int64, v: Int64): Unit {
        buf[offset] = UInt8(v & 0xFF)
    }

    private static func readByte(buf: Array<Byte>, offset: Int64): Int64 {
        return Int64(buf[offset])
    }
}
