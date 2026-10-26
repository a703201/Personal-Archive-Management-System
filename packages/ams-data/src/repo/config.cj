// ============================================================
// ams.data.repo · 标签 / 通知 / 配置仓储
//
// 需求：
//   FR-TAG-001 标签 CRUD（个人标签、层级、颜色、使用计数）
//   FR-TAG-002 标签应用与移除（条目打标、热门标签）
//   FR-NTF-001 站内通知（列表、未读数、标记已读）
//   FR-CFG-004 字典与参数配置管理
//
// [安全约束]
//   ① 标签按 owner_id 隔离：任何查询/更新都必须带 owner 条件，
//      否则会出现跨用户数据泄漏（这是本模块最容易犯的错）。
//   ② is_secret 的配置项 value 不进列表接口，只返回脱敏标记。
//   ③ 全部 SQL 参数化。
//
// [分层约束]
//   返回 RowData（行数据），领域映射在 ams-app 完成。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 标签仓储。
 */
public class TagRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 列出某用户的标签（未删除），可按使用次数倒序。
     */
    public func list(ownerId: Int64): RowSet {
        let sql = "SELECT id, owner_id, name, name_norm, color, category, usage_count, parent_id, " +
                  "(EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms, version " +
                  "FROM arc_tags WHERE owner_id = ? AND deleted_at IS NULL " +
                  "ORDER BY usage_count DESC, id"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 取单个标签（限 owner）。
     */
    public func find(ownerId: Int64, tagId: Int64): Option<RowData> {
        let sql = "SELECT id, owner_id, name, name_norm, color, category, usage_count, parent_id, version " +
                  "FROM arc_tags WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, tagId)
            st.set(1, ownerId)
            let rs = readRows(st.query())
            return rs.first()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 创建标签。
     *
     * 同名同父标签由唯一索引 uk_arc_tags 拦截（依赖 DB 约束，
     * 不做「先查后插」的竞态检查）。
     */
    public func create(
        ownerId: Int64,
        name: String,
        nameNorm: String,
        color: Option<String>,
        category: Option<Int64>,
        parentId: Option<Int64>,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_tags (id, owner_id, name, name_norm, color, category, parent_id, " +
                  "created_at, created_by, updated_at, updated_by) " +
                  "VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            st.set(2, name)
            st.set(3, nameNorm)
            // 可空列必须传 NULL 而非空串：
            //   arc_tags 上有 UNIQUE 索引 (owner_id, name_norm, COALESCE(parent_id, 0))，
            //   空串 parent_id 会被当作真实值参与唯一性判定。
            match (color) {
                case Some(v) => st.set(4, v)
                case None => st.setNull(4)
            }
            match (category) {
                case Some(v) => st.set(5, v)
                case None => st.setNull(5)
            }
            match (parentId) {
                case Some(v) => st.set(6, v)
                case None => st.setNull(6)
            }
            st.set(7, operatorId)
            st.set(8, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 更新标签（限 owner）。
     */
    public func update(
        ownerId: Int64,
        tagId: Int64,
        name: String,
        nameNorm: String,
        color: Option<String>,
        category: Option<Int64>,
        operatorId: Int64
    ): Bool {
        let sql = "UPDATE arc_tags SET name = ?, name_norm = ?, color = ?, category = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, name)
            st.set(1, nameNorm)
            match (color) {
                case Some(v) => st.set(2, v)
                case None => st.setNull(2)
            }
            match (category) {
                case Some(v) => st.set(3, v)
                case None => st.setNull(3)
            }
            st.set(4, operatorId)
            st.set(5, tagId)
            st.set(6, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 软删除标签（限 owner）。
     *
     * 同时解除与条目的关联，避免条目上残留失效标签。
     */
    public func softDelete(ownerId: Int64, tagId: Int64, operatorId: Int64): Bool {
        try {
            let c = this.db.connect()
            let del = c.prepareStatement(
                "DELETE FROM arc_item_tags WHERE tag_id = ? AND item_id IN " +
                "(SELECT id FROM arc_items WHERE subject_id IN " +
                " (SELECT subject_id FROM arc_subjects WHERE owner_id = ?))"
            )
            del.set(1, tagId)
            del.set(2, ownerId)
            del.update()

            let sql = "UPDATE arc_tags SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP, " +
                      "updated_by = ?, version = version + 1 " +
                      "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, tagId)
            st.set(2, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 给条目打标签。
     */
    public func attach(tagId: Int64, itemId: Int64): Bool {
        let sql = "INSERT INTO arc_item_tags (id, item_id, tag_id, created_at) " +
                  "VALUES (?, ?, ?, CURRENT_TIMESTAMP)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, Ids.next())
            st.set(1, itemId)
            st.set(2, tagId)
            st.update()
            // 使用计数 +1
            this.bumpUsage(tagId, 1)
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 移除条目的标签。
     */
    public func detach(tagId: Int64, itemId: Int64): Bool {
        let sql = "DELETE FROM arc_item_tags WHERE item_id = ? AND tag_id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            st.set(1, tagId)
            let n = st.update().rowCount
            if (n > 0) {
                this.bumpUsage(tagId, -1)
            }
            return n > 0
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 取条目的标签列表。
     */
    public func listByItem(itemId: Int64): RowSet {
        let sql = "SELECT t.id, t.name, t.color, t.category, t.usage_count " +
                  "FROM arc_item_tags it JOIN arc_tags t ON t.id = it.tag_id " +
                  "WHERE it.item_id = ? AND t.deleted_at IS NULL ORDER BY t.name"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 增减标签使用计数（下限 0）。
     */
    private func bumpUsage(tagId: Int64, delta: Int64): Unit {
        let sql = "UPDATE arc_tags SET usage_count = GREATEST(0, usage_count + ?), " +
                  "last_used_at = CURRENT_TIMESTAMP WHERE id = ?"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, delta)
            st.set(1, tagId)
            st.update()
        } catch (e: Exception) {
            // 计数失败不影响主流程语义（标签关系已建立）
        }
    }
}

/**
 * 站内通知仓储。
 */
public class NotifyRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 发通知。
     */
    public func push(
        userId: Int64,
        category: Option<Int64>,
        title: String,
        body: String,
        link: Option<String>,
        priority: Int64,
        expiresAtMillis: Option<Int64>
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO nft_messages (id, user_id, category, title, body, link, priority, " +
                  "is_read, created_at, expires_at) " +
                  "VALUES (?, ?, ?, ?, ?, ?, ?, FALSE, CURRENT_TIMESTAMP, ?)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, userId)
            st.set(2, category ?? 0)
            st.set(3, title)
            st.set(4, body)
            match (link) {
                case Some(v) => st.set(5, v)
                case None => st.setNull(5)
            }
            st.set(6, priority)
            match (expiresAtMillis) {
                case Some(ms) =>
                    // 以 epoch 毫秒构造带时区的时刻串，交给 openGauss 解析
                    st.set(7, Times.toIso8601(ms))
                case None => st.setNull(7)
            }
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 列出用户通知（未读优先、时间倒序）。
     */
    public func list(userId: Int64, onlyUnread: Bool, offset: Int64, limit: Int64): RowSet {
        let lim = if (limit <= 0) { 20 } else if (limit > 100) { 100 } else { limit }
        let off = if (offset < 0) { 0 } else { offset }
        let base = "SELECT id, user_id, category, title, body, link, priority, is_read, " +
                   "(EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms " +
                   "FROM nft_messages WHERE user_id = ? AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)"
        let sql = if (onlyUnread) {
            "${base} AND is_read = FALSE ORDER BY priority DESC, created_at DESC LIMIT ${lim} OFFSET ${off}"
        } else {
            "${base} ORDER BY is_read ASC, priority DESC, created_at DESC LIMIT ${lim} OFFSET ${off}"
        }
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 未读数量。
     */
    public func unreadCount(userId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM nft_messages " +
                  "WHERE user_id = ? AND is_read = FALSE " +
                  "AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 标记单条已读（限 user_id，防越权）。
     */
    public func markRead(userId: Int64, messageId: Int64): Bool {
        let sql = "UPDATE nft_messages SET is_read = TRUE, read_at = CURRENT_TIMESTAMP " +
                  "WHERE id = ? AND user_id = ? AND is_read = FALSE"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, messageId)
            st.set(1, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 全部标记已读。
     */
    public func markAllRead(userId: Int64): Int64 {
        let sql = "UPDATE nft_messages SET is_read = TRUE, read_at = CURRENT_TIMESTAMP " +
                  "WHERE user_id = ? AND is_read = FALSE"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 清理过期通知（后台任务调用）。
     */
    public func purgeExpired(): Int64 {
        let sql = "DELETE FROM nft_messages WHERE expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }
}

/**
 * 配置仓储（字典 + 参数）。
 */
public class ConfigRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 列出参数配置。
     *
     * 安全：is_secret 的项**不返回 value**，只返回占位标记。
     */
    public func listSettings(scope: String): RowSet {
        let sql = "SELECT id, scope, key, value_type, is_secret, description, " +
                  "CASE WHEN is_secret = TRUE THEN '***' ELSE value END AS value, " +
                  "(EXTRACT(EPOCH FROM updated_at) * 1000)::bigint AS updated_at_ms, version " +
                  "FROM cfg_settings WHERE scope = ? AND deleted_at IS NULL ORDER BY key"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, scope)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 取单个参数值。
     *
     * 敏感项返回脱敏值（调用方需知道是否 secret）。
     */
    public func getSetting(scope: String, key: String): Option<RowData> {
        let sql = "SELECT id, scope, key, value_type, is_secret, " +
                  "CASE WHEN is_secret = TRUE THEN '***' ELSE value END AS value, version " +
                  "FROM cfg_settings WHERE scope = ? AND key = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, scope)
            st.set(1, key)
            let rs = readRows(st.query())
            return rs.first()
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 取参数值（非敏感，直接返回字符串）。
     */
    public func getValue(scope: String, key: String, defaultValue: String): String {
        match (this.getSetting(scope, key)) {
            case Some(r) => return r.str("value")
            case None => return defaultValue
        }
    }

    /**
     * 取参数值（整型）。
     */
    public func getInt(scope: String, key: String, defaultValue: Int64): Int64 {
        match (this.getSetting(scope, key)) {
            case Some(r) =>
                let v = r.str("value")
                if (v.isEmpty()) { return defaultValue }
                return RowData.toI64(v)
            case None => return defaultValue
        }
    }

    /**
     * 写入/更新参数（upsert 语义）。
     */
    public func setSetting(
        scope: String,
        key: String,
        value: String,
        valueType: String,
        isSecret: Bool,
        description: String,
        operatorId: Int64
    ): Bool {
        // openGauss 不支持 ON CONFLICT，用「先查后判 + 分支插入/更新」实现 upsert。
        // 唯一索引 uk_cfg_settings(scope, key) 保证并发下的最终一致。
        try {
            let c = this.db.connect()
            let q = c.prepareStatement(
                "SELECT id FROM cfg_settings WHERE scope = ? AND key = ? AND deleted_at IS NULL"
            )
            q.set(1, scope)
            q.set(2, key)
            let rs = readRows(q.query())
            match (rs.first()) {
                case Some(r) =>
                    let id = r.i64("id")
                    let u = c.prepareStatement(
                        "UPDATE cfg_settings SET value = ?, value_type = ?, is_secret = ?, " +
                        "description = ?, updated_at = CURRENT_TIMESTAMP, updated_by = ?, " +
                        "version = version + 1 WHERE id = ?"
                    )
                    u.set(1, value)
                    u.set(2, valueType)
                    u.set(3, isSecret)
                    u.set(4, description)
                    u.set(5, operatorId)
                    u.set(6, id)
                    u.update()
                case None =>
                    let ins = c.prepareStatement(
                        "INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, " +
                        "description, created_at, created_by, updated_at, updated_by) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
                    )
                    ins.set(1, Ids.next())
                    ins.set(2, scope)
                    ins.set(3, key)
                    ins.set(4, value)
                    ins.set(5, valueType)
                    ins.set(6, isSecret)
                    ins.set(7, description)
                    ins.set(8, operatorId)
                    ins.set(9, operatorId)
                    ins.update()
            }
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 删除参数（软删除）。
     */
    public func deleteSetting(scope: String, key: String, operatorId: Int64): Bool {
        let sql = "UPDATE cfg_settings SET deleted_at = CURRENT_TIMESTAMP, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE scope = ? AND key = ? AND deleted_at IS NULL"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, scope)
            st.set(2, key)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 列出字典类型。
     */
    public func listDictTypes(): RowSet {
        let sql = "SELECT id, code, name, description, version " +
                  "FROM cfg_dict_types WHERE deleted_at IS NULL ORDER BY code"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 列出某字典类型的字典项。
     */
    public func listDictItems(dictTypeCode: String): RowSet {
        let sql = "SELECT i.id, i.dict_type_id, i.code, i.label, i.sort_order, i.is_enabled " +
                  "FROM cfg_dict_items i JOIN cfg_dict_types t ON t.id = i.dict_type_id " +
                  "WHERE t.code = ? AND t.deleted_at IS NULL " +
                  "ORDER BY i.sort_order, i.code"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, dictTypeCode)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 创建字典类型。
     */
    public func createDictType(code: String, name: String, description: String, operatorId: Int64): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO cfg_dict_types (id, code, name, description, created_at, created_by, " +
                  "updated_at, updated_by) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, code)
            st.set(2, name)
            st.set(3, description)
            st.set(4, operatorId)
            st.set(5, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }

    /**
     * 新增字典项。
     */
    public func createDictItem(
        dictTypeId: Int64,
        code: String,
        label: String,
        sortOrder: Int64,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO cfg_dict_items (id, dict_type_id, code, label, sort_order, is_enabled, " +
                  "created_at, created_by, updated_at, updated_by) " +
                  "VALUES (?, ?, ?, ?, ?, TRUE, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        try {
            let c = this.db.connect()
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, dictTypeId)
            st.set(2, code)
            st.set(3, label)
            st.set(4, sortOrder)
            st.set(5, operatorId)
            st.set(6, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        }
    }
}
