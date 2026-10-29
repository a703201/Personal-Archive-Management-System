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
 * 标签层级的最大深度（FR-TAG-005）。
 *
 * 为什么要封顶：层级是**自引用**结构，深度不受限时，前端递归渲染、
 * 级联删除、权限继承都会随深度线性/指数放大；而实际用途（大类→小类）
 * 三层足够。封顶把最坏情况变成常数。
 */
public const TAG_MAX_DEPTH: Int64 = 5

/**
 * 判断把 tagId 挂到 newParentId 下是否会形成环（**纯函数**，可单测）。
 *
 * 做法：从 newParentId 出发沿 parent 链上溯，途中若遇到 tagId 说明
 * 目标父节点已经在该标签的子树里 —— 挂上去就成环。
 * 步数上限取边数 + 1：正常链最长也就 N 步，超过必然是环（防御坏数据）。
 *
 * @param edges 全量 (标签 id, 父标签 id)；父为空用 0 表示
 */
public func tagMoveWouldCycle(edges: Array<(Int64, Int64)>, tagId: Int64, newParentId: Int64): Bool {
    var cur = newParentId
    var steps: Int64 = 0
    let limit = edges.size + 1
    while (cur > 0 && steps < limit) {
        if (cur == tagId) {
            return true
        }
        var next: Int64 = 0
        for ((id, pid) in edges) {
            if (id == cur) {
                next = pid
                break
            }
        }
        if (next == cur) {
            // 自引用（坏数据）：立即判定为环，避免死循环
            return true
        }
        cur = next
        steps = steps + 1
    }
    // 走到根仍未遇到自己；若步数超限（数据本身成环）也按环处理
    return steps >= limit
}

/**
 * 计算某标签的层级深度（顶层为 1，**纯函数**，可单测）。
 */
public func tagDepthOf(edges: Array<(Int64, Int64)>, tagId: Int64): Int64 {
    var cur = tagId
    var depth: Int64 = 1
    let limit = edges.size + 1
    while (cur > 0 && depth <= limit) {
        var next: Int64 = 0
        for ((id, pid) in edges) {
            if (id == cur) {
                next = pid
                break
            }
        }
        if (next == 0) {
            return depth
        }
        cur = next
        depth = depth + 1
    }
    return depth
}

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
                  "(EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms, " +
                  "(EXTRACT(EPOCH FROM last_used_at) * 1000)::bigint AS last_used_at_ms, version " +
                  "FROM arc_tags WHERE owner_id = ? AND deleted_at IS NULL " +
                  "ORDER BY usage_count DESC, id"
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

    /**
     * 取单个标签（限 owner）。
     */
    public func find(ownerId: Int64, tagId: Int64): Option<RowData> {
        let sql = "SELECT id, owner_id, name, name_norm, color, category, usage_count, parent_id, version " +
                  "FROM arc_tags WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, tagId)
            st.set(1, ownerId)
            let rs = readRows(st.query())
            return rs.first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
        }
    }

    /**
     * 软删除标签（限 owner）。
     *
     * 同时解除与条目的关联，避免条目上残留失效标签。
     */
    public func softDelete(ownerId: Int64, tagId: Int64, operatorId: Int64): Bool {
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
        }
    }

    /**
     * 合并标签（FR-TAG-003）。
     *
     * 把 source 的全部条目关联迁移到 target（已同时拥有两者的条目不重复插入，
     * 避免 uk_arc_item_tags 唯一冲突），随后软删除 source 并修正使用计数。
     *
     * @return 实际迁移的关联条数
     */
    public func merge(ownerId: Int64, sourceId: Int64, targetId: Int64, operatorId: Int64): Int64 {
        if (sourceId == targetId || sourceId <= 0 || targetId <= 0) {
            return 0
        }
        let c = this.db.connect()
        try {
            // ① 取出 source 的全部条目关联
            let sel = c.prepareStatement(
                "SELECT item_id FROM arc_item_tags WHERE tag_id = ?"
            )
            sel.set(0, sourceId)
            let srcRows = readRows(sel.query()).all()
            if (srcRows.size == 0) {
                // source 没有关联，直接软删标签即可
                this.softDelete(ownerId, sourceId, operatorId)
                return 0
            }
            // ② 取出 target 已有的条目关联（用于去重）
            let tex = c.prepareStatement(
                "SELECT item_id FROM arc_item_tags WHERE tag_id = ?"
            )
            tex.set(0, targetId)
            let have = HashSet<String>()
            for (r in readRows(tex.query()).all().iterator()) {
                have.add("${r.i64("item_id")}")
            }
            // ③ 逐条迁移：app 侧生成 id（Ids.next），跳过已存在的条目关联。
            //    注意：openGauss 没有 Ids.next() 之类的 SQL 函数，
            //    不能写 `SELECT Ids.next(), ...`（会 DATABASE_FAILURE）。
            var moved: Int64 = 0
            for (r in srcRows.iterator()) {
                let itemId = r.i64("item_id")
                let key = "${itemId}"
                if (have.contains(key)) {
                    continue
                }
                have.add(key)
                let ins = c.prepareStatement(
                    "INSERT INTO arc_item_tags (id, item_id, tag_id, created_at) " +
                    "VALUES (?, ?, ?, CURRENT_TIMESTAMP)"
                )
                ins.set(0, Ids.next())
                ins.set(1, itemId)
                ins.set(2, targetId)
                ins.update()
                moved = moved + 1
            }
            // ④ 删除 source 关联
            let del = c.prepareStatement("DELETE FROM arc_item_tags WHERE tag_id = ?")
            del.set(0, sourceId)
            del.update()
            // ⑤ 软删除 source 标签
            let up = c.prepareStatement(
                "UPDATE arc_tags SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP, " +
                "updated_by = ?, version = version + 1 " +
                "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
            )
            up.set(0, operatorId)
            up.set(1, sourceId)
            up.set(2, ownerId)
            up.update()
            // ⑥ 修正使用计数（target 增加，source 归零）
            if (moved > 0) {
                this.bumpUsage(targetId, moved)
            }
            return moved
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 标签使用统计（FR-TAG-004）。
     *
     * 一条 SQL 出聚合值，不在应用层逐行累加：标签量级是几十到几百，
     * 但把「总量 / 已用 / 未用 / 累计打标次数 / 最近使用时间」分五次查
     * 既慢又容易口径不一致（各查各的快照）。
     *
     * `MAX(last_used_at)` 自动忽略 NULL，未使用过的标签不会污染结果。
     */
    public func stats(ownerId: Int64): RowSet {
        let sql = "SELECT COUNT(*) AS total, " +
                  "COALESCE(SUM(usage_count), 0) AS total_usage, " +
                  "SUM(CASE WHEN usage_count > 0 THEN 1 ELSE 0 END) AS used, " +
                  "SUM(CASE WHEN usage_count = 0 THEN 1 ELSE 0 END) AS unused, " +
                  "MAX((EXTRACT(EPOCH FROM last_used_at) * 1000)::bigint) AS last_used_at_ms " +
                  "FROM arc_tags WHERE owner_id = ? AND deleted_at IS NULL"
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

    /**
     * 取该用户的全部「标签 → 父标签」边（含未删除的标签）。
     *
     * 移动标签前做环路检测需要它：一次查询拿到全量边，比逐层上溯
     * 每次发一条 SQL 便宜，也不会在递归里把连接耗尽。
     */
    public func parentEdges(ownerId: Int64): Array<(Int64, Int64)> {
        let sql = "SELECT id, COALESCE(parent_id, 0) AS pid FROM arc_tags " +
                  "WHERE owner_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            let rows = readRows(st.query())
            let out = ArrayList<(Int64, Int64)>()
            for (r in rows.all()) {
                out.add((r.i64("id"), r.i64("pid")))
            }
            return out.toArray()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 移动标签（FR-TAG-005）：把 tagId 挂到 newParentId 下，None 表示提升为顶层。
     *
     * 【为什么必须在写库前做环路检查】
     *   parent_id 是自引用列，`A→B→A` 会让「树」变成环，任何递归遍历
     *   （前端渲染、级联删除、权限继承）都会栈溢出或死循环。
     *   唯一索引只约束「同名同父」，管不了环，所以判定必须由应用层做。
     *
     * @throws AppError(ValidationFailed) 自引用 / 会形成环 / 超过最大层级
     */
    public func move(ownerId: Int64, tagId: Int64, newParentId: Option<Int64>): Bool {
        if (!this.find(ownerId, tagId).isSome()) {
            throw notFound("标签")
        }
        var pid: Int64 = 0
        match (newParentId) {
            case Some(v) => pid = v
            case None => pid = 0
        }
        if (pid == tagId) {
            throw AppError(AppErrorKind.ValidationFailed, "标签不能作为自己的父标签")
        }
        let edges = this.parentEdges(ownerId)
        if (pid > 0) {
            if (!this.find(ownerId, pid).isSome()) {
                throw notFound("父标签")
            }
            if (tagMoveWouldCycle(edges, tagId, pid)) {
                throw AppError(
                    AppErrorKind.ValidationFailed,
                    "会形成循环层级（该父标签已在自己的子层级中）"
                )
            }
            if (tagDepthOf(edges, pid) + 1 > TAG_MAX_DEPTH) {
                throw AppError(AppErrorKind.ValidationFailed, "标签层级最多 ${TAG_MAX_DEPTH} 层")
            }
        }
        let sql = "UPDATE arc_tags SET parent_id = ?, updated_at = CURRENT_TIMESTAMP, " +
                  "updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND owner_id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            match (newParentId) {
                case Some(v) => st.set(0, v)
                case None => st.setNull(0)
            }
            st.set(1, ownerId)
            st.set(2, tagId)
            st.set(3, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 给条目打标签。
     */
    public func attach(tagId: Int64, itemId: Int64): Bool {
        let sql = "INSERT INTO arc_item_tags (id, item_id, tag_id, created_at) " +
                  "VALUES (?, ?, ?, CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
        }
    }

    /**
     * 批量打标（FR-ARCH-013）：给多个条目打同一个标签。
     *
     * 【必须幂等】
     *   直接 INSERT 会让「已打过该标签的条目」重复入库，usage_count 跟着虚增，
     *   标签统计（FR-TAG-004）与热门标签就会失真。故先一次查出已存在的
     *   item_id 集合，只给缺的条目插入。
     *
     * @return 实际新增的关系数
     */
    public func attachMany(tagId: Int64, itemIds: Array<Int64>): Int64 {
        if (itemIds.isEmpty()) {
            return 0
        }
        let existing = HashSet<Int64>()
        let check = "SELECT item_id FROM arc_item_tags WHERE tag_id = ? AND item_id IN (" +
                    ItemRepo.placeholders(itemIds.size) + ")"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(check)
            st.set(0, tagId)
            var i: Int = 1
            for (id in itemIds) {
                st.set(i, id)
                i++
            }
            for (r in readRows(st.query()).all()) {
                existing.add(r.i64("item_id"))
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
        var added: Int64 = 0
        for (id in itemIds) {
            if (existing.contains(id)) {
                continue
            }
            let sql = "INSERT INTO arc_item_tags (id, item_id, tag_id, created_at) " +
                      "VALUES (?, ?, ?, CURRENT_TIMESTAMP)"
            let c2 = this.db.connect()
            try {
                let st = c2.prepareStatement(sql)
                st.set(0, Ids.next())
                st.set(1, id)
                st.set(2, tagId)
                st.update()
                this.bumpUsage(tagId, 1)
                added = added + 1
            } catch (e: Exception) {
                // 单条失败不影响其余条目（批量语义：部分成功）
            } finally {
                c2.close()
            }
        }
        return added
    }

    /**
     * 移除条目的标签。
     */
    public func detach(tagId: Int64, itemId: Int64): Bool {
        let sql = "DELETE FROM arc_item_tags WHERE item_id = ? AND tag_id = ?"
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
        }
    }

    /**
     * 取条目的标签列表。
     */
    public func listByItem(itemId: Int64): RowSet {
        let sql = "SELECT t.id, t.name, t.color, t.category, t.usage_count " +
                  "FROM arc_item_tags it JOIN arc_tags t ON t.id = it.tag_id " +
                  "WHERE it.item_id = ? AND t.deleted_at IS NULL ORDER BY t.name"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, itemId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 增减标签使用计数（下限 0）。
     */
    /**
     * 使用计数增减。
     *
     * 只在**增加**（打标）时刷新 `last_used_at`：它是「最后使用时间」，
     * 摘标签（delta < 0）不该把它推后 —— 否则「最近用过」的统计会被
     * 清理动作污染（FR-TAG-004 的口径）。
     */
    private func bumpUsage(tagId: Int64, delta: Int64): Unit {
        let sql = if (delta > 0) {
            "UPDATE arc_tags SET usage_count = GREATEST(0, usage_count + ?), " +
            "last_used_at = CURRENT_TIMESTAMP WHERE id = ?"
        } else {
            "UPDATE arc_tags SET usage_count = GREATEST(0, usage_count + ?) WHERE id = ?"
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, delta)
            st.set(1, tagId)
            st.update()
        } catch (e: Exception) {
            // 计数失败不影响主流程语义（标签关系已建立）
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 未读数量。
     */
    public func unreadCount(userId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM nft_messages " +
                  "WHERE user_id = ? AND is_read = FALSE " +
                  "AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 标记单条已读（限 user_id，防越权）。
     */
    public func markRead(userId: Int64, messageId: Int64): Bool {
        let sql = "UPDATE nft_messages SET is_read = TRUE, read_at = CURRENT_TIMESTAMP " +
                  "WHERE id = ? AND user_id = ? AND is_read = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, messageId)
            st.set(1, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 全部标记已读。
     */
    public func markAllRead(userId: Int64): Int64 {
        let sql = "UPDATE nft_messages SET is_read = TRUE, read_at = CURRENT_TIMESTAMP " +
                  "WHERE user_id = ? AND is_read = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 清理过期通知（后台任务调用）。
     */
    public func purgeExpired(): Int64 {
        let sql = "DELETE FROM nft_messages WHERE expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP"
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
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, scope)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, scope)
            st.set(1, key)
            let rs = readRows(st.query())
            return rs.first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
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
        //
        // 【参数下标 0-based】
        //   此处原本写成 1-based（q.set(1..2) / u.set(1..6) / ins.set(1..9)），
        //   与全仓其它仓库不一致，会抛 "index: N out of bounds"。
        //   之所以一直没暴露：本函数**此前零调用点** ——
        //   配置中心（FR-CFG-003）是它的第一个使用者。
        //   见 user.cj 里同样的踩坑注释。
        let c = this.db.connect()
        try {
            let q = c.prepareStatement(
                "SELECT id FROM cfg_settings WHERE scope = ? AND key = ? AND deleted_at IS NULL"
            )
            q.set(0, scope)
            q.set(1, key)
            let rs = readRows(q.query())
            match (rs.first()) {
                case Some(r) =>
                    let id = r.i64("id")
                    let u = c.prepareStatement(
                        "UPDATE cfg_settings SET value = ?, value_type = ?, is_secret = ?, " +
                        "description = ?, updated_at = CURRENT_TIMESTAMP, updated_by = ?, " +
                        "version = version + 1 WHERE id = ?"
                    )
                    u.set(0, value)
                    u.set(1, valueType)
                    u.set(2, isSecret)
                    u.set(3, description)
                    u.set(4, operatorId)
                    u.set(5, id)
                    u.update()
                case None =>
                    let ins = c.prepareStatement(
                        "INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, " +
                        "description, created_at, created_by, updated_at, updated_by) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
                    )
                    ins.set(0, Ids.next())
                    ins.set(1, scope)
                    ins.set(2, key)
                    ins.set(3, value)
                    ins.set(4, valueType)
                    ins.set(5, isSecret)
                    ins.set(6, description)
                    ins.set(7, operatorId)
                    ins.set(8, operatorId)
                    ins.update()
            }
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 删除参数（软删除）。
     */
    public func deleteSetting(scope: String, key: String, operatorId: Int64): Bool {
        let sql = "UPDATE cfg_settings SET deleted_at = CURRENT_TIMESTAMP, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE scope = ? AND key = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, scope)
            st.set(2, key)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出字典类型。
     */
    public func listDictTypes(): RowSet {
        let sql = "SELECT id, code, name, description, version " +
                  "FROM cfg_dict_types WHERE deleted_at IS NULL ORDER BY code"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, dictTypeCode)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 创建字典类型。
     */
    public func createDictType(code: String, name: String, description: String, operatorId: Int64): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO cfg_dict_types (id, code, name, description, created_at, created_by, " +
                  "updated_at, updated_by) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
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
        let c = this.db.connect()
        try {
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
        } finally {
            c.close()
        }
    }
}
