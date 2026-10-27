// ============================================================
// ams.data.repo.itemfield · 扩展字段明细仓储
//
// 职责（FR-ARCH-004 扩展字段存储）：
//   arc_items.extra 是「松散 JSONB」，适合随手写；
//   arc_item_fields 是**强类型明细表**，按 field_def_id 逐字段存值，
//   每个字段有独立的数据类型列（text / num / date / bool / json），
//   并可带 value_enc（密文）与 value_bidx（盲索引）供加密检索。
//
//   本仓储负责明细行的读写：`extra` 之外第二套存储通道，
//   使「按模板定义的结构化字段」可校验、可筛选、可加密。
//
// 约定：
//   ① 唯一约束 uk_arc_item_fields(item_id, field_def_id)
//      → 写入一律用 INSERT ... ON CONFLICT DO UPDATE（幂等覆盖）
//   ② 取值列的选择由 data_type 决定（见 save 的分支）
//   ③ value_enc / value_bidx 留给「敏感字段加密 + 盲索引」链路，
//      本轮未开启（敏感值先落 value_text，待 T35 接入后迁移）
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import stdx.encoding.hex.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 扩展字段值（读取视图：把多类型列归一成一个 value 字符串）。
 */
public class ItemFieldValue {
    public let id: Int64
    public let itemId: Int64
    public let fieldDefId: Int64
    public let fieldKey: String
    public let fieldName: String
    public let dataType: Int64
    public let sensitivity: Int64
    /** 归一后的取值字符串（空串 = 未填） */
    public let value: String

    public init(
        id: Int64,
        itemId: Int64,
        fieldDefId: Int64,
        fieldKey: String,
        fieldName: String,
        dataType: Int64,
        sensitivity: Int64,
        value: String
    ) {
        this.id = id
        this.itemId = itemId
        this.fieldDefId = fieldDefId
        this.fieldKey = fieldKey
        this.fieldName = fieldName
        this.dataType = dataType
        this.sensitivity = sensitivity
        this.value = value
    }
}

/**
 * 扩展字段明细仓储。
 */
public class ItemFieldRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 查询条目的全部扩展字段值。
     *
     * 用 LEFT JOIN 带出字段定义元信息（field_key / data_type / sensitivity），
     * 并按 display_order 排序 —— 前端据此直接渲染动态表单。
     */
    public func listByItem(itemId: Int64): ArrayList<ItemFieldValue> {
        let sql = "SELECT f.id, f.item_id, f.field_def_id, " +
                  "COALESCE(d.field_key, '')  AS field_key, " +
                  "COALESCE(d.field_name, '') AS field_name, " +
                  "COALESCE(d.data_type, 0)   AS data_type, " +
                  "COALESCE(d.sensitivity, 1) AS sensitivity, " +
                  "COALESCE(" +
                  "    CASE" +
                  "        WHEN f.value_text IS NOT NULL THEN f.value_text" +
                  "        WHEN f.value_num  IS NOT NULL THEN CAST(f.value_num AS TEXT)" +
                  "        WHEN f.value_date IS NOT NULL THEN TO_CHAR(f.value_date, 'YYYY-MM-DD')" +
                  "        WHEN f.value_bool IS NOT NULL THEN CAST(f.value_bool AS TEXT)" +
                  "        WHEN f.value_json IS NOT NULL THEN CAST(f.value_json AS TEXT)" +
                  "        ELSE NULL" +
                  "    END, '') AS value " +
                  "FROM arc_item_fields f " +
                  "LEFT JOIN arc_field_defs d ON d.id = f.field_def_id " +
                  "WHERE f.item_id = ? " +
                  "ORDER BY COALESCE(d.display_order, 9999), f.id"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            let rows = readRows(st.query())
            return ItemFieldRepo.collect(rows)
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 写入（覆盖）一个字段值 —— 幂等 upsert。
     *
     * @param dataType 字段类型编码（ams.core.item.FieldType.toCode）
     * @param value    取值字符串；空串表示清空（存 NULL）
     * @param bidx     盲索引（HMAC-SM3 摘要，BYTEA）；可选，由上层按字段规则算好。
     *                 传入 None 表示不维护盲索引（该列置 NULL，精确检索将忽略此字段）。
     */
    public func save(
        itemId: Int64,
        fieldDefId: Int64,
        dataType: Int64,
        value: String,
        bidx!: ?Array<Byte> = None
    ): Unit {
        if (dataType == 2) {
            ItemFieldRepo.writeNum(this.db, itemId, fieldDefId, value, bidx)
        } else if (dataType == 3) {
            ItemFieldRepo.writeDate(this.db, itemId, fieldDefId, value, bidx)
        } else if (dataType == 6) {
            ItemFieldRepo.writeBool(this.db, itemId, fieldDefId, value, bidx)
        } else if (dataType == 11) {
            ItemFieldRepo.writeJson(this.db, itemId, fieldDefId, value, bidx)
        } else {
            ItemFieldRepo.writeText(this.db, itemId, fieldDefId, value, bidx)
        }
    }

    /**
     * 删除条目的全部扩展字段值（软删除条目 / 重建前清理用）。
     */
    public func deleteByItem(itemId: Int64): Int64 {
        let sql = "DELETE FROM arc_item_fields WHERE item_id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            st.update()
            return itemId
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    // ------------------------------------------------------------
    // 按类型分支写入
    // ------------------------------------------------------------

    private static func writeText(db: Database, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        let sql = "INSERT INTO arc_item_fields (id, item_id, field_def_id, value_text, value_bidx) " +
                  "VALUES (?, ?, ?, ?, decode(?, 'hex')) " +
                  "ON CONFLICT (item_id, field_def_id) DO UPDATE " +
                  "SET value_text = EXCLUDED.value_text, value_bidx = EXCLUDED.value_bidx"
        ItemFieldRepo.exec5(db, sql, itemId, fieldDefId, value, bidx)
    }

    private static func writeJson(db: Database, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        let sql = "INSERT INTO arc_item_fields (id, item_id, field_def_id, value_json, value_bidx) " +
                  "VALUES (?, ?, ?, ?::jsonb, decode(?, 'hex')) " +
                  "ON CONFLICT (item_id, field_def_id) DO UPDATE " +
                  "SET value_json = EXCLUDED.value_json, value_bidx = EXCLUDED.value_bidx"
        ItemFieldRepo.exec5(db, sql, itemId, fieldDefId, value, bidx)
    }

    private static func writeDate(db: Database, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        let sql = "INSERT INTO arc_item_fields (id, item_id, field_def_id, value_date, value_bidx) " +
                  "VALUES (?, ?, ?, CAST(? AS DATE), decode(?, 'hex')) " +
                  "ON CONFLICT (item_id, field_def_id) DO UPDATE " +
                  "SET value_date = EXCLUDED.value_date, value_bidx = EXCLUDED.value_bidx"
        try {
            let c = db.connect()
            let st = c.prepareStatement(sql)
            ItemFieldRepo.bindCommon(st, itemId, fieldDefId)
            if (value.isEmpty()) {
                st.setNull(3)
            } else {
                st.set(3, value)
            }
            ItemFieldRepo.bindBidx(st, 4, bidx)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    private static func writeNum(db: Database, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        // 数值同时写 value_num 与 numeric_value_norm（后者供范围/排序检索）
        let sql = "INSERT INTO arc_item_fields (id, item_id, field_def_id, value_num, numeric_value_norm, value_bidx) " +
                  "VALUES (?, ?, ?, CAST(? AS NUMERIC), CAST(? AS NUMERIC), decode(?, 'hex')) " +
                  "ON CONFLICT (item_id, field_def_id) DO UPDATE " +
                  "SET value_num = EXCLUDED.value_num, " +
                  "    numeric_value_norm = EXCLUDED.numeric_value_norm, " +
                  "    value_bidx = EXCLUDED.value_bidx"
        try {
            let c = db.connect()
            let st = c.prepareStatement(sql)
            ItemFieldRepo.bindCommon(st, itemId, fieldDefId)
            if (value.isEmpty()) {
                st.setNull(3)
                st.setNull(4)
            } else {
                st.set(3, value)
                st.set(4, value)
            }
            ItemFieldRepo.bindBidx(st, 5, bidx)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    private static func writeBool(db: Database, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        let sql = "INSERT INTO arc_item_fields (id, item_id, field_def_id, value_bool, value_bidx) " +
                  "VALUES (?, ?, ?, CAST(? AS BOOLEAN), decode(?, 'hex')) " +
                  "ON CONFLICT (item_id, field_def_id) DO UPDATE " +
                  "SET value_bool = EXCLUDED.value_bool, value_bidx = EXCLUDED.value_bidx"
        try {
            let c = db.connect()
            let st = c.prepareStatement(sql)
            ItemFieldRepo.bindCommon(st, itemId, fieldDefId)
            if (value.isEmpty()) {
                st.setNull(3)
            } else {
                st.set(3, value)
            }
            ItemFieldRepo.bindBidx(st, 4, bidx)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 通用 upsert（TEXT / JSONB 两种，占位符形式一致）。
     */
    private static func exec5(db: Database, sql: String, itemId: Int64, fieldDefId: Int64, value: String, bidx: ?Array<Byte>): Unit {
        try {
            let c = db.connect()
            let st = c.prepareStatement(sql)
            ItemFieldRepo.bindCommon(st, itemId, fieldDefId)
            if (value.isEmpty()) {
                st.setNull(3)
            } else {
                st.set(3, value)
            }
            ItemFieldRepo.bindBidx(st, 4, bidx)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /** 绑定盲索引（BYTEA）：有则写原始字节，无则 NULL。 */
    /** 绑定盲索引（BYTEA）：与查询侧 decode(?, 'hex') 对称，统一走十六进制串。 */
    private static func bindBidx(st: Statement, i: Int64, bidx: ?Array<Byte>): Unit {
        match (bidx) {
            case Some(b) => st.set(i, toHexString(b))
            case None => st.setNull(i)
        }
    }

    /** 绑定公共三列：id / item_id / field_def_id */
    private static func bindCommon(st: Statement, itemId: Int64, fieldDefId: Int64): Unit {
        st.set(0, Ids.next())
        st.set(1, itemId)
        st.set(2, fieldDefId)
    }

    // ------------------------------------------------------------

    private static func collect(rows: RowSet): ArrayList<ItemFieldValue> {
        let out = ArrayList<ItemFieldValue>()
        for (r in rows.all().iterator()) {
            out.add(ItemFieldValue(
                r.i64("id"),
                r.i64("item_id"),
                r.i64("field_def_id"),
                r.str("field_key"),
                r.str("field_name"),
                r.i64("data_type"),
                r.i64("sensitivity"),
                r.str("value")
            ))
        }
        return out
    }
}
