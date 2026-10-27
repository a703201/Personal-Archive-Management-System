// ============================================================
// ams.data.repo.item · 档案条目仓储
//
// 职责（FR-ARCH-001 ~ FR-ARCH-008）：
//   - 条目 CRUD（按 subject_id + category + status 索引查询）
//   - 状态流转落库（draft → active → archived → deleted）
//   - 乐观锁（version 递增 + 冲突检测）
//   - 软删除与回收站（deleted_at + 恢复）
//   - 扩展字段（extra JSONB + arc_item_fields 明细）
//
// 设计要点：
//   ① **归属强制**：所有查询都带 subject_id 条件，且 subject_id 由服务端
//      传入（FR-ACL-006：禁止由前端传参决定归属）。
//   ② **状态流转与乐观锁在同一事务语义内**：更新时带 version 条件，
//      影响行数为 0 即判定为冲突（FR-ARCH-007）。
//   ③ 时间戳由数据库换算（EXTRACT(EPOCH ...)），不在应用层解析 TIMESTAMPTZ。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*

/**
 * SQL 参数。
 *
 * 驱动（opengauss-driver）的 `Statement.set<T>` 是**泛型**的，
 * 只接受 String / Int64 / Bool / 各类数值等具体类型 ——
 * 传 `Any` 或 `Option<String>` 会抛
 * "SqlException: not supported type"（实测）。
 * 故这里用枚举把参数类型显式化，bind 时再分派。
 *
 * 注意：驱动的参数索引是 **0-based**。
 */
public enum SqlParam {
    /** 字符串（可空：空串按 NULL 处理） */
    | Str(String)
    /** 64 位整数 */
    | Num(Int64)
    /** 显式 NULL */
    | Nul
}

/**
 * 条目记录（仓储层的轻量视图）。
 *
 * 与 ams.core 的 ArchiveItem 分离：仓储层只关心「数据库里是什么」，
 * 领域模型的转换由 ams-app 的应用服务负责（分层纪律）。
 */
public class ItemRecord {
    public let id: String
    public let subjectId: String
    public let category: Int64
    public let title: String
    public let status: Int64
    public let sensitivity: Int64
    public let issuedDate: String
    public let expiresAt: String
    public let issuer: String
    public let remark: String
    public let extraJson: String
    public let version: Int64
    public let createdAt: Int64
    public let updatedAt: Int64
    public let deletedAt: Int64

    public init(
        id: String,
        subjectId: String,
        category: Int64,
        title: String,
        status: Int64,
        sensitivity: Int64,
        issuedDate: String,
        expiresAt: String,
        issuer: String,
        remark: String,
        extraJson: String,
        version: Int64,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64
    ) {
        this.id = id
        this.subjectId = subjectId
        this.category = category
        this.title = title
        this.status = status
        this.sensitivity = sensitivity
        this.issuedDate = issuedDate
        this.expiresAt = expiresAt
        this.issuer = issuer
        this.remark = remark
        this.extraJson = extraJson
        this.version = version
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.deletedAt = deletedAt
    }
}

/**
 * 条目仓储。
 */
public class ItemRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 按 ID 查条目（不含已删除）。
     *
     * @param subjectIds 可访问的主体 ID 集合（**服务端算出**，FR-ACL-006）
     */
    public func findById(id: Int64, subjectIds: Array<String>): Option<ItemRecord> {
        if (subjectIds.isEmpty()) {
            return None
        }
        let sql = "SELECT id, subject_id, category, title, status, sensitivity, " +
                  "issued_date, expires_at, issuer, remark, extra::text AS extra, " +
                  "version, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM deleted_at) * 1000, 0) AS BIGINT) AS deleted_ms " +
                  "FROM arc_items WHERE id = ? AND deleted_at IS NULL " +
                  "AND subject_id IN (" + ItemRepo.placeholders(subjectIds.size) + ")"
        let params = ArrayList<SqlParam>()
        params.add(SqlParam.Num(id))
        for (s in subjectIds) {
            params.add(SqlParam.Str(s))
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            ItemRepo.bind(st, params)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return Some(ItemRepo.toRecord(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按 ID 查条目（**不过滤归属**）。
     *
     * ⚠️ 这个方法**只能**用在已完成资源级鉴权之后：
     *   ① 鉴权中间件的 guard 用它构造 AuthzResource —— 归属判定由
     *      Authorizer 负责（它会检查「可访问主体集合」**和**「显式授权」）；
     *   ② handler 在 guard 通过后再用它取数据。
     *
     * 【为什么需要这个方法】
     *   若在 guard 阶段就按归属过滤，被**显式授权**（acl_grants）的用户
     *   根本查不到条目 → guard 返回 None → 跳过判定 → 404，
     *   于是 FR-ACL-008（单条目/单分类临时授权）端到端**不通**。
     *
     *   安全性由 Authorizer 保证：拒绝时统一 403，不区分「不存在」与「无权限」。
     */
    public func findByIdRaw(id: Int64): Option<ItemRecord> {
        let sql = "SELECT id, subject_id, category, title, status, sensitivity, " +
                  "issued_date, expires_at, issuer, remark, extra::text AS extra, " +
                  "version, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM deleted_at) * 1000, 0) AS BIGINT) AS deleted_ms " +
                  "FROM arc_items WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return Some(ItemRepo.toRecord(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出条目（按归属过滤）。
     *
     * @param subjectIds  可访问的主体 ID
     * @param category    分类码（0 = 不限）
     * @param status      状态（-1 = 不限）
     * @param keyword     标题关键字（空 = 不限）
     * @param limit       每页条数
     * @param offset      偏移
     */
    public func list(
        subjectIds: Array<String>,
        category: Int64,
        status: Int64,
        keyword: String,
        limit: Int64,
        offset: Int64
    ): RowSet {
        if (subjectIds.isEmpty()) {
            return RowSet()
        }
        var sql = "SELECT id, subject_id, category, title, status, sensitivity, " +
                  "issued_date, expires_at, issuer, remark, extra::text AS extra, " +
                  "version, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM deleted_at) * 1000, 0) AS BIGINT) AS deleted_ms " +
                  "FROM arc_items WHERE deleted_at IS NULL " +
                  "AND subject_id IN (" + ItemRepo.placeholders(subjectIds.size) + ")"
        let params = ArrayList<SqlParam>()
        for (s in subjectIds) {
            params.add(SqlParam.Str(s))
        }
        if (category > 0) {
            sql += " AND category = ?"
            params.add(SqlParam.Num(category))
        }
        if (status >= 0) {
            sql += " AND status = ?"
            params.add(SqlParam.Num(status))
        }
        if (!keyword.isEmpty()) {
            sql += " AND (title ILIKE ? OR remark ILIKE ?)"
            params.add(SqlParam.Str("%${keyword}%"))
            params.add(SqlParam.Str("%${keyword}%"))
        }
        sql += " ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?"
        params.add(SqlParam.Num(limit))
        params.add(SqlParam.Num(offset))
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            ItemRepo.bind(st, params)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计条目数（分页用）。
     */
    public func count(
        subjectIds: Array<String>,
        category: Int64,
        status: Int64,
        keyword: String
    ): Int64 {
        if (subjectIds.isEmpty()) {
            return 0
        }
        var sql = "SELECT COUNT(*) AS n FROM arc_items WHERE deleted_at IS NULL " +
                  "AND subject_id IN (" + ItemRepo.placeholders(subjectIds.size) + ")"
        let params = ArrayList<SqlParam>()
        for (s in subjectIds) {
            params.add(SqlParam.Str(s))
        }
        if (category > 0) {
            sql += " AND category = ?"
            params.add(SqlParam.Num(category))
        }
        if (status >= 0) {
            sql += " AND status = ?"
            params.add(SqlParam.Num(status))
        }
        if (!keyword.isEmpty()) {
            sql += " AND (title ILIKE ? OR remark ILIKE ?)"
            params.add(SqlParam.Str("%${keyword}%"))
            params.add(SqlParam.Str("%${keyword}%"))
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            ItemRepo.bind(st, params)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("n")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 创建条目。
     *
     * @param extraJson 扩展字段（JSON 字符串）
     * @return 新条目 ID
     */
    public func create(
        subjectId: Int64,
        category: Int64,
        title: String,
        status: Int64,
        sensitivity: Int64,
        issuedDate: String,
        expiresAt: String,
        issuer: String,
        remark: String,
        extraJson: String,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_items (" +
                  "id, subject_id, category, title, title_norm, status, sensitivity, " +
                  "issued_date, expires_at, issuer, remark, extra, source, " +
                  "created_at, created_by, updated_at, updated_by, version" +
                  ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, 0, " +
                  "CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?, 1)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, subjectId)
            st.set(2, category)
            st.set(3, title)
            st.set(4, title)
            st.set(5, status)
            st.set(6, sensitivity)
            ItemRepo.bindStr(st, 7, issuedDate)
            ItemRepo.bindStr(st, 8, expiresAt)
            ItemRepo.bindStr(st, 9, issuer)
            ItemRepo.bindStr(st, 10, remark)
            st.set(11, extraJson)
            st.set(12, operatorId)
            st.set(13, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新条目（**带乐观锁**）。
     *
     * @param expectedVersion 期望的版本号；不匹配则不更新（返回 false = 冲突）
     * @return 是否更新成功（false = 版本冲突或记录不存在）
     */
    public func update(
        id: Int64,
        expectedVersion: Int64,
        subjectId: Int64,
        title: String,
        sensitivity: Int64,
        issuedDate: String,
        expiresAt: String,
        issuer: String,
        remark: String,
        extraJson: String,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_items SET title = ?, title_norm = ?, sensitivity = ?, " +
                  "issued_date = ?, expires_at = ?, issuer = ?, remark = ?, extra = ?::jsonb, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND version = ? AND deleted_at IS NULL AND subject_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, title)
            st.set(1, title)
            st.set(2, sensitivity)
            ItemRepo.bindStr(st, 3, issuedDate)
            ItemRepo.bindStr(st, 4, expiresAt)
            ItemRepo.bindStr(st, 5, issuer)
            ItemRepo.bindStr(st, 6, remark)
            st.set(7, extraJson)
            st.set(8, operatorId)
            st.set(9, id)
            st.set(10, expectedVersion)
            st.set(11, subjectId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 状态流转（带乐观锁）。
     *
     * @param toStatus 目标状态
     * @return true = 成功；false = 版本冲突
     */
    public func transition(
        id: Int64,
        expectedVersion: Int64,
        toStatus: Int64,
        subjectId: Int64,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_items SET status = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND version = ? AND deleted_at IS NULL AND subject_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, toStatus)
            st.set(1, operatorId)
            st.set(2, id)
            st.set(3, expectedVersion)
            st.set(4, subjectId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除（进回收站，保留 30 天）。
     */
    public func softDelete(
        id: Int64,
        expectedVersion: Int64,
        subjectId: Int64,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_items SET status = ?, deleted_at = CURRENT_TIMESTAMP, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND version = ? AND deleted_at IS NULL AND subject_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, 3)   // ItemStatus.Deleted
            st.set(1, operatorId)
            st.set(2, id)
            st.set(3, expectedVersion)
            st.set(4, subjectId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 从回收站恢复（恢复到 active）。
     */
    public func restore(
        id: Int64,
        subjectId: Int64,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_items SET status = 1, deleted_at = NULL, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NOT NULL AND subject_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, id)
            st.set(2, subjectId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 从回收站恢复（按**可访问主体集合**定位归属）。
     *
     * 已删除的条目不在 findById 的结果里（那里过滤了 deleted_at IS NULL），
     * 故恢复时用 IN (...) 表达归属条件。
     */
    public func restoreAny(
        id: Int64,
        subjectIds: Array<String>,
        operatorId: Int64
    ): Bool {
        if (subjectIds.isEmpty()) {
            return false
        }
        let sql = "UPDATE arc_items SET status = 1, deleted_at = NULL, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NOT NULL " +
                  "AND subject_id IN (" + ItemRepo.placeholders(subjectIds.size) + ")"
        let params = ArrayList<SqlParam>()
        params.add(SqlParam.Num(operatorId))
        params.add(SqlParam.Num(id))
        for (s in subjectIds) {
            params.add(SqlParam.Str(s))
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            ItemRepo.bind(st, params)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出回收站条目（已删除且未过期）。
     */
    public func listRecycleBin(subjectIds: Array<String>): RowSet {
        if (subjectIds.isEmpty()) {
            return RowSet()
        }
        let sql = "SELECT id, subject_id, category, title, status, sensitivity, " +
                  "issued_date, expires_at, issuer, remark, extra::text AS extra, " +
                  "version, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM updated_at) * 1000, 0) AS BIGINT) AS updated_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM deleted_at) * 1000, 0) AS BIGINT) AS deleted_ms " +
                  "FROM arc_items WHERE deleted_at IS NOT NULL " +
                  "AND deleted_at > CURRENT_TIMESTAMP - INTERVAL '30 days' " +
                  "AND subject_id IN (" + ItemRepo.placeholders(subjectIds.size) + ") " +
                  "ORDER BY deleted_at DESC"
        let params = ArrayList<SqlParam>()
        for (s in subjectIds) {
            params.add(SqlParam.Str(s))
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            ItemRepo.bind(st, params)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 物理清理过期条目（回收站超 30 天）。
     *
     * FR-ARCH-008：到期物理清理。由调度器调用。
     * @return 清理条数
     */
    public func purgeExpired(): Int64 {
        let sql = "DELETE FROM arc_items " +
                  "WHERE deleted_at IS NOT NULL AND deleted_at <= CURRENT_TIMESTAMP - INTERVAL '30 days'"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 找出「**恰好**在 days 天后到期」的条目（FR-NTF-002 到期提醒）。
     *
     * 为什么用**精确日期匹配**（= CURRENT_DATE + N）而不是区间（<= +N）：
     *   区间扫描会让同一条目在接下来的每一天都被扫出来 → 每天重复推送。
     *   精确匹配 + 每日执行一次，天然做到「每个里程碑只提醒一次」
     *   （30 天 / 7 天 / 1 天前各一次），无需额外的「已提醒」去重表。
     *
     * JOIN arc_subjects 取 owner_id —— 站内通知按“用户”寻址，
     * 而条目是按“主体”归属的，二者通过主体的拥有者关联。
     *
     * @param days 到期前的天数（0 表示今天到期）
     * @return 行：id / subject_id / title / expires_at / owner_id
     */
    public func listExpiringOn(days: Int64): RowSet {
        let sql = "SELECT i.id, i.subject_id, i.title, " +
                  "TO_CHAR(i.expires_at, 'YYYY-MM-DD') AS expires_date, " +
                  "COALESCE(s.owner_id, 0) AS owner_id " +
                  "FROM arc_items i " +
                  "JOIN arc_subjects s ON s.id = i.subject_id AND s.deleted_at IS NULL " +
                  "WHERE i.deleted_at IS NULL " +
                  "AND i.expires_at = CURRENT_DATE + CAST(? AS INTEGER) " +
                  "ORDER BY i.expires_at, i.id"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, days)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 调整条目的附件计数（FR-SRC-003 / 检索排序依赖）。
     *
     * 此前附件上传后**从不更新** arc_items.attachment_count，
     * 导致「按附件数排序/筛选」永远拿到 0。这里在上传落库后 +1。
     * 用原子 UPDATE 自增，避免并发下的读改写竞态。
     */
    public func bumpAttachmentCount(itemId: Int64, delta: Int64): Unit {
        let sql = "UPDATE arc_items SET attachment_count = attachment_count + ? " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, delta)
            st.set(1, itemId)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ---- 内部工具 ----

    /**
     * 行记录 → ItemRecord。
     */
    private static func toRecord(r: RowData): ItemRecord {
        return ItemRecord(
            "${r.i64("id")}",
            "${r.i64("subject_id")}",
            r.i64("category"),
            r.str("title"),
            r.i64("status"),
            r.i64("sensitivity"),
            r.getOpt("issued_date") ?? "",
            r.getOpt("expires_at") ?? "",
            r.getOpt("issuer") ?? "",
            r.getOpt("remark") ?? "",
            r.str("extra"),
            r.i64("version"),
            r.i64("created_ms"),
            r.i64("updated_ms"),
            r.i64("deleted_ms")
        )
    }

    /**
     * 生成 IN 子句的占位符（?, ?, ...）。
     */
    private static func placeholders(n: Int64): String {
        if (n <= 0) {
            return "NULL"
        }
        let sb = StringBuilder()
        for (i in 0..n) {
            if (i > 0) {
                sb.append(", ")
            }
            sb.append("?")
        }
        return sb.toString()
    }

    /**
     * 绑定参数。
     *
     * ⚠️ 驱动的参数索引是 **0-based**（实测：1-based 会报
     *    "index: N out of bounds: N"）。
     */
    private static func bind(st: Statement, params: ArrayList<SqlParam>): Unit {
        var i: Int = 0
        for (p in params.iterator()) {
            ItemRepo.bindOne(st, i, p)
            i++
        }
    }

    /**
     * 绑定单个参数（按类型分派）。
     *
     * 抽成独立方法的原因：仓颉的 match 分支**必须是单个表达式**，
     * 不能写 { 多行语句 }。
     */
    private static func bindOne(st: Statement, index: Int, p: SqlParam): Unit {
        match (p) {
            case SqlParam.Str(v) => ItemRepo.bindStr(st, index, v)
            case SqlParam.Num(v) => st.set(index, v)
            case SqlParam.Nul => st.setNull(index)
        }
    }

    /**
     * 绑定字符串（空串按 NULL 处理）。
     */
    private static func bindStr(st: Statement, index: Int, v: String): Unit {
        if (v.isEmpty()) {
            st.setNull(index)
        } else {
            st.set(index, v)
        }
    }

}
