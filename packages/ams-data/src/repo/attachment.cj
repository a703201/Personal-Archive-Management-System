// ============================================================
// ams.data.repo.attachment · 附件仓储
//
// 职责（FR-ATT-001 ~ FR-ATT-007）：
//   - arc_attachments 主记录读写（含去重键、状态、下载计数）
//   - arc_attachment_versions 版本明细（新增 / 列举 / 切换当前版本）
//   - 附件的状态机落库：uploading → scanning → ready / quarantined
//
// 约定：
//   ① BYTEA 列（sm3_fingerprint / iv）由驱动直接 `st.set<Array<Byte>>` 绑定，
//      读取时用 encode(col,'hex') 转十六进制串（与 AuditRepo 一致）。
//   ② 软删除：deleted_at 非空；列表查询一律过滤。
//   ③ 条目级附件与主体级附件通过 item_id 区分（item_id 为 NULL 表示主体级），
//      故 item_id 用 Option<Int64> 表达。
//   ④ wrapped_dek 存放被包裹 DEK 的文本表示（见 008 迁移），
//      单独用 setWrappedDek 更新，避免主 INSERT 参数过多。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 附件主记录。
 */
public class AttachmentRecord {
    public let id: Int64
    public let subjectId: Int64
    /** 所属条目；0 表示主体级独立附件 */
    public let itemId: Int64
    public let category: Int64
    public let title: String
    public let currentVersionId: Int64
    public let versionCount: Int64
    public let storageKey: String
    public let keyVersion: Int64
    public let wrappedDek: String
    public let fileSize: Int64
    public let fileExt: String
    public let mimeType: String
    public let status: Int64
    public let downloadCount: Int64
    public let dedupKey: String
    /** 手动录入摘要（FR-ATT-013 降级：OCR 不可用时由用户填写） */
    public let summary: String
    /** 手动录入关键词（逗号分隔，随条目检索索引） */
    public let keywords: String

    public init(
        id: Int64, subjectId: Int64, itemId: Int64, category: Int64, title: String,
        currentVersionId: Int64, versionCount: Int64, storageKey: String,
        keyVersion: Int64, wrappedDek: String, fileSize: Int64, fileExt: String,
        mimeType: String, status: Int64, downloadCount: Int64, dedupKey: String,
        summary!: String = "", keywords!: String = ""
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
        this.wrappedDek = wrappedDek
        this.fileSize = fileSize
        this.fileExt = fileExt
        this.mimeType = mimeType
        this.status = status
        this.downloadCount = downloadCount
        this.dedupKey = dedupKey
        this.summary = summary
        this.keywords = keywords
    }
}

/**
 * 附件仓储。
 */
public class AttachmentRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    private static let COLS: String =
        "id, subject_id, COALESCE(item_id, 0) AS item_id, category, title, " +
        "COALESCE(current_version_id, 0) AS current_version_id, version_count, " +
        "storage_key, key_version, COALESCE(wrapped_dek, '') AS wrapped_dek, " +
        "COALESCE(file_size, 0) AS file_size, COALESCE(file_ext, '') AS file_ext, " +
        "COALESCE(mime_type, '') AS mime_type, status, download_count, " +
        "COALESCE(dedup_key, '') AS dedup_key, " +
        "COALESCE(summary, '') AS summary, COALESCE(keywords, '') AS keywords"

    /**
     * 新建附件主记录（初始状态由调用方给定，通常为 scanning）。
     */
    public func create(
        subjectId: Int64,
        itemId: Option<Int64>,
        category: Int64,
        title: String,
        storageKey: String,
        keyVersion: Int64,
        fileSize: Int64,
        fileExt: String,
        mimeType: String,
        fingerprint: Array<Byte>,
        dedupKey: String,
        status: Int64,
        operatorId: Int64,
        summary!: String = "",
        keywords!: String = ""
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_attachments (" +
                  "id, subject_id, item_id, category, title, current_version_id, version_count, " +
                  "storage_key, storage_backend, encryption_alg, key_version, file_size, " +
                  "file_ext, mime_type, sm3_fingerprint, dedup_key, status, " +
                  "is_current_deleted, watermark_enabled, download_count, " +
                  "summary, keywords, " +
                  "created_at, created_by, updated_at, updated_by, version" +
                  ") VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0, 'SM4-CBC', ?, ?, ?, ?, ?, ?, ?, " +
                  "FALSE, TRUE, 0, ?, ?, " +
                  "CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?, 1)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, subjectId)
            match (itemId) {
                case Some(v) => st.set(2, v)
                case None => st.setNull(2)
            }
            st.set(3, category)
            st.set(4, title)
            st.set(5, storageKey)
            st.set(6, keyVersion)
            st.set(7, fileSize)
            st.set(8, fileExt)
            st.set(9, mimeType)
            st.set(10, fingerprint)
            st.set(11, dedupKey)
            st.set(12, status)
            st.set(13, summary)
            st.set(14, keywords)
            st.set(15, operatorId)
            st.set(16, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 写入被包裹的 DEK（创建后单独更新，见 008 迁移说明）。
     */
    public func setWrappedDek(id: Int64, wrappedDek: String): Unit {
        let sql = "UPDATE arc_attachments SET wrapped_dek = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, wrappedDek)
            st.set(1, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func findById(id: Int64): Option<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let all = readRows(st.query()).all()
            if (all.size == 0) {
                return None
            }
            return Some(AttachmentRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按条目列举附件。
     */
    public func listByItem(itemId: Int64): ArrayList<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE item_id = ? AND deleted_at IS NULL ORDER BY created_at DESC, id DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            return AttachmentRepo.collect(readRows(st.query()))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 同主体内按去重键查已存在的附件（FR-ATT-002 秒传复用）。
     */
    public func findByDedupKey(subjectId: Int64, dedupKey: String): Option<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE subject_id = ? AND dedup_key = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, subjectId)
            st.set(1, dedupKey)
            let all = readRows(st.query()).all()
            if (all.size == 0) {
                return None
            }
            return Some(AttachmentRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取某主体全部「可用」附件的去重键集合（FR-IMP-004 附件去重预检用）。
     *
     * 一次性取回，导入预检时按内存集合比对，避免「每个文件各查一次库」。
     * 只含未删除、未隔离（status<>3）的附件 —— 隔离件（疑似恶意）不参与去重，
     * 否则会误导用户以为「安全文件已存在」。
     */
    public func listDedupKeys(subjectId: Int64): HashSet<String> {
        let sql = "SELECT dedup_key FROM arc_attachments " +
                  "WHERE subject_id = ? AND deleted_at IS NULL AND status <> 3 " +
                  "AND dedup_key IS NOT NULL AND dedup_key <> ''"
        let c = this.db.connect()
        let set = HashSet<String>()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, subjectId)
            let rows = readRows(st.query())
            for (r in rows.all()) {
                let k = r.str("dedup_key")
                if (!k.isEmpty()) {
                    set.add(k)
                }
            }
            return set
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 新增一个版本（version_no 由调用方给出，通常为当前数量 +1）。
     */
    public func addVersion(
        attachmentId: Int64,
        versionNo: Int64,
        storageKey: String,
        fileSize: Int64,
        fileExt: String,
        mimeType: String,
        fingerprint: Array<Byte>,
        status: Int64,
        changeNote: String,
        uploadedBy: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_attachment_versions (" +
                  "id, attachment_id, version_no, storage_key, file_size, file_ext, " +
                  "mime_type, sm3_fingerprint, iv, is_current, status, change_note, " +
                  "uploaded_by, uploaded_at" +
                  ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, FALSE, ?, ?, ?, CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, attachmentId)
            st.set(2, versionNo)
            st.set(3, storageKey)
            st.set(4, fileSize)
            st.set(5, fileExt)
            st.set(6, mimeType)
            st.set(7, fingerprint)
            st.set(8, status)
            st.set(9, changeNote)
            st.set(10, uploadedBy)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列举版本（按版本号倒序）。
     */
    public func listVersions(attachmentId: Int64): RowSet {
        let sql = "SELECT id, version_no, storage_key, file_size, " +
                  "COALESCE(file_ext, '') AS file_ext, COALESCE(mime_type, '') AS mime_type, " +
                  "encode(sm3_fingerprint, 'hex') AS fp_hex, is_current, status, " +
                  "COALESCE(change_note, '') AS change_note, uploaded_by, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM uploaded_at) * 1000, 0) AS BIGINT) AS uploaded_ms " +
                  "FROM arc_attachment_versions WHERE attachment_id = ? " +
                  "ORDER BY version_no DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, attachmentId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 切换当前版本（FR-ATT-004）：把目标版本置为当前，其余置为非当前。
     */
    public func setCurrentVersion(attachmentId: Int64, versionId: Int64): Bool {
        let c = this.db.connect()
        try {
            let st1 = c.prepareStatement(
                "UPDATE arc_attachment_versions SET is_current = FALSE WHERE attachment_id = ?")
            st1.set(0, attachmentId)
            st1.update()
            let st2 = c.prepareStatement(
                "UPDATE arc_attachment_versions SET is_current = TRUE, status = 2 " +
                "WHERE id = ? AND attachment_id = ?")
            st2.set(0, versionId)
            st2.set(1, attachmentId)
            st2.update()
            let st3 = c.prepareStatement(
                "UPDATE arc_attachments SET current_version_id = ?, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ?")
            st3.set(0, versionId)
            st3.set(1, attachmentId)
            st3.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新附件状态（状态机：uploading/scanning/ready/quarantined/…）。
     */
    public func setStatus(id: Int64, status: Int64): Unit {
        let sql = "UPDATE arc_attachments SET status = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, status)
            st.set(1, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新主记录的当前版本指针与版本计数。
     */
    public func setCurrentVersionId(id: Int64, versionId: Int64, versionCount: Int64): Unit {
        let sql = "UPDATE arc_attachments SET current_version_id = ?, version_count = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, versionId)
            st.set(1, versionCount)
            st.set(2, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 下载计数 + 最后访问时间（FR-ATT-005 下载审计的基础数据）。
     */
    public func incrDownload(id: Int64): Unit {
        let sql = "UPDATE arc_attachments SET download_count = download_count + 1, " +
                  "last_accessed_at = CURRENT_TIMESTAMP WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计若干主体下的附件总字节数（FR-ATT-011 存储配额用）。
     *
     * @return 总字节；无附件或主体为空时返回 0
     */
    public func totalBytesInSubjects(subjectIds: Array<String>): Int64 {
        if (subjectIds.isEmpty()) {
            return 0
        }
        let c = this.db.connect()
        try {
            let sb = StringBuilder()
            sb.append(
                "SELECT COALESCE(SUM(file_size), 0) AS total FROM arc_attachments " +
                "WHERE deleted_at IS NULL AND subject_id IN ("
            )
            for (i in 0..subjectIds.size) {
                if (i > 0) { sb.append(", ") }
                sb.append("?")
            }
            sb.append(")")
            let st = c.prepareStatement(sb.toString())
            for (i in 0..subjectIds.size) {
                st.set(i, subjectIds[i])
            }
            match (readRows(st.query()).first()) {
                case Some(r) => return r.i64("total")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------
    // FR-ATT-009 版本对比 / FR-ATT-010 批量操作
    // ------------------------------------------------------------

    /**
     * 取「当前版本」的存储键。
     *
     * 附件主记录的 storage_key 记的是**首版**对象；切换版本后必须按
     * current_version_id 反查真实对象，否则「切换版本」只是改了个标记，
     * 下载拿到的还是第一版内容（FR-ATT-004 的实际缺口）。
     */
    public func currentVersionStorageKey(attachmentId: Int64): Option<String> {
        let sql = "SELECT storage_key FROM arc_attachment_versions " +
                  "WHERE attachment_id = ? AND is_current = TRUE " +
                  "ORDER BY version_no DESC LIMIT 1"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, attachmentId)
            match (readRows(st.query()).first()) {
                case Some(r) => return Some(r.str("storage_key"))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取单个版本明细（版本对比用）。
     *
     * @return 版本行；不属于该附件时返回 None
     */
    public func findVersion(attachmentId: Int64, versionId: Int64): ?RowData {
        let sql = "SELECT id, version_no, storage_key, file_size, " +
                  "COALESCE(file_ext, '') AS file_ext, COALESCE(mime_type, '') AS mime_type, " +
                  "encode(sm3_fingerprint, 'hex') AS fp_hex, is_current, status, " +
                  "COALESCE(change_note, '') AS change_note, uploaded_by, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM uploaded_at) * 1000, 0) AS BIGINT) AS uploaded_ms " +
                  "FROM arc_attachment_versions WHERE attachment_id = ? AND id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, attachmentId)
            st.set(1, versionId)
            match (readRows(st.query()).first()) {
                case Some(r) => return Some(r)
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 给附件打标签（幂等：已存在则不重复写）。
     *
     * @return true = 本次真正新增了关联
     */
    public func addTag(attachmentId: Int64, tagId: Int64, operatorId: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO arc_attachment_tags (id, attachment_id, tag_id, created_by, created_at) " +
                "SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP " +
                "WHERE NOT EXISTS (SELECT 1 FROM arc_attachment_tags " +
                "WHERE attachment_id = ? AND tag_id = ?)"
            )
            st.set(0, Ids.next())
            st.set(1, attachmentId)
            st.set(2, tagId)
            st.set(3, operatorId)
            st.set(4, attachmentId)
            st.set(5, tagId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除附件（批量删除用）。
     *
     * 只改 status 不够：列表查询过滤的是 deleted_at，
     * 所以必须真正打上删除时间，否则「删了还在列表里」（实测踩到）。
     */
    public func softDelete(id: Int64, operatorId: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE arc_attachments SET deleted_at = CURRENT_TIMESTAMP, status = 9, " +
                "updated_at = CURRENT_TIMESTAMP, updated_by = ? " +
                "WHERE id = ? AND deleted_at IS NULL"
            )
            st.set(0, operatorId)
            st.set(1, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 取消附件上的某个标签 */
    public func removeTag(attachmentId: Int64, tagId: Int64): Bool {        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "DELETE FROM arc_attachment_tags WHERE attachment_id = ? AND tag_id = ?"
            )
            st.set(0, attachmentId)
            st.set(1, tagId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 附件的标签列表 */
    public func listTagsOf(attachmentId: Int64): RowSet {
        let sql = "SELECT t.id AS id, t.name AS name, COALESCE(t.color, '') AS color " +
                  "FROM arc_tags t JOIN arc_attachment_tags l ON l.tag_id = t.id " +
                  "WHERE l.attachment_id = ? ORDER BY t.name"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, attachmentId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 标签是否存在（批量打标签时先校验，避免写出悬挂关联） */
    public func tagExists(tagId: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement("SELECT CAST(COUNT(1) AS BIGINT) AS n FROM arc_tags WHERE id = ?")
            st.set(0, tagId)
            match (readRows(st.query()).first()) {
                case Some(r) => return r.i64("n") > 0
                case None => return false
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------

    private static func collect(rows: RowSet): ArrayList<AttachmentRecord> {
        let out = ArrayList<AttachmentRecord>()
        for (r in rows.all().iterator()) {
            out.add(AttachmentRepo.toRecord(r))
        }
        return out
    }

    private static func toRecord(r: RowData): AttachmentRecord {
        return AttachmentRecord(
            r.i64("id"),
            r.i64("subject_id"),
            r.i64("item_id"),
            r.i64("category"),
            r.str("title"),
            r.i64("current_version_id"),
            r.i64("version_count"),
            r.str("storage_key"),
            r.i64("key_version"),
            r.str("wrapped_dek"),
            r.i64("file_size"),
            r.str("file_ext"),
            r.str("mime_type"),
            r.i64("status"),
            r.i64("download_count"),
            r.str("dedup_key"),
            summary: r.str("summary"),
            keywords: r.str("keywords")
        )
    }

    /**
     * 更新附件摘要与关键词（FR-ATT-013 降级：OCR 不可用时由用户手动录入）。
     */
    public func updateMeta(id: Int64, summary: String, keywords: String, operatorId: Int64): Bool {
        let sql = "UPDATE arc_attachments SET summary = ?, keywords = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, summary)
            st.set(1, keywords)
            st.set(2, operatorId)
            st.set(3, id)
            st.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
