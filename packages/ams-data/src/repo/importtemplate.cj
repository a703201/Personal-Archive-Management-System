// ============================================================
// ams.data.repo.importtemplate · 导入模板仓储（FR-IMP-005）
//
// 职责：arc_import_templates 的读写，owner_id 强隔离。
//
// 约定：
//   ① mapping / defaults 以 JSON 字符串原文存储（落 JSONB）；
//      解析交给接口层（SimpleJson 不暴露键集合，需要自建解析）。
//   ② 列表 / 详情 / 更新 / 删除全部带 owner_id 条件，杜绝越权读写他人模板。
//   ③ 小表，删除用硬删（带 owner 校验）；无需软删的回收站语义。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 导入模板记录（仓储层视图）。
 *
 * @param mappingJson  CSV 表头 → 字段键 的 JSON 原文
 * @param defaultsJson 字段键 → 默认值 的 JSON 原文
 */
public class ImportTemplateRecord {
    public let id: Int64
    public let ownerId: Int64
    public let name: String
    public let mappingJson: String
    public let defaultsJson: String
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: Int64,
        ownerId: Int64,
        name: String,
        mappingJson: String,
        defaultsJson: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        this.id = id
        this.ownerId = ownerId
        this.name = name
        this.mappingJson = mappingJson
        this.defaultsJson = defaultsJson
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }
}

/**
 * 导入模板仓储（owner_id 隔离）。
 */
public class ImportTemplateRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 列出某用户全部模板（按更新时间倒序）。 */
    public func listByOwner(ownerId: Int64): ArrayList<ImportTemplateRecord> {
        let sql = "SELECT id, owner_id, name, " +
                  "mapping::text AS mapping, defaults::text AS defaults, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms " +
                  "FROM arc_import_templates WHERE owner_id = ? ORDER BY updated_at DESC, id DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            return ImportTemplateRepo.collect(readRows(st.query()))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按 ID 查（带 owner 校验；非本人返回 None）。 */
    public func findByIdAndOwner(id: Int64, ownerId: Int64): Option<ImportTemplateRecord> {
        let sql = "SELECT id, owner_id, name, " +
                  "mapping::text AS mapping, defaults::text AS defaults, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms " +
                  "FROM arc_import_templates WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            let rows = readRows(st.query())
            let all = rows.all()
            if (all.size == 0) {
                return None
            }
            return Some(ImportTemplateRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 仅按 ID 查（接口层已校验归属，此处不重复带 owner）。 */
    public func findById(id: Int64): Option<ImportTemplateRecord> {
        let sql = "SELECT id, owner_id, name, " +
                  "mapping::text AS mapping, defaults::text AS defaults, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms " +
                  "FROM arc_import_templates WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let rows = readRows(st.query())
            let all = rows.all()
            if (all.size == 0) {
                return None
            }
            return Some(ImportTemplateRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 新建模板，返回新 ID。 */
    public func create(
        ownerId: Int64,
        name: String,
        mappingJson: String,
        defaultsJson: String,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_import_templates (" +
                  "id, owner_id, name, mapping, defaults, created_at, created_by, updated_at, updated_by" +
                  ") VALUES (?, ?, ?, ?::jsonb, ?::jsonb, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            st.set(2, name)
            st.set(3, if (mappingJson.isEmpty()) { "{}" } else { mappingJson })
            st.set(4, if (defaultsJson.isEmpty()) { "{}" } else { defaultsJson })
            st.set(5, operatorId)
            st.set(6, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 更新（带 owner 校验）。 */
    public func update(
        id: Int64,
        ownerId: Int64,
        name: String,
        mappingJson: String,
        defaultsJson: String,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_import_templates SET name = ?, mapping = ?::jsonb, " +
                  "defaults = ?::jsonb, updated_at = CURRENT_TIMESTAMP, updated_by = ? " +
                  "WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, name)
            st.set(1, if (mappingJson.isEmpty()) { "{}" } else { mappingJson })
            st.set(2, if (defaultsJson.isEmpty()) { "{}" } else { defaultsJson })
            st.set(3, operatorId)
            st.set(4, id)
            st.set(5, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 删除（带 owner 校验）。 */
    public func delete(id: Int64, ownerId: Int64): Bool {
        let sql = "DELETE FROM arc_import_templates WHERE id = ? AND owner_id = ?"
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

    // ------------------------------------------------------------

    private static func collect(rows: RowSet): ArrayList<ImportTemplateRecord> {
        let out = ArrayList<ImportTemplateRecord>()
        for (r in rows.all().iterator()) {
            out.add(ImportTemplateRepo.toRecord(r))
        }
        return out
    }

    private static func toRecord(r: RowData): ImportTemplateRecord {
        return ImportTemplateRecord(
            r.i64("id"),
            r.i64("owner_id"),
            r.str("name"),
            r.str("mapping"),
            r.str("defaults"),
            r.i64("created_ms"),
            r.i64("updated_ms")
        )
    }
}
