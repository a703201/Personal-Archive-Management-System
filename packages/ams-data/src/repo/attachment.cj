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

    public init(
        id: Int64, subjectId: Int64, itemId: Int64, category: Int64, title: String,
        currentVersionId: Int64, versionCount: Int64, storageKey: String,
        keyVersion: Int64, wrappedDek: String, fileSize: Int64, fileExt: String,
        mimeType: String, status: Int64, downloadCount: Int64, dedupKey: String
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
        "COALESCE(dedup_key, '') AS dedup_key"

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
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_attachments (" +
                  "id, subject_id, item_id, category, title, current_version_id, version_count, " +
                  "storage_key, storage_backend, encryption_alg, key_version, file_size, " +
                  "file_ext, mime_type, sm3_fingerprint, dedup_key, status, " +
                  "is_current_deleted, watermark_enabled, download_count, " +
                  "created_at, created_by, updated_at, updated_by, version" +
                  ") VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0, 'SM4-CBC', ?, ?, ?, ?, ?, ?, ?, " +
                  "FALSE, TRUE, 0, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?, 1)"
        try {
            let c = this.db.connect()
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
            st.set(13, operatorId)
            st.set(14, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 写入被包裹的 DEK（创建后单独更新，见 008 迁移说明）。
     */
    public func setWrappedDek(id: Int64, wrappedDek: String): Unit {
        let sql = "UPDATE arc_attachments SET wrapped_dek = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, wrappedDek)
            st.set(1, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    public func findById(id: Int64): Option<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE id = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let all = readRows(st.query()).all()
            if (all.size == 0) {
                return None
            }
            return Some(AttachmentRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 按条目列举附件。
     */
    public func listByItem(itemId: Int64): ArrayList<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE item_id = ? AND deleted_at IS NULL ORDER BY created_at DESC, id DESC"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            return AttachmentRepo.collect(readRows(st.query()))
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 同主体内按去重键查已存在的附件（FR-ATT-002 秒传复用）。
     */
    public func findByDedupKey(subjectId: Int64, dedupKey: String): Option<AttachmentRecord> {
        let sql = "SELECT " + AttachmentRepo.COLS + " FROM arc_attachments " +
                  "WHERE subject_id = ? AND dedup_key = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
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
        try {
            let c = this.db.connect()
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
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, attachmentId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 切换当前版本（FR-ATT-004）：把目标版本置为当前，其余置为非当前。
     */
    public func setCurrentVersion(attachmentId: Int64, versionId: Int64): Bool {
        try {
            let c = this.db.connect()
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
        }
    }

    /**
     * 更新附件状态（状态机：uploading/scanning/ready/quarantined/…）。
     */
    public func setStatus(id: Int64, status: Int64): Unit {
        let sql = "UPDATE arc_attachments SET status = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, status)
            st.set(1, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 更新主记录的当前版本指针与版本计数。
     */
    public func setCurrentVersionId(id: Int64, versionId: Int64, versionCount: Int64): Unit {
        let sql = "UPDATE arc_attachments SET current_version_id = ?, version_count = ?, " +
                  "updated_at = CURRENT_TIMESTAMP WHERE id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, versionId)
            st.set(1, versionCount)
            st.set(2, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 下载计数 + 最后访问时间（FR-ATT-005 下载审计的基础数据）。
     */
    public func incrDownload(id: Int64): Unit {
        let sql = "UPDATE arc_attachments SET download_count = download_count + 1, " +
                  "last_accessed_at = CURRENT_TIMESTAMP WHERE id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
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
            r.str("dedup_key")
        )
    }
}
