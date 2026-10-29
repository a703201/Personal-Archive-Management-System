// ============================================================
// ams.data.repo.itemtemplate · 条目模板仓储（FR-ARCH-012 · 方案 C）
//
// 模板 = 条目骨架 + 字段默认值 + 有效期偏移。
// 所有读写都以 owner_id 为界：个人模板只能被本人看到/修改/套用。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 条目模板仓储。
 */
public class ItemTemplateRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 列出某用户的全部模板（最近更新在前）。 */
    public func list(ownerId: Int64): RowSet {
        let sql = ItemTemplateRepo.selectCols() +
                  " FROM arc_item_templates WHERE owner_id = ? " +
                  "ORDER BY updated_at DESC, id DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按 ID 查模板（**必须带 ownerId**，避免越权读取他人模板）。 */
    public func findById(id: Int64, ownerId: Int64): Option<RowData> {
        let sql = ItemTemplateRepo.selectCols() +
                  " FROM arc_item_templates WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 新建模板。 */
    public func create(
        ownerId: Int64,
        name: String,
        category: Int64,
        title: String,
        status: Int64,
        sensitivity: Int64,
        issuer: String,
        remark: String,
        expiresOffsetDays: Int64,
        extra: String,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_item_templates (" +
                  "id, owner_id, name, category, title, status, sensitivity, " +
                  "issuer, remark, expires_offset_days, extra, " +
                  "created_at, updated_at, created_by, updated_by" +
                  ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, " +
                  "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            st.set(2, name)
            st.set(3, category)
            st.set(4, title)
            st.set(5, status)
            st.set(6, sensitivity)
            st.set(7, issuer)
            st.set(8, remark)
            st.set(9, expiresOffsetDays)
            st.set(10, extra)
            st.set(11, operatorId)
            st.set(12, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 更新模板（owner 归属校验在 WHERE 里）。 */
    public func update(
        id: Int64,
        ownerId: Int64,
        name: String,
        category: Int64,
        title: String,
        status: Int64,
        sensitivity: Int64,
        issuer: String,
        remark: String,
        expiresOffsetDays: Int64,
        extra: String,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_item_templates SET name = ?, category = ?, title = ?, " +
                  "status = ?, sensitivity = ?, issuer = ?, remark = ?, " +
                  "expires_offset_days = ?, extra = ?::jsonb, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ? " +
                  "WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, name)
            st.set(1, category)
            st.set(2, title)
            st.set(3, status)
            st.set(4, sensitivity)
            st.set(5, issuer)
            st.set(6, remark)
            st.set(7, expiresOffsetDays)
            st.set(8, extra)
            st.set(9, operatorId)
            st.set(10, id)
            st.set(11, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 删除模板（owner 归属校验在 WHERE 里）。 */
    public func delete(id: Int64, ownerId: Int64): Bool {
        let sql = "DELETE FROM arc_item_templates WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    private static func selectCols(): String {
        return "SELECT id, owner_id, name, category, title, status, sensitivity, " +
               "issuer, remark, expires_offset_days, extra::text AS extra, " +
               "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms"
    }
}
