// ============================================================
// ams.data.repo.fielddef · 字段定义仓储
//
// 职责（FR-ARCH-003 字段定义表 / FR-ARCH-005 分类模板预置）：
//   - arc_field_defs 的读写
//   - 内置分类字段模板的落库支撑（实际播种由 ams-app 层调用）
//
// 约定：
//   ① **内置模板**：subject_id IS NULL；本仓储以 `subjectId == 0` 表示
//   ② **用户自定义字段**：subject_id = 用户主体 ID
//   ③ **软删除**：deleted_at 非空即视为删除，列表查询一律过滤
//   ④ 布尔列沿用本项目既有写法 —— 以 SQL 字面量 TRUE/FALSE 拼入
//      （见 RoleRepo.createRole 的 FALSE），不由驱动绑定 boolean，
//      规避 `st.set<Bool>` 的类型不确定性。字面量取值只有两种，无注入风险。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 字段定义记录（arc_field_defs 的仓储层视图）。
 */
public class FieldDefRecord {
    public let id: Int64
    /** 归属主体；0 = 内置模板（DB 中 subject_id IS NULL） */
    public let subjectId: Int64
    public let category: Int64
    public let fieldKey: String
    public let fieldName: String
    public let dataType: Int64
    /** 敏感度：1=普通 2=敏感 3=高敏（ams.core.item.ItemSensitivity 编码） */
    public let sensitivity: Int64
    public let isRequired: Bool
    public let isSearchable: Bool
    public let isFilterable: Bool
    public let isBidxCapable: Bool
    public let enumDictCode: String
    public let displayOrder: Int64
    public let validationRule: String
    public let defaultValue: String
    public let isSystem: Bool
    public let status: Int64

    public init(
        id: Int64,
        subjectId: Int64,
        category: Int64,
        fieldKey: String,
        fieldName: String,
        dataType: Int64,
        sensitivity: Int64,
        isRequired: Bool,
        isSearchable: Bool,
        isFilterable: Bool,
        isBidxCapable: Bool,
        enumDictCode: String,
        displayOrder: Int64,
        validationRule: String,
        defaultValue: String,
        isSystem: Bool,
        status: Int64
    ) {
        this.id = id
        this.subjectId = subjectId
        this.category = category
        this.fieldKey = fieldKey
        this.fieldName = fieldName
        this.dataType = dataType
        this.sensitivity = sensitivity
        this.isRequired = isRequired
        this.isSearchable = isSearchable
        this.isFilterable = isFilterable
        this.isBidxCapable = isBidxCapable
        this.enumDictCode = enumDictCode
        this.displayOrder = displayOrder
        this.validationRule = validationRule
        this.defaultValue = defaultValue
        this.isSystem = isSystem
        this.status = status
    }
}

/**
 * 字段定义仓储。
 */
public class FieldDefRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /** 统一 SELECT 列表（把可空列 COALESCE 成空串，便于 RowData 读取） */
    private static let COLS: String =
        "id, COALESCE(subject_id, 0) AS subject_id, category, field_key, field_name, " +
        "data_type, sensitivity, is_required, is_searchable, is_filterable, " +
        "is_bidx_capable, COALESCE(enum_dict_code, '') AS enum_dict_code, display_order, " +
        "COALESCE(validation_rule::text, '') AS validation_rule, " +
        "COALESCE(default_value, '') AS default_value, is_system, status"

    /**
     * 某分类下「可见的字段定义」：内置模板 + 指定主体的自定义字段。
     *
     * 用于档案动态表单渲染与元数据落库前的校验。
     */
    public func listByCategory(category: Int64, subjectId: Int64): ArrayList<FieldDefRecord> {
        let sql = "SELECT " + FieldDefRepo.COLS + " FROM arc_field_defs " +
                  "WHERE category = ? AND deleted_at IS NULL AND status = 1 " +
                  "AND (subject_id IS NULL OR subject_id = ?) " +
                  "ORDER BY display_order, id"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, category)
            st.set(1, subjectId)
            let rows = readRows(st.query())
            return FieldDefRepo.collect(rows)
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 仅取内置模板（不含用户自定义）。
     */
    public func listBuiltin(category: Int64): ArrayList<FieldDefRecord> {
        let sql = "SELECT " + FieldDefRepo.COLS + " FROM arc_field_defs " +
                  "WHERE category = ? AND subject_id IS NULL " +
                  "AND deleted_at IS NULL AND status = 1 " +
                  "ORDER BY display_order, id"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, category)
            let rows = readRows(st.query())
            return FieldDefRepo.collect(rows)
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    public func findById(id: Int64): Option<FieldDefRecord> {
        let sql = "SELECT " + FieldDefRepo.COLS + " FROM arc_field_defs " +
                  "WHERE id = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let rows = readRows(st.query())
            let all = rows.all()
            if (all.size == 0) {
                return None
            }
            return Some(FieldDefRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 按「分类 + 字段键」查内置模板 —— **模板播种的幂等判定依据**。
     *
     * 唯一索引 uk_arc_field_defs(COALESCE(subject_id,0), category, field_key)
     * 保证同一分类下字段键不重复，故可用它判重。
     */
    public func findBuiltinByKey(category: Int64, fieldKey: String): Option<FieldDefRecord> {
        let sql = "SELECT " + FieldDefRepo.COLS + " FROM arc_field_defs " +
                  "WHERE category = ? AND field_key = ? AND subject_id IS NULL " +
                  "AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, category)
            st.set(1, fieldKey)
            let rows = readRows(st.query())
            let all = rows.all()
            if (all.size == 0) {
                return None
            }
            return Some(FieldDefRepo.toRecord(all[0]))
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 新建字段定义。
     *
     * @param subjectId 0 表示内置模板（写 NULL），否则为用户自定义字段
     */
    public func create(
        subjectId: Int64,
        category: Int64,
        fieldKey: String,
        fieldName: String,
        dataType: Int64,
        sensitivity: Int64,
        isRequired: Bool,
        isSearchable: Bool,
        isFilterable: Bool,
        isBidxCapable: Bool,
        enumDictCode: String,
        displayOrder: Int64,
        validationRule: String,
        defaultValue: String,
        isSystem: Bool,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_field_defs (" +
                  "id, subject_id, category, field_key, field_name, data_type, sensitivity, " +
                  "is_required, is_searchable, is_filterable, is_bidx_capable, " +
                  "enum_dict_code, display_order, validation_rule, default_value, " +
                  "is_system, status, created_at, created_by, updated_at, updated_by, version" +
                  ") VALUES (?, ?, ?, ?, ?, ?, ?, " +
                  FieldDefRepo.bl(isRequired) + ", " +
                  FieldDefRepo.bl(isSearchable) + ", " +
                  FieldDefRepo.bl(isFilterable) + ", " +
                  FieldDefRepo.bl(isBidxCapable) + ", " +
                  "?, ?, ?::jsonb, ?, " +
                  FieldDefRepo.bl(isSystem) + ", 1, " +
                  "CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?, 1)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            if (subjectId == 0) {
                st.setNull(1)
            } else {
                st.set(1, subjectId)
            }
            st.set(2, category)
            st.set(3, fieldKey)
            st.set(4, fieldName)
            st.set(5, dataType)
            st.set(6, sensitivity)
            // 索引 7..10 = 布尔位（已字面量化，不占位）
            FieldDefRepo.bindNullableStr(st, 7, enumDictCode)
            st.set(8, displayOrder)
            FieldDefRepo.bindNullableStr(st, 9, validationRule)
            FieldDefRepo.bindNullableStr(st, 10, defaultValue)
            st.set(11, operatorId)
            st.set(12, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 更新字段定义的可编辑属性（展示名 / 默认值 / 校验规则 / 顺序 / 必填）。
     *
     * 注意：**不允许改** field_key 与 data_type ——
     * 已落库的 arc_item_fields 按这两个维度存值，改动会导致历史值错配。
     */
    public func update(
        id: Int64,
        fieldName: String,
        displayOrder: Int64,
        validationRule: String,
        defaultValue: String,
        isRequired: Bool,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_field_defs SET field_name = ?, display_order = ?, " +
                  "validation_rule = ?::jsonb, default_value = ?, is_required = " +
                  FieldDefRepo.bl(isRequired) + ", " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL AND is_system = FALSE"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, fieldName)
            st.set(1, displayOrder)
            FieldDefRepo.bindNullableStr(st, 2, validationRule)
            FieldDefRepo.bindNullableStr(st, 3, defaultValue)
            st.set(4, operatorId)
            st.set(5, id)
            st.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 软删除（仅允许用户自建字段；is_system 的内置模板不可删）。
     */
    public func softDelete(id: Int64): Bool {
        let sql = "UPDATE arc_field_defs SET deleted_at = CURRENT_TIMESTAMP, " +
                  "updated_at = CURRENT_TIMESTAMP " +
                  "WHERE id = ? AND deleted_at IS NULL AND is_system = FALSE"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 内置模板已落库条数 —— 用于判断是否需要播种。
     */
    public func countBuiltin(): Int64 {
        let sql = "SELECT COUNT(*) AS cnt FROM arc_field_defs " +
                  "WHERE subject_id IS NULL AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            let rows = readRows(st.query())
            let all = rows.all()
            if (all.size == 0) {
                return 0
            }
            return all[0].i64("cnt")
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    // ------------------------------------------------------------

    /**
     * 布尔 → SQL 字面量（取值域固定为 TRUE/FALSE，无注入风险）。
     */
    private static func bl(v: Bool): String {
        if (v) {
            return "TRUE"
        }
        return "FALSE"
    }

    /**
     * 绑定可空字符串（空串按 NULL 处理）。
     *
     * 不复用 ItemRepo.bindStr —— 它是 ItemRepo 的 **private static** 成员，
     * 跨类调用在仓颉中不合法，故在此提供同语义的本地实现。
     */
    private static func bindNullableStr(st: Statement, index: Int, v: String): Unit {
        if (v.isEmpty()) {
            st.setNull(index)
        } else {
            st.set(index, v)
        }
    }

    private static func collect(rows: RowSet): ArrayList<FieldDefRecord> {
        let out = ArrayList<FieldDefRecord>()
        for (r in rows.all().iterator()) {
            out.add(FieldDefRepo.toRecord(r))
        }
        return out
    }

    private static func toRecord(r: RowData): FieldDefRecord {
        return FieldDefRecord(
            r.i64("id"),
            r.i64("subject_id"),
            r.i64("category"),
            r.str("field_key"),
            r.str("field_name"),
            r.i64("data_type"),
            r.i64("sensitivity"),
            r.bool("is_required"),
            r.bool("is_searchable"),
            r.bool("is_filterable"),
            r.bool("is_bidx_capable"),
            r.str("enum_dict_code"),
            r.i64("display_order"),
            r.str("validation_rule"),
            r.str("default_value"),
            r.bool("is_system"),
            r.i64("status")
        )
    }
}
