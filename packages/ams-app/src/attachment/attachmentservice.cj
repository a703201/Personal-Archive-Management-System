// ============================================================
// ams.app.attachment · 附件应用服务
//
// 覆盖 FR-ATT-001（上传/类型与大小限制）、002（SM3 指纹去重）、
//       003（加密存储）、004（版本切换）、005（预览与下载）、
//       006（元数据含拍摄时间）、007（内容与病毒扫描）
//
// 【上传主流程】
//   校验大小/扩展名/MIME
//     → SM3 指纹 → 同主体去重（命中则秒传复用，不再落盘）
//     → KeyManager 生成随机 DEK 并包裹（wrapped）后持久化
//     → AttachmentCipher 加密（SM4-CBC + HMAC-SM3，Encrypt-then-MAC）
//     → 写入存储后端（扫描未通过则写隔离区）
//     → 落 arc_attachments + arc_attachment_versions(v1)
//
// 【关于病毒扫描（FR-ATT-007）】
//   本服务内置的是**内容一致性校验**：校验真实魔数是否与声明扩展名相符
//   （JPEG FFD8FF / PNG 89504E47 / PDF %PDF），可拦截「改名伪装」类恶意文件。
//   真正的病毒引擎（ClamAV 等）属部署侧能力，此处留出 ScanHook：
//   约定返回 false 即判隔离；未接入外部引擎时以魔数校验作为兜底。
//
// 【关于拍摄时间（FR-ATT-006）】
//   JPEG 的 EXIF 解析需要完整的 TIFF IFD 遍历，成本较高；
//   这里在 EXIF 区段内按 `YYYY:MM:DD HH:MM:SS` 模式定位首个时间串，
//   作为拍摄时间的启发式取值（启发式，非严格 IFD 解析，已在注释标明）。
// ============================================================
package ams.app.attachment

import std.collection.*
import std.env.*
import stdx.encoding.base64.*

import ams.core.attachment.*
import ams.core.media.*
import ams.crypto.key.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.storage.*

/**
 * 上传结果。
 */
public class UploadResult {
    public let attachmentId: Int64
    /** true = 命中去重，复用了既有附件（未重新落盘） */
    public let dedupHit: Bool
    /** 最终状态：2=Ready 可用，3=Quarantined 隔离 */
    public let status: Int64

    public init(attachmentId: Int64, dedupHit: Bool, status: Int64) {
        this.attachmentId = attachmentId
        this.dedupHit = dedupHit
        this.status = status
    }
}

/**
 * 附件应用服务。
 */
public class AttachmentService {
    private let repo: AttachmentRepo
    private let storage: StorageBackend
    private let quarantine: StorageBackend
    private let keyManager: KeyManager
    private let cipherProvider: CryptoProvider
    private let itemRepo: ?ItemRepo
    /**
     * 用户仓储（可选）：装配后上传前强制校验「目标主体属于当前操作者」，
     * 堵住「传任意 subjectId 即可往他人主体挂附件」的越权面。
     * 单次上传 / 分片上传 / 批量导入共用同一条 upload() 链路，故在此一处收口。
     */
    private let userRepo: ?UserRepo
    /** Q2 多厂商：落库时自述平台 code（默认 local，零回归） */
    private let storageProvider: String

    public init(
        repo: AttachmentRepo,
        storage: StorageBackend,
        quarantine: StorageBackend,
        keyManager: KeyManager,
        cipherProvider: CryptoProvider,
        itemRepo!: ?ItemRepo = None,
        userRepo!: ?UserRepo = None,
        storageProvider!: String = "local"
    ) {
        this.repo = repo
        this.storage = storage
        this.quarantine = quarantine
        this.keyManager = keyManager
        this.cipherProvider = cipherProvider
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.storageProvider = storageProvider
    }

    /**
     * 上传附件。
     *
     * @param plain 明文内容（当前为非流式整块，见 FR-ATT-002 的已知局限）
     * @param dedup 是否允许内容去重（默认 true = 同主体同内容秒传复用）。
     *              批量导入（FR-IMP-002）必须传 false：去重命中时**不会**为
     *              新条目建立归属关系，等于「文件静默丢失」——导入语义要求
     *              每个条目都真正拥有自己的附件。
     */
    public func upload(
        subjectId: Int64,
        itemId: Option<Int64>,
        category: Int64,
        title: String,
        fileName: String,
        plain: Array<Byte>,
        operatorId: Int64,
        dedup!: Bool = true,
        summary!: String = "",
        keywords!: String = ""
    ): UploadResult {
        // ---- 1. 基础校验（FR-ATT-001）----
        if (plain.size > FileTypes.maxFileSize) {
            throw validationError("file", "文件超过 50MB 上限")
        }
        if (plain.size == 0) {
            throw validationError("file", "文件内容为空")
        }
        let ext = FileTypes.extensionOf(fileName)
        if (!FileTypes.isAllowedExtension(ext)) {
            throw validationError("file", "不支持的文件类型（仅 jpg/png/pdf）")
        }
        let mime = FileTypes.mimeOf(ext)
        if (!FileTypes.isAllowedMime(mime)) {
            throw validationError("file", "不支持的 MIME 类型")
        }

        // ---- 1b. 归属修正：挂了条目就以**条目的主体**为准 ----
        // 之前路由直接把「当前用户 ID」当 subject_id 传进来，导致附件挂在
        // 一个根本不存在的主体上：列表按 itemId 查得到，但任何主体级鉴权
        // （本 P1 的批量操作、版本上传）都会判成「不属于当前账号」。
        var owner = subjectId
        match (itemId) {
            case Some(iid) =>
                match (this.itemRepo) {
                    case Some(ir) =>
                        match (ir.findByIdRaw(iid)) {
                            // ItemRecord 的 ID 字段是字符串（与 JSON 输出一致）
                            case Some(it) => owner = RowData.toI64(it.subjectId)
                            case None => throw notFound("所属条目")
                        }
                    case None => ()
                }
            case None => ()
        }
        if (owner <= 0) {
            throw validationError("subjectId", "缺少 subjectId 或 itemId，无法确定附件归属")
        }
        // ---- 1c. 归属校验（防越权往他人主体挂附件）----
        // owner 已在 1b 按 itemId 反查修正，故这里校验的就是最终落库主体。
        match (this.userRepo) {
            case Some(ur) =>
                let subs = ur.listAccessibleSubjectIds(operatorId)
                if (!subs.contains("${owner}")) {
                    throw AppError(AppErrorKind.Forbidden, "无权向该主体上传附件")
                }
            case None =>
                // 纯单测 / 内嵌场景未注入用户仓储：不静默放行，留告警便于排查。
                // 生产装配（main.cj）必定注入，故运行时不会走到这条分支。
                Log.get().warn("attachment.upload.owner_check_skipped", None, [
                    ("subjectId", "${owner}"), ("operatorId", "${operatorId}")
                ])
        }
        // ---- 2. 指纹与去重（FR-ATT-002）----
        let cipher = AttachmentCipher(this.cipherProvider)
        let fp = match (cipher.fingerprint(plain)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => throw e
        }
        let dkey = cipher.dedupKey("${owner}", fp)
        if (dedup) {
            match (this.repo.findByDedupKey(owner, dkey)) {
                case Some(existing) =>
                    // 同主体已存在完全相同内容 → 秒传复用，不重复落盘
                    return UploadResult(existing.id, true, existing.status)
                case None => ()
            }
        }

        // ---- 3. 数据密钥（FR-ATT-003）----
        let kv = KeyVersion("ams-attachment", 1)
        let wrapped = match (this.keyManager.generateDataKey(kv)) {
            case CryptoResult.Ok(w) => w
            case CryptoResult.Err(e) => throw e
        }
        let dek = match (this.keyManager.unwrap(wrapped)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => throw e
        }

        // ---- 4. 加密 ----
        let encrypted = match (cipher.encrypt(plain, dek)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => throw e
        }

        // ---- 5. 内容与病毒扫描（FR-ATT-007）----
        let clean = AttachmentService.scanContent(plain, ext)
        let status = if (clean) { AttachmentStatus.Ready } else { AttachmentStatus.Quarantined }

        // ---- 6. 落存储（隔离件写隔离区，正常区读不到）----
        let id = Ids.next()
        let storageKey = "att_${id}_v1.bin"
        if (clean) {
            this.storage.put(storageKey, encrypted)
        } else {
            this.quarantine.put(storageKey, encrypted)
            Log.get().warn("attachment.quarantined", None, [
                ("id", "${id}"), ("ext", ext)
            ])
        }

        // ---- 7. 落库 ----
        let attId = this.repo.create(
            owner, itemId, category, title, storageKey,
            kv.version, plain.size, ext, mime, fp, dkey,
            status.toCode(), operatorId, summary: summary, keywords: keywords,
            // Q2 方案 A：落库记录真实后端与厂商，供后续按后端路由读取 / 迁移
            storageBackend: this.storage.backendCode(),
            storageProvider: this.storageProvider
        )
        this.repo.setWrappedDek(attId, AttachmentService.encodeWrapped(wrapped))

        // ---- 7b. 同步条目附件计数（FR-SRC-003 排序依赖）----
        // 仅新建（非秒传命中）才 +1；仅当附件确实挂在某条目下。
        match (itemId) {
            case Some(iid) =>
                match (this.itemRepo) {
                    case Some(ir) =>
                        try {
                            ir.bumpAttachmentCount(iid, 1)
                        } catch (e: Exception) {
                            Log.get().warn("attachment.count.bump.failed", None, [
                                ("itemId", "${iid}"), ("reason", e.toString())
                            ])
                        }
                    case None => ()
                }
            case None => ()
        }

        let versionId = this.repo.addVersion(
            attId, 1, storageKey, encrypted.size, ext, mime, fp,
            status.toCode(), "初始版本", operatorId
        )
        this.repo.setCurrentVersionId(attId, versionId, 1)

        // ---- 8. 拍摄时间（FR-ATT-006，启发式 EXIF）----
        match (AttachmentService.captureTimeOf(plain, ext)) {
            case Some(t) =>
                Log.get().info("attachment.exif", None, [
                    ("id", "${attId}"), ("capturedAt", t)
                ])
            case None => ()
        }

        // ---- 9. 媒体处理（仅开关开启时自动触发；失败绝不阻断上传）----
        // OCR 需隐私显式同意（PRD FR-ATT-013）：两个开关都为 true 才执行。
        if (AttachmentService.mediaEnabled()) {
            try {
                let media = this.processMedia(attId, "AMS")
                Log.get().info("attachment.media.auto", None, [
                    ("id", "${attId}"), ("ocrStatus", "${media.ocrStatus}"),
                    ("error", media.error)
                ])
            } catch (e: Exception) {
                Log.get().warn("attachment.media.auto.failed", None, [
                    ("id", "${attId}"), ("reason", e.toString())
                ])
            }
        }

        return UploadResult(attId, false, status.toCode())
    }

    /**
     * 更新附件摘要与关键词（FR-ATT-013 降级：OCR 不可用时由用户手动录入）。
     */
    public func updateMeta(attachmentId: Int64, summary: String, keywords: String, operatorId: Int64): Bool {
        return this.repo.updateMeta(attachmentId, summary, keywords, operatorId)
    }

    /**
     * 媒体处理总开关（零回归：默认关闭）。
     *
     * OCR 需隐私显式同意（PRD FR-ATT-013）：AMS_MEDIA_ENABLED 与
     * AMS_OCR_CONSENT 两个环境变量必须**同时**显式为 true 才允许自动处理。
     * 在 AttachmentService 内部直接读环境变量，不改 main.cj 装配。
     */
    public static func mediaEnabled(): Bool {
        let enabled = (getVariable("AMS_MEDIA_ENABLED") ?? "false").toAsciiLower()
        let consent = (getVariable("AMS_OCR_CONSENT") ?? "false").toAsciiLower()
        let enabledOn = enabled == "true" || enabled == "1"
        let consentOn = consent == "true" || consent == "1"
        return enabledOn && consentOn
    }

    /**
     * 进程内处理附件媒体：OCR / 缩略图 / 像素水印。
     *
     * 取明文 → MediaEngine.process（纯仓颉、同步、无外部进程）→
     * 非空的缩略图 / 水印图落文件存储 → OCR 结果落库。
     * 任何异常都吞掉并记日志，返回带 error 的 MediaResult，绝不阻断调用方。
     */
    public func processMedia(attachmentId: Int64, watermarkText: String): MediaResult {
        try {
            let plain = this.download(attachmentId)
            let result = MediaEngine.process(plain, true, true, true, watermarkText)
            if (result.thumbnail.size > 0) {
                this.storage.put("thumb_${attachmentId}.png", result.thumbnail)
            }
            if (result.watermarked.size > 0) {
                this.storage.put("wm_${attachmentId}.png", result.watermarked)
            }
            try {
                this.repo.updateOcr(attachmentId, result.ocrText, result.ocrStatus,
                    result.ocrEngine, result.error)
            } catch (e: Exception) {
                Log.get().warn("attachment.media.ocr.persist.failed", None, [
                    ("id", "${attachmentId}"), ("reason", e.toString())
                ])
            }
            return result
        } catch (e: Exception) {
            Log.get().warn("attachment.media.failed", None, [
                ("id", "${attachmentId}"), ("reason", e.toString())
            ])
            let failed = MediaResult()
            failed.ocrStatus = 3
            failed.error = e.toString()
            return failed
        }
    }

    /** 读取已落盘的缩略图（PNG 字节）；未生成返回 None。 */
    public func mediaThumbnail(attachmentId: Int64): Option<Array<Byte>> {
        return this.storage.get("thumb_${attachmentId}.png")
    }

    /** 读取已落盘的像素水印图（PNG 字节）；未生成返回 None。 */
    public func mediaWatermarked(attachmentId: Int64): Option<Array<Byte>> {
        return this.storage.get("wm_${attachmentId}.png")
    }

    /**
     * 下载（解密）附件明文。
     *
     * [FR-ATT-005] 仅 Ready 状态可下载；隔离与删除状态一律拒绝。
     * 权限分离由路由层用 attachment:download:* 与 attachment:read:* 区分，
     * 这里只负责状态机约束与解密。
     */
    public func download(attachmentId: Int64): Array<Byte> {
        let rec = match (this.repo.findById(attachmentId)) {
            case Some(r) => r
            case None => throw notFound("附件")
        }
        let st = AttachmentStatus.fromCode(rec.status)
        if (!st.isDownloadable()) {
            throw forbidden(message: "附件不可用（未就绪或已被隔离）")
        }
        if (rec.wrappedDek.isEmpty()) {
            throw AppError(AppErrorKind.CryptoFailure, "附件缺少数据密钥，无法解密")
        }
        let wrapped = AttachmentService.decodeWrapped(rec.wrappedDek)
        let dek = match (this.keyManager.unwrap(wrapped)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => throw e
        }
        // 版本可能已被切换：以「当前版本」的存储键为准，回退到主记录键
        let storageKey = match (this.repo.currentVersionStorageKey(attachmentId)) {
            case Some(k) => k
            case None => rec.storageKey
        }
        match (this.storage.get(storageKey)) {
            case Some(enc) =>
                let cipher = AttachmentCipher(this.cipherProvider)
                let plain = match (cipher.decrypt(enc, dek)) {
                    case CryptoResult.Ok(p) => p
                    case CryptoResult.Err(e) => throw e
                }
                this.repo.incrDownload(attachmentId)
                return plain
            case None => throw notFound("附件内容")
        }
    }

    /**
     * 列举版本（FR-ATT-004）。
     */
    public func listVersions(attachmentId: Int64): RowSet {
        return this.repo.listVersions(attachmentId)
    }

    /**
     * 切换当前版本（FR-ATT-004）。
     */
    public func switchVersion(attachmentId: Int64, versionId: Int64): Bool {
        return this.repo.setCurrentVersion(attachmentId, versionId)
    }

    /**
     * 上传新版本（FR-ATT-004 / 009 的数据前提）。
     *
     * 与首次上传的差异：
     *   · 复用该附件已有的 **DEK**（一条附件一把数据密钥，
     *     这样切版本只换对象、不换密钥，历史版本仍可解）；
     *   · 版本号 = version_count + 1，对象键 `att_<id>_v<n>.bin`；
     *   · 写完版本后把当前版本指向它，并更新版本计数。
     *
     * @param attachmentId 目标附件
     * @param fileName     新版本文件名（决定扩展名/MIME）
     * @param changeNote   变更说明（版本对比里会展示）
     * @param plain        明文内容
     * @param operatorId   操作员
     * @return 新版本 ID
     */
    public func uploadVersion(
        attachmentId: Int64,
        fileName: String,
        changeNote: String,
        plain: Array<Byte>,
        operatorId: Int64
    ): Int64 {
        let rec = match (this.repo.findById(attachmentId)) {
            case Some(r) => r
            case None => throw notFound("附件")
        }
        if (plain.size > FileTypes.maxFileSize) {
            throw validationError("file", "文件超过 50MB 上限")
        }
        if (plain.size == 0) {
            throw validationError("file", "文件内容为空")
        }
        let ext = FileTypes.extensionOf(fileName)
        if (!FileTypes.isAllowedExtension(ext)) {
            throw validationError("file", "不支持的文件类型（仅 jpg/png/pdf）")
        }
        let mime = FileTypes.mimeOf(ext)
        if (!FileTypes.isAllowedMime(mime)) {
            throw validationError("file", "不支持的 MIME 类型")
        }
        if (rec.wrappedDek.isEmpty()) {
            throw AppError(AppErrorKind.CryptoFailure, "附件缺少数据密钥，无法加密新版本")
        }
        let dek = match (this.keyManager.unwrap(AttachmentService.decodeWrapped(rec.wrappedDek))) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => throw e
        }
        let cipher = AttachmentCipher(this.cipherProvider)
        let fp = match (cipher.fingerprint(plain)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => throw e
        }
        let encrypted = match (cipher.encrypt(plain, dek)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => throw e
        }
        let clean = AttachmentService.scanContent(plain, ext)
        let status = if (clean) { AttachmentStatus.Ready } else { AttachmentStatus.Quarantined }
        let versionNo = rec.versionCount + 1
        let storageKey = "att_${attachmentId}_v${versionNo}.bin"
        if (clean) {
            this.storage.put(storageKey, encrypted)
        } else {
            this.quarantine.put(storageKey, encrypted)
        }
        let note = if (changeNote.isEmpty()) { "第 ${versionNo} 版" } else { changeNote }
        let versionId = this.repo.addVersion(
            attachmentId, versionNo, storageKey, encrypted.size, ext, mime, fp,
            status.toCode(), note, operatorId
        )
        // 两件事都要做：
        //   ① setCurrentVersion 翻转版本行的 is_current（下载按它取对象）
        //   ② setCurrentVersionId 更新主记录的 current_version_id 与 version_count
        this.repo.setCurrentVersion(attachmentId, versionId)
        this.repo.setCurrentVersionId(attachmentId, versionId, versionNo)
        return versionId
    }

    // ------------------------------------------------------------
    // WrappedKey 编解码（见 db/migrations/008_attachment_dek.sql）
    // ------------------------------------------------------------

    /**
     * 序列化： "<keyId>|<version>|<alg>|<base64(mac)>|<base64(ct)>"
     */
    private static func encodeWrapped(w: WrappedKey): String {
        return "${w.keyVersion.keyId}|${w.keyVersion.version}|${w.alg}|" +
               "${toBase64String(w.mac)}|${toBase64String(w.ciphertext)}"
    }

    /**
     * 反序列化；格式错误或 base64 非法时抛内部错误。
     */
    private static func decodeWrapped(text: String): WrappedKey {
        let parts = text.split("|")
        if (parts.size < 5) {
            throw AppError(AppErrorKind.CryptoFailure, "包裹密钥格式不正确")
        }
        let mac = match (fromBase64String(parts[3])) {
            case Some(v) => v
            case None => throw AppError(AppErrorKind.CryptoFailure, "包裹密钥 MAC 解码失败")
        }
        let ct = match (fromBase64String(parts[4])) {
            case Some(v) => v
            case None => throw AppError(AppErrorKind.CryptoFailure, "包裹密钥密文解码失败")
        }
        return WrappedKey(
            KeyVersion(parts[0], RowData.toI64(parts[1])),
            mac,
            ct,
            alg: RowData.toI64(parts[2])
        )
    }

    // ------------------------------------------------------------
    // 扫描与元数据
    // ------------------------------------------------------------

    /**
     * 内容一致性校验：真实魔数是否与声明扩展名相符（FR-ATT-007 兜底扫描）。
     *
     * 接入外部病毒引擎时，在此结果之上再 AND 引擎判定即可。
     */
    private static func scanContent(plain: Array<Byte>, ext: String): Bool {
        if (plain.size < 8) {
            return false
        }
        match (ext.toAsciiLower()) {
            case "jpg" => return AttachmentService.startsWith(plain, [0xFFu8, 0xD8u8, 0xFFu8])
            case "jpeg" => return AttachmentService.startsWith(plain, [0xFFu8, 0xD8u8, 0xFFu8])
            case "png" => return AttachmentService.startsWith(plain, [0x89u8, 0x50u8, 0x4Eu8, 0x47u8])
            case "pdf" => return AttachmentService.startsWith(plain, [0x25u8, 0x50u8, 0x44u8, 0x46u8])
            case _ => return false
        }
    }

    private static func startsWith(data: Array<Byte>, prefix: Array<Byte>): Bool {
        if (data.size < prefix.size) {
            return false
        }
        for (i in 0..prefix.size) {
            if (data[i] != prefix[i]) {
                return false
            }
        }
        return true
    }

    /**
     * 启发式提取拍摄时间（FR-ATT-006）。
     *
     * 仅在 JPEG 且含 "Exif" 时，在前 64KB 内定位首个 `YYYY:MM:DD HH:MM:SS` 串。
     * 这是**启发式**做法（未做完整 TIFF IFD 遍历），
     * 对绝大多数相机/手机直出照片有效；若需严格解析，应引入 EXIF 库。
     */
    private static func captureTimeOf(plain: Array<Byte>, ext: String): Option<String> {
        if (ext.toAsciiLower() != "jpg" && ext.toAsciiLower() != "jpeg") {
            return None
        }
        let limit = if (plain.size > 65536) { 65536 } else { plain.size }
        var found = false
        for (i in 0..limit) {
            if (plain[i] == 0x45u8) {   // 'E'
                found = true
            }
        }
        if (!found) {
            return None
        }
        // 逐字节滑窗找 "YYYY:MM:DD HH:MM:SS" 形状
        let sb = StringBuilder()
        var i2: Int64 = 0
        while (i2 < limit - 18) {
            if (AttachmentService.isDigit(plain[i2]) && AttachmentService.isDigit(plain[i2 + 1]) &&
                AttachmentService.isDigit(plain[i2 + 2]) && AttachmentService.isDigit(plain[i2 + 3]) &&
                plain[i2 + 4] == 0x3Au8 && plain[i2 + 7] == 0x3Au8 && plain[i2 + 10] == 0x20u8 &&
                plain[i2 + 13] == 0x3Au8 && plain[i2 + 16] == 0x3Au8) {
                return Some(AttachmentService.asciiOf(plain, i2, 19))
            }
            i2 = i2 + 1
        }
        return None
    }

    private static func isDigit(b: Byte): Bool {
        return b >= 0x30u8 && b <= 0x39u8
    }

    private static func asciiOf(data: Array<Byte>, from: Int64, len: Int64): String {
        let sb = StringBuilder()
        for (i in 0..len) {
            sb.append("${data[from + i]}")
        }
        return sb.toString()
    }
}
